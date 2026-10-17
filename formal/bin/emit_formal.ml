(* Emit all formal harnesses (non-debug) as Verilog into <dir>; print their names. *)
open! Core
open Hardcaml
open Pemu_formal

let () =
  let dir = (Sys.get_argv ()).(1) in
  List.iter (Registry.all ()) ~f:(fun c ->
    Rtl.output ~output_mode:(To_file (dir ^/ Circuit.name c ^ ".v")) Verilog c;
    print_endline (Circuit.name c))
;;
