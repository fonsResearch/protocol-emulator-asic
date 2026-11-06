(* Increment 2, option D (doc/decisions/inc2_loadable_options.md section 6): host-loadable window
   tables on the ROM lanes. Exact differential check: a shipped ROM package with the windows of a
   variant contract loaded must behave as Psim running the variant contract (the variant compiles to
   the same structure; probe_loadable.exe variants). Each case also runs without the override, against
   the shipped contract, to show that the loaded windows change the verdict. *)
open! Core
open Pemu_spec_v1
open Pemu_monitor_v1
module D = Test_c3_diff
module T = Test_c3_two
module Psim = Pemu_protocols_v1.Psim
module Peers = Pemu_protocols_v1.Peers
module P1 = Programs_v1
module Lib = Library_v1

let wins c = (Compile.compile_exn c).Mprog.windows

let%expect_test "option D: ROM package + loaded windows = variant contract (Psim)" =
  let k = List.hd_exn (D.calibrate ()) in
  (* UART TX: firmware with d = 6 on the d = 4 ROM package (index 0), lane 0 *)
  let tx ~d ~bad ~contract_d : T.lane_cfg =
    { lane = 0; name = sprintf "uart_tx d%d%s vs contract d%d" d (if bad then " bad start" else "") contract_d
    ; setup =
        { (D.uart_tx_setup (if bad then P1.uart_tx_bad_start ~d else P1.uart_tx ~d)) with
          contract = Lib.uart_tx ~d:contract_d ~pin:0 }
    ; pkg = 0; tx_bytes = [ 0xA5; 0x3C; 0x00 ]; peer = (fun () -> D.no_peer); pins = 0x01 }
  in
  let w6 = wins (Lib.uart_tx ~d:6 ~pin:0) in
  T.run ~k ~name:"1a: d6 firmware, ROM d4, no override" [ tx ~d:6 ~bad:false ~contract_d:4 ] ~cycles:6000;
  T.run ~windows:[ 0, w6 ] ~k ~name:"1b: d6 firmware, ROM d4 + windows(d6)" [ tx ~d:6 ~bad:false ~contract_d:6 ] ~cycles:6000;
  T.run ~windows:[ 0, w6 ] ~k ~name:"1c: d6 bad start, ROM d4 + windows(d6)" [ tx ~d:6 ~bad:true ~contract_d:6 ] ~cycles:6000;
  (* SPI target: g = 9 on the g = 6 ROM package (index 3), lane 1; peer inter-byte gap in cycles *)
  let tgt ~g ~gap : T.lane_cfg =
    let mk () =
      Peers.spi_controller ~cpol:false ~cpha:false ~hp:40 ~setup:40 ~hold:40 ~gap ~mdly:2 ~t0:300 ~bytes:D.peer_bytes ()
    in
    { lane = 1; name = sprintf "spi_tgt gap %d vs contract g%d" gap g
    ; setup = { D.tgt_setup with Psim.contract = Lib.spi_tgt ~cpol:false ~cpha:false ~h_min:3 ~g }
    ; pkg = 3; tx_bytes = D.host_bytes; peer = (fun () -> (mk ()).cdrive); pins = 0xF0 }
  in
  let w9 = wins (Lib.spi_tgt ~cpol:false ~cpha:false ~h_min:3 ~g:9) in
  List.iter [ 144; 64; 40 ] ~f:(fun gap ->
    T.run ~k ~name:(sprintf "2a: gap %d, ROM g6, no override" gap) [ tgt ~g:6 ~gap ] ~cycles:8000;
    T.run ~windows:[ 1, w9 ] ~k ~name:(sprintf "2b: gap %d, ROM g6 + windows(g9)" gap) [ tgt ~g:9 ~gap ] ~cycles:8000);
  [%expect {|
    1a: d6 firmware, ROM d4, no override
      lane 0 uart_tx d6 vs contract d4  mon-in =      pins =      pushes = (0) | psim fail 13@81 blame -
      first fail  predicted L0 13@81     chip L0 13@81     =
      first blame predicted -            chip -            =
    1b: d6 firmware, ROM d4 + windows(d6)
      lane 0 uart_tx d6 vs contract d6  mon-in =      pins =      pushes = (0) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    1c: d6 bad start, ROM d4 + windows(d6)
      lane 0 uart_tx d6 bad start vs contract d6 mon-in =      pins =      pushes = (0) | psim fail 13@97 blame -
      first fail  predicted L0 13@97     chip L0 13@97     =
      first blame predicted -            chip -            =
    2a: gap 144, ROM g6, no override
      lane 1 spi_tgt gap 144 vs contract g6 mon-in =      pins =      pushes = (8) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    2b: gap 144, ROM g6 + windows(g9)
      lane 1 spi_tgt gap 144 vs contract g9 mon-in =      pins =      pushes = (8) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    2a: gap 64, ROM g6, no override
      lane 1 spi_tgt gap 64 vs contract g6 mon-in =      pins =      pushes = (8) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    2b: gap 64, ROM g6 + windows(g9)
      lane 1 spi_tgt gap 64 vs contract g9 mon-in =      pins =      pushes = (8) | psim fail - blame 55@1049
      first fail  predicted -            chip -            =
      first blame predicted L1 55@1049   chip L1 55@1049   =
    2a: gap 40, ROM g6, no override
      lane 1 spi_tgt gap 40 vs contract g6 mon-in =      pins =      pushes = (8) | psim fail - blame 55@1025
      first fail  predicted -            chip -            =
      first blame predicted L1 55@1025   chip L1 55@1025   =
    2b: gap 40, ROM g6 + windows(g9)
      lane 1 spi_tgt gap 40 vs contract g9 mon-in =      pins =      pushes = (8) | psim fail - blame 55@1025
      first fail  predicted -            chip -            =
      first blame predicted L1 55@1025   chip L1 55@1025   =
    |}]
