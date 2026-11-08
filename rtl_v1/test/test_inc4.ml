(* Increment 4 probe (log/increments_v2.md section 6): SPI modes 1-3 (controller ROM 8-10, target
   ROM 11-13 of Rom_lib.v2_inc4, P = 7) on the v2 top RTL in the shipped configuration (lane pipe +
   vpipe + param_windows), against Psim, with the C3 directed peers and defects of mode 0. *)
open! Core
open Pemu_spec_v1
open Pemu_monitor_v1
open Pemu_rtl_v1
module D = Test_c3_diff
module P1 = Programs_v1
module Lib = Library_v1
module Peers = Pemu_protocols_v1.Peers

let lib = List.map (Rom_lib.v2_inc4 ()) ~f:Compile.compile_exn

let ctl_setup ~cpol ~cpha =
  { Pemu_protocols_v1.Psim.prog = P1.spi_ctl ~cpol ~cpha; own = P1.spi_own_ctl; od = 0; cfg = P1.spi_cfg_ctl
  ; cfg2 = P1.spi_cfg2_ctl; p = 7; contract = Lib.spi_ctl ~cpol ~cpha ~h:2; open_drain_wired_and = 0 }
;;

let tgt_setup ~cpol ~cpha =
  { Pemu_protocols_v1.Psim.prog = P1.spi_tgt ~cpol ~cpha; own = P1.spi_own_tgt; od = 0; cfg = 0; cfg2 = 0; p = 7
  ; contract = Lib.spi_tgt ~cpol ~cpha ~h_min:3 ~g:6; open_drain_wired_and = 0 }
;;

let%expect_test "increment 4: SPI modes 1-3 on the v2 top (lane pipe + vpipe + param_windows)" =
  let k = List.hd_exn (D.calibrate ()) in
  let run ~name ~setup ~pkg ~peer ~cycles =
    D.compare_one_cfg ~lane_pipe:true ~verdict_pipe:true ~param_windows:true ~lib ~k ~name ~setup ~pkg
      ~tx_bytes:D.host_bytes ~peer ~cycles ()
  in
  List.iteri [ false, true; true, false; true, true ] ~f:(fun i (cpol, cpha) ->
    let m = i + 1 in
    printf "mode %d: ctl package %s, tgt package %s\n" m (List.nth_exn lib (8 + i)).name (List.nth_exn lib (11 + i)).name;
    let tgt tco () = (Peers.spi_target ~cpol ~cpha ~tco ~send:D.peer_bytes ()).drive in
    run ~name:(sprintf "spi_ctl m%d tco 3" m) ~setup:(ctl_setup ~cpol ~cpha) ~pkg:(8 + i) ~peer:(tgt 3) ~cycles:6000;
    run ~name:(sprintf "spi_ctl m%d tco 14 (blame)" m) ~setup:(ctl_setup ~cpol ~cpha) ~pkg:(8 + i) ~peer:(tgt 14) ~cycles:6000;
    let ctl ?defect () =
      Peers.spi_controller ~cpol ~cpha ~hp:40 ~setup:40 ~hold:40 ~gap:144 ~mdly:2 ~t0:300 ~bytes:D.peer_bytes ?defect ()
    in
    let cycles = (ctl ()).frames_end + 200 in
    run ~name:(sprintf "spi_tgt m%d hp 40" m) ~setup:(tgt_setup ~cpol ~cpha) ~pkg:(11 + i) ~peer:(fun () -> (ctl ()).cdrive) ~cycles;
    run ~name:(sprintf "spi_tgt m%d early CS (blame)" m) ~setup:(tgt_setup ~cpol ~cpha) ~pkg:(11 + i)
      ~peer:(fun () -> (ctl ~defect:(Peers.Early_rise (2, 9)) ()).cdrive) ~cycles);
  [%expect {|
    mode 1: ctl package spi_ctl_v1_m1_h2, tgt package spi_tgt_v1_m1_h3_g6
    spi_ctl m1 tco 3               mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    spi_ctl m1 tco 14 (blame)      mon-in = pads = pins = | fail psim - chip - | blame psim 91@121 chip 91@121 | rx = (8)
    spi_tgt m1 hp 40               mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    spi_tgt m1 early CS (blame)    mon-in = pads = pins = | fail psim - chip - | blame psim 61@2337 chip 61@2337 | rx = (7)
    mode 2: ctl package spi_ctl_v1_m2_h2, tgt package spi_tgt_v1_m2_h3_g6
    spi_ctl m2 tco 3               mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    spi_ctl m2 tco 14 (blame)      mon-in = pads = pins = | fail psim - chip - | blame psim 91@113 chip 91@113 | rx = (8)
    spi_tgt m2 hp 40               mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    spi_tgt m2 early CS (blame)    mon-in = pads = pins = | fail psim - chip - | blame psim 52@2345 chip 52@2345 | rx = (7)
    mode 3: ctl package spi_ctl_v1_m3_h2, tgt package spi_tgt_v1_m3_h3_g6
    spi_ctl m3 tco 3               mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    spi_ctl m3 tco 14 (blame)      mon-in = pads = pins = | fail psim - chip - | blame psim 91@121 chip 91@121 | rx = (8)
    spi_tgt m3 hp 40               mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    spi_tgt m3 early CS (blame)    mon-in = pads = pins = | fail psim - chip - | blame psim 61@2337 chip 61@2337 | rx = (7)
    |}]
;;
