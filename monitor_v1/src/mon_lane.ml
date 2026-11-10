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
     they belong to a step that Mon_spec evaluated before the restart.

   [pipe] (v2 timing increment, log/increments_v2.md section 3.4; default false): slot u runs in
   cycle tick + 1 + u, always from the copies latched at the tick, so the tick (running, tick,
   reset) only enables those latches and the sequencer; no datapath select depends on it. A
   firing of unit u in step c then appears in cycle c + u + 1, and the assumption becomes
   "ticks at least [slots] + 1 cycles apart" ([overrun] otherwise).

   [slots] (v2, default 8 = Mon_spec.n_units): number of unit state entries and slots per step.
   Units slots .. 7 have no state and never fire; the assumption becomes "ticks at least [slots]
   cycles apart" (T<slots>). Refines Mon_spec for packages with at most [slots] units. pc6/pc7
   (loadable units) exist only with 8 slots. *)
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
    ; act : 'a (* the unit of this cycle's slot evaluates *)
    ; pc6 : 'a [@bits 7] (* effective pc of units 6/7 at their next slot (lazy mask applied) *)
    ; pc7 : 'a [@bits 7]
    ; pcs : 'a list [@length 8] [@bits 7]
        (* effective pc of every unit with a slot (v2 serial loadable lane); zero for u >= slots *)
    }
  [@@deriving hardcaml]
end

(* Proof hooks (formal harnesses only):
   [only_unit j]: the state entries of units other than j are free inputs (fresh every cycle)
   instead of registers; sound for properties about slot j only, which reads entry j only.
   [bug]: planted defects for negative controls. *)
type internals =
  { entries : S.ustate array (* state registers (or free inputs, see only_unit) *)
  ; mask_q : Signal.t
  ; smask : Signal.t
  ; busy_q : Signal.t
  ; slot_q : Signal.t
  ; bank_l : Signal.t
  ; ev_l : S.events
  }

