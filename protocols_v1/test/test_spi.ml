(* SPI v1 packages (doc/protocols/spi_v1.md) over the lane model, the monitor and cycle-level
   SPI peers (Psim). *)
open! Core
open Pemu_protocols_v1
module P1 = Pemu_spec_v1.Programs_v1
module Lib = Pemu_monitor_v1.Library_v1
open Peers

let modes = [ false, false; false, true; true, false; true, true ]
let mode_name (cpol, cpha) = sprintf "m%d" ((if cpol then 2 else 0) + if cpha then 1 else 0)

(* U on a trace: every fail has a blame in the same or an earlier cycle *)
let u_ok (r : Psim.result) =
  let blamed = ref false and ok = ref true in
  List.iter (Psim.firings r) ~f:(fun (_, ro, _) ->
    match ro with
    | Blame -> blamed := true
    | Fail -> if not !blamed then ok := false);
  !ok
;;

let ctl_setup ~cpol ~cpha ~p =
  { Psim.prog = P1.spi_ctl ~cpol ~cpha; own = P1.spi_own_ctl; od = 0; cfg = P1.spi_cfg_ctl
  ; cfg2 = P1.spi_cfg2_ctl; p; contract = Lib.spi_ctl ~cpol ~cpha ~h:2; open_drain_wired_and = 0 }
;;

let tgt_setup ~cpol ~cpha ~p =
  { Psim.prog = P1.spi_tgt ~cpol ~cpha; own = P1.spi_own_tgt; od = 0; cfg = 0; cfg2 = 0; p
  ; contract = Lib.spi_tgt ~cpol ~cpha ~h_min:3 ~g:6; open_drain_wired_and = 0 }
;;

let host = [ 0xA5; 0x3C; 0x00; 0xFF; 0x81; 0x7E; 0x55; 0x0F ]
let peer_bytes = [ 0x96; 0x01; 0x80; 0xC3; 0x5A; 0xF0; 0x33; 0xE7 ]
let eq = [%equal: int list]

let%expect_test "SPI controller h=2, P=7, target peer tco=3 cycles" =
  List.iter modes ~f:(fun (cpol, cpha) ->
    let tgt = spi_target ~cpol ~cpha ~tco:3 ~send:peer_bytes () in
    let r = Psim.run ~tx_bytes:host ~setup:(ctl_setup ~cpol ~cpha ~p:7) ~cycles:6000 ~peer:tgt.drive () in
    printf "%s pushes %s, target got %s, firings [%s] model_mismatch %d\n" (mode_name (cpol, cpha))
      (if eq (Psim.pushes r) peer_bytes then "= target bytes" else "WRONG")
      (if eq (tgt.received ()) host then "= host bytes" else "WRONG")
      (Psim.show_firings r) r.model_mismatch);
  [%expect {|
    m0 pushes = target bytes, target got = host bytes, firings [] model_mismatch 0
    m1 pushes = target bytes, target got = host bytes, firings [] model_mismatch 0
    m2 pushes = target bytes, target got = host bytes, firings [] model_mismatch 0
    m3 pushes = target bytes, target got = host bytes, firings [] model_mismatch 0
    |}]
;;

let%expect_test "SPI controller: target clock-to-output sweep (P=7, step = 8 cycles)" =
  List.iter modes ~f:(fun (cpol, cpha) ->
    let line =
      List.map [ 1; 4; 8; 12; 14; 16; 18; 20; 24 ] ~f:(fun tco ->
        let tgt = spi_target ~cpol ~cpha ~tco ~send:peer_bytes () in
        let r = Psim.run ~tx_bytes:host ~setup:(ctl_setup ~cpol ~cpha ~p:7) ~cycles:6000 ~peer:tgt.drive () in
        sprintf "%d:%s%s%s" tco
          (if eq (Psim.pushes r) peer_bytes then "ok" else "data")
          (match Psim.firings r with [] -> "" | (_, _, c) :: _ -> sprintf "/%02X" c)
          (if u_ok r then "" else "/U-VIOLATION"))
    in
    printf "%s %s\n" (mode_name (cpol, cpha)) (String.concat ~sep:" " line));
  [%expect {|
    m0 1:ok 4:ok 8:ok 12:ok/91 14:ok/91 16:ok/91 18:ok/91 20:data/92 24:data/92
    m1 1:ok 4:ok 8:ok 12:ok/91 14:ok/91 16:ok/91 18:ok/91 20:data/92 24:data/92
    m2 1:ok 4:ok 8:ok 12:ok/91 14:ok/91 16:ok/91 18:ok/91 20:data/92 24:data/92
    m3 1:ok 4:ok 8:ok 12:ok/91 14:ok/91 16:ok/91 18:ok/91 20:data/92 24:data/92
    |}]
