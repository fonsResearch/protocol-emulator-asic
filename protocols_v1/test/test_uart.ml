(* UART v1 packages over the lane model, the monitor and cycle-level peers (Psim). *)
open! Core
open Pemu_protocols_v1
module P1 = Pemu_spec_v1.Programs_v1
module Lib = Pemu_monitor_v1.Library_v1

open Peers

let rx_setup ?(prog = P1.uart_rx ~d:8 ~pin:1) () =
  { Psim.prog; own = 0; od = 0; cfg = 0; cfg2 = 0; p = 64
  ; contract = Lib.uart_rx ~d:8 ~m:2 ~pin:1; open_drain_wired_and = 0 }
;;

let summary name (r : Psim.result) ~sent =
  let pushed = Psim.pushes r in
  printf "%-28s steps %5d pushes %2d data %s firings [%s] model_mismatch %d\n" name r.steps
    (List.length pushed)
    (if [%equal: int list] pushed sent then "= sent" else "!= sent")
    (Psim.show_firings r) r.model_mismatch
;;

let%expect_test "UART RX d=8 m=2, 115200 baud at 60 MHz (P = 64)" =
  let nominal = 60e6 /. 115200. in
  let bytes = [ 0x55; 0xA5; 0x00; 0xFF; 0x3C; 0x81; 0x7E; 0x01 ] in
  let gap b = 3 + (b * 7 % 400) in
  List.iter [ "nominal", 1.0; "+2.5% baud", 1.0 /. 1.025; "-2.5% baud", 1.0 /. 0.975 ]
    ~f:(fun (n, f) ->
      let bp = nominal *. f in
      let frames = frames_of ~bp ~st0:2000 bytes ~gap in
      let r = Psim.run ~setup:(rx_setup ()) ~cycles:80_000 ~peer:(sender ~pin:1 ~bp ~frames ~defect:No_defect) () in
      summary n r ~sent:bytes);
  (* misbehaving senders: blame required, and no fail before the first blame *)
  List.iter
    [ "8% fast sender", nominal /. 1.08, No_defect
    ; "1-cycle glitch (unobservable)", nominal, Glitch (2, Float.to_int (4.5 *. nominal), 1)
    ; "0.25-bit glitch in bit 3 core", nominal, Glitch (2, Float.to_int (4.4 *. nominal), Float.to_int (0.25 *. nominal))
    ; "short stop bit", nominal, Short_stop 4 ]
    ~f:(fun (n, bp, defect) ->
      let frames = frames_of ~bp ~st0:2000 bytes ~gap in
      let r = Psim.run ~setup:(rx_setup ()) ~cycles:80_000 ~peer:(sender ~pin:1 ~bp ~frames ~defect) () in
      summary n r ~sent:bytes);
  (* firmware mutant: first sample one bit period late *)
  let late = List.mapi (P1.uart_rx ~d:8 ~pin:1) ~f:(fun i x -> if i = 2 then Pemu_spec_v1.Isa1.Wait (8 + 4 - 3 + 8) else x) in
  let frames = frames_of ~bp:nominal ~st0:2000 bytes ~gap in
  let r = Psim.run ~setup:(rx_setup ~prog:late ()) ~cycles:80_000 ~peer:(sender ~pin:1 ~bp:nominal ~frames ~defect:No_defect) () in
  summary "mutant: sampling 1 bit late" r ~sent:bytes;
  [%expect {|
    nominal                      steps  1230 pushes  8 data = sent firings [] model_mismatch 0
    +2.5% baud                   steps  1230 pushes  8 data = sent firings [] model_mismatch 0
    -2.5% baud                   steps  1230 pushes  8 data = sent firings [] model_mismatch 0
    8% fast sender               steps  1230 pushes  6 data != sent firings [B32@4421] model_mismatch 0
    1-cycle glitch (unobservable) steps  1230 pushes  8 data = sent firings [] model_mismatch 0
    0.25-bit glitch in bit 3 core steps  1230 pushes  8 data != sent firings [B32@15276] model_mismatch 0
    short stop bit               steps  1230 pushes  8 data = sent firings [B33@28536] model_mismatch 0
    mutant: sampling 1 bit late  steps  1230 pushes  6 data != sent firings [F4B@7021] model_mismatch 0
    |}]
