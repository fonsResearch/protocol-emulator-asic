(* Monitor circuits for compiled contracts.

   [Front]: observation front end shared by every monitor implementation: 2-flop input
   synchronisers (reset 0, doc/interface.md section 3), the 40-entry observable vector,
   previous-cycle values and the prev_valid flag for edge predicates.

   [Hardwired]: S1-mon as a circuit. One compiled program elaborated as a fixed state machine
   per watcher (per-instruction constants, selected by the program counter). This is the
   monitor used in the proof harness for U; the programmable engine ([Engine]) is proved
   equal to it per contract (A1-mon, translation validation).

   Verdict outputs are combinational in the current cycle (same convention as
   monitors/src/uart_tx_monitor.ml) and forced to 0 while rst_sync_n = 0. *)
open! Core
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_sync_n : 'a
    ; ui_in : 'a [@bits 8]
    ; uio_in : 'a [@bits 8]
    ; uo_out : 'a [@bits 8]
    ; uio_out : 'a [@bits 8]
    ; uio_oe : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { fail_now : 'a
    ; blame_now : 'a
    ; fail_flag : 'a
    ; blame_flag : 'a
    ; first_fail_valid : 'a
    ; first_fail : 'a [@bits 8]
    ; first_blame_valid : 'a
    ; first_blame : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

(* Fixed hardware index of each source in the 40-entry observable vector. *)
let source_index : Contract.source -> int = function
  | Uo k -> k
  | Uio_out k -> 8 + k
  | Uio_oe k -> 16 + k
  | Ui k -> 24 + k
  | Uio_in k -> 32 + k
;;

let n_sources = 40

module Front = struct
  type t =
    { spec : Reg_spec.t
    ; obs : Signal.t (* 40 bits, current cycle *)
    ; prev : Signal.t (* 40 bits, previous observed cycle *)
    ; prev_valid : Signal.t
    ; active : Signal.t (* rst_sync_n *)
    }

  let create (i : _ I.t) =
    let spec = Reg_spec.create ~clock:i.clock ~clear:~:(i.rst_sync_n) () in
    let s1_ui = reg spec i.ui_in -- "mon_s1_ui" in
    let s2_ui = reg spec s1_ui -- "mon_s2_ui" in
    let s1_uio = reg spec i.uio_in -- "mon_s1_uio" in
    let s2_uio = reg spec s1_uio -- "mon_s2_uio" in
    let obs = concat_lsb [ i.uo_out; i.uio_out; i.uio_oe; s2_ui; s2_uio ] in
    let prev = reg spec obs -- "mon_prev" in
    let prev_valid = reg spec vdd -- "mon_prev_valid" in
    { spec; obs; prev; prev_valid; active = i.rst_sync_n }
  ;;

  (* value of atom (source index, kind) in the current cycle *)
  let atom t idx (kind : Contract.kind) =
    let now = bit t.obs idx
    and before = bit t.prev idx in
    match kind with
    | Level -> now
    | Rise -> t.prev_valid &: now &: ~:before
    | Fall -> t.prev_valid &: ~:now &: before
    | Changed -> t.prev_valid &: (now ^: before)
  ;;
end

let role_bit : Contract.role -> Signal.t = function
  | Fail -> gnd
  | Blame -> vdd
;;

let pc_width n = Int.max 1 (Int.ceil_log2 n)
let count_width (p : Program.t) = Int.ceil_log2 (Program.max_window p + 2)

(* Per-watcher outcome in the current cycle. *)
type outcome =
  { fire : Signal.t
  ; fire_role : Signal.t (* 1 = blame *)
  ; fire_code : Signal.t (* 8 bits, full code *)
  }

(* Verdict block shared by all implementations: sticky flags and first causes. Watchers are
   prioritised by index (lowest wins) when several fire with the same role in one cycle. *)
let verdict (f : Front.t) (outs : outcome list) =
  let spec = f.spec in
  let fires role_is_blame =
    List.map outs ~f:(fun o ->
      o.fire &: (if role_is_blame then o.fire_role else ~:(o.fire_role)), o.fire_code)
  in
  let first_of l =
    List.fold_right l ~init:(gnd, zero 8) ~f:(fun (fi, code) (v, c) ->
      mux2 fi vdd v, mux2 fi code c)
  in
  let fail_now, fail_code_now = first_of (fires false)
  and blame_now, blame_code_now = first_of (fires true) in
  let fail_now = fail_now &: f.active
  and blame_now = blame_now &: f.active in
  let fail_r = wire 1
  and blame_r = wire 1
  and ffv_r = wire 1
  and ff_r = wire 8
  and fbv_r = wire 1
  and fb_r = wire 8 in
  let fail_flag = fail_r |: fail_now
  and blame_flag = blame_r |: blame_now in
  let ffv = ffv_r |: fail_now
  and ff = mux2 ffv_r ff_r fail_code_now
  and fbv = fbv_r |: blame_now
  and fb = mux2 fbv_r fb_r blame_code_now in
  fail_r <== reg spec fail_flag;
  blame_r <== reg spec blame_flag;
  ffv_r <== reg spec ffv;
  ff_r <== reg spec ff;
  fbv_r <== reg spec fbv;
  fb_r <== reg spec fb;
  let a = f.active in
  { O.fail_now
  ; blame_now
  ; fail_flag = fail_flag &: a
  ; blame_flag = blame_flag &: a
  ; first_fail_valid = ffv &: a
  ; first_fail = mux2 a ff (zero 8)
  ; first_blame_valid = fbv &: a
  ; first_blame = mux2 a fb (zero 8)
  }
;;

module Hardwired = struct
  let pred_value (f : Front.t) (p : Program.t) : Program.pred -> Signal.t = function
    | P_true -> vdd
    | P_false -> gnd
    | P_and lits ->
      List.map lits ~f:(fun (l : Program.literal) ->
        let idx = source_index (snd p.observables.(l.obs)) in
        let a = Front.atom f idx l.kind in
        if l.neg then ~:a else a)
      |> List.reduce_exn ~f:( &: )
  ;;

  let code (w : Program.watcher_prog) (_, c) = of_int ~width:8 (w.base + c)

  let watcher (f : Front.t) (p : Program.t) ~cw wi (w : Program.watcher_prog) =
    let n = Array.length w.instrs in
    let pw = pc_width n in
    let pc_d = wire pw
    and cnt_d = wire cw
    and stop_d = wire 1 in
    let nm s = sprintf "mon_w%d_%s" wi s in
    let pc = reg f.spec pc_d -- nm "pc"
    and cnt = reg f.spec cnt_d -- nm "cnt"
    and stopped = reg f.spec stop_d -- nm "stopped" in
    let k = uresize cnt (cw + 1) +:. 1 in
    (* per-instruction decisions, gated by pc == j *)
    let per =
      Array.to_list w.instrs
      |> List.mapi ~f:(fun j (ins : Program.instr) ->
        let sel = pc ==:. j in
        let pv = pred_value f p ins.pred in
        let complete, fire, frole, fcode =
          match ins.op with
          | Await_idle -> pv, gnd, gnd, zero 8
          | Await { lo; hi; timeout; early } ->
            let complete = pv &: (k >=:. lo) in
            let early_fire, er, ec =
              match early with
              | None -> gnd, gnd, zero 8
              | Some ck -> pv &: (k <:. lo), role_bit (fst ck), code w ck
            in
            let tmo = ~:pv &: (k >=:. hi) in
            ( complete
            , early_fire |: tmo
            , mux2 early_fire er (role_bit (fst timeout))
            , mux2 early_fire ec (code w timeout) )
          | Hold { n; check } ->
            pv &: (k >=:. n), ~:pv, role_bit (fst check), code w check
          | Skip n -> k >=:. n, gnd, gnd, zero 8
        in
        let complete = complete &: ~:fire in
        let next_pc, c_fire, c_role, c_code, c_stop =
          match ins.on_complete with
          | Goto t -> of_int ~width:pw t, gnd, gnd, zero 8, gnd
          | Fire ck -> pc, vdd, role_bit (fst ck), code w ck, vdd
          | Stop -> pc, gnd, gnd, zero 8, vdd
        in
        let fire_any = fire |: (complete &: c_fire) in
        let role = mux2 fire frole c_role
        and cd = mux2 fire fcode c_code in
        sel, complete, fire_any, role, cd, next_pc, complete &: c_stop)
    in
    let pick f_ default =
      List.fold_right per ~init:default ~f:(fun ((sel, _, _, _, _, _, _) as x) acc ->
        mux2 sel (f_ x) acc)
    in
    let live = ~:stopped in
    let complete = live &: pick (fun (_, c, _, _, _, _, _) -> c) gnd
    and fire = live &: pick (fun (_, _, fi, _, _, _, _) -> fi) gnd
    and frole = pick (fun (_, _, _, r, _, _, _) -> r) gnd
    and fcode = pick (fun (_, _, _, _, c, _, _) -> c) (zero 8)
    and next_pc = pick (fun (_, _, _, _, _, np, _) -> np) pc
    and stop_now = live &: pick (fun (_, _, _, _, _, _, s) -> s) gnd in
    let max_cnt = (1 lsl cw) - 1 in
    pc_d <== mux2 complete next_pc pc;
    cnt_d <== mux2 complete (zero cw) (mux2 (cnt ==:. max_cnt) cnt (cnt +:. 1));
    stop_d <== (stopped |: (fire &: f.active) |: (stop_now &: f.active));
    { fire; fire_role = frole; fire_code = fcode }
  ;;

  let create (p : Program.t) (i : _ I.t) =
    let f = Front.create i in
    let cw = count_width p in
    let outs = Array.to_list (Array.mapi p.watchers ~f:(watcher f p ~cw)) in
    verdict f outs
  ;;

  let circuit ?(name = "mon_hardwired") p =
    let module C = Circuit.With_interface (I) (O) in
    C.create_exn ~name (create p)
  ;;
end
