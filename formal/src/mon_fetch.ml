(* Loadable-path obligations of the monitor engine (doc/contracts/monitor_isa_v1.md
   section 7). Together with R1 (mon_ref.ml) they give: a loadable unit's slot evaluates the
   instruction the store holds at its pc, with the context the store held at LOAD.

   Window predicates (harness level, shared by F0 and F1), for unit u >= 1 and a step t:
     since   = cycles since the last step (1 in the cycle after it), seen = a step happened,
     rst_win = a reset cycle after the last step, before this cycle;
     slot(u)    = seen && since = u && no reset in t+1..now        (slot of u, cycle t + u)
     pending(u) = seen && 1 <= since <= u && no reset in t+1..now   (slot of u still due)
     allow(u)   = slot(u) || (not running && not pending(u))
   Environment assumption T8 as in R1.

   F0 (Mon_lane, free tables and instruction words), u = 6, 7:
     (a) the effective pc of unit u (output pc6/pc7) changes from cycle c to c+1 only if
         allow(u) holds in c;
     (b) outside reset cycles, Mon_lane evaluates unit u exactly where slot(u) holds (in a
         reset cycle it may evaluate the slot due, without effect: the verdict and unit state
         are reset; found as an F0 counterexample, harness statement corrected);
     (c) in slot(u) the pc the slot fetches with equals pc_eff(u).
   F1 (Mon_engine.fetcher alone). Environment: pc_u is free but changes only after a cycle
     with allow(u) (= F0 a); steps are at least min_p + 1 cycles apart and the first step
     comes at least min_p cycles after running starts (admission + prescaler, ISA section 1:
     ticks P + 1 apart, first tick P cycles after the start, P >= min_p); the fetcher is
     enabled while the lane runs or slots are pending, as in Mon_engine. Context (bases,
     LOAD_UNITS) is constant: it can change only while halted with the sequencer idle,
     where the fetcher is disabled and its valid bits clear. Store: symbolic address A with
     word D; reads elsewhere return free data; no writes (writes need the lane halted and
     idle, where the fetcher is disabled).
     Claims: (timing) in slot(u) with unit u loadable, IR_u is valid for pc_u;
             (data) whenever IR_u is valid, its word k equals D if base_u + 6 ir_pc_u + k = A.
   F2 (Mon_engine, lane 1 loadable). Every input free, including host writes, lane running
     and ticks. Store: symbolic address A with word D, updated by writes to A. Claim: while
     lane 1's ctx_loaded is set, the header word at A (index i = A - LOAD_CTX < 56), as held
     in the context registers, equals D on the stored bits.
   Negative controls: F0 with pc_eff ignoring the step mask; F1 with the completion restart
   bug, with the fetcher gated by running only, and with min_p = 11 for two units (12 is
   still sufficient: unit 7's instruction is valid exactly at its next slot, so the
   admission rule 6u+1 = 13 has one cycle of slack); F2 with the loader capturing without
   the read latency. *)
open! Core
open Hardcaml
open Signal
module S = Pemu_monitor_v1.Mon_spec
module L = Pemu_monitor_v1.Mon_lane
module E = Pemu_monitor_v1.Mon_engine
module M = Pemu_monitor_v1.Mprog

let sat4 x = mux2 (x ==:. 15) x (x +:. 1)

(* harness window bookkeeping *)
type win =
  { since : Signal.t
  ; seen : Signal.t
  ; rst_win : Signal.t
  ; ok_so_far : Signal.t
  }

let window ~gs ~rst_sync_n ~step ~min_gap =
  let since_d = wire 4 in
  let since = reg gs since_d -- "h_since" in
  let seen_d = wire 1 in
  let seen = reg gs seen_d -- "h_seen_step" in
  since_d <== mux2 step (of_int ~width:4 1) (sat4 since);
  seen_d <== (seen |: step);
  let rst_win_d = wire 1 in
  let rst_win = reg gs rst_win_d -- "h_rst_in_window" in
  rst_win_d <== mux2 step gnd (rst_win |: ~:rst_sync_n);
  let env_d = wire 1 in
  let env = reg gs env_d -- "h_env_bad" in
  env_d <== (env |: (step &: seen &: (since <: min_gap)));
  { since; seen; rst_win; ok_so_far = ~:env_d }
;;

let slot_h w ~rst_sync_n u = w.seen &: (w.since ==:. u) &: ~:(w.rst_win) &: rst_sync_n

let pending_h w ~rst_sync_n u =
  w.seen &: (w.since >=:. 1) &: (w.since <=:. u) &: ~:(w.rst_win) &: rst_sync_n
;;

let allow_h w ~rst_sync_n ~running u =
  slot_h w ~rst_sync_n u |: (~:running &: ~:(pending_h w ~rst_sync_n u))
;;

