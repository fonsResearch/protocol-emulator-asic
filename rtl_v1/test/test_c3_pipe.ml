(* C3 host clear_fault sweep with the pipelined slot schedule (Mon_engine ~lane_pipe, shipped in
   v2-inc5-usb; log/proofs_v2.md section 7.2 for the unpipelined original). A blame of unit j in
   step t is consumed by the lane at t + j + 2 instead of t + j + 1, so the predicted window in
   which a host clear (landing d cycles after the blame step) makes the chip diverge from the A2
   harness composition is d in 1 .. j + 1 (was 1 .. j). Same scenarios as Test_c3_env. *)
open! Core
module D = Test_c3_diff
module E = Test_c3_env
module Peers = Pemu_protocols_v1.Peers

let cfg = [ `Lane_pipe; `Vpipe; `Pwin ]

let chip_run ~ctrl_writes ~k ~setup ~pkg ~tx_bytes ~peer ~cycles =
  D.chip_run ~lane_pipe:true ~verdict_pipe:true ~param_windows:true ~ctrl_writes ~k ~setup ~pkg ~tx_bytes ~peer
    ~cycles ()
;;

let clear_latency ~k =
  let c = chip_run ~ctrl_writes:[ 1000, 0x21 ] ~k ~setup:(D.rx_setup ()) ~pkg:1 ~tx_bytes:[] ~peer:D.no_peer ~cycles:3000 in
  match c.clears with [ t ] -> t - 1000 | l -> raise_s [%message "one pulse expected" (l : int list)]
;;

let scenario ~k ~lat ?clear ~setup ~pkg ~tx_bytes ~peer ~cycles () =
  let ctrl_writes = match clear with None -> [] | Some t -> [ t - lat, 0x21 ] in
  let c = chip_run ~ctrl_writes ~k ~setup ~pkg ~tx_bytes ~peer:(peer ()) ~cycles in
  let r, pmi = E.psim_run ~clear_at:c.clears ~setup ~tx_bytes ~peer ~cycles in
  (match clear with
   | Some t when not ([%equal: int list] c.clears [ t ]) -> raise_s [%message "clear misplaced" (t : int)]
   | _ -> ());
  c, r, E.compare_runs ~setup ~cycles c r pmi
;;

let sweep ~k ~lat ~name ~setup ~pkg ~tx_bytes ~peer ~cycles =
  let c, r, x = scenario ~k ~lat ~setup ~pkg ~tx_bytes ~peer ~cycles () in
  let t = match D.psim_first r Blame with Some (_, t) -> t | None -> failwith "no blame" in
  let j = (c.first_units lsr 4) land 7 in
  printf "%s: no clear: diverged %b; first blame %s, unit j = %d, predicted window 1..%d\n" name (E.diverged x)
    (D.show_opt (D.psim_first r Blame)) j (j + 1);
  let bad = ref 0 in
  List.iter [ -40; 0; 1; 2; 3; 4; 5; 6; 7; 10; 40; 200 ] ~f:(fun d ->
    let _, _, x = scenario ~k ~lat ~clear:(t + d) ~setup ~pkg ~tx_bytes ~peer ~cycles () in
    let predicted = d >= 1 && d <= j + 1 in
    if Bool.( <> ) predicted (E.diverged x) then incr bad;
    printf "  d %4d: mon-in %-7s pins %-7s verdict %s rx %s | predicted %-8s observed %s\n" d (E.show_o x.mon_first)
      (E.show_o x.pins_first) (if x.verdict_eq then "=" else "DIFF") (if x.rx_eq then "=" else "DIFF")
      (if predicted then "diverge" else "equal") (if E.diverged x then "diverge" else "equal"));
  printf "  prediction mismatches: %d\n" !bad
;;

let%expect_test "C3 (lane pipe): host clear_fault around a blame" =
  ignore (cfg : _ list);
  let k = List.hd_exn (D.calibrate ()) in
  let lat = clear_latency ~k in
  printf "clear latency %d cycles\n" lat;
  let peer () =
    let bp = D.uart_bp /. 1.08 in
    Peers.sender ~pin:1 ~bp ~frames:(E.frames bp) ~defect:No_defect
  in
  sweep ~k ~lat ~name:"uart_rx 8% fast" ~setup:{ (D.rx_setup ()) with cfg = 1 } ~pkg:1 ~tx_bytes:[] ~peer ~cycles:30_000;
  let peer () =
    (Peers.spi_target ~cpol:false ~cpha:false ~tco:3 ~send:D.peer_bytes ~miso_glitch:(3, 4) ~glitch_len:10 ()).drive
  in
  sweep ~k ~lat ~name:"spi_ctl MISO hold glitch (frame 3, bit 4)"
    ~setup:{ D.ctl_setup with cfg = D.ctl_setup.cfg lor 1 } ~pkg:2 ~tx_bytes:D.host_bytes ~peer ~cycles:6000;
  [%expect {|
    clear latency 194 cycles
    uart_rx 8% fast: no clear: diverged false; first blame 32@4421, unit j = 0, predicted window 1..1
      d  -40: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    0: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    1: mon-in @4487   pins =       verdict = rx DIFF | predicted diverge  observed diverge
      d    2: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    3: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    4: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    5: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    6: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    7: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d   10: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d   40: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d  200: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      prediction mismatches: 0
    spi_ctl MISO hold glitch (frame 3, bit 4): no clear: diverged false; first blame 91@1145, unit j = 4, predicted window 1..5
      d  -40: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    0: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    1: mon-in @1154   pins @1154   verdict = rx DIFF | predicted diverge  observed diverge
      d    2: mon-in @1154   pins @1154   verdict = rx DIFF | predicted diverge  observed diverge
      d    3: mon-in @1154   pins @1154   verdict = rx DIFF | predicted diverge  observed diverge
      d    4: mon-in @1154   pins @1154   verdict = rx DIFF | predicted diverge  observed diverge
      d    5: mon-in @1154   pins @1154   verdict = rx DIFF | predicted diverge  observed diverge
      d    6: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    7: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d   10: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d   40: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d  200: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      prediction mismatches: 0
    |}]
;;
