(* Time-multiplexed monitor lane (user decision 2026-10-18, option C): the predicate bank is
   evaluated in parallel once per step (Mon_spec.observe); one unit datapath
   (Mon_spec.unit_step) serves the 8 unit states in slots, unit u in cycle tick + u.

   Assumption (checked by the [overrun] output): ticks of the lane are at least 8 cycles
   apart, so slot 7 of a step is done before the next step.

   Equivalence target: a firing of unit u in step c of Mon_spec appears here in cycle c + u
   with the same role and code, for steps whose slot window c..c+7 contains no reset cycle.

   - Slot 0 runs in the tick cycle and uses the live bank and stream events; slots 1-7
     use the copies latched at the tick.
   - Restart rule (ISA section 1) is applied lazily: every cycle in which the lane is not
     running sets all bits of [mask]. A unit whose bit was set before the current step
     reads its reset state at its slot, and the slot write commits it. A non-running cycle
     inside a slot window does not affect the units still to be processed in that step:
     they belong to a step that Mon_spec evaluated before the restart. *)
open! Core
open Hardcaml
open Signal
module S = Mon_spec
module I = Mon_spec.I

module O = struct
  type 'a t =
    { fire : 'a
    ; unit_ : 'a [@bits 3] [@rtlname "unit"]
    ; role : 'a (* 1 = blame *)
    ; code : 'a [@bits 8]
    ; overrun : 'a (* a tick while slots of the previous step are pending (assumption broken) *)
    ; busy : 'a (* slots 1-7 of a step are pending in this cycle *)
    }
  [@@deriving hardcaml]
end

let create
  ~(tables : S.tables)
  ~(present : Signal.t array)
  ~(fetch : Signal.t -> Signal.t -> Signal.t)
  (i : _ I.t)
  =
  let spec = Reg_spec.create ~clock:i.clock ~clear:~:(i.rst_sync_n) () in
  let nspec = Reg_spec.create ~clock:i.clock () in
  let running, step, bank = S.observe ~tables i in
  let bankv = concat_lsb bank in
  (* slot sequencer *)
  let busy = wire 1
  and slot = wire 3 in
  let busy_q = reg spec busy -- "mon_busy"
  and slot_q = reg spec slot -- "mon_slot" in
  busy <== (step |: (busy_q &: (slot_q <>:. 7)));
  slot <== mux2 step (one 3) (slot_q +:. 1);
  let active = step |: busy_q in
  let cur = mux2 step (zero 3) slot_q in
  (* bank and stream events seen by the slot *)
  let bank_l = reg nspec ~enable:step bankv -- "mon_bank_l" in
  let pbv = mux2 step bankv bank_l in
  let ev_l x name = reg nspec ~enable:step x -- name in
  let ev : S.events =
    { pop_ev = mux2 step i.pop_ev (ev_l i.pop_ev "mon_pop_ev_l")
    ; pop_data = mux2 step i.pop_data (ev_l i.pop_data "mon_pop_data_l")
    ; push_ev = mux2 step i.push_ev (ev_l i.push_ev "mon_push_ev_l")
    ; push_data = mux2 step i.push_data (ev_l i.push_data "mon_push_data_l")
    }
  in
  (* lazy restart: no clear, so reset (running low) sets the mask *)
  let mask = wire S.n_units in
  let mask_q = reg nspec mask -- "mon_mask" in
  mask <== mux2 (~:running) (ones S.n_units) (mux2 step (zero S.n_units) mask_q);
  let smask = reg nspec ~enable:step mask_q -- "mon_smask" in
  let eff_mask = mux2 step mask_q smask in
  (* unit state file *)
  let ds = Array.init S.n_units ~f:(fun _ -> List.map S.ustate_widths ~f:wire) in
  let qs =
    Array.mapi ds ~f:(fun u d ->
      List.map2_exn d [ "pc"; "k"; "m0"; "m1"; "reg"; "stopped" ] ~f:(fun d n ->
        reg nspec d -- sprintf "mon_u%d_%s" u n))
  in
  let sel l = mux cur (Array.to_list l) in
  let st_raw =
    S.ustate_of_list (List.init 6 ~f:(fun f -> sel (Array.map qs ~f:(fun q -> List.nth_exn q f))))
  in
  let start = sel tables.starts in
  let rst_st = S.ustate_reset ~start in
  let masked = mux cur (bits_lsb eff_mask) in
  let st =
    S.ustate_of_list
      (List.map2_exn (S.ustate_to_list rst_st) (S.ustate_to_list st_raw) ~f:(fun r q ->
         mux2 masked r q))
  in
  let present_cur = sel present in
  let act = active &: present_cur &: ~:(st.stopped) in
  let guard =
    let g f = sel (Array.map tables.guards ~f) in
    ( g (fun (a, _, _, _, _) -> a)
    , g (fun (_, b, _, _, _) -> b)
    , g (fun (_, _, c, _, _) -> c)
    , g (fun (_, _, _, d, _) -> d)
    , g (fun (_, _, _, _, e) -> e) )
  in
  let pb idx = mux idx (bits_lsb pbv) in
  let win idx = mux idx (Array.to_list tables.windows) in
  let w = fetch cur st.pc in
  let next, fire, code_idx = S.unit_step ~pb ~win ~guard ~w ~st ~act ~ev in
  Array.iteri ds ~f:(fun u d ->
    let we = active &: (cur ==:. u) in
    List.iter2_exn d
      (List.map2_exn (S.ustate_to_list next) qs.(u) ~f:(fun n q -> mux2 we n q))
      ~f:( <== ));
  { O.fire
  ; unit_ = cur
  ; role = fire &: mux code_idx (Array.to_list tables.code_role)
  ; code = mux2 fire (mux code_idx (Array.to_list tables.code_val)) (zero 8)
  ; overrun = step &: busy_q
  ; busy = busy_q
  }
;;

(* single ROM package *)
let of_package (p : Mprog.t) i =
  let tables = S.tables_of_package p in
  let present = Array.map tables.present ~f:(fun b -> if b then vdd else gnd) in
  let fetch u pc = mux u (List.init S.n_units ~f:(fun k -> S.rom_fetch p k pc)) in
  create ~tables ~present ~fetch i
;;