let free_const gs name w =
  let d = wire w in
  let q = reg gs d -- ("free_c_" ^ name) in
  d <== q;
  q
;;

let lane_inputs () =
  let clock = input "clock" 1 in
  let gs = Reg_spec.create ~clock () in
  let started = reg gs vdd -- "env_started" in
  let rst_sync_n = input "rst_sync_n" 1 &: started in
  let inp n w = input n w in
  ( gs
  , started
  , { S.I.clock; rst_sync_n; running = inp "running" 1; tick = inp "tick" 1; ui_in = inp "ui_in" 8
    ; uio_in = inp "uio_in" 8; uo_out = inp "uo_out" 8; uio_out = inp "uio_out" 8
    ; uio_oe = inp "uio_oe" 8; pop_ev = inp "pop_ev" 1; pop_data = inp "pop_data" 8
    ; push_ev = inp "push_ev" 1; push_data = inp "push_data" 8 } )
;;

(* ---- F0 ---- *)
let f0 ?debug ?bug ~name () =
  let gs, started, i = lane_inputs () in
  let c = free_const gs in
  let tables : S.tables =
    { remap = Array.init 16 ~f:(fun k -> c (sprintf "remap%d" k) 6)
    ; preds =
        Array.init 16 ~f:(fun k ->
          if k = 0 || k = 15 then zero M.pred_width else c (sprintf "pred%d" k) M.pred_width)
    ; windows = Array.init 8 ~f:(fun k -> if k = 0 then zero 12 else c (sprintf "win%d" k) 12)
    ; code_role = Array.init 16 ~f:(fun k -> if k = 0 then gnd else c (sprintf "crole%d" k) 1)
    ; code_val = Array.init 16 ~f:(fun k -> if k = 0 then zero 8 else c (sprintf "cval%d" k) 8)
    ; starts = Array.init S.n_units ~f:(fun u -> c (sprintf "start%d" u) 7)
    ; guards =
        Array.init S.n_units ~f:(fun u ->
          let g n w = c (sprintf "%s%d" n u) w in
          g "gen" 1, g "gp" 4, g "gs" 7, g "ge" 7, g "gh" 7)
    ; present = Array.create ~len:S.n_units true
    }
  in
  let present = Array.init S.n_units ~f:(fun u -> c (sprintf "present%d" u) 1) in
  let fetch_pc = wire 7 in
  let lint = ref None in
  let lo =
    L.create ?bug ~probe:(fun x -> lint := Some x) ~tables ~present
      ~fetch:(fun _ pc ->
        fetch_pc <== pc;
        input "free_w" M.instr_width)
      i
  in
  let lint = Option.value_exn !lint in
  let rst_sync_n = i.rst_sync_n in
  let running = rst_sync_n &: i.running in
  let step = running &: i.tick in
  let w = window ~gs ~rst_sync_n ~step ~min_gap:(of_int ~width:4 8) in
  let checks u pc_eff =
    let allow = allow_h w ~rst_sync_n ~running u in
    let prev_allow = reg gs allow -- sprintf "h_prev_allow%d" u
    and prev_pc = reg gs pc_eff -- sprintf "h_prev_pc%d" u
    and prev_started = reg gs started -- sprintf "h_prev_started%d" u in
    let lane_slot = lint.busy_q &: (lint.slot_q ==:. u) in
    let sl = slot_h w ~rst_sync_n u in
    (prev_started &: (pc_eff <>: prev_pc) &: ~:prev_allow)
    (* in a reset cycle Mon_lane may still evaluate the slot due (busy clears at the next
       edge); that evaluation has no effect: the verdict and the unit state are being reset *)
    |: (rst_sync_n &: (lane_slot ^: sl))
    |: (sl &: (fetch_pc <>: pc_eff))
  in
  let bad = w.ok_so_far &: (checks 6 lo.pc6 |: checks 7 lo.pc7) in
  Harness.bad_circuit ?debug ~dbg:[ "since", w.since; "pc6", lo.pc6; "fetch_pc", fetch_pc ] ~name bad
;;

(* ---- F1 ---- *)
let addr8 ~base ~pc ~k =
  let x = uresize pc 8 in
  base +: (sll x 2 +: sll x 1) +: uresize k 8
;;

(* [part]: `Timing (claim T only) or `Data (claim D with its strengthening invariants:
   sequencer consistency, in-flight words, DOUT at capture, valid IR words) *)
