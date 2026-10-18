(* Monitor engine v1 (doc/contracts/monitor_isa_v1.md sections 1, 1a, 6, 7, 8): two
   time-multiplexed lanes (Mon_lane), a ROM package library selected per lane, a loadable
   store per lane (user decision 2026-10-18) with context registers, host remap registers, the
   verdict block and the blame outputs to the lanes.

   Register window 0x40-0x7F (interface v1.1 draft):
     0x40 VERDICT   R  bit0 fail, bit1 blame, bit2 first-blame lane, bit3 first-fail lane,
                       bit4/5 overrun seen L0/L1 (T8 violated), bit6/7 fetch late L0/L1 (sticky)
     0x41 FIRST_FAIL  R cause code      0x42 FIRST_BLAME R cause code
     0x43 FIRST_UNITS R first-fail unit [2:0], first-blame unit [6:4]
     0x44-0x47 FAIL_TIME, 0x48-0x4B BLAME_TIME  R  step cycle (32-bit, wraps), LSB first
     0x50 + 8L  PKG        R/W ctx  bit7 monitor enable, [3:0] ROM library index
       +1 LOAD_UNITS R/W ctx  bit0/1: units 6/7 run from the loadable store (loadable mode if
                              either is set: units 0-5 idle, context from the context
                              registers); write bit7 = 1: load the context header
                              R: bit5 ctx_loaded, bit6 loading
       +2 LOAD_CTX   R/W ctx  word address of the 56-word context header
       +4 LSTORE_ADDR R/W ctx store word address (auto-increments after each word)
       +5 LSTORE_DATA W,P ctx low byte, then high byte; the word is written at LSTORE_ADDR
     0x60 + 16L + i REMAP R/W ctx local observable i -> global source [5:0]
   "ctx": accepted only while lane L is halted, its slot sequencer is idle and no context load
   is in progress. Any accepted ctx write except the LOAD strobe clears ctx_loaded.
   Admission (exported for the core): a lane with the monitor enabled may run only if
   P >= min_p (7; 13 in loadable mode with both units 6 and 7) and, in loadable mode,
   ctx_loaded.
   Verdict clearing: CTRL.CLR_VERDICT (caller passes [clr_verdict]); a firing recorded in the
   same cycle survives the clear [choice]. *)
open! Core
open Hardcaml
open Signal
module S = Mon_spec
module M = Mprog

(* What lane L's monitor observes (user decision 2026-10-18: mask by OWN). The caller
   passes lane L's own outputs restricted to its owned pins, and a uo_out view holding only
   lane L's xo bits, so the monitor of lane L has no on-chip path from the other lane.
   Pad inputs (ui_in, uio_in) are shared and external. *)
type lane_view =
  { running : Signal.t (* lane running (ISA v1.0.2), already gated by reset *)
  ; tick : Signal.t
  ; uo_out : Signal.t
  ; uio_out : Signal.t
  ; uio_oe : Signal.t
  ; pop_ev : Signal.t
  ; pop_data : Signal.t
  ; push_ev : Signal.t
  ; push_data : Signal.t
  }

type host =
  { wr : Signal.t
  ; addr : Signal.t (* 7 *)
  ; wdata : Signal.t (* 8 *)
  ; clr_verdict : Signal.t
  }

(* one 256x16 store per lane; [store l port] returns A_DOUT (registered in the macro) *)
type store_port =
  { addr : Signal.t
  ; din : Signal.t
  ; wen : Signal.t
  ; ren : Signal.t
  }

type firing =
  { fire : Signal.t
  ; unit_ : Signal.t
  ; role : Signal.t
  ; code : Signal.t
  ; stamp : Signal.t (* step cycle *)
  }

type t =
  { read : Signal.t -> Signal.t (* address in 0x40-0x7F -> data; 0 elsewhere *)
  ; fail : Signal.t
  ; blame : Signal.t
  ; blame_to_lane : Signal.t array (* registered *)
  ; pkg_en : Signal.t array (* lane L has the monitor enabled (admission applies) *)
  ; min_p : Signal.t array (* 16 bits *)
  ; ready : Signal.t array (* ROM mode, or loadable mode with the context loaded *)
  ; firings : firing array (* per lane, for tests *)
  }

