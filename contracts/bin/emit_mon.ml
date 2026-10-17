(* Emit monitor circuits as Verilog for the area estimate.
   usage: emit_mon.exe <dir>   (prints the emitted module names) *)
open! Core
open Hardcaml
open Pemu_contracts

let () =
  let dir = (Sys.get_argv ()).(1) in
  let p = Program.compile (Library.uart_tx_v01 ~d:4 ()) in
  let circuits =
    [ Mon_circuit.Hardwired.circuit ~name:"mon_hardwired_uart_d4" p
    ; Engine.circuit_rom ~name:"mon_engine_rom_uart_d4" p
    ]
    @ List.map
        [ 2, 16, 12; 4, 16, 12; 4, 32, 12; 8, 16, 12; 4, 16, 16 ]
        ~f:(fun (n_units, depth, cw) -> Engine.Loadable.circuit ~n_units ~depth ~cw)
  in
  List.iter circuits ~f:(fun c ->
    Rtl.output ~output_mode:(To_file (dir ^/ Circuit.name c ^ ".v")) Verilog c;
    print_endline (Circuit.name c));
  printf
    "# loadable instruction width (cw=12, pw=4): %d bits\n"
    (Engine.width { Engine.cw = 12; pw = 4 })
;;