let f1 ?debug ?bug ?(en_running_only = false) ?(min_p2 = 13) ~part ~name () =
  let clock = input "clock" 1 in
  let gs = Reg_spec.create ~clock () in
  let nspec = gs in
  let started = reg gs vdd -- "env_started" in
  let rst_sync_n = input "rst_sync_n" 1 &: started in
  let spec = Reg_spec.create ~clock ~clear:~:rst_sync_n () in
  let running = rst_sync_n &: input "running" 1 in
  let step = running &: input "tick" 1 in
  let lu = free_const gs "lu" 2 in
  let ld_mode = lu <>:. 0 in
  let min_p = mux2 (lu ==:. 3) (of_int ~width:5 min_p2) (of_int ~width:5 7) in
  let w = window ~gs ~rst_sync_n ~step ~min_gap:(select (min_p +:. 1) 3 0) in
  let age_d = wire 5 in
  let age = reg gs age_d -- "h_run_age" in
  age_d <== mux2 running (mux2 (age ==:. 31) age (age +:. 1)) (zero 5);
  let env2_d = wire 1 in
  let env2 = reg gs env2_d -- "h_env2_bad" in
  env2_d <== (env2 |: (step &: (age <: min_p)));
  let ok = w.ok_so_far &: ~:env2_d in
  let busy_h = w.seen &: (w.since >=:. 1) &: (w.since <=:. 7) &: ~:(w.rst_win) in
  let en = if en_running_only then running else running |: busy_h in
  let pcs =
    Array.init 2 ~f:(fun k ->
      let u = 6 + k in
      let d = wire 7 in
      let q = reg gs d -- sprintf "free_pc%d" u in
      d <== mux2 (allow_h w ~rst_sync_n ~running u) (input (sprintf "pc_in%d" u) 7) q;
      q)
  in
  let pbases = [| free_const gs "base6" 8; free_const gs "base7" 8 |] in
  let base ub = mux2 ub pbases.(1) pbases.(0) in
  let a = free_const gs "A" 8
  and dsym = free_const gs "D" 16 in
  let dout = wire 16 in
  let fo = E.fetcher ?bug ~spec ~nspec ~l:1 ~en ~ld_mode ~lu ~pcs ~pbases ~dout () in
  let dq = wire 16 in
  let dreg =
    reg gs (mux2 fo.issue (mux2 (fo.f_addr ==: a) dsym (input "rdata" 16)) dq) -- "free_dout"
  in
  dq <== dreg;
  dout <== dreg;
  let bad =
    match part with
    | `Timing ->
      let timing u =
        let k = u - 6 in
        slot_h w ~rst_sync_n u &: ld_mode &: bit lu k
        &: ~:(fo.irv.(k) &: (fo.ir_pc.(k) ==: pcs.(k)))
      in
      timing 6 |: timing 7
    | `Data ->
      let word_ok ub pc wd x = (addr8 ~base:(base ub) ~pc ~k:(of_int ~width:3 wd) <>: a) |: (x ==: dsym) in
      let s1 =
        (~:(fo.f_busy)
         |: (fo.fcap &: (fo.fcap_k +:. 1 ==: fo.f_k) &: (fo.fcap_u ==: fo.f_u)
             &: (fo.fcap_pc ==: fo.f_pc) &: (fo.f_k >=:. 1) &: (fo.f_k <=:. 5)))
        &: (fo.f_busy |: ~:(fo.fcap) |: (fo.fcap_k ==:. 5))
      in
      let s2d =
        ~:(fo.fcap)
        |: (addr8 ~base:(base fo.fcap_u) ~pc:fo.fcap_pc ~k:fo.fcap_k <>: a)
        |: (dout ==: dsym)
      in
      let s2w =
        List.init 6 ~f:(fun wd ->
          let mine = mux2 fo.fcap_u fo.ir_words.(1).(wd) fo.ir_words.(0).(wd) in
          ~:(fo.fcap) |: (fo.fcap_k <=:. wd) |: word_ok fo.fcap_u fo.fcap_pc wd mine)
        |> reduce ~f:( &: )
      in
      let s3 =
        List.init 2 ~f:(fun k ->
          let ub = if k = 1 then vdd else gnd in
          ~:(fo.irv.(k))
          |: (List.init 6 ~f:(fun wd -> word_ok ub fo.ir_pc.(k) wd fo.ir_words.(k).(wd))
              |> reduce ~f:( &: )))
        |> reduce ~f:( &: )
      in
      let s4 =
        List.init 2 ~f:(fun k ->
          ~:(fo.irv.(k))
          |: (~:(fo.fcap &: (fo.fcap_u ==:. k)) &: ~:(fo.f_busy &: (fo.f_u ==:. k))))
        |> reduce ~f:( &: )
      in
      ~:(s1 &: s2d &: s2w &: s3 &: s4)
  in
  Harness.bad_circuit ?debug
    ~dbg:[ "since", w.since; "irv6", fo.irv.(0); "irv7", fo.irv.(1); "issue", fo.issue ]
    ~name (ok &: bad)
;;