;;

let%expect_test "SPI controller: MISO hold-time glitch at a sampling edge" =
  List.iter modes ~f:(fun (cpol, cpha) ->
    let tgt = spi_target ~cpol ~cpha ~tco:3 ~send:peer_bytes ~miso_glitch:(2, 4) ~glitch_len:10 () in
    let r = Psim.run ~tx_bytes:host ~setup:(ctl_setup ~cpol ~cpha ~p:7) ~cycles:6000 ~peer:tgt.drive () in
    printf "%s firings [%s] U %b\n" (mode_name (cpol, cpha)) (Psim.show_firings r) (u_ok r));
  [%expect {|
    m0 firings [B91@833] U true
    m1 firings [B91@825] U true
    m2 firings [B91@833] U true
    m3 firings [B91@825] U true
    |}]
;;

let ctl_peer ?defect ~cpol ~cpha ~hp () =
  spi_controller ~cpol ~cpha ~hp ~setup:hp ~hold:hp ~gap:(2 * hp + 64) ~mdly:2 ~t0:300 ~bytes:peer_bytes ?defect ()
;;

let%expect_test "SPI target h_min=3 g=6, P=7, controller peer half period 40 cycles" =
  List.iter modes ~f:(fun (cpol, cpha) ->
    let c = ctl_peer ~cpol ~cpha ~hp:40 () in
    let r = Psim.run ~tx_bytes:host ~setup:(tgt_setup ~cpol ~cpha ~p:7) ~cycles:(c.frames_end + 200) ~peer:c.cdrive () in
    printf "%s pushes %s, controller got %s, firings [%s] model_mismatch %d\n" (mode_name (cpol, cpha))
      (if eq (Psim.pushes r) peer_bytes then "= controller bytes" else "WRONG")
      (if eq (c.sampled ()) host then "= host bytes" else "WRONG")
      (Psim.show_firings r) r.model_mismatch);
  [%expect {|
    m0 pushes = controller bytes, controller got = host bytes, firings [] model_mismatch 0
    m1 pushes = controller bytes, controller got = host bytes, firings [] model_mismatch 0
    m2 pushes = controller bytes, controller got = host bytes, firings [] model_mismatch 0
    m3 pushes = controller bytes, controller got = host bytes, firings [] model_mismatch 0
    |}]
;;

let%expect_test "SPI target: controller half-period sweep (cycles; h_min = 3 steps = 24 cycles)" =
  List.iter modes ~f:(fun (cpol, cpha) ->
    let line =
      List.map [ 12; 16; 20; 23; 24; 26; 28; 32; 40 ] ~f:(fun hp ->
        let c = ctl_peer ~cpol ~cpha ~hp () in
        let r = Psim.run ~tx_bytes:host ~setup:(tgt_setup ~cpol ~cpha ~p:7) ~cycles:(c.frames_end + 200) ~peer:c.cdrive () in
        sprintf "%d:%s%s%s" hp
          (if eq (Psim.pushes r) peer_bytes && eq (c.sampled ()) host then "ok" else "data")
          (match Psim.firings r with [] -> "" | (_, _, c) :: _ -> sprintf "/%02X" c)
          (if u_ok r then "" else "/U-VIOLATION"))
    in
    printf "%s %s\n" (mode_name (cpol, cpha)) (String.concat ~sep:" " line));
  [%expect {|
    m0 12:data/52 16:data/52 20:data/52 23:data/52 24:ok 26:ok 28:ok 32:ok 40:ok
    m1 12:data/52 16:data/52 20:data/52 23:data/52 24:ok 26:ok 28:ok 32:ok 40:ok
    m2 12:data/52 16:data/52 20:data/52 23:data/52 24:ok 26:ok 28:ok 32:ok 40:ok
    m3 12:data/52 16:data/52 20:data/52 23:data/52 24:ok 26:ok 28:ok 32:ok 40:ok
    |}]
