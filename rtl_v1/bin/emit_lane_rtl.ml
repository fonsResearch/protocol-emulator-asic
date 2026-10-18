(* Emit Verilog: [macro] lane with RM_IHPSG13_1P_256x16_c2_bm_bist instantiated (synthesis);
   [behavioural] lane with the Hardcaml SRAM model (simulation); [top_macro] core v1;
   [top_macro_mon] core v1 with the monitor engine and a 2-package ROM library (UART TX v1
   guarantee, d = 3 on uio[0] and d = 4 on uio[1]), for area measurement. *)
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
  if String.equal mode "top_macro_mon"
  then (
    let lib =
      Pemu_monitor_v1.(
        [ Compile.compile_exn (Library_v1.uart_tx ~d:3 ~pin:0)
        ; Compile.compile_exn (Library_v1.uart_tx ~d:4 ~pin:1) ])
    in
    let circ =
      CT.create_exn ~name:"pemu_core_v1m"
        (Top_v1.create ~lib ~sram:(fun l ->
           Sram256.blackbox
             ~instance:(if l < 2 then sprintf "u_imem_l%d" l else sprintf "u_lstore_l%d" (l - 2))))
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