let is_port a = (a ==:. 0x55) |: (a ==:. 0x5D)

(* mux over the library; a one-package library needs no select *)
let lmux_idx idx = function
  | [ x ] -> x
  | l -> mux idx l
;;

(* ---- package library tables, selected by a 4-bit index ---- *)
let lib_tables (lib : M.t list) ~idx ~remap : S.tables * Signal.t array =
  let tabs = List.map lib ~f:S.tables_of_package in
  let n = List.length lib in
  if n = 0 then raise_s [%message "empty package library"];
  let pick f = lmux_idx idx (List.map tabs ~f) in
  let arr len f = Array.init len ~f:(fun k -> pick (fun (t : S.tables) -> f t k)) in
  let in_lib = idx <:. n in
  let tables : S.tables =
    { remap
    ; preds = arr 16 (fun t k -> t.preds.(k))
    ; windows = arr 8 (fun t k -> t.windows.(k))
    ; code_role = arr 16 (fun t k -> t.code_role.(k))
    ; code_val = arr 16 (fun t k -> t.code_val.(k))
    ; starts = arr S.n_units (fun t k -> t.starts.(k))
    ; guards =
        Array.init S.n_units ~f:(fun k ->
          let g f = pick (fun (t : S.tables) -> f t.guards.(k)) in
          ( g (fun (a, _, _, _, _) -> a), g (fun (_, b, _, _, _) -> b), g (fun (_, _, c, _, _) -> c)
          , g (fun (_, _, _, d, _) -> d), g (fun (_, _, _, _, e) -> e) ))
    ; present = Array.create ~len:S.n_units true (* not used by Mon_lane *)
    }
  in
  let present =
    Array.init S.n_units ~f:(fun k ->
      in_lib
      &: lmux_idx idx (List.map lib ~f:(fun p -> if k < Array.length p.units then vdd else gnd)))
  in
  tables, present
;;

(* instruction ROM: (package, unit, pc) -> 82-bit word; zero outside a program *)
let lib_fetch (lib : M.t list) ~idx u pc =
  let per_pkg (p : M.t) =
    mux u
      (List.init S.n_units ~f:(fun k ->
         if k >= Array.length p.units
         then zero M.instr_width
         else (
           let code = p.units.(k).code in
           let n = Array.length code in
           let aw = Int.max 1 (Int.ceil_log2 n) in
           let words =
             List.init (1 lsl aw) ~f:(fun a ->
               if a < n then S.bits_of_list (M.encode_instr code.(a)) else zero M.instr_width)
           in
           mux2 (pc <:. n) (mux (select pc (aw - 1) 0) words) (zero M.instr_width))))
  in
  lmux_idx idx (List.map lib ~f:per_pkg)
;;

(* IR fetcher of one lane's loadable units 6 and 7 (section 7). [pcs]: effective pc of each
   unit (Mon_lane pc6/pc7); [pbases]: program base addresses; [dout]: store A_DOUT.
   [en] = the lane runs or slots of its last step are pending: a lane can halt just after a
   tick, and slots 6/7 of that step still need their instruction (a fetch gated by running
   alone was aborted there; found while writing the F1 proof). While enabled in loadable
   mode it keeps IR_u = store[base_u + 6 pc_u .. + 5]; a fetch starts in
   the cycle the mismatch appears (word 0 issued then), one read per cycle, data captured one
   cycle later. Formal: formal/src/mon_fetch.ml (F1). *)
type fetch_out =
  { irv : Signal.t array
  ; ir_pc : Signal.t array
  ; ir_word : int -> Signal.t
  ; ir_words : Signal.t array array
  ; issue : Signal.t
  ; f_addr : Signal.t
  ; f_busy : Signal.t (* internals, for proofs *)
  ; f_u : Signal.t
  ; f_pc : Signal.t
  ; f_k : Signal.t
  ; fcap : Signal.t
  ; fcap_u : Signal.t
  ; fcap_k : Signal.t
  ; fcap_pc : Signal.t
  }

