(* Emit the observer circuits as Verilog: ctr_ok.v (wrap=9), ctr_bug.v (wrap=10). *)
open! Core
open Hardcaml

let () =
  let dir = (Sys.get_argv ()).(1) in
  List.iter [ "ctr_ok", 9; "ctr_bug", 10 ] ~f:(fun (name, wrap) ->
    Rtl.output
      ~output_mode:(To_file (dir ^/ name ^ ".v"))
      Verilog
      (Smoke_counter.observer ~wrap))
