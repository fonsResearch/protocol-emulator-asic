(* Increment 3 (log/increments_v2.md section 3): the I2C target Sm package (ROM 6 of
   Rom_lib.v2_inc3, P = 4, contract h_min 23 / l_min 27 / hd 23 at 30 MHz) on the v2 top RTL,
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

let run ?(verdict_pipe = true) ?(param_windows = true) ~k ~name ~t ~cycles () =
  let peer () = (Peers.i2c_controller ~t txs).cdrive in
  let c = D.chip_run ~lib ~verdict_pipe ~param_windows ~k ~setup ~pkg ~tx_bytes:host ~peer:(peer ()) ~cycles () in
  let r, pmi = E.psim_run ~clear_at:[] ~setup ~tx_bytes:host ~peer ~cycles in
  let x = E.compare_runs ~setup ~cycles c r pmi in
  if Option.is_some x.mon_first then printf "  (mon-in fields: %s)\n" (String.concat ~sep:"," x.mon_fields);
  printf "%-30s mon-in %-7s pins %-7s verdict %s pushes %s [%s] | psim [%s] U %b\n" name (E.show_o x.mon_first)
    (E.show_o x.pins_first) (if x.verdict_eq then "=" else "DIFF") (if x.rx_eq then "=" else "DIFF")
    (String.concat ~sep:" " (List.map (Psim.pushes r) ~f:(sprintf "%02X")))
    (Psim.show_firings r) (u_ok r)
;;

let%expect_test "increment 3: I2C target Sm on the v2 top (vpipe + param_windows), 30 MHz minima" =
  let k = List.hd_exn (D.calibrate ()) in
  printf "P = %d\n" setup.p;
  run ~k ~name:"clean" ~t:sm30 ~cycles:60_000 ();
  run ~k ~name:"clean, default build" ~verdict_pipe:false ~param_windows:false ~t:sm30 ~cycles:60_000 ();
  run ~k ~name:"controller tLOW 120" ~t:{ sm30 with tlow = 120 } ~cycles:60_000 ();
  run ~k ~name:"controller tHIGH 100" ~t:{ sm30 with thigh = 100 } ~cycles:60_000 ();
  run ~k ~name:"controller tHD;STA 60" ~t:{ sm30 with thd_sta = 60 } ~cycles:60_000 ();
  run ~k ~name:"controller late data (dh 150)" ~t:{ sm30 with dh = 150 } ~cycles:60_000 ();
  [%expect {|
    P = 4
    clean                          mon-in =       pins =       verdict = pushes = [11 22] | psim [] U true
    clean, default build           mon-in =       pins =       verdict = pushes = [11 22] | psim [] U true
    controller tLOW 120            mon-in =       pins =       verdict = pushes = [11 22] | psim [B71@641] U true
    controller tHIGH 100           mon-in =       pins =       verdict = pushes = [11 22] | psim [B72@761] U true
    controller tHD;STA 60          mon-in =       pins =       verdict = pushes = [11 22] | psim [B82@461] U true
    controller late data (dh 150)  mon-in =       pins =       verdict = pushes = [11 22] | psim [B83@671,F51@2816] U true
    |}]
;;
