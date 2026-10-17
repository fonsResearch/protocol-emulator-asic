(* Emit the S1 v1 lane spec circuit as Verilog with a UART TX (8N1) program in ROM. The
   program pops a byte, sends start bit, 8 data bits LSB first, stop bit, with WAIT k between
   bits (bit time = k+1 steps; tick prescaling is outside the lane). *)
open! Core
open Hardcaml
open Pemu_spec_v1

let uart_tx ~k =
  Isa1.
    [ Ldi (Xo, 0); Out 1; Oen 1 (* idle high *)
    ; Pop Sr (* 3 *)
    ; Out 0; Wait k (* start bit *)
    ; Ldi (L Lc, 8)
    ; Pin (0, Out_lsb); Wait (k - 1); Djnz 7 (* data bits *)
    ; Out 1; Wait k (* stop bit *)
    ; Jmp 3 ]
;;

module C = Circuit.With_interface (Lane_circuit.I) (Lane_circuit.O)

let () =
  let words = Isa1.assemble (uart_tx ~k:3) in
  let circ = C.create_exn ~name:"lane_spec" (Lane_circuit.create ~imem:(Lane_circuit.imem_rom words)) in
  Rtl.print Verilog circ
;;