;;

let%expect_test "option D: I2C controller l7 h5 tsu4 thold7 on the Fm ROM package" =
  let k = List.hd_exn (D.calibrate ()) in
  let lib = List.map (Pemu_rtl_v1.Rom_lib.v2_inc1 ()) ~f:Compile.compile_exn in
  let setup ~l ~h ~tsu ~thold =
    { Psim.prog = P1.i2c_ctl ~l ~h ~tsu ~thold; own = P1.i2c_own; od = P1.i2c_od; cfg = 0; cfg2 = 0; p = 8
    ; contract = Lib.i2c_ctl ~l ~h ~tsu ~thold; open_drain_wired_and = P1.i2c_own }
  in
  let host = [ 0xA0; 0x03; 0x11; 0x22; 0x33; 0xA1; 0x02 ] in
  let peer () = (Peers.i2c_target ~addr:0x50 ~read_data:[ 0xC3; 0x5A ] ()).drive in
  let w = wins (Lib.i2c_ctl ~l:7 ~h:5 ~tsu:4 ~thold:7) in
  let one ~name ?windows s =
    let c = D.chip_run ~lib ?windows ~k ~setup:s ~pkg:4 ~tx_bytes:host ~peer:(peer ()) ~cycles:14_000 () in
    let r, pmi = Test_c3_env.psim_run ~clear_at:[] ~setup:s ~tx_bytes:host ~peer ~cycles:14_000 in
    let x = Test_c3_env.compare_runs ~setup:s ~cycles:14_000 c r pmi in
    printf "%-46s mon-in %-7s pins %-7s verdict %s pushes %s | psim [%s]\n" name (Test_c3_env.show_o x.mon_first)
      (Test_c3_env.show_o x.pins_first) (if x.verdict_eq then "=" else "DIFF") (if x.rx_eq then "=" else "DIFF")
      (Psim.show_firings r)
  in
  one ~name:"l7h5 firmware, Fm ROM, no override (vs l6h4)" (setup ~l:7 ~h:5 ~tsu:4 ~thold:7 |> fun s -> { s with Psim.contract = Lib.i2c_ctl ~l:6 ~h:4 ~tsu:3 ~thold:6 });
  one ~name:"l7h5 firmware, Fm ROM + windows(l7h5)" ~windows:w (setup ~l:7 ~h:5 ~tsu:4 ~thold:7);
  [%expect {|
    l7h5 firmware, Fm ROM, no override (vs l6h4)   mon-in =       pins =       verdict = pushes = | psim [F61@5392]
    l7h5 firmware, Fm ROM + windows(l7h5)          mon-in =       pins =       verdict = pushes = | psim []
    |}]
;;

let%expect_test "option D: window registers, readback and context rule" =
  let h = D.create ~param_windows:true () in
  let r a = List.hd_exn (D.read h a 1) in
  D.write h 0x53 [ 3 ]; D.write h 0x56 [ 0x34 ]; D.write h 0x57 [ 0x02 ];
  D.write h 0x53 [ 0x83 ];
  printf "L0 WIN_CTL 0x%02X window 3 = 0x%02X%02X\n" (r 0x53) (r 0x57) (r 0x56);
  (* lane 0 running: context writes refused *)
  D.write h 0x10 [ 0x01 ]; D.write h 0x12 [ 7; 0 ]; D.write h 0x14 [ 1 ]; D.write h 0x18 [ 0; 0 ];
  D.write h 0x01 [ 0x01 ];
  D.write h 0x53 [ 3 ]; D.write h 0x56 [ 0xFF ]; D.write h 0x57 [ 0x0F ];
  printf "after writes while running: WIN_CTL 0x%02X window 3 = 0x%02X%02X\n" (r 0x53) (r 0x57) (r 0x56);
  [%expect {|
    L0 WIN_CTL 0x83 window 3 = 0x0234
    after writes while running: WIN_CTL 0x83 window 3 = 0x0234
    |}]
;;
