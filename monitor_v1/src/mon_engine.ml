(* Monitor engine v1, ROM packages (doc/contracts/monitor_isa_v1.md sections 1, 1a, 6, 8):
   two time-multiplexed lanes (Mon_lane), a ROM package library selected per lane, host
   remap registers, the verdict block and the blame outputs to the lanes.
   Not here yet: the loadable store and units 6/7 fetching from it (section 7); the
   LOAD_* registers exist and read back but have no effect.

   Register window 0x40-0x7F (interface v1.1 draft):
     0x40 VERDICT   R  bit0 fail, bit1 blame, bit2 first-blame lane, bit3 first-fail lane,
                       bit4/5 overrun seen L0/L1 (sticky; T8 violated)
     0x41 FIRST_FAIL  R cause code      0x42 FIRST_BLAME R cause code
     0x43 FIRST_UNITS R first-fail unit [2:0], first-blame unit [6:4]
     0x44-0x47 FAIL_TIME, 0x48-0x4B BLAME_TIME  R  step cycle (32-bit, wraps), LSB first
     0x4C LSTORE_ADDR W, 0x4D LSTORE_DATA W,P (moved from 0x7C/0x7D, which collide with REMAP)
     0x50 + 8L PKG R/W while L halted: bit7 enable, [3:0] library index
       +1 LOAD_UNITS, +2 LOAD_BASE6, +3 LOAD_BASE7  R/W while L halted (no effect yet)
     0x60 + 16L + i REMAP R/W while L halted: local observable i -> global source [5:0]
   Verdict clearing: CTRL.CLR_VERDICT (caller passes [clr_verdict]); a firing recorded in
   the same cycle survives the clear [choice]. *)
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
  ; pkg_en : Signal.t array (* lane L has an enabled package (T8 admission applies) *)
  ; firings : firing array (* per lane, for tests *)
  }

let is_port a = a ==:. 0x4D

(* ---- package library tables, selected by a 4-bit index ---- *)
let lib_tables (lib : M.t list) ~idx ~remap : S.tables * Signal.t array =
  let tabs = List.map lib ~f:S.tables_of_package in
  let n = List.length lib in
  if n = 0 then raise_s [%message "empty package library"];
  let pick f = mux idx (List.map tabs ~f) in
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
      &: mux idx (List.map lib ~f:(fun p -> if k < Array.length p.units then vdd else gnd)))
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
  mux idx (List.map lib ~f:per_pkg)
;;

let create ~clock ~rst_sync_n ~(lib : M.t list) ~(host : host) ~(lanes : lane_view array)
  ~ui_in ~uio_in =
  let spec = Reg_spec.create ~clock ~clear:~:rst_sync_n () in
  let wr_at a = host.wr &: (host.addr ==:. a) in
  (* free-running cycle counter (wraps) *)
  let now = wire 32 in
  let now_q = reg spec now -- "mon_now" in
  now <== now_q +:. 1;
  let regs_lane l =
    let halted = ~:(lanes.(l).running) in
    let r8 off name = reg spec ~enable:(wr_at (0x50 + (8 * l) + off) &: halted) host.wdata -- name in
    let pkg = r8 0 (sprintf "mon_pkg%d" l)
    and load_units = r8 1 (sprintf "mon_load_units%d" l)
    and base6 = r8 2 (sprintf "mon_load_base6_%d" l)
    and base7 = r8 3 (sprintf "mon_load_base7_%d" l) in
    let remap =
      Array.init 16 ~f:(fun k ->
        reg spec ~enable:(wr_at (0x60 + (16 * l) + k) &: halted) (select host.wdata 5 0)
        -- sprintf "mon_remap%d_%d" l k)
    in
    pkg, [| pkg; uresize (select load_units 1 0) 8; base6; base7 |], remap
  in
  let lregs = Array.init 2 ~f:regs_lane in
  let lane_out =
    Array.init 2 ~f:(fun l ->
      let pkg, _, remap = lregs.(l) in
      let en = bit pkg 7
      and idx = select pkg 3 0 in
      let tables, present = lib_tables lib ~idx ~remap in
      let present = Array.map present ~f:(fun p -> p &: en) in
      let fetch = lib_fetch lib ~idx in
      let v = lanes.(l) in
      let i =
        { S.I.clock; rst_sync_n; running = v.running; tick = v.tick; ui_in; uio_in
        ; uo_out = v.uo_out; uio_out = v.uio_out; uio_oe = v.uio_oe; pop_ev = v.pop_ev; pop_data = v.pop_data; push_ev = v.push_ev
        ; push_data = v.push_data }
      in
      let o = Mon_lane.create ~tables ~present ~fetch i in
      let step = rst_sync_n &: v.running &: v.tick in
      let stamp_l = reg spec ~enable:step now_q -- sprintf "mon_stamp%d" l in
      let stamp = mux2 step now_q stamp_l in
      en, o, { fire = o.fire; unit_ = o.unit_; role = o.role; code = o.code; stamp })
  in
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
      zero 2 @: overrun.(1) @: overrun.(0) @: fail_lane @: blame_lane @: blame @: fail
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
      let regs l = let _, r, _ = lregs.(l) in Array.to_list r @ List.init 4 ~f:(fun _ -> zero 8) in
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
  ; firings = Array.init 2 ~f:fir
  }
;;
