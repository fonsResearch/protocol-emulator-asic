(* Mutation scopes for the v2 design (plan step 9), on the generic engine of [Mutate]
   (enumerate, copier, operators unchanged).

   Units:
     lane_rtl   Pemu_rtl_v1.Lane_rtl, SRAM macro stubbed (A_DOUT is the formal read data)
     lane_spec  Pemu_spec_v1.Lane_circuit, imem stubbed
     mon_lane   Pemu_monitor_v1.Mon_lane (5 slots; [pipe] as shipped), with its observation
                front end (Mon_spec.observe, built inside Mon_lane when no ~front is given) in
                scope, package tables, present bits and the instruction fetch as formal inputs.
                The ROM contents are therefore not mutated here (contract mutants are separate).

   A site index identifies the same graph node in every elaboration of the same unit with the
   same parameters, as in [Mutate]. *)
open! Core
open Hardcaml
open Signal
module Lr = Pemu_rtl_v1.Lane_rtl
module Sram = Pemu_rtl_v1.Sram256
module Lc = Pemu_spec_v1.Lane_circuit
module L = Pemu_monitor_v1.Mon_lane
module S = Pemu_monitor_v1.Mon_spec
module M = Pemu_monitor_v1.Mprog

type unit_ =
  | Lane_rtl
  | Lane_spec
  | Mon_lane
[@@deriving sexp_of, equal]

let unit_to_string = function
  | Lane_rtl -> "lane_rtl"
  | Lane_spec -> "lane_spec"
  | Mon_lane -> "mon_lane"
;;

let unit_of_string = function
  | "lane_rtl" -> Lane_rtl
  | "lane_spec" -> Lane_spec
  | "mon_lane" -> Mon_lane
  | s -> failwithf "unknown unit %s" s ()
;;

(* the active mutation: (unit, site index); consulted by the v2 harness constructors *)
let active : (unit_ * int) option ref = ref None

let with_active m ~f =
  let saved = !active in
  active := m;
  Exn.protect ~f ~finally:(fun () -> active := saved)
;;

