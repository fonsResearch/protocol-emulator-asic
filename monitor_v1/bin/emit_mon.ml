(* Emit monitor circuits as Verilog for synthesis measurements.
   free: one lane of the ISA spec circuit with every table entry and every unit's fetched
   instruction word a top-level input (no constant propagation: upper bound on the
   per-lane datapath). *)
open! Core
open Hardcaml
open Signal
open Pemu_monitor_v1
module S = Mon_spec

let free_tables ?(units = 8) () =
  let inp n w = input n w in
  let tables : S.tables =
    { remap = Array.init 16 ~f:(fun k -> inp (sprintf "remap%d" k) 6)
    ; preds = Array.init 16 ~f:(fun k ->
        if k = 0 || k = 15 then zero Mprog.pred_width else inp (sprintf "pred%d" k) Mprog.pred_width)
    ; windows = Array.init 8 ~f:(fun k -> if k = 0 then zero 12 else inp (sprintf "win%d" k) 12)
    ; code_role = Array.init 16 ~f:(fun k -> if k = 0 then gnd else inp (sprintf "crole%d" k) 1)
    ; code_val = Array.init 16 ~f:(fun k -> if k = 0 then zero 8 else inp (sprintf "cval%d" k) 8)
    ; starts = Array.init S.n_units ~f:(fun u -> inp (sprintf "start%d" u) 7)
    ; guards = Array.init S.n_units ~f:(fun u ->
        ( inp (sprintf "gen%d" u) 1, inp (sprintf "gp%d" u) 4, inp (sprintf "gs%d" u) 7
        , inp (sprintf "ge%d" u) 7, inp (sprintf "gh%d" u) 7 ))
    ; present = Array.init S.n_units ~f:(fun u -> u < units)
    }
  in
  tables
;;

let free ?units () =
  let tables = free_tables ?units () in
  let pcs = ref [] in
  let fetch u pc =
    pcs := output (sprintf "pc%d" u) pc :: !pcs;
    input (sprintf "iw%d" u) Mprog.instr_width
  in
  let i = S.I.map S.I.port_names_and_widths ~f:(fun (n, w) -> input n w) in
  let o = S.create ~tables ~fetch i in
  let outs = S.O.to_list (S.O.map2 S.O.port_names o ~f:output) in
  Circuit.create_exn ~name:"mon_lane_free" (outs @ !pcs)
;;

(* time-multiplexed lane, free tables, one fetch port (unit, pc) -> word *)
let lane_free () =
  let tables = free_tables () in
  let present = Array.init S.n_units ~f:(fun u -> input (sprintf "present%d" u) 1) in
  let outs_f = ref [] in
  let fetch u pc =
    outs_f := [ output "f_unit" u; output "f_pc" pc ];
    input "iw" Mprog.instr_width
  in
  let i = S.I.map S.I.port_names_and_widths ~f:(fun (n, w) -> input n w) in
  let o = Mon_lane.create ~tables ~present ~fetch i in
  let outs = Mon_lane.O.to_list (Mon_lane.O.map2 Mon_lane.O.port_names o ~f:output) in
  Circuit.create_exn ~name:"mon_lane_tm_free" (outs @ !outs_f)
;;

let () =
  match Sys.get_argv () with
  | [| _; "free" |] -> Rtl.print Verilog (free ())
  | [| _; "lane_free" |] -> Rtl.print Verilog (lane_free ())
  | [| _; "free"; n |] -> Rtl.print Verilog (free ~units:(Int.of_string n) ())
  | _ -> eprintf "usage: emit_mon free\n"
;;
