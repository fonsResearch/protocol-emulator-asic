(* I2C v1 packages (doc/protocols/i2c_v1.md) over the lane model, the monitor and cycle-level
   I2C peers (Psim). *)
open! Core
open Pemu_protocols_v1
module P1 = Pemu_spec_v1.Programs_v1
module Lib = Pemu_monitor_v1.Library_v1
open Peers


let u_ok (r : Psim.result) =
  let blamed = ref false and ok = ref true in
  List.iter (Psim.firings r) ~f:(fun (_, ro, _) ->
    match ro with
    | Blame -> blamed := true
    | Fail -> if not !blamed then ok := false);
  !ok
;;

(* speed grades (doc section 4): P, l, h, tsu, thold *)
let sm = 59, 5, 5, 5, 5
let fm = 14, 6, 4, 3, 6

let ctl_setup (p, l, h, tsu, thold) =
  { Psim.prog = P1.i2c_ctl ~l ~h ~tsu ~thold; own = P1.i2c_own; od = P1.i2c_od; cfg = 0; cfg2 = 0; p
  ; contract = Lib.i2c_ctl ~l ~h ~tsu ~thold; open_drain_wired_and = P1.i2c_own }
;;

(* write 3 to 0x50; write 1 + Sr + read 2 from 0x50; read 1 from absent 0x51; write 2 to
   absent 0x52 *)
let host =
  [ 0xA0; 0x03; 0x11; 0x22; 0x33; 0xA0; 0x81; 0x05; 0xA1; 0x02; 0xA3; 0x01; 0xA4; 0x02; 0xAA; 0xBB ]
;;

let hex l = String.concat ~sep:" " (List.map l ~f:(sprintf "%02X"))

let run_ctl ?(cycles = 120_000) ?nack_write ?stretch ?dd ?ack_on_rise ?change_in_high ?prog grade =
  let tgt = i2c_target ~addr:0x50 ~read_data:[ 0xC3; 0x5A ] ?nack_write ?stretch ?dd ?ack_on_rise ?change_in_high () in
  let setup = ctl_setup grade in
  let setup = match prog with Some p -> { setup with prog = p } | None -> setup in
  let r = Psim.run ~tx_bytes:host ~setup ~cycles ~peer:tgt.drive () in
  printf "bus: %s\npushes: %s\nfirings [%s] U %b model_mismatch %d steps %d\n" (tgt.log ())
    (hex (Psim.pushes r)) (Psim.show_firings r) (u_ok r) r.model_mismatch r.steps;
  r
;;

let%expect_test "I2C controller program size" =
  List.iter [ "Sm", sm; "Fm", fm ] ~f:(fun (n, (_, l, h, tsu, thold)) ->
    printf "%s %d instructions\n" n (List.length (P1.i2c_ctl ~l ~h ~tsu ~thold)));
  [%expect {|
    Sm 162 instructions
    Fm 166 instructions
    |}]
;;

let%expect_test "I2C controller Fm, target peer" =
  ignore (run_ctl fm : Psim.result);
  [%expect {|
    bus: S A50W+ W11+ W22+ W33+ P S A50W+ W05+ Sr A50R+ RC3+ R5A- P S A51R- P S A52W- P
    pushes: 00 00 C3 5A 00 01 01
    firings [] U true model_mismatch 0 steps 7999
    |}]
;;

let%expect_test "I2C controller Sm, target peer" =
  ignore (run_ctl ~cycles:500_000 sm : Psim.result);
  [%expect {|
    bus: S A50W+ W11+ W22+ W33+ P S A50W+ W05+ Sr A50R+ RC3+ R5A- P S A51R- P S A52W- P
    pushes: 00 00 C3 5A 00 01 01
    firings [] U true model_mismatch 0 steps 8333
    |}]
;;

let%expect_test "I2C controller Fm: clock stretching 200 cycles after each ACK cell" =
  ignore (run_ctl ~stretch:200 fm : Psim.result);
  [%expect {|
    bus: S A50W+ W11+ W22+ W33+ P S A50W+ W05+ Sr A50R+ RC3+ R5A- P S A51R- P S A52W- P
    pushes: 00 00 C3 5A 00 01 01
    firings [] U true model_mismatch 0 steps 7999
    |}]
;;

let%expect_test "I2C controller Fm: target NACKs the second written byte" =
  ignore (run_ctl ~nack_write:1 fm : Psim.result);
  [%expect {|
    bus: S A50W+ W11+ W22- P S A50W+ W05+ Sr A50R+ RC3+ R5A- P S A51R- P S A52W- P
    pushes: 02 00 C3 5A 00 01 01
    firings [] U true model_mismatch 0 steps 7999
    |}]
;;

