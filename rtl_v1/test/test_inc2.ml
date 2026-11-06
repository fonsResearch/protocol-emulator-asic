(* Increment 2 (doc/decisions/inc2_loadable_options.md, option A): lane 1 as a v2 serial loadable
   lane. Differential check: each scenario runs twice on the v2 top RTL, once with lane 1's package
   from the ROM and once with the same compiled package written to lane 1's store and loaded; both
   are compared with Psim (monitor-input stream, owned pins, pushes, first fail/blame with code and
   stamp). A loaded package is correct if it gives the same result as the ROM lane and Psim. Lane 0
   (ROM) runs the SPI controller beside it. P = 13 on lane 1: the admission bound for a 2-unit
   loaded package is 6 * 2 + 1. *)
open! Core
open Pemu_spec_v1
module D = Test_c3_diff
module T = Test_c3_two
module Psim = Pemu_protocols_v1.Psim
module Peers = Pemu_protocols_v1.Peers
module P1 = Programs_v1

let tx ?(bad = false) ~p () : T.lane_cfg =
  { lane = 1; name = sprintf "uart_tx%s P%d" (if bad then " bad start" else "") p
  ; setup = { (D.uart_tx_setup (if bad then P1.uart_tx_bad_start ~d:4 else P1.uart_tx ~d:4)) with p }
  ; pkg = 0; tx_bytes = [ 0xA5; 0x3C; 0x00 ]; peer = (fun () -> D.no_peer); pins = 0x01 }
;;

let rx ~rate () : T.lane_cfg =
  let frames bp = Peers.frames_of ~bp ~st0:2000 [ 0x55; 0xA5; 0x00; 0xFF; 0x3C; 0x81; 0x7E; 0x01 ] ~gap:(fun b -> 3 + (b * 7 % 400)) in
  { lane = 1; name = sprintf "uart_rx rate x%.2f" rate; setup = D.rx_setup (); pkg = 1; tx_bytes = []
  ; peer = (fun () -> let bp = D.uart_bp /. rate in Peers.sender ~pin:1 ~bp ~frames:(frames bp) ~defect:No_defect)
  ; pins = 0x02 }
;;

let spi_ctl ~tco () : T.lane_cfg =
  { lane = 0; name = sprintf "spi_ctl tco %d" tco; setup = D.ctl_setup; pkg = 2; tx_bytes = D.host_bytes
  ; peer = (fun () -> (Peers.spi_target ~cpol:false ~cpha:false ~tco ~send:D.peer_bytes ()).drive); pins = 0xF0 }
;;

let%expect_test "increment 2: lane 1 loaded from its store equals lane 1 from ROM equals Psim" =
  let k = List.hd_exn (D.calibrate ()) in
  let both ~name lanes ~cycles =
    T.run ~k ~name:(name ^ " [L1 ROM]") lanes ~cycles;
    T.run ~loadable_l1:true ~k ~name:(name ^ " [L1 loaded]") lanes ~cycles
  in
  both ~name:"1: L0 spi_ctl tco 3, L1 uart_tx" [ spi_ctl ~tco:3 (); tx ~p:13 () ] ~cycles:6000;
  both ~name:"2: L0 spi_ctl tco 3, L1 uart_tx bad start (fail)" [ spi_ctl ~tco:3 (); tx ~bad:true ~p:13 () ] ~cycles:6000;
  both ~name:"3: L0 spi_ctl tco 14 (blame), L1 uart_rx 8% fast (blame)" [ spi_ctl ~tco:14 (); rx ~rate:1.08 () ] ~cycles:30_000;
  both ~name:"4: L0 spi_ctl tco 3, L1 uart_rx clean" [ spi_ctl ~tco:3 (); rx ~rate:1.0 () ] ~cycles:30_000;
  [%expect {|
    1: L0 spi_ctl tco 3, L1 uart_tx [L1 ROM]
      lane 0 spi_ctl tco 3              mon-in =      pins =      pushes = (8) | psim fail - blame -
      lane 1 uart_tx P13                mon-in =      pins =      pushes = (0) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    1: L0 spi_ctl tco 3, L1 uart_tx [L1 loaded]
      lane 0 spi_ctl tco 3              mon-in =      pins =      pushes = (8) | psim fail - blame -
      lane 1 uart_tx P13                mon-in =      pins =      pushes = (0) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    2: L0 spi_ctl tco 3, L1 uart_tx bad start (fail) [L1 ROM]
      lane 0 spi_ctl tco 3              mon-in =      pins =      pushes = (8) | psim fail - blame -
      lane 1 uart_tx bad start P13      mon-in =      pins =      pushes = (0) | psim fail 13@141 blame -
      first fail  predicted L1 13@141    chip L1 13@141    =
      first blame predicted -            chip -            =
    2: L0 spi_ctl tco 3, L1 uart_tx bad start (fail) [L1 loaded]
      lane 0 spi_ctl tco 3              mon-in =      pins =      pushes = (8) | psim fail - blame -
      lane 1 uart_tx bad start P13      mon-in =      pins =      pushes = (0) | psim fail 13@141 blame -
      first fail  predicted L1 13@141    chip L1 13@141    =
      first blame predicted -            chip -            =
    3: L0 spi_ctl tco 14 (blame), L1 uart_rx 8% fast (blame) [L1 ROM]
      lane 0 spi_ctl tco 14             mon-in =      pins =      pushes = (8) | psim fail - blame 91@113
      lane 1 uart_rx rate x1.08         mon-in =      pins =      pushes = (4) | psim fail - blame 32@4421
      first fail  predicted -            chip -            =
      first blame predicted L0 91@113    chip L0 91@113    =
    3: L0 spi_ctl tco 14 (blame), L1 uart_rx 8% fast (blame) [L1 loaded]
      lane 0 spi_ctl tco 14             mon-in =      pins =      pushes = (8) | psim fail - blame 91@113
      lane 1 uart_rx rate x1.08         mon-in =      pins =      pushes = (4) | psim fail - blame 32@4421
      first fail  predicted -            chip -            =
      first blame predicted L0 91@113    chip L0 91@113    =
    4: L0 spi_ctl tco 3, L1 uart_rx clean [L1 ROM]
      lane 0 spi_ctl tco 3              mon-in =      pins =      pushes = (8) | psim fail - blame -
      lane 1 uart_rx rate x1.00         mon-in =      pins =      pushes = (5) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    4: L0 spi_ctl tco 3, L1 uart_rx clean [L1 loaded]
      lane 0 spi_ctl tco 3              mon-in =      pins =      pushes = (8) | psim fail - blame -
      lane 1 uart_rx rate x1.00         mon-in =      pins =      pushes = (5) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    |}]