(* [bug] (negative controls only): `Restart_on_complete = a completing fetch sees the stale
   valid bit (the defect found in the first end-to-end run). *)
let fetcher ?bug ~spec ~nspec ~l ~en ~ld_mode ~lu ~pcs ~pbases ~dout () =
  let running = en in
  let pc6 = pcs.(0)
  and pc7 = pcs.(1) in
  let ir = Array.init 2 ~f:(fun _ -> Array.init 6 ~f:(fun _ -> wire 16)) in
  let irv = Array.init 2 ~f:(fun _ -> wire 1)
  and ir_pc = Array.init 2 ~f:(fun _ -> wire 7) in
  let f_busy_d = wire 1 in
  let f_busy = reg spec f_busy_d -- sprintf "mon_f_busy%d" l in
  let f_u_d = wire 1 and f_pc_d = wire 7 and f_k_d = wire 3 in
  let f_u = reg spec f_u_d -- sprintf "mon_f_u%d" l
  and f_pc = reg spec f_pc_d -- sprintf "mon_f_pc%d" l
  and f_k = reg spec f_k_d -- sprintf "mon_f_k%d" l in
  let fcap = wire 1 and fcap_u = wire 1 and fcap_pc = wire 7 and fcap_k = wire 3 in
  (* IR state as it will be after this cycle's capture: a fetch completing now (word 5
     captured) counts as valid, so it does not restart itself *)
  let want u =
    let completing = fcap &: (fcap_u ==:. u) &: (fcap_k ==:. 5) in
    let completing = match bug with Some `Restart_on_complete -> gnd | _ -> completing in
    let valid = irv.(u) |: completing
    and at = mux2 completing fcap_pc ir_pc.(u) in
    running &: ld_mode &: bit lu u &: ~:(valid &: (at ==: pcs.(u)))
  in
  (* a fetch starts combinationally in the cycle the mismatch is seen (word 0 issued then) *)
  let start_f = ~:f_busy &: (want 0 |: want 1) in
  let su = mux2 (want 0) gnd vdd in
  let iss_u = mux2 f_busy f_u su
  and iss_pc = mux2 f_busy f_pc (mux2 su pc7 pc6)
  and iss_k = mux2 f_busy f_k (zero 3) in
  let issue = (f_busy |: start_f) &: running in
  let last = iss_k ==:. 5 in
  f_busy_d <== (issue &: ~:last);
  f_u_d <== iss_u;
  f_pc_d <== iss_pc;
  f_k_d <== mux2 issue (iss_k +:. 1) f_k;
  let six_pc = let x = uresize iss_pc 8 in sll x 2 +: sll x 1 in
  let f_addr =
    mux2 iss_u pbases.(1) pbases.(0) +: six_pc
    +: uresize (match bug with Some `Addr_off_by_one -> iss_k +:. 1 | _ -> iss_k) 8
  in
  fcap <== reg spec issue -- sprintf "mon_f_cap%d" l;
  fcap_u <== reg spec iss_u -- sprintf "mon_f_cap_u%d" l;
  fcap_k <== reg spec iss_k -- sprintf "mon_f_cap_k%d" l;
  fcap_pc <== reg spec iss_pc -- sprintf "mon_f_cap_pc%d" l;
  Array.iteri ir ~f:(fun u words ->
    let mine = fcap &: (fcap_u ==:. u) in
    Array.iteri words ~f:(fun w d ->
      d <== reg nspec ~enable:(mine &: (fcap_k ==:. w)) dout -- sprintf "mon_ir%d_u%d_w%d" l (6 + u) w);
    (* valid: cleared when a fetch for u starts or the lane stops; set by the last word *)
    let starts_u = issue &: (iss_k ==:. 0) &: (iss_u ==:. u) in
    let v_d = wire 1 in
    let vq = reg spec v_d -- sprintf "mon_irv%d_u%d" l (6 + u) in
    v_d <== mux2 (~:(running) |: starts_u) gnd (mux2 (mine &: (fcap_k ==:. 5)) vdd vq);
    irv.(u) <== vq;
    ir_pc.(u) <== reg spec ~enable:(mine &: (fcap_k ==:. 5)) fcap_pc -- sprintf "mon_ir_pc%d_u%d" l (6 + u));
  { irv
  ; ir_pc
  ; ir_word = (fun u -> select (concat_lsb (Array.to_list ir.(u))) (M.instr_width - 1) 0)
  ; ir_words = ir
  ; issue
  ; f_addr
  ; f_busy
  ; f_u
  ; f_pc
  ; f_k
  ; fcap
  ; fcap_u
  ; fcap_k
  ; fcap_pc
  }
;;

(* behavioural 256x16 store for engine-level simulation (single port, synchronous read,
   write has priority; DOUT holds otherwise; read-during-write returns the new word) *)
let behavioural_store ~clock (p : store_port) =
  let spec = Reg_spec.create ~clock () in
  let words =
    Array.init 256 ~f:(fun a ->
      let q = wire 16 in
      let r = reg spec (mux2 (p.wen &: (p.addr ==:. a)) p.din q) in
      q <== r;
      r)
  in
  let dq = wire 16 in
  let d = reg spec (mux2 p.wen p.din (mux2 p.ren (mux p.addr (Array.to_list words)) dq)) in
  dq <== d;
  d
;;

(* [loadable.(l)] = false builds lane l without the loadable path (no store, no context
   registers, no fetcher; LOAD_UNITS writes have no effect): a build-time configuration. *)
(* Proof hooks (formal harnesses only): [probe_ctx l words ld] receives, for lane l, the 56
   context header words as reconstructed from the context registers, each with the mask of
   the bits that are stored, and the loader's internals. [bug]: planted defects for negative
   controls. *)
type loader_probe =
  { ld_k : Signal.t
  ; loading_q : Signal.t
  ; cap : Signal.t
  ; cap_k : Signal.t
  ; ld_dout : Signal.t
  ; ld_issue : Signal.t
  ; ctx_base_q : Signal.t
  ; ctx_loaded_q : Signal.t
  }

let create
  ?probe_ctx
  ?(bug : [ `Fetch_running_only | `Ld_no_delay ] option)
  ~(loadable : bool array) ~clock ~rst_sync_n ~(lib : M.t list) ~(store : int -> store_port -> Signal.t)
  ~(host : host) ~(lanes : lane_view array) ~ui_in ~uio_in () =
  let spec = Reg_spec.create ~clock ~clear:~:rst_sync_n () in
  let wr_at a = host.wr &: (host.addr ==:. a) in
  (* free-running cycle counter (wraps) *)
  let now = wire 32 in
  let now_q = reg spec now -- "mon_now" in
  now <== now_q +:. 1;
  let nspec = Reg_spec.create ~clock () in
  let lane_build l =
    let v = lanes.(l) in
    let base = 0x50 + (8 * l) in
    (* forward wires from Mon_lane *)
    let busy = wire 1
    and act = wire 1
    and cur = wire 3
    and pc6 = wire 7
    and pc7 = wire 7 in
    let loading = wire 1 in
    let loading_q = reg spec loading -- sprintf "mon_loading%d" l in
    let ctx_ok = ~:(v.running) &: ~:busy &: ~:loading_q in
    let wr_ctx off = wr_at (base + off) &: ctx_ok in
    let r8 off name = reg spec ~enable:(wr_ctx off) host.wdata -- name in
    let pkg = r8 0 (sprintf "mon_pkg%d" l) in
    let lu = reg spec ~enable:(wr_ctx 1) (select host.wdata 1 0) -- sprintf "mon_load_units%d" l in
    let ctx_base = r8 2 (sprintf "mon_load_ctx%d" l) in
    let remap =
      Array.init 16 ~f:(fun k ->
        reg spec ~enable:(wr_at (0x60 + (16 * l) + k) &: ctx_ok) (select host.wdata 5 0)
        -- sprintf "mon_remap%d_%d" l k)
    in
    let en = bit pkg 7
    and idx = select pkg 3 0 in
    let ld_mode = (lu <>:. 0) &: (if loadable.(l) then vdd else gnd) in
    (* ---- host store port: LSTORE_ADDR (+4), LSTORE_DATA (+5, low then high byte) ---- *)
    let st_wr_data = wr_ctx 5 in
    let st_phase_d = wire 1 in
    let st_phase = reg spec st_phase_d -- sprintf "mon_lst_phase%d" l in
    let st_lo = reg spec ~enable:(st_wr_data &: ~:st_phase) host.wdata -- sprintf "mon_lst_lo%d" l in
    let st_we = st_wr_data &: st_phase in
    let st_addr_d = wire 8 in
    let st_addr = reg spec st_addr_d -- sprintf "mon_lst_addr%d" l in
    st_addr_d <== mux2 (wr_ctx 4) host.wdata (mux2 st_we (st_addr +:. 1) st_addr);
    st_phase_d <== mux2 (wr_ctx 4) gnd (mux2 st_wr_data ~:st_phase st_phase);
    (* ---- context loader: 56 reads from LOAD_CTX ---- *)
    let start_load = wr_ctx 1 &: bit host.wdata 7 in
    let ld_k_d = wire 6 in
    let ld_k = reg spec ld_k_d -- sprintf "mon_ld_k%d" l in
    let ld_issue = loading_q &: (ld_k <:. M.ctx_words) in
    ld_k_d <== mux2 start_load (zero 6) (mux2 ld_issue (ld_k +:. 1) ld_k);
    let cap = reg spec ld_issue -- sprintf "mon_ld_cap%d" l
    and cap_k =
      match bug with
      | Some `Ld_no_delay -> ld_k
      | _ -> reg spec ld_k -- sprintf "mon_ld_cap_k%d" l
    in
    let ld_done = cap &: (cap_k ==:. M.ctx_words - 1) in
    loading <== (start_load |: (loading_q &: ~:ld_done));
    let any_ctx_write =
      List.reduce_exn
        ((List.map [ 0; 1; 2; 4; 5 ] ~f:wr_ctx)
         @ List.init 16 ~f:(fun k -> wr_at (0x60 + (16 * l) + k) &: ctx_ok))
        ~f:( |: )
    in
    let ctx_loaded_d = wire 1 in
    let ctx_loaded = reg spec ctx_loaded_d -- sprintf "mon_ctx_loaded%d" l in
    ctx_loaded_d <== mux2 ld_done vdd (mux2 any_ctx_write gnd ctx_loaded);
    (* ---- fetcher (running only): IR_u = store[base_u + 6 pc_eff_u ..] for u = 6, 7 ---- *)
    let dout = wire 16 in
    (* context registers (filled by the loader) *)
    let cfield i hi lo name =
      reg nspec ~enable:(cap &: (cap_k ==:. i)) (select dout hi lo) -- sprintf "mon_ctx%d_%s" l name
    in
    let c_preds =
      Array.init 16 ~f:(fun k ->
        if k = 0 || k = 15
        then zero M.pred_width
        else cfield ((2 * (k - 1)) + 1) 12 0 (sprintf "pred%d_hi" k) @: cfield (2 * (k - 1)) 15 0 (sprintf "pred%d_lo" k))
    in
    let c_windows = Array.init 8 ~f:(fun k -> if k = 0 then zero 12 else cfield (28 + k - 1) 11 0 (sprintf "win%d" k)) in
    let c_role = Array.init 16 ~f:(fun k -> if k = 0 then gnd else cfield (35 + k - 1) 8 8 (sprintf "crole%d" k)) in
    let c_val = Array.init 16 ~f:(fun k -> if k = 0 then zero 8 else cfield (35 + k - 1) 7 0 (sprintf "cval%d" k)) in
    let c_hdr u =
      let o = 50 + (3 * u) in
      let n x = sprintf "u%d_%s" (6 + u) x in
      let start = cfield o 6 0 (n "start")
      and gen = cfield o 7 7 (n "gen")
      and gp = cfield o 11 8 (n "gp")
      and gs = cfield (o + 1) 6 0 (n "gs")
      and ge = cfield (o + 1) 13 7 (n "ge")
      and gh = cfield (o + 2) 6 0 (n "gh")
      and pbase = cfield (o + 2) 15 8 (n "base") in
      start, (gen, gp, gs, ge, gh), pbase
    in
    let h6 = c_hdr 0
    and h7 = c_hdr 1 in
    Option.iter probe_ctx ~f:(fun f ->
      let w v m = uresize v 16, of_int ~width:16 m in
      let hdr (start, (gen, gp, gs, ge, gh), pbase) =
        [ w (gp @: gen @: start) 0xFFF; w (ge @: gs) 0x3FFF; w (pbase @: gnd @: gh) 0xFF7F ]
      in
      let words =
        List.concat
          [ List.concat_map (List.init 14 ~f:(fun k -> k + 1)) ~f:(fun k ->
              [ w (select c_preds.(k) 15 0) 0xFFFF; w (select c_preds.(k) 28 16) 0x1FFF ])
          ; List.init 7 ~f:(fun k -> w c_windows.(k + 1) 0xFFF)
          ; List.init 15 ~f:(fun k -> w (c_role.(k + 1) @: c_val.(k + 1)) 0x1FF)
          ; hdr h6
          ; hdr h7
          ]
      in
      assert (List.length words = M.ctx_words);
      f l (Array.of_list words)
        { ld_k; loading_q; cap; cap_k; ld_dout = dout; ld_issue; ctx_base_q = ctx_base
        ; ctx_loaded_q = ctx_loaded });
    let rom_tables, rom_present = lib_tables lib ~idx ~remap in
    let lmux a b = mux2 ld_mode a b in
    let tables : S.tables =
      { remap
      ; preds = Array.mapi rom_tables.preds ~f:(fun k r -> lmux c_preds.(k) r)
      ; windows = Array.mapi rom_tables.windows ~f:(fun k r -> lmux c_windows.(k) r)
      ; code_role = Array.mapi rom_tables.code_role ~f:(fun k r -> lmux c_role.(k) r)
      ; code_val = Array.mapi rom_tables.code_val ~f:(fun k r -> lmux c_val.(k) r)
      ; starts =
          Array.mapi rom_tables.starts ~f:(fun u r ->
            match u with
            | 6 -> lmux (fst3 h6) r
            | 7 -> lmux (fst3 h7) r
            | _ -> r)
      ; guards =
          Array.mapi rom_tables.guards ~f:(fun u ((a, b, c, d, e) as r) ->
            let pick (a', b', c', d', e') = lmux a' a, lmux b' b, lmux c' c, lmux d' d, lmux e' e in
            match u with
            | 6 -> pick (snd3 h6)
            | 7 -> pick (snd3 h7)
            | _ -> r)
      ; present = rom_tables.present
      }
    in
    let present =
      Array.mapi rom_present ~f:(fun u r ->
        en
        &:
        match u with
        | 6 -> mux2 ld_mode (bit lu 0) r
        | 7 -> mux2 ld_mode (bit lu 1) r
        | _ -> ~:ld_mode &: r)
    in
    let pcs = [| pc6; pc7 |]
    and pbases = [| trd3 h6; trd3 h7 |] in
    let fe =
      fetcher ~spec ~nspec ~l
        ~en:(match bug with Some `Fetch_running_only -> v.running | _ -> v.running |: busy)
        ~ld_mode ~lu ~pcs ~pbases ~dout ()
    in
    let irv = fe.irv
    and ir_pc = fe.ir_pc
    and issue = fe.issue
    and f_addr = fe.f_addr
    and ir_word = fe.ir_word in
    (* ---- the store: host writes (halted), loader reads (halted), fetcher reads (running) ---- *)
    dout
    <== if not loadable.(l) then zero 16 else store l
          { addr = mux2 st_we st_addr (mux2 ld_issue (ctx_base +: uresize ld_k 8) f_addr)
          ; din = host.wdata @: st_lo
          ; wen = st_we
          ; ren = ld_issue |: issue
          };
    (* ---- the lane ---- *)
    let rom_fetch = lib_fetch lib ~idx in
    let fetch c pc =
      let lf = mux2 (c ==:. 7) (ir_word 1) (ir_word 0) in
      mux2 ld_mode lf (rom_fetch c pc)
    in
    let i =
      { S.I.clock; rst_sync_n; running = v.running; tick = v.tick; ui_in; uio_in
      ; uo_out = v.uo_out; uio_out = v.uio_out; uio_oe = v.uio_oe; pop_ev = v.pop_ev
      ; pop_data = v.pop_data; push_ev = v.push_ev; push_data = v.push_data }
    in
    let o = Mon_lane.create ~tables ~present ~fetch i in
    busy <== o.busy;
    act <== o.act;
    cur <== o.unit_;
    pc6 <== o.pc6;
    pc7 <== o.pc7;
    (* a loadable unit's slot with a stale IR (admission makes this unreachable; sticky flag) *)
    let late_now =
      ld_mode &: act
      &: (((cur ==:. 6) &: ~:(irv.(0) &: (ir_pc.(0) ==: pc6)))
          |: ((cur ==:. 7) &: ~:(irv.(1) &: (ir_pc.(1) ==: pc7))))
    in
    ignore (late_now -- sprintf "mon_late_now%d" l : Signal.t);
    let step = rst_sync_n &: v.running &: v.tick in
    let stamp_l = reg spec ~enable:step now_q -- sprintf "mon_stamp%d" l in
    let stamp = mux2 step now_q stamp_l in
    let min_p = mux2 (ld_mode &: (lu ==:. 3)) (of_int ~width:16 13) (of_int ~width:16 7) in
    let ready = ~:ld_mode |: ctx_loaded in
    let regs8 =
      [| pkg; zero 1 @: loading_q @: ctx_loaded @: zero 3 @: lu; ctx_base; zero 8; st_addr; zero 8
       ; zero 8; zero 8 |]
    in
    ( (en, o, { fire = o.fire; unit_ = o.unit_; role = o.role; code = o.code; stamp })
    , late_now
    , (regs8, remap)
    , (min_p, ready) )
  in
  let built = Array.init 2 ~f:lane_build in
  let lane_out = Array.map built ~f:(fun (a, _, _, _) -> a) in
  let late_now = Array.map built ~f:(fun (_, b, _, _) -> b) in
  let lregs = Array.map built ~f:(fun (_, _, (r, m), _) -> (), r, m) in
  let fir l = let _, _, f = lane_out.(l) in f in
  (* ---- verdict ---- *)
  let clr = host.clr_verdict in
  let record ~is_blame =
    let name = if is_blame then "blame" else "fail" in
    let rec_now l =
      let f = fir l in
      f.fire &: (if is_blame then f.role else ~:(f.role))
    in
    let per_lane =
      Array.init 2 ~f:(fun l ->
        let seen = wire 1 in
        let seen_q = reg spec seen -- sprintf "mon_%s_seen%d" name l in
        let take = rec_now l &: ~:seen_q in
        seen <== (take |: (seen_q &: ~:clr));
        let f = fir l in
        let code = reg spec ~enable:take f.code -- sprintf "mon_%s_code%d" name l
        and unit_ = reg spec ~enable:take f.unit_ -- sprintf "mon_%s_unit%d" name l
        and time = reg spec ~enable:take f.stamp -- sprintf "mon_%s_time%d" name l in
        seen_q, take, code, unit_, time)
    in
    (* first lane: decided when a lane records, against the other lane's record or same-cycle
       record; stamps differ by at most 7 whenever the order is in question *)
    let first = wire 1 in
    let first_q = reg spec first -- sprintf "mon_%s_first" name in
    let precedes l =
      let seen_o, take_o, _, _, time_o = per_lane.(1 - l) in
      let s_self = (fir l).stamp in
      let has_o = seen_o |: take_o in
      let t_o = mux2 seen_o time_o (fir (1 - l)).stamp in
      let d = t_o -: s_self in
      ~:has_o
      |: ((d <>:. 0) &: (d <:. 8))
      |: (if l = 0 then d ==:. 0 else gnd)
    in
    let _, take0, _, _, _ = per_lane.(0)
    and _, take1, _, _, _ = per_lane.(1) in
    first
    <== mux2 (take0 &: precedes 0) gnd (mux2 (take1 &: precedes 1) vdd first_q);
    let flag = List.reduce_exn (Array.to_list per_lane |> List.map ~f:(fun (s, _, _, _, _) -> s)) ~f:( |: ) in
    (* code, unit and time read 0 while the flag is clear (after CLR_VERDICT) *)
    let pick f =
      let v = mux2 first_q (f per_lane.(1)) (f per_lane.(0)) in
      mux2 flag v (zero (width v))
    in
    ( flag
    , first_q
    , pick (fun (_, _, c, _, _) -> c)
    , pick (fun (_, _, _, u, _) -> u)
    , pick (fun (_, _, _, _, t) -> t) )
  in
  let fail, fail_lane, fail_code, fail_unit, fail_time = record ~is_blame:false
  and blame, blame_lane, blame_code, blame_unit, blame_time = record ~is_blame:true in
  let overrun =
    Array.init 2 ~f:(fun l ->
      let _, o, _ = lane_out.(l) in
      let d = wire 1 in
      let q = reg spec d -- sprintf "mon_overrun%d" l in
      d <== (o.overrun |: (q &: ~:clr));
      q)
  in
  let late =
    Array.init 2 ~f:(fun l ->
      let d = wire 1 in
      let q = reg spec d -- sprintf "mon_late%d" l in
      d <== (late_now.(l) |: (q &: ~:clr));
      q)
  in
  let blame_to_lane =
    Array.init 2 ~f:(fun l ->
      let f = fir l in
      reg spec (f.fire &: f.role) -- sprintf "mon_blame_to_lane%d" l)
  in
  let byte x k = select x ((8 * k) + 7) (8 * k) in
  let read a =
    let lo = select a 3 0 in
    let w4 = select a 6 4 in
    let verdict =
      late.(1) @: late.(0) @: overrun.(1) @: overrun.(0) @: fail_lane @: blame_lane @: blame @: fail
    in
    let w4_0 =
      mux lo
        [ verdict; fail_code; blame_code; gnd @: blame_unit @: gnd @: fail_unit
        ; byte fail_time 0; byte fail_time 1; byte fail_time 2; byte fail_time 3
        ; byte blame_time 0; byte blame_time 1; byte blame_time 2; byte blame_time 3
        ; zero 8; zero 8; zero 8; zero 8 ]
    in
    let w4_1 =
      let l = bit lo 3 in
      let off = select lo 2 0 in
      let regs l = let _, r, _ = lregs.(l) in Array.to_list r in
      mux2 l (mux off (regs 1)) (mux off (regs 0))
    in
    let remap_rd l = let _, _, r = lregs.(l) in mux lo (Array.to_list r |> List.map ~f:(fun x -> uresize x 8)) in
    mux w4 [ zero 8; zero 8; zero 8; zero 8; w4_0; w4_1; remap_rd 0; remap_rd 1 ]
  in
  { read
  ; fail
  ; blame
  ; blame_to_lane
  ; pkg_en = Array.map lane_out ~f:(fun (en, _, _) -> en)
  ; min_p = Array.map built ~f:(fun (_, _, _, (m, _)) -> m)
  ; ready = Array.map built ~f:(fun (_, _, _, (_, r)) -> r)
  ; firings = Array.init 2 ~f:fir
  }
;;