let%expect_test "I2C controller Fm: target data delay sweep (step = 15 cycles, low phase >= 6 steps)" =
  List.iter [ 1; 8; 14; 16; 30; 60; 80; 90; 100; 120 ] ~f:(fun dd ->
    let tgt = i2c_target ~addr:0x50 ~read_data:[ 0xC3; 0x5A ] ~dd () in
    let r = Psim.run ~tx_bytes:host ~setup:(ctl_setup fm) ~cycles:120_000 ~peer:tgt.drive () in
    printf "dd %3d: pushes %s firings [%s] U %b\n" dd (hex (Psim.pushes r))
      (String.concat ~sep:"," (List.take (String.split (Psim.show_firings r) ~on:',') 3)) (u_ok r));
  [%expect {|
    dd   1: pushes 00 00 C3 5A 00 01 01 firings [] U true
    dd   8: pushes 00 00 C3 5A 00 01 01 firings [] U true
    dd  14: pushes 00 00 C3 5A 00 01 01 firings [] U true
    dd  16: pushes 00 00 C3 5A 00 01 01 firings [] U true
    dd  30: pushes 00 00 C3 5A 00 01 01 firings [] U true
    dd  60: pushes 00 00 C3 5A 00 01 01 firings [] U true
    dd  80: pushes 00 00 C3 5A 00 01 01 firings [] U true
    dd  90: pushes 00 00 C3 5A 00 01 01 firings [] U true
    dd 100: pushes 00 00 C3 5A 00 01 01 firings [] U true
    dd 120: pushes 01 01 01 01 01 firings [B77@1921] U true
    |}]
;;

let%expect_test "I2C controller Fm: target misbehaviour (A1 ACK at SCL rise, A2 data change in high)" =
  ignore (run_ctl ~ack_on_rise:true fm : Psim.result);
  List.iter [ 8; 20; 35 ] ~f:(fun d -> printf "change %d cycles after rise:\n" d; ignore (run_ctl ~change_in_high:d fm : Psim.result));
  [%expect {|
    bus: S A50W+ W11+ W22+ W33+ P S A50W+ W05+ Sr A50R+ RC3+ R5A- P S A51R- P S A52W- P
    pushes: 00 00 C3 5A 00 01 01
    firings [B76@12601] U true model_mismatch 0 steps 7999
    change 8 cycles after rise:
    bus: S A50W+ W11+ W22+ W33+ P S A50W+ W05+ Sr A50R+ RC3+ R5A- P S A51R- P S A52W- P
    pushes: 00 00 C3 5A 00 01 01
    firings [] U true model_mismatch 0 steps 7999
    change 20 cycles after rise:
    bus: S A50W+ W11+ W22+ W33+ P S A50W+ W05+ Sr A50R+ RC3+ R5A- P S A51R- P S A52W- P
    pushes: 00 00 C3 5A 00 01 01
    firings [] U true model_mismatch 0 steps 7999
    change 35 cycles after rise:
    bus: S A50W+ W11+ W22+ W33+ P S A50W+ W05+ Sr A50R+ RC3+ R5A- P S A51R- P S A52W- P
    pushes: 00 00 E1 6D 00 01 01
    firings [B77@13501] U true model_mismatch 0 steps 7999
    |}]
;;

let%expect_test "I2C controller Fm: firmware timing mutants (contract at nominal timing)" =
  let _, l, h, tsu, thold = fm in
  List.iter
    [ "l-1", P1.i2c_ctl ~l:(l - 1) ~h ~tsu ~thold; "h-1", P1.i2c_ctl ~l ~h:(h - 1) ~tsu ~thold; "h-2", P1.i2c_ctl ~l ~h:(h - 2) ~tsu ~thold
    ; "tsu-1", P1.i2c_ctl ~l ~h ~tsu:(tsu - 1) ~thold; "thold-1", P1.i2c_ctl ~l ~h ~tsu ~thold:(thold - 1) ]
    ~f:(fun (n, prog) ->
      let tgt = i2c_target ~addr:0x50 ~read_data:[ 0xC3; 0x5A ] () in
      let setup = { (ctl_setup fm) with prog } in
      let r = Psim.run ~tx_bytes:host ~setup ~cycles:120_000 ~peer:tgt.drive () in
      let f = Psim.firings r in
      printf "%-8s first %s U %b\n" n
        (match f with [] -> "none" | (c, ro, k) :: _ -> sprintf "%s%02X@%d" (match ro with Fail -> "F" | Blame -> "B") k c)
        (u_ok r));
  [%expect {|
    l-1      first F52@556 U false
    h-1      first none U true
    h-2      first F53@616 U false
    tsu-1    first F61@6976 U false
    thold-1  first F62@451 U false
    |}]
;;

(* ---- target ---- *)

(* contract parameters at divisor p: floor(UM10204 minimum / step) - 1 (cycles at 60 MHz) *)
let tgt_params ~p (t : i2c_ctl_timing) =
  let f c = Int.max 2 ((c / (p + 1)) - 1) in
  f t.thigh, f t.tlow, f t.thd_sta
;;

let tgt_setup ~p t =
  let h_min, l_min, hd = tgt_params ~p t in
  { Psim.prog = P1.i2c_tgt ~addr:0x50; own = P1.i2c_own; od = P1.i2c_od; cfg = 0; cfg2 = 0; p
  ; contract = Lib.i2c_tgt ~h_min ~l_min ~hd; open_drain_wired_and = P1.i2c_own }
;;

