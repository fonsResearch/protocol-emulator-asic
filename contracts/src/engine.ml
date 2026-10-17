(* Programmable monitor engine (spike version).

   N watcher units; each executes encoded instructions from its own program store with a
   generic datapath: two literal selectors over the 40-entry observable vector, a window
   counter and comparators, and an on-complete action. Program stores:
   - [Rom]: the encoded program as constants (used in proofs: A1-mon miter against
     [Mon_circuit.Hardwired] on the same program);
   - [Registers]: loadable flops behind a write port (used for the area estimate; not yet in
     any proof).

   Encoding (LSB first), widths from [layout]:
     op 2 | pmode 2 | nlit2 1 | l0 idx 6, kind 2, neg 1 | l1 idx 6, kind 2, neg 1
     | lo cw | hi cw | c_role 1 | c_code 8 | e_en 1 | e_role 1 | e_code 8
     | oc 2 | target pw | f_role 1 | f_code 8
   op: 0 await_idle, 1 await, 2 hold (n in hi), 3 skip (n in hi).
   pmode: 0 false, 1 true, 2 literals. oc: 0 goto, 1 fire, 2 stop. *)
open! Core
open Hardcaml
open Signal
module MC = Mon_circuit

type layout =
  { cw : int (* window counter width *)
  ; pw : int (* program counter width *)
  }

let fields l =
  [ "op", 2; "pmode", 2; "nlit2", 1; "l0_idx", 6; "l0_kind", 2; "l0_neg", 1; "l1_idx", 6
  ; "l1_kind", 2; "l1_neg", 1; "lo", l.cw; "hi", l.cw; "c_role", 1; "c_code", 8; "e_en", 1
  ; "e_role", 1; "e_code", 8; "oc", 2; "target", l.pw; "f_role", 1; "f_code", 8
  ]
;;

let width l = List.sum (module Int) (fields l) ~f:snd

let kind_code : Contract.kind -> int = function
  | Level -> 0
  | Rise -> 1
  | Fall -> 2
  | Changed -> 3
;;

let role_code : Contract.role -> int = function
  | Fail -> 0
  | Blame -> 1
;;

(* Field values (as ints) of one instruction. *)
let encode_fields (p : Program.t) (w : Program.watcher_prog) (ins : Program.instr) =
  let lit = function
    | None -> 0, 0, 0
    | Some (l : Program.literal) ->
      MC.source_index (snd p.observables.(l.obs)), kind_code l.kind, Bool.to_int l.neg
  in
  let pmode, nlit2, l0, l1 =
    match ins.pred with
    | P_false -> 0, 0, lit None, lit None
    | P_true -> 1, 0, lit None, lit None
    | P_and [ a ] -> 2, 0, lit (Some a), lit None
    | P_and [ a; b ] -> 2, 1, lit (Some a), lit (Some b)
    | P_and _ -> assert false
  in
  let code (_, c) = w.base + c in
  let op, lo, hi, (cr, cc), early =
    match ins.op with
    | Await_idle -> 0, 0, 0, (0, 0), None
    | Await { lo; hi; timeout; early } ->
      1, lo, hi, (role_code (fst timeout), code timeout), early
    | Hold { n; check } -> 2, 0, n, (role_code (fst check), code check), None
    | Skip n -> 3, 0, n, (0, 0), None
  in
  let e_en, er, ec =
    match early with
    | None -> 0, 0, 0
    | Some ck -> 1, role_code (fst ck), code ck
  in
  let oc, target, fr, fc =
    match ins.on_complete with
    | Goto t -> 0, t, 0, 0
    | Fire ck -> 1, 0, role_code (fst ck), code ck
    | Stop -> 2, 0, 0, 0
  in
  let l0i, l0k, l0n = l0
  and l1i, l1k, l1n = l1 in
  [ op; pmode; nlit2; l0i; l0k; l0n; l1i; l1k; l1n; lo; hi; cr; cc; e_en; er; ec; oc; target
  ; fr; fc ]
;;

let encode l p w ins =
  List.map2_exn (fields l) (encode_fields p w ins) ~f:(fun (_, wd) v -> of_int ~width:wd v)
  |> concat_lsb
;;

(* Split an instruction word into named fields. *)
let decode l word =
  let _, fs =
    List.fold (fields l) ~init:(0, String.Map.empty) ~f:(fun (pos, m) (n, wd) ->
      pos + wd, Map.set m ~key:n ~data:(select word (pos + wd - 1) pos))
  in
  fun n -> Map.find_exn fs n
;;

