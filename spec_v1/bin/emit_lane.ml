(* Emit the S1 v1 lane spec circuit as Verilog with the UART TX (8N1, d = 4 steps per bit)
   reference program in ROM. *)
open! Core
open Hardcaml
open Pemu_spec_v1

module C = Circuit.With_interface (Lane_circuit.I) (Lane_circuit.O)

let () =
  let words = Isa1.assemble (Programs_v1.uart_tx ~d:4) in
  let circ = C.create_exn ~name:"lane_spec" (Lane_circuit.create ~imem:(Lane_circuit.imem_rom words)) in
  Rtl.print Verilog circ
;;