let tgt_txs =
  [ `W (0x50, [ 0x11; 0x22; 0x33 ]), false; `W (0x50, [ 0x44 ]), true; `R (0x50, 2), false; `R (0x51, 1), false
  ; `W (0x52, [ 0xAA ]), false; `R (0x50, 1), false ]
;;

let run_tgt ?(txs = tgt_txs) ?(host = [ 0x50; 0xC3; 0x5A; 0x7E ]) ~p ~t ~cycles () =
  let c = i2c_controller ~t txs in
  let r = Psim.run ~tx_bytes:host ~setup:(tgt_setup ~p t) ~cycles ~peer:c.cdrive () in
  let h_min, l_min, hd = tgt_params ~p t in
  printf "P=%d (h_min %d l_min %d hd %d) done %b\n  bus: %s\n  pushes: %s firings [%s] U %b mm %d\n" p h_min l_min hd
    (c.cdone ()) (c.clog ()) (hex (Psim.pushes r)) (Psim.show_firings r) (u_ok r) r.model_mismatch;
  r
;;

let%expect_test "I2C target program size" =
  printf "%d instructions\n" (List.length (P1.i2c_tgt ~addr:0x50));
  [%expect {| 141 instructions |}]
;;

let%expect_test "I2C target Fm, controller peer at UM10204 minima, P = 7, 3, 1" =
  List.iter [ 7; 3; 1 ] ~f:(fun p -> ignore (run_tgt ~p ~t:i2c_fm ~cycles:60_000 () : Psim.result));
  [%expect {|
    P=7 (h_min 3 l_min 8 hd 3) done true
      bus: S A50W+ W11+ W22+ W33+ P S A50W- W44- Sr A50R+ RC3 R5A P S A51R- RFF P S A52W- WAA- P S A50R- RFF P
      pushes: 11 22 33 firings [] U true mm 0
    P=3 (h_min 8 l_min 18 hd 8) done true
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RC3 R5A P S A51R- RFF P S A52W- WAA- P S A50R+ R7E P
      pushes: 11 22 33 44 firings [] U true mm 0
    P=1 (h_min 17 l_min 38 hd 17) done true
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RC3 R5A P S A51R- RFF P S A52W- WAA- P S A50R+ R7E P
      pushes: 11 22 33 44 firings [B91@3,B71@5] U true mm 0
    |}]
;;

let%expect_test "I2C target Sm, controller peer at UM10204 minima, P = 7, 3, 1" =
  List.iter [ 7; 3; 1 ] ~f:(fun p -> ignore (run_tgt ~p ~t:i2c_sm ~cycles:250_000 () : Psim.result));
  [%expect {|
    P=7 (h_min 29 l_min 34 hd 29) done true
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RC3 R5A P S A51R- RFF P S A52W- WAA- P S A50R+ R7E P
      pushes: 11 22 33 44 firings [] U true mm 0
    P=3 (h_min 59 l_min 69 hd 59) done true
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RC3 R5A P S A51R- RFF P S A52W- WAA- P S A50R+ R7E P
      pushes: 11 22 33 44 firings [] U true mm 0
    P=1 (h_min 119 l_min 140 hd 119) done true
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RC3 R5A P S A51R- RFF P S A52W- WAA- P S A50R+ R7E P
      pushes: 11 22 33 44 firings [B91@3,B71@5] U true mm 0
    |}]
;;

let%expect_test "I2C target Fm: START/Sr hold-time sweep (cycles; UM10204 min 36)" =
  let good = [ 0x11; 0x22; 0x33; 0x44 ] in
  List.iter [ 7; 3; 1 ] ~f:(fun p ->
    let line =
      List.map [ 12; 20; 28; 36; 44; 52; 60; 68; 76 ] ~f:(fun thd_sta ->
        let t = { i2c_fm with thd_sta } in
        let c = i2c_controller ~t tgt_txs in
        let r = Psim.run ~tx_bytes:[ 0x50; 0xC3; 0x5A; 0x7E ] ~setup:(tgt_setup ~p i2c_fm) ~cycles:60_000 ~peer:c.cdrive () in
        let ok = [%equal: int list] (Psim.pushes r) good && String.is_suffix (c.clog ()) ~suffix:"A50R+ R7E P" in
        let f = List.filter (Psim.firings r) ~f:(fun (cy, _, _) -> cy > 20) in
        sprintf "%d:%s%s%s" thd_sta (if ok then "ok" else "BAD")
          (match f with [] -> "" | (_, ro, k) :: _ -> sprintf "/%s%02X" (match ro with Fail -> "F" | Blame -> "B") k)
          (if u_ok r then "" else "/U!"))
    in
    printf "P=%d %s\n" p (String.concat ~sep:" " line));
  [%expect {|
    P=7 12:BAD/B82 20:BAD/B82 28:BAD 36:BAD 44:BAD 52:ok 60:ok 68:ok 76:ok
    P=3 12:BAD/B82 20:BAD/B82 28:ok/B82 36:ok 44:ok 52:ok 60:ok 68:ok 76:ok
    P=1 12:BAD/B82 20:ok/B82 28:ok/B82 36:ok 44:ok 52:ok 60:ok 68:ok 76:ok
    |}]
;;