;;

(* Necessity of the sender assumption: the next start bit arrives after a stop bit of only
   f bit periods. Without the sender watcher the receiver guarantee can fail with no blame;
   with it, every fail is preceded (or accompanied) by a blame. *)
let%expect_test "UART RX: stop-bit truncation sweep" =
  let nominal = 60e6 /. 115200. in
  let full = Lib.uart_rx ~d:8 ~m:2 ~pin:1 in
  let recv_only = { full with watchers = List.filter full.watchers ~f:(fun w -> String.equal w.wname "receiver") } in
  let fail_wo_blame (r : Psim.result) =
    let blamed = ref false and bad = ref false in
    List.iter (Psim.firings r) ~f:(fun (_, ro, _) ->
      match ro with
      | Blame -> blamed := true
      | Fail -> if not !blamed then bad := true);
    !bad
  in
  List.iter (List.init 21 ~f:(fun i -> 0.55 +. (0.01 *. Float.of_int i))) ~f:(fun f ->
    let st = 2000 in
    let frames = [ st, 0x5A; st + Float.to_int (Float.round_nearest ((9. +. f) *. nominal)), 0xC3; st + 30000, 0x0F ] in
    let peer = sender ~pin:1 ~bp:nominal ~frames ~defect:No_defect in
    let r_full = Psim.run ~setup:{ (rx_setup ()) with contract = full } ~cycles:40_000 ~peer ()
    and r_recv = Psim.run ~setup:{ (rx_setup ()) with contract = recv_only } ~cycles:40_000 ~peer () in
    printf "stop %.2f bit: with assumption [%s]%s | receiver only [%s]%s\n" f (Psim.show_firings r_full)
      (if fail_wo_blame r_full then " FAIL-WITHOUT-BLAME" else "")
      (Psim.show_firings r_recv)
      (if fail_wo_blame r_recv then " fail without blame" else ""));
  [%expect {|
    stop 0.55 bit: with assumption [B33@7021,F4B@12026] | receiver only [F4B@12026] fail without blame
    stop 0.56 bit: with assumption [B33@7021,F4B@12026] | receiver only [F4B@12026] fail without blame
    stop 0.57 bit: with assumption [B33@7021,F4B@12026] | receiver only [F4B@12026] fail without blame
    stop 0.58 bit: with assumption [B33@7021,F4B@12026] | receiver only [F4B@12026] fail without blame
    stop 0.59 bit: with assumption [B33@7021,F4B@12026] | receiver only [F4B@12026] fail without blame
    stop 0.60 bit: with assumption [B33@7021,F4B@12026] | receiver only [F4B@12026] fail without blame
    stop 0.61 bit: with assumption [B33@7021,F4B@12026] | receiver only [F4B@12026] fail without blame
    stop 0.62 bit: with assumption [B33@7021,F4B@12026] | receiver only [F4B@12026] fail without blame
    stop 0.63 bit: with assumption [B33@7021,F4B@12026] | receiver only [F4B@12026] fail without blame
    stop 0.64 bit: with assumption [] | receiver only []
    stop 0.65 bit: with assumption [] | receiver only []
    stop 0.66 bit: with assumption [] | receiver only []
    stop 0.67 bit: with assumption [] | receiver only []
    stop 0.68 bit: with assumption [] | receiver only []
    stop 0.69 bit: with assumption [] | receiver only []
    stop 0.70 bit: with assumption [] | receiver only []
    stop 0.71 bit: with assumption [] | receiver only []
    stop 0.72 bit: with assumption [] | receiver only []
    stop 0.73 bit: with assumption [] | receiver only []
    stop 0.74 bit: with assumption [] | receiver only []
    stop 0.75 bit: with assumption [] | receiver only []
    |}]
;;
