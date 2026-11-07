(* Increment 3 (log/increments_v2.md section 3): the I2C target Sm package (ROM 6 of
   Rom_lib.v2_inc3, P = 5, contract h_min 19 / l_min 22 / hd 19 at 30 MHz) on the v2 top RTL,
   against Psim with an I2C controller peer at the 30 MHz UM10204 Sm minima on the wired-AND bus.
   Same comparison as the C3 tests (Test_c3_env.compare_runs): lane-0 monitor-input stream, owned
   pins, verdict, pushes. Host stream: config byte (address 0x50), then two read bytes. *)
open! Core
open Pemu_spec_v1
open Pemu_monitor_v1
open Pemu_rtl_v1
module D = Test_c3_diff
module E = Test_c3_env
module Psim = Pemu_protocols_v1.Psim
module Peers = Pemu_protocols_v1.Peers
module P1 = Programs_v1

let lib = List.map (Rom_lib.v2_inc3 ()) ~f:Compile.compile_exn
let pkg = 6
let host = [ 0x50; 0xA1; 0x36 ]

let setup =
  { Psim.prog = P1.i2c_tgt ~addr:0x50; own = P1.i2c_own; od = P1.i2c_od; cfg = 0; cfg2 = 0
  ; p = Rom_lib.i2c_tgt_sm_p; contract = Rom_lib.i2c_tgt_sm_at ~clock_hz:Rom_lib.v2_clock_hz
  ; open_drain_wired_and = P1.i2c_own }
;;

let sm30 =
  { Peers.tlow = 141; thigh = 120; thd_sta = 120; tsu_sta = 141; tsu_sto = 120; tbuf = 141; dh = 1; su = 8 }
;;

