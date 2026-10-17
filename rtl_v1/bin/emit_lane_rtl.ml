(* Emit the lane RTL as Verilog: [macro] instantiates RM_IHPSG13_1P_256x16_c2_bm_bist (for
   synthesis); [behavioural] uses the Hardcaml SRAM model (for simulation). *)
open! Core
open Hardcaml
open Pemu_rtl_v1
module C = Circuit.With_interface (Lane_rtl.I) (Lane_rtl.O)

let () =
  let mode = (Sys.get_argv ()).(1) in
  let sram =
    match mode with
    | "macro" -> Sram256.blackbox
    | _ -> fun i -> fst (Sram256.behavioural i)
  in
  let circ = C.create_exn ~name:("pemu_lane_" ^ mode) (Lane_rtl.create ~sram) in
  Rtl.print Verilog circ
;;
