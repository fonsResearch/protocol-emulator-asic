(* Emit the core as Verilog for the Tiny Tapeout flow.
   usage: generate.exe <output-dir>
   - pemu_core.v        behavioural SRAM model (flip-flops), for simulation and formal
   - pemu_core_macro.v  RM_IHPSG13_1P_64x16_c2 instantiated (black box), for synthesis *)
open! Core
open Hardcaml

let () =
  let dir = (Sys.get_argv ()).(1) in
  Rtl.output
    ~output_mode:(To_file (dir ^/ "pemu_core.v"))
    Verilog
    (Pemu_rtl.Engine.circuit_behavioural ());
  Rtl.output
    ~output_mode:(To_file (dir ^/ "pemu_core_macro.v"))
    Verilog
    (Pemu_rtl.Engine.circuit_macro ())
;;