(* ---- F2 ---- *)
let f2 ?debug ?bug ~name () =
  let clock = input "clock" 1 in
  let gs = Reg_spec.create ~clock () in
  let started = reg gs vdd -- "env_started" in
  let rst_sync_n = input "rst_sync_n" 1 &: started in
  let inp n w = input n w in
  let lanes =
    Array.init 2 ~f:(fun l ->
      { E.running = rst_sync_n &: inp (sprintf "running%d" l) 1; tick = inp (sprintf "tick%d" l) 1
      ; uo_out = inp (sprintf "uo%d" l) 8; uio_out = inp (sprintf "uio_out%d" l) 8
      ; uio_oe = inp (sprintf "uio_oe%d" l) 8; pop_ev = inp (sprintf "pop_ev%d" l) 1
      ; pop_data = inp (sprintf "pop_data%d" l) 8; push_ev = inp (sprintf "push_ev%d" l) 1
      ; push_data = inp (sprintf "push_data%d" l) 8 })
  in
  let a = free_const gs "A" 8 in
  let dsym_d = wire 16 in
  let dsym = reg gs dsym_d -- "free_D" in
  let store _ (p : E.store_port) =
    dsym_d <== mux2 (p.wen &: (p.addr ==: a)) p.din dsym;
    let dq = wire 16 in
    let rd = mux2 (p.addr ==: a) dsym (inp "rdata" 16) in
    let d = reg gs (mux2 p.wen (mux2 p.ren p.din dq) (mux2 p.ren rd dq)) -- "free_dout" in
    dq <== d;
    d
  in
  let pr = ref None in
  let lib = [ Pemu_monitor_v1.Compile.compile_exn (Pemu_monitor_v1.Library_v1.uart_tx ~d:3 ~pin:0) ] in
  let _e =
    E.create ?bug ~probe_ctx:(fun l ws ld -> if l = 1 then pr := Some (ws, ld))
      ~loadable:[| false; true |] ~clock ~rst_sync_n ~lib ~store
      ~host:{ wr = inp "wr" 1; addr = inp "addr" 7; wdata = inp "wdata" 8; clr_verdict = inp "clr" 1 }
      ~lanes ~ui_in:(inp "ui_in" 8) ~uio_in:(inp "uio_in" 8) ()
  in
  let words, ld = Option.value_exn !pr in
  let ok_i i =
    let held, mask = words.(i) in
    (ld.ctx_base_q +:. i <>: a) |: ((held &: mask) ==: (dsym &: mask))
  in
  let claim = ~:(ld.ctx_loaded_q) |: (List.init M.ctx_words ~f:ok_i |> reduce ~f:( &: )) in
  (* strengthening: loader sequencing, DOUT at capture, words captured so far *)
  let l1 =
    (~:(ld.cap) |: (ld.loading_q &: (ld.cap_k +:. 1 ==: ld.ld_k)))
    &: (~:(ld.loading_q) |: (ld.ld_k <=:. M.ctx_words))
    &: (~:(ld.ctx_loaded_q) |: ~:(ld.loading_q))
  in
  let l2 = ~:(ld.cap) |: (ld.ctx_base_q +: uresize ld.cap_k 8 <>: a) |: (ld.ld_dout ==: dsym) in
  let cnt = mux2 ld.cap ld.cap_k ld.ld_k in
  let l3 =
    ~:(ld.loading_q)
    |: (List.init M.ctx_words ~f:(fun i -> (cnt <=:. i) |: ok_i i) |> reduce ~f:( &: ))
  in
  let bad = ~:(claim &: l1 &: l2 &: l3) in
  Harness.bad_circuit ?debug ~dbg:[ "ctx_loaded", ld.ctx_loaded_q; "ld_k", ld.ld_k ] ~name bad
;;

let all ?debug () =
  [ f0 ?debug ~name:"f0_mon_pc_eff" ()
  ; f0 ?debug ~bug:`Pc_eff_mask_only ~name:"f0_mon_pc_eff_mask_neg" ()
  ; f1 ?debug ~part:`Timing ~name:"f1t_mon_fetch" ()
  ; f1 ?debug ~part:`Timing ~bug:`Restart_on_complete ~name:"f1t_mon_fetch_restart_neg" ()
  ; f1 ?debug ~part:`Timing ~en_running_only:true ~name:"f1t_mon_fetch_runonly_neg" ()
  ; f1 ?debug ~part:`Timing ~min_p2:11 ~name:"f1t_mon_fetch_p11_neg" ()
  ; f1 ?debug ~part:`Data ~name:"f1d_mon_fetch_data" ()
  ; f1 ?debug ~part:`Data ~bug:`Addr_off_by_one ~name:"f1d_mon_fetch_data_addr_neg" ()
  ; f2 ?debug ~name:"f2_mon_ctx_load" ()
  ; f2 ?debug ~bug:`Ld_no_delay ~name:"f2_mon_ctx_load_delay_neg" ()
  ]
;;
