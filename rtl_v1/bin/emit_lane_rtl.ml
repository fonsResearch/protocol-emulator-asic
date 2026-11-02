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
  if String.is_prefix mode ~prefix:"top_macro_mon"
  then (
    (* top_macro_mon: default build, lane 1 loadable (user decision 2026-10-18);
       top_macro_mon_both: both lanes loadable; top_macro_mon_rom: ROM only *)
    (* top_macro_mon_sweep (v2 step 2 area sweep): PEMU_LOADABLE = rom | l1 | both and
       PEMU_LIB = uart2 | lib10 | all select the configuration *)
    let sweep = String.equal mode "top_macro_mon_sweep" in
    let env_or v d = Option.value (Sys.getenv v) ~default:d in
    let loadable =
      match (if sweep then "top_macro_mon_" ^ env_or "PEMU_LOADABLE" "l1" else mode) with
      | "top_macro_mon_both" -> [| true; true |]
      | "top_macro_mon_rom" -> [| false; false |]
      | _ -> [| false; true |]
    in
    (* top_macro_mon_lib10 / _lib15 / _liball: ROM-library area study (plan step 7): the 10 committed
       protocol packages; lib15 adds five copies of the largest (SPI target, mode 0) as
       stand-ins for the planned I2C and USB packages *)
    let protocol10 = Rom_lib.protocol10 () in
    let study =
      if sweep
      then (
        match env_or "PEMU_LIB" "uart2" with
        | "lib10" -> Some "10"
        | "all" -> Some "all"
        | "v2min" -> Some "v2min"
        | "v2inc1" -> Some "v2inc1"
        | _ -> None)
      else String.chop_prefix mode ~prefix:"top_macro_mon_lib"
    in
    let lib =
      Pemu_monitor_v1.(
        match study with
        | Some "10" -> List.map protocol10 ~f:Compile.compile_exn
        | Some "all" -> List.map (Rom_lib.all15 ()) ~f:Compile.compile_exn
        | Some "v2min" -> List.map (Rom_lib.minimum_v2 ()) ~f:Compile.compile_exn
        | Some "v2inc1" -> List.map (Rom_lib.v2_inc1 ()) ~f:Compile.compile_exn
        | Some "15" ->
          List.map
            (protocol10 @ List.init 5 ~f:(fun _ -> Library_v1.spi_tgt ~cpol:false ~cpha:false ~h_min:3 ~g:6))
            ~f:Compile.compile_exn
        | _ ->
          [ Compile.compile_exn (Library_v1.uart_tx ~d:3 ~pin:0)
          ; Compile.compile_exn (Library_v1.uart_tx ~d:4 ~pin:1) ])
    in
    (* PEMU_LIB_STATS=1: per-package ROM word counts on stderr (area study) *)
    if Option.is_some (Sys.getenv "PEMU_LIB_STATS")
    then
      List.iter lib ~f:(fun (p : Pemu_monitor_v1.Mprog.t) ->
        let w = Array.sum (module Int) p.units ~f:(fun u -> Array.length u.code) in
        eprintf "lib %s units %d words %d\n" p.name (Array.length p.units) w);
    let circ =
      CT.create_exn ~name:"pemu_core_v1m"
        (Top_v1.create ~loadable ?mon_slots:(Option.map (Sys.getenv "PEMU_SLOTS") ~f:Int.of_string) ~lib ~sram:(fun l ->
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