let index_for u = match !active with Some (u', i) when equal_unit_ u u' -> Some i | _ -> None
let uid_set l = Mutate.uid_set l

(* ---- lane RTL ---- *)
let lane_rtl_scope () =
  let formal = Lr.I.map Lr.I.port_widths ~f:wire in
  let dout_formal = wire 16 in
  let captured = ref None in
  let o =
    Lr.create
      ~sram:(fun si ->
        captured := Some si;
        { Sram.O.a_dout = dout_formal })
      formal
  in
  let si = Option.value_exn !captured in
  let roots = Lr.O.to_list o @ Sram.I.to_list si in
  formal, dout_formal, o, si, roots, uid_set (dout_formal :: Lr.I.to_list formal)
;;

(* mutant (or identity, index -1) lane RTL with the signature of [Lr.create ~sram] *)
let lane_rtl ~index ~(sram : Lr.sram) (actual : Signal.t Lr.I.t) =
  let formal, dout_formal, o, si, roots, stop = lane_rtl_scope () in
  let sites = Mutate.enumerate ~stop roots in
  let subst = Mutate.bind_subst formal actual ~to_list:Lr.I.to_list in
  let dout_w = wire 16 -- "rtl_imem_dout_w" in
  Hashtbl.set subst ~key:(Signal.uid dout_formal) ~data:dout_w;
  let copy = Mutate.copier ~subst ~mutation:(Mutate.mutation_of ~sites index) in
  let o' = Lr.O.map o ~f:copy in
  let si' = Sram.I.map si ~f:copy in
  dout_w <== (sram si').a_dout;
  o'
;;

(* ---- lane spec ---- *)
let lane_spec_scope () =
  let formal = Lc.I.map Lc.I.port_widths ~f:wire in
  let rdata_formal = wire 16 in
  let pc_cap = ref [] in
  let o =
    Lc.create
      ~imem:(fun pc ->
        pc_cap := pc :: !pc_cap;
        rdata_formal)
      formal
  in
  (match !pc_cap with [ _ ] -> () | _ -> failwith "Mutate_v2: Lane_circuit imem called more than once");
  let pc = List.hd_exn !pc_cap in
  let roots = Lc.O.to_list o @ [ pc ] in
  formal, rdata_formal, o, pc, roots, uid_set (rdata_formal :: Lc.I.to_list formal)
;;

let lane_spec ~index ~(imem : Signal.t -> Signal.t) (actual : Signal.t Lc.I.t) =
  (* Lane_circuit.create prepends its taps to a global list: isolate this elaboration's taps
     (an earlier copy's taps refer to that copy's formal wires) *)
  let saved_taps = !Lc.taps in
  Lc.taps := [];
  let formal, rdata_formal, o, pc, roots, stop = lane_spec_scope () in
  let sites = Mutate.enumerate ~stop roots in
  let subst = Mutate.bind_subst formal actual ~to_list:Lc.I.to_list in
  let rdata_w = wire 16 in
  Hashtbl.set subst ~key:(Signal.uid rdata_formal) ~data:rdata_w;
  (* Lane_circuit.taps (ag_pkg symmetry lemma) were set by the scope's elaboration: re-point them
     at the copied graph *)
  let taps = !Lc.taps in
  let copy = Mutate.copier ~subst ~mutation:(Mutate.mutation_of ~sites index) in
  let o' = Lc.O.map o ~f:copy in
  rdata_w <== imem (copy pc);
  Lc.taps := List.map taps ~f:(fun (n, s) -> n, copy s) @ saved_taps;
  o'
;;

(* ---- monitor lane ---- *)
let formal_tables () : S.tables * Signal.t list =
  let all = ref [] in
  let w n =
    let x = wire n in
    all := x :: !all;
    x
  in
  let t : S.tables =
    { remap = Array.init 16 ~f:(fun _ -> w 6)
    ; preds = Array.init 16 ~f:(fun _ -> w M.pred_width)
    ; windows = Array.init 8 ~f:(fun _ -> w 12)
    ; code_role = Array.init 16 ~f:(fun _ -> w 1)
    ; code_val = Array.init 16 ~f:(fun _ -> w 8)
    ; starts = Array.init S.n_units ~f:(fun _ -> w 7)
    ; guards = Array.init S.n_units ~f:(fun _ -> w 1, w 4, w 7, w 7, w 7)
    ; present = Array.init S.n_units ~f:(fun _ -> true)
    }
  in
  t, !all
;;

let tables_to_list (t : S.tables) =
  Array.to_list t.remap @ Array.to_list t.preds @ Array.to_list t.windows @ Array.to_list t.code_role
  @ Array.to_list t.code_val @ Array.to_list t.starts
  @ List.concat_map (Array.to_list t.guards) ~f:(fun (a, b, c, d, e) -> [ a; b; c; d; e ])
;;

let mon_lane_scope ~slots ~pipe =
  let formal = S.I.map S.I.port_widths ~f:wire in
  let tables, _ = formal_tables () in
  let present = Array.init S.n_units ~f:(fun _ -> wire 1) in
  let w_formal = wire M.instr_width in
  let cap = ref [] in
  let lint = ref None in
  let o =
    L.create ~slots ~pipe ~tables ~present ~probe:(fun x -> lint := Some x)
      ~fetch:(fun cur pc ->
        cap := (cur, pc) :: !cap;
        w_formal)
      formal
  in
  let cur, pc =
    match !cap with [ x ] -> x | _ -> failwith "Mutate_v2: Mon_lane fetch called more than once"
  in
  let roots = L.O.to_list o @ [ cur; pc ] in
  let stop =
    uid_set ((w_formal :: S.I.to_list formal) @ tables_to_list tables @ Array.to_list present)
  in
  formal, tables, present, w_formal, (cur, pc), o, roots, stop, Option.value_exn !lint
;;

(* the probe hook of Mon_lane (R1 invariants): internals of the copied (mutant) graph *)
let copy_internals copy (x : L.internals) : L.internals =
  let ev (e : S.events) : S.events =
    { pop_ev = copy e.pop_ev; pop_data = copy e.pop_data; push_ev = copy e.push_ev
    ; push_data = copy e.push_data }
  in
  { entries =
      Array.map x.entries ~f:(fun st -> S.ustate_of_list (List.map (S.ustate_to_list st) ~f:copy))
  ; mask_q = copy x.mask_q; smask = copy x.smask; busy_q = copy x.busy_q; slot_q = copy x.slot_q
  ; bank_l = copy x.bank_l; ev_l = ev x.ev_l }
;;

let mon_lane ?probe ~index ~slots ~pipe ~(tables : S.tables) ~(present : Signal.t array)
  ~(fetch : Signal.t -> Signal.t -> Signal.t) (actual : Signal.t S.I.t)
  =
  let formal, ftab, fpresent, w_formal, (cur, pc), o, roots, stop, lint =
    mon_lane_scope ~slots ~pipe
  in
  let sites = Mutate.enumerate ~stop roots in
  let subst = Mutate.bind_subst formal actual ~to_list:S.I.to_list in
  List.iter2_exn (tables_to_list ftab) (tables_to_list tables) ~f:(fun f a ->
    Hashtbl.set subst ~key:(Signal.uid f) ~data:a);
  Array.iter2_exn fpresent present ~f:(fun f a -> Hashtbl.set subst ~key:(Signal.uid f) ~data:a);
  let w_w = wire M.instr_width in
  Hashtbl.set subst ~key:(Signal.uid w_formal) ~data:w_w;
  let copy = Mutate.copier ~subst ~mutation:(Mutate.mutation_of ~sites index) in
  let o' = L.O.map o ~f:copy in
  w_w <== fetch (copy cur) (copy pc);
  Option.iter probe ~f:(fun f -> f (copy_internals copy lint));
  o'
;;

let sites ?(slots = 5) ?(pipe = true) u =
  match u with
  | Lane_rtl ->
    let _, _, _, _, roots, stop = lane_rtl_scope () in
    Mutate.enumerate ~stop roots
  | Lane_spec ->
    let _, _, _, _, roots, stop = lane_spec_scope () in
    Mutate.enumerate ~stop roots
  | Mon_lane ->
    let _, _, _, _, _, _, roots, stop, _ = mon_lane_scope ~slots ~pipe in
    Mutate.enumerate ~stop roots
;;