let create
  ?(slots = S.n_units)
  ?(pipe = false)
  ?front
  ?probe
  ?only_unit
  ?(bug : [ `Smask_unlatched | `Pc_eff_mask_only ] option)
  ~(tables : S.tables)
  ~(present : Signal.t array)
  ~(fetch : Signal.t -> Signal.t -> Signal.t)
  (i : _ I.t)
  =
  if slots < 1 || slots > S.n_units then raise_s [%message "Mon_lane: bad slot count" (slots : int)];
  let spec = Reg_spec.create ~clock:i.clock ~clear:~:(i.rst_sync_n) () in
  let nspec = Reg_spec.create ~clock:i.clock () in
  let running, step, bank =
    match front with Some f -> f | None -> S.observe ~tables i
  in
  let bankv = concat_lsb bank in
  (* slot sequencer *)
  let busy = wire 1
  and slot = wire 3 in
  let busy_q = reg spec busy -- "mon_busy"
  and slot_q = reg spec slot -- "mon_slot" in
  busy <== (step |: (busy_q &: (slot_q <>:. slots - 1)));
  (* [pipe]: busy_q = a slot runs in this cycle, slot_q = that slot (0 in the cycle after the
     tick); otherwise slot 0 runs in the tick cycle and busy_q = slots 1.. pending *)
  slot <== mux2 step (if pipe then zero 3 else one 3) (slot_q +:. 1);
  let active = if pipe then busy_q else step |: busy_q in
  let cur = if pipe then slot_q else mux2 step (zero 3) slot_q in
  (* bank and stream events seen by the slot *)
  let bank_l = reg nspec ~enable:step bankv -- "mon_bank_l" in
  let pbv = if pipe then bank_l else mux2 step bankv bank_l in
  let ev_l x name = reg nspec ~enable:step x -- name in
  let evl : S.events =
    { pop_ev = ev_l i.pop_ev "mon_pop_ev_l"
    ; pop_data = ev_l i.pop_data "mon_pop_data_l"
    ; push_ev = ev_l i.push_ev "mon_push_ev_l"
    ; push_data = ev_l i.push_data "mon_push_data_l"
    }
  in
  let ev : S.events =
    if pipe then evl else
    { pop_ev = mux2 step i.pop_ev evl.pop_ev
    ; pop_data = mux2 step i.pop_data evl.pop_data
    ; push_ev = mux2 step i.push_ev evl.push_ev
    ; push_data = mux2 step i.push_data evl.push_data
    }
  in
  (* lazy restart: no clear, so reset (running low) sets the mask *)
  let mask = wire S.n_units in
  let mask_q = reg nspec mask -- "mon_mask" in
  mask <== mux2 (~:running) (ones S.n_units) (mux2 step (zero S.n_units) mask_q);
  let smask = reg nspec ~enable:step mask_q -- "mon_smask" in
  let eff_mask =
    match bug with
    | Some `Smask_unlatched -> mask_q
    | Some `Pc_eff_mask_only | None -> if pipe then smask else mux2 step mask_q smask
  in
  (* unit state file *)
  let ds = Array.init slots ~f:(fun _ -> List.map S.ustate_widths ~f:wire) in
  let qs =
    Array.mapi ds ~f:(fun u d ->
      List.map2_exn d [ "pc"; "k"; "m0"; "m1"; "reg"; "stopped" ] ~f:(fun d n ->
        match only_unit with
        | Some j when j <> u -> input (sprintf "free_in_u%d_%s" u n) (width d)
        | _ -> reg nspec d -- sprintf "mon_u%d_%s" u n))
  in
  Option.iter probe ~f:(fun f ->
    f { entries = Array.map qs ~f:S.ustate_of_list; mask_q; smask; busy_q; slot_q; bank_l
      ; ev_l = evl });
  let sel l = mux cur (Array.to_list l) in
  let st_raw =
    S.ustate_of_list (List.init 6 ~f:(fun f -> sel (Array.map qs ~f:(fun q -> List.nth_exn q f))))
  in
  let start = sel (Array.sub tables.starts ~pos:0 ~len:slots) in
  let rst_st = S.ustate_reset ~start in
  let masked = mux cur (List.take (bits_lsb eff_mask) slots) in
  let st =
    S.ustate_of_list
      (List.map2_exn (S.ustate_to_list rst_st) (S.ustate_to_list st_raw) ~f:(fun r q ->
         mux2 masked r q))
  in
  (* pc a unit will use at its next slot. If its slot in the current window is still pending
     the step mask applies (smask, latched at the tick); otherwise the accumulating mask. In
     the tick cycle itself smask is not latched yet, and mask_q is what it will latch. *)
  let pc_eff u =
    let pending =
      match bug with Some `Pc_eff_mask_only -> gnd | _ -> busy_q &: (slot_q <=:. u)
    in
    let m = mux2 pending (bit smask u) (bit mask_q u) in
    mux2 m tables.starts.(u) (List.hd_exn qs.(u))
  in
  let present_cur = sel (Array.sub present ~pos:0 ~len:slots) in
  let act = active &: present_cur &: ~:(st.stopped) in
  let guard =
    let g f = sel (Array.map (Array.sub tables.guards ~pos:0 ~len:slots) ~f) in
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
  ; act
  ; pc6 = (if slots = S.n_units then pc_eff 6 else zero 7)
  ; pc7 = (if slots = S.n_units then pc_eff 7 else zero 7)
  ; pcs = List.init S.n_units ~f:(fun u -> if u < slots then pc_eff u else zero 7)
  }
;;

(* single ROM package *)
let of_package ?slots (p : Mprog.t) i =
  let tables = S.tables_of_package p in
  let present = Array.map tables.present ~f:(fun b -> if b then vdd else gnd) in
  let fetch u pc = mux u (List.init S.n_units ~f:(fun k -> S.rom_fetch p k pc)) in
  create ?slots ~tables ~present ~fetch i
;;

(* Mutation-campaign hook (formal/src/mutate_v2.ml, plan step 9): when set, Mon_engine builds its
   monitor lanes with it instead of [create]. Never set in the shipped flow. *)
let hook :
  (slots:int -> pipe:bool -> tables:S.tables -> present:Signal.t array
   -> fetch:(Signal.t -> Signal.t -> Signal.t) -> Signal.t I.t -> Signal.t O.t)
    option
    ref
  = ref None

let instance ~slots ~pipe ~tables ~present ~fetch i =
  match !hook with
  | Some f -> f ~slots ~pipe ~tables ~present ~fetch i
  | None -> create ~slots ~pipe ~tables ~present ~fetch i