let txs = [ `W (0x50, [ 0x11; 0x22 ]), true; `R (0x50, 2), false; `W (0x52, [ 0xAA ]), false ]

let u_ok (r : Psim.result) =
  let f = Psim.firings r in
  let b = List.find_map f ~f:(fun (c, ro, _) -> if Lang.equal_role ro Blame then Some c else None) in
  List.for_all f ~f:(fun (c, ro, _) ->
    match ro, b with Blame, _ -> true | Fail, Some b -> b <= c | Fail, None -> false)
;;

let run ?(lane_pipe = true) ?(verdict_pipe = true) ?(param_windows = true) ~k ~name ~t ~cycles () =
  let peer () = (Peers.i2c_controller ~t txs).cdrive in
  let c = D.chip_run ~lib ~lane_pipe ~verdict_pipe ~param_windows ~k ~setup ~pkg ~tx_bytes:host ~peer:(peer ()) ~cycles () in
  let r, pmi = E.psim_run ~clear_at:[] ~setup ~tx_bytes:host ~peer ~cycles in
  let x = E.compare_runs ~setup ~cycles c r pmi in
  if Option.is_some x.mon_first then printf "  (mon-in fields: %s)\n" (String.concat ~sep:"," x.mon_fields);
  printf "%-30s mon-in %-7s pins %-7s verdict %s pushes %s [%s] | psim [%s] U %b\n" name (E.show_o x.mon_first)
    (E.show_o x.pins_first) (if x.verdict_eq then "=" else "DIFF") (if x.rx_eq then "=" else "DIFF")
    (String.concat ~sep:" " (List.map (Psim.pushes r) ~f:(sprintf "%02X")))
    (Psim.show_firings r) (u_ok r)
;;

let%expect_test "increment 3: I2C target Sm on the v2 top (lane pipe + vpipe + param_windows), 30 MHz minima" =
  let k = List.hd_exn (D.calibrate ()) in
  printf "P = %d\n" setup.p;
  run ~k ~name:"clean" ~t:sm30 ~cycles:60_000 ();
  run ~k ~name:"clean, default build" ~lane_pipe:false ~verdict_pipe:false ~param_windows:false ~t:sm30 ~cycles:60_000 ();
  run ~k ~name:"controller tLOW 120" ~t:{ sm30 with tlow = 120 } ~cycles:60_000 ();
  run ~k ~name:"controller tHIGH 100" ~t:{ sm30 with thigh = 100 } ~cycles:60_000 ();
  run ~k ~name:"controller tHD;STA 60" ~t:{ sm30 with thd_sta = 60 } ~cycles:60_000 ();
  run ~k ~name:"controller late data (dh 150)" ~t:{ sm30 with dh = 150 } ~cycles:60_000 ();
  [%expect {|
    P = 5
    clean                          mon-in =       pins =       verdict = pushes = [11 22] | psim [] U true
    clean, default build           mon-in =       pins =       verdict = pushes = [11 22] | psim [] U true
    controller tLOW 120            mon-in =       pins =       verdict = pushes = [11 22] | psim [B71@643] U true
    controller tHIGH 100           mon-in =       pins =       verdict = pushes = [11 22] | psim [B72@763] U true
    controller tHD;STA 60          mon-in =       pins =       verdict = pushes = [11 22] | psim [B82@463] U true
    controller late data (dh 150)  mon-in =       pins =       verdict = pushes = [11 22] | psim [B83@673,F51@2815] U true
    |}]
;;

(* The pipelined slot schedule (Mon_engine ~lane_pipe, log/increments_v2.md section 3.4) under the
   C3 directed scenarios of Test_c3_diff (v2 minimum packages 0-3, same peers and defects), in the
   shipped configuration. Firing stamps are unchanged, so verdict codes and times must equal Psim. *)
let%expect_test "lane pipe: C3 directed scenarios, v2 minimum packages" =
  let k = List.hd_exn (D.calibrate ()) in
  let run ~name ~setup ~pkg ~tx_bytes ~peer ~cycles =
    D.compare_one_cfg ~lane_pipe:true ~verdict_pipe:true ~param_windows:true ~k ~name ~setup ~pkg ~tx_bytes ~peer ~cycles ()
  in
  let frames bp =
    Peers.frames_of ~bp ~st0:2000 [ 0x55; 0xA5; 0x00; 0xFF; 0x3C; 0x81; 0x7E; 0x01 ] ~gap:(fun b -> 3 + (b * 7 % 400))
  in
  let bp = D.uart_bp in
  run ~name:"uart_tx correct" ~setup:(D.uart_tx_setup (P1.uart_tx ~d:4)) ~pkg:0 ~tx_bytes:[ 0xA5; 0x3C; 0x00 ] ~peer:(fun () -> D.no_peer) ~cycles:4000;
  run ~name:"uart_tx bad start (fail)" ~setup:(D.uart_tx_setup (P1.uart_tx_bad_start ~d:4)) ~pkg:0 ~tx_bytes:[ 0xA5; 0x3C; 0x00 ] ~peer:(fun () -> D.no_peer) ~cycles:4000;
  run ~name:"uart_rx nominal" ~setup:(D.rx_setup ()) ~pkg:1 ~tx_bytes:[] ~peer:(fun () -> Peers.sender ~pin:1 ~bp ~frames:(frames bp) ~defect:No_defect) ~cycles:60_000;
  run ~name:"uart_rx 8% fast (blame)" ~setup:(D.rx_setup ()) ~pkg:1 ~tx_bytes:[] ~peer:(fun () -> let bp = bp /. 1.08 in Peers.sender ~pin:1 ~bp ~frames:(frames bp) ~defect:No_defect) ~cycles:60_000;
  run ~name:"spi_ctl m0 tco 3" ~setup:D.ctl_setup ~pkg:2 ~tx_bytes:D.host_bytes ~peer:(fun () -> (Peers.spi_target ~cpol:false ~cpha:false ~tco:3 ~send:D.peer_bytes ()).drive) ~cycles:6000;
  run ~name:"spi_ctl m0 tco 14 (blame)" ~setup:D.ctl_setup ~pkg:2 ~tx_bytes:D.host_bytes ~peer:(fun () -> (Peers.spi_target ~cpol:false ~cpha:false ~tco:14 ~send:D.peer_bytes ()).drive) ~cycles:6000;
  let ctl ?defect () = Peers.spi_controller ~cpol:false ~cpha:false ~hp:40 ~setup:40 ~hold:40 ~gap:144 ~mdly:2 ~t0:300 ~bytes:D.peer_bytes ?defect () in
  let cycles = (ctl ()).frames_end + 200 in
  run ~name:"spi_tgt m0 hp 40" ~setup:D.tgt_setup ~pkg:3 ~tx_bytes:D.host_bytes ~peer:(fun () -> (ctl ()).cdrive) ~cycles;
  run ~name:"spi_tgt m0 early CS (blame)" ~setup:D.tgt_setup ~pkg:3 ~tx_bytes:D.host_bytes ~peer:(fun () -> (ctl ~defect:(Peers.Early_rise (2, 9)) ()).cdrive) ~cycles;
  [%expect {|
    uart_tx correct                mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (0)
    uart_tx bad start (fail)       mon-in = pads = pins = | fail psim 13@81 chip 13@81 | blame psim - chip - | rx = (0)
    uart_rx nominal                mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    uart_rx 8% fast (blame)        mon-in = pads = pins = | fail psim - chip - | blame psim 32@4421 chip 32@4421 | rx = (6)
    spi_ctl m0 tco 3               mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    spi_ctl m0 tco 14 (blame)      mon-in = pads = pins = | fail psim - chip - | blame psim 91@113 chip 91@113 | rx = (8)
    spi_tgt m0 hp 40               mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    spi_tgt m0 early CS (blame)    mon-in = pads = pins = | fail psim - chip - | blame psim 52@2345 chip 52@2345 | rx = (7)
    |}]
;;

(* admission with the pipelined schedule: P >= slots = 5 (STATUS refused flag otherwise) *)
let%expect_test "lane pipe: the I2C target at P = 4 is refused, at P = 5 it runs" =
  let k = List.hd_exn (D.calibrate ()) in
  List.iter [ 4; 5 ] ~f:(fun p ->
    let c =
      D.chip_run ~lib ~lane_pipe:true ~verdict_pipe:true ~param_windows:true ~k ~setup:{ setup with p } ~pkg
        ~tx_bytes:host ~peer:(Peers.i2c_controller ~t:sm30 txs).cdrive ~cycles:30_000 ()
    in
    printf "P = %d: pushes [%s]\n" p (String.concat ~sep:" " (List.map c.rx ~f:(sprintf "%02X"))));
  [%expect {|
    P = 4: pushes []
    P = 5: pushes [11 22]
    |}]
;;