;;

let%expect_test "SPI target: controller defects (hp = 40 cycles)" =
  List.iter modes ~f:(fun (cpol, cpha) ->
    List.iter
      [ "early CS rise", Early_rise (2, 9)
      ; "MOSI at sample", Mosi_at_sample (3, 6)
      ; "SCLK not idle", Bad_idle (1)
      ; "fast edge pair", Fast_pair (4, 6)
      ]
      ~f:(fun (n, defect) ->
        let c = ctl_peer ~defect ~cpol ~cpha ~hp:40 () in
        let r = Psim.run ~tx_bytes:host ~setup:(tgt_setup ~cpol ~cpha ~p:7) ~cycles:(c.frames_end + 200) ~peer:c.cdrive () in
        printf "%s %-15s firings [%s] U %b\n" (mode_name (cpol, cpha)) n (Psim.show_firings r) (u_ok r)));
  [%expect {|
    m0 early CS rise   firings [B52@2345] U true
    m0 MOSI at sample  firings [B61@3297] U true
    m0 SCLK not idle   firings [B51@1129,F72@1289,B61@1689] U true
    m0 fast edge pair  firings [B52@3897] U true
    m1 early CS rise   firings [B61@2337,B52@2345] U true
    m1 MOSI at sample  firings [B61@3337] U true
    m1 SCLK not idle   firings [B51@1129,B61@1169,F72@1329] U true
    m1 fast edge pair  firings [B52@3897] U true
    m2 early CS rise   firings [B52@2345] U true
    m2 MOSI at sample  firings [B61@3297] U true
    m2 SCLK not idle   firings [B51@1129,F72@1289,B61@1689] U true
    m2 fast edge pair  firings [B52@3897] U true
    m3 early CS rise   firings [B61@2337,B52@2345] U true
    m3 MOSI at sample  firings [B61@3337] U true
    m3 SCLK not idle   firings [B51@1129,B61@1169,F72@1329] U true
    m3 fast edge pair  firings [B52@3897] U true
    |}]
;;

let%expect_test "SPI target: controller MOSI delay after the shifting edge (hp = 40 cycles)" =
  List.iter modes ~f:(fun (cpol, cpha) ->
    let line =
      List.map [ 2; 16; 30; 36; 40; 44; 50; 56; 60; 70 ] ~f:(fun mdly ->
        let c = spi_controller ~cpol ~cpha ~hp:40 ~setup:40 ~hold:40 ~gap:144 ~mdly ~t0:300 ~bytes:peer_bytes () in
        let r = Psim.run ~tx_bytes:host ~setup:(tgt_setup ~cpol ~cpha ~p:7) ~cycles:(c.frames_end + 200) ~peer:c.cdrive () in
        sprintf "%d:%s%s%s" mdly
          (if eq (Psim.pushes r) peer_bytes then "ok" else "data")
          (match Psim.firings r with [] -> "" | (_, _, c) :: _ -> sprintf "/%02X" c)
          (if u_ok r then "" else "/U-VIOLATION"))
    in
    printf "%s %s\n" (mode_name (cpol, cpha)) (String.concat ~sep:" " line));
  [%expect {|
    m0 2:ok 16:ok 30:ok 36:ok/61 40:ok/61 44:ok/62 50:ok/62 56:data/62 60:data/62 70:data/62
    m1 2:ok 16:ok 30:ok 36:ok/61 40:ok/61 44:ok/62 50:ok/62 56:data/62 60:data/62 70:data/62
    m2 2:ok 16:ok 30:ok 36:ok/61 40:ok/61 44:ok/62 50:ok/62 56:data/62 60:data/62 70:data/62
    m3 2:ok 16:ok 30:ok 36:ok/61 40:ok/61 44:ok/62 50:ok/62 56:data/62 60:data/62 70:data/62
    |}]
;;
