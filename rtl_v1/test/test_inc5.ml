(* Increment 5 (log/increments_v2.md section 5): USB-LS TX (ROM 7 of Rom_lib.v2_inc5, P = 19 at
   30 MHz) on the v2 top RTL in the shipped configuration (lane pipe + vpipe + param_windows),
   against Psim. Firmware mutants as the A2 negatives (formal/src/ag_pkg.ml usb_all): sync (bad SYNC
   byte, monitor fail), nopush (status not pushed, monitor fail), sendc (CRC not updated: contents,
   G7, are not checked on chip, so no firing is expected). *)
open! Core
open Pemu_spec_v1
open Pemu_monitor_v1
open Pemu_rtl_v1
module D = Test_c3_diff
module P1 = Programs_v1

let lib = List.map (Rom_lib.v2_inc5 ()) ~f:Compile.compile_exn
let pkg = 7
let p = Rom_lib.usb_ls_p ~clock_hz:Rom_lib.v2_clock_hz

let setup prog =
  { Pemu_protocols_v1.Psim.prog; own = P1.usb_own; od = 0; cfg = P1.usb_cfg; cfg2 = 0; p
  ; contract = Library_v1.usb_ls_tx (); open_drain_wired_and = 0 }
;;

let mut ~from ~to_ = List.map P1.usb_ls_tx ~f:(fun x -> if Isa1.equal x from then to_ else x)

let%expect_test "increment 5: USB-LS TX on the v2 top (lane pipe + vpipe + param_windows)" =
  let k = List.hd_exn (D.calibrate ()) in
  printf "P = %d, package %s\n" p (List.nth_exn lib pkg).name;
  let run ~name ~prog ~tx_bytes ~cycles =
    D.compare_one_cfg ~lane_pipe:true ~verdict_pipe:true ~param_windows:true ~lib ~k ~name ~setup:(setup prog) ~pkg ~tx_bytes
      ~peer:(fun () -> D.no_peer) ~cycles ()
  in
  let two = [ 0xC3; 0; 0x4B; 3; 0x01; 0x02; 0x03 ] in
  run ~name:"two packets" ~prog:P1.usb_ls_tx ~tx_bytes:two ~cycles:5000;
  run ~name:"N = 9 (status 1, halt)" ~prog:P1.usb_ls_tx ~tx_bytes:[ 0xC3; 9; 0x01 ] ~cycles:3000;
  run ~name:"mutant sync (fail)" ~prog:(mut ~from:(Isa1.Ldi (L Sr, 0x80)) ~to_:(Isa1.Ldi (L Sr, 0x81))) ~tx_bytes:two ~cycles:5000;
  run ~name:"mutant nopush (fail)" ~prog:(mut ~from:(Isa1.Push R3) ~to_:Isa1.Nop) ~tx_bytes:two ~cycles:5000;
  run ~name:"mutant sendc (G7, unchecked)" ~prog:(mut ~from:(Isa1.Ser (Sendc R2)) ~to_:(Isa1.Ser (Send R2))) ~tx_bytes:two ~cycles:5000;
  [%expect {|
    P = 19, package usb_ls_tx_v1
    two packets                    mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (2)
    N = 9 (status 1, halt)         mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (1)
    mutant sync (fail)             mon-in = pads = pins = | fail psim A3@421 chip A3@421 | blame psim - chip - | rx = (2)
    mutant nopush (fail)           mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (2)
    mutant sendc (G7, unchecked)   mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (2)
    |}]
;;
