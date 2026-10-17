(* Emit Verilog: [macro] lane with RM_IHPSG13_1P_256x16_c2_bm_bist instantiated (synthesis);
   [behavioural] lane with the Hardcaml SRAM model (simulation); [top_macro] core v1. *)
open! Core
open Hardcaml
open Pemu_rtl_v1
module C = Circuit.With_interface (Lane_rtl.I) (Lane_rtl.O)
module CT = Circuit.With_interface (Top_v1.I) (Top_v1.O)

let () =
  let mode = (Sys.get_argv ()).(1) in
  if String.equal mode "top_macro"
  then (
    let circ =
      CT.create_exn ~name:"pemu_core_v1" (Top_v1.create ~sram:(fun l -> Sram256.blackbox ~instance:(sprintf "u_imem_l%d" l)))
    in
    Rtl.print Verilog circ;
    exit 0);
  let sram =
    match mode with
    | "macro" -> Sram256.blackbox ?instance:None
    | _ -> fun i -> fst (Sram256.behavioural i)
  in
  let circ = C.create_exn ~name:("pemu_lane_" ^ mode) (Lane_rtl.create ~sram) in
  Rtl.print Verilog circ
;;