;;

(* admission and context rules of the loadable lane (host-visible) *)
let%expect_test "increment 2: admission bound, LOAD_UNITS readback, stale context" =
  let h = D.create ~loadable:[| false; true |] () in
  let p = List.nth_exn D.lib 0 (* uart_tx: 2 units *) in
  let r a = List.hd_exn (D.read h a 1) in
  let setup_lane1 ~p:pv =
    let s = { (D.uart_tx_setup (P1.uart_tx ~d:4)) with p = pv } in
    let words = Isa1.assemble s.prog in
    D.write h 0x20 [ s.own ]; D.write h 0x22 [ pv land 0xFF; pv lsr 8 ];
    D.write h 0x24 [ List.length s.prog ]; D.write h 0x27 [ 0 ];
    D.write h 0x28 (List.concat_map (List.init (List.length s.prog) ~f:Fn.id) ~f:(fun a -> [ words.(a) land 0xFF; words.(a) lsr 8 ]))
  in
  setup_lane1 ~p:7;
  T.load_package h ~lane:1 p;
  printf "after LOAD: LOAD_UNITS 0x%02X (bit5 ctx_loaded, units [4:0])\n" (r 0x59);
  D.write h 0x01 [ 0x02 ];
  D.wait h 20;
  printf "P = 7, 2 units (bound 13): STATUS 0x%02X FLAGS 0x%02X\n" (r 0x02) (r 0x2D);
  D.write h 0x01 [ 0x00 ];
  D.wait h 20;
  setup_lane1 ~p:13;
  D.write h 0x01 [ 0x02 ];
  D.wait h 20;
  printf "P = 13: STATUS 0x%02X FLAGS 0x%02X\n" (r 0x02) (r 0x2D);
  D.write h 0x01 [ 0x00 ];
  D.wait h 200;
  (* a store write after LOAD clears ctx_loaded, so RUN is refused until the next LOAD *)
  T.write_store h ~lane:1 [ 200, 0x1234 ];
  printf "after a store write: LOAD_UNITS 0x%02X\n" (r 0x59);
  D.write h 0x01 [ 0x02 ];
  D.wait h 20;
  printf "RUN with stale context: STATUS 0x%02X FLAGS 0x%02X\n" (r 0x02) (r 0x2D);
  [%expect {|
    after LOAD: LOAD_UNITS 0x23 (bit5 ctx_loaded, units [4:0])
    P = 7, 2 units (bound 13): STATUS 0x08 FLAGS 0x14
    P = 13: STATUS 0x0A FLAGS 0x04
    after a store write: LOAD_UNITS 0x03
    RUN with stale context: STATUS 0x08 FLAGS 0x14
    |}]
;;