let unit_ ?(window_bug = false) (f : MC.Front.t) ~l ~ui ~(fetch : Signal.t -> Signal.t) =
  let nm s = sprintf "eng_u%d_%s" ui s in
  let pc_d = wire l.pw
  and cnt_d = wire l.cw
  and stop_d = wire 1 in
  let pc = reg f.spec pc_d -- nm "pc"
  and cnt = reg f.spec cnt_d -- nm "cnt"
  and stopped = reg f.spec stop_d -- nm "stopped" in
  let fld = decode l (fetch pc) in
  let lit p =
    let idx = fld (p ^ "_idx")
    and kind = fld (p ^ "_kind")
    and neg = fld (p ^ "_neg") in
    let now = mux idx (bits_lsb f.obs)
    and before = mux idx (bits_lsb f.prev) in
    let a =
      mux
        kind
        [ now
        ; f.prev_valid &: now &: ~:before
        ; f.prev_valid &: ~:now &: before
        ; f.prev_valid &: (now ^: before)
        ]
    in
    a ^: neg
  in
  let lits = lit "l0" &: mux2 (fld "nlit2") (lit "l1") vdd in
  let pv = mux (fld "pmode") [ gnd; vdd; lits; lits ] in
  let k = uresize cnt (l.cw + 1) +:. 1 in
  let ge_lo = k >=: uresize (fld "lo") (l.cw + 1)
  and ge_hi =
    if window_bug
    then k >: uresize (fld "hi") (l.cw + 1) (* planted: windows one cycle too long *)
    else k >=: uresize (fld "hi") (l.cw + 1)
  in
  let op = fld "op" in
  let is_await = op ==:. 1
  and is_hold = op ==:. 2 in
  let complete =
    mux op [ pv; pv &: ge_lo; pv &: ge_hi; ge_hi ]
  in
  let early_fire = is_await &: fld "e_en" &: pv &: ~:ge_lo in
  let tmo = is_await &: ~:pv &: ge_hi in
  let hold_bad = is_hold &: ~:pv in
  let fire_now = early_fire |: tmo |: hold_bad in
  let complete = complete &: ~:fire_now in
  let oc = fld "oc" in
  let c_fire = oc ==:. 1
  and c_stop = (oc ==:. 1) |: (oc ==:. 2) in
  let fire_role = mux2 fire_now (mux2 early_fire (fld "e_role") (fld "c_role")) (fld "f_role")
  and fire_code = mux2 fire_now (mux2 early_fire (fld "e_code") (fld "c_code")) (fld "f_code") in
  let live = ~:stopped in
  let fire = live &: (fire_now |: (complete &: c_fire)) in
  let complete = live &: complete in
  let goto = complete &: (oc ==:. 0) in
  let max_cnt = (1 lsl l.cw) - 1 in
  pc_d <== mux2 goto (fld "target") pc;
  cnt_d <== mux2 complete (zero l.cw) (mux2 (cnt ==:. max_cnt) cnt (cnt +:. 1));
  stop_d <== (stopped |: (fire &: f.active) |: (complete &: c_stop &: f.active));
  { MC.fire; fire_role; fire_code }
;;

let layout_of_program (p : Program.t) =
  let depth = Array.fold p.watchers ~init:1 ~f:(fun a w -> Int.max a (Array.length w.instrs)) in
  { cw = MC.count_width p; pw = MC.pc_width depth }
;;

(* ROM-store engine for one compiled program (same interface as the hardwired monitor). *)
let create_rom ?(bug = `None) (p : Program.t) (i : _ MC.I.t) =
  let f = MC.Front.create i in
  let l = layout_of_program p in
  let outs =
    Array.to_list
      (Array.mapi p.watchers ~f:(fun ui w ->
         let words = Array.to_list (Array.map w.instrs ~f:(encode l p w)) in
         let fetch pc =
           match words with
           | [ only ] -> ignore (pc : Signal.t); only
           | _ -> mux pc words
         in
         (* planted bugs for A1-mon negative controls. The window bug goes into every unit:
            planted in watcher 0 only, it was vacuous, because that watcher (host_run) has no
            bounded window and the comparator was optimised away (A1MON negative control
            passed, 2026-10-17). The code bug stays in watcher 0. *)
         let window_bug = Poly.equal bug `Window_off_by_one in
         let o = unit_ ~window_bug f ~l ~ui ~fetch in
         if ui = 0 && Poly.equal bug `Code_off_by_one
         then { o with fire_code = o.fire_code +:. 1 }
         else o))
  in
  MC.verdict f outs
;;

let circuit_rom ?(name = "mon_engine_rom") ?bug p =
  let module C = Circuit.With_interface (MC.I) (MC.O) in
  C.create_exn ~name (create_rom ?bug p)
;;

(* Loadable engine for the area estimate: [n_units] watchers x [depth] instruction slots. *)
module Loadable = struct
  module I = struct
    type 'a t =
      { mon : 'a MC.I.t
      ; we : 'a
      ; wunit : 'a [@bits 3]
      ; waddr : 'a [@bits 6]
      ; wdata : 'a [@bits 128]
      }
    [@@deriving hardcaml]
  end

  let create ~n_units ~depth ~cw (i : _ I.t) =
    let l = { cw; pw = MC.pc_width depth } in
    let wd = width l in
    let f = MC.Front.create i.mon in
    let outs =
      List.init n_units ~f:(fun ui ->
        let slots =
          List.init depth ~f:(fun a ->
            let we = i.we &: (i.wunit ==:. ui) &: (i.waddr ==:. a) in
            (* program slots are not cleared by reset: a reset must not erase the program *)
            reg (Reg_spec.create ~clock:i.mon.clock ()) ~enable:we (select i.wdata (wd - 1) 0)
            -- sprintf "eng_u%d_slot%d" ui a)
        in
        unit_ f ~l ~ui ~fetch:(fun pc -> mux pc slots))
    in
    MC.verdict f outs
  ;;

  let circuit ~n_units ~depth ~cw =
    let module C = Circuit.With_interface (I) (MC.O) in
    C.create_exn
      ~name:(sprintf "mon_engine_load_u%d_d%d_w%d" n_units depth cw)
      (create ~n_units ~depth ~cw)
  ;;
end
