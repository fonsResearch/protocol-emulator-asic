(* v2 static admissibility (D13 recurrence check, log/harness_audit_v2.md C4): every package of
   the v2 minimum library runs monitored at its documented P with 5 serial slots. Negative
   controls: the I2C target at its v1 divisor P = 3, and the minimum library on 4 slots. *)
open! Core
open Pemu_rtl_v1
open Pemu_monitor_v1

let show ~slots lib =
  match Rom_lib.admissibility_violations ~slots lib with
  | [] -> printf "slots %d: all admissible\n" slots
  | v -> List.iter v ~f:(printf "slots %d: VIOLATION %s\n" slots)
;;

let%expect_test "divisor rules reproduce the documented 33 MHz values; 30 MHz values admissible" =
  let ps l = List.map l ~f:snd in
  let doc33 = ps (Rom_lib.v2_inc1_with_p ()) in
  let r33 = Rom_lib.divisors_at ~clock_hz:33_000_000 in
  let r30 = Rom_lib.divisors_at ~clock_hz:30_000_000 in
  let show_l l = String.concat ~sep:" " (List.map l ~f:Int.to_string) in
  printf "documented 33 MHz: %s\nrules at 33 MHz:   %s (equal %b)\nrules at 30 MHz:   %s\n" (show_l doc33)
    (show_l r33) (List.equal Int.equal doc33 r33) (show_l r30);
  show ~slots:5 (Rom_lib.v2_inc1_with_p_at ~clock_hz:30_000_000);
  [%expect {|
    documented 33 MHz: 71 35 7 7 8 32
    rules at 33 MHz:   71 35 7 7 8 32 (equal true)
    rules at 30 MHz:   64 32 7 7 7 29
    slots 5: all admissible
    |}]
;;

let%expect_test "v2 minimum library is admissible at 5 slots" =
  show ~slots:5 (Rom_lib.minimum_v2_with_p ());
  show ~slots:5 [ Library_v1.i2c_tgt ~h_min:8 ~l_min:18 ~hd:8, 3 ];
  show ~slots:4 (Rom_lib.minimum_v2_with_p ());
  show ~slots:5 (Rom_lib.v2_inc1_with_p ());
  [%expect {|
    slots 5: all admissible
    slots 5: VIOLATION i2c_tgt_v1_h8_l18: units 5 (slots 5), P 3 (min 4)
    slots 4: VIOLATION spi_ctl_v1_m0_h2: units 5 (slots 4), P 7 (min 3)
    slots 4: VIOLATION spi_tgt_v1_m0_h3_g6: units 5 (slots 4), P 7 (min 3)
    slots 5: all admissible
    |}]
;;

let%expect_test "increment 3: I2C target Sm package (P = 4) parameters, units, words, admissibility" =
  List.iter [ 30_000_000; 33_000_000 ] ~f:(fun clock_hz ->
    let h, l, hd = Rom_lib.i2c_tgt_sm_params ~clock_hz in
    printf "%d Hz: h_min %d l_min %d hd %d\n" clock_hz h l hd);
  let lib = Rom_lib.v2_inc3_with_p_at ~clock_hz:Rom_lib.v2_clock_hz in
  List.iteri lib ~f:(fun i (c, p) ->
    let m = Compile.compile_exn c in
    let words = Array.sum (module Int) m.units ~f:(fun u -> Array.length u.code) in
    printf "%d %-24s P %2d units %d instr %3d\n" i m.name p (Array.length m.units) words);
  show ~slots:5 lib;
  [%expect {|
    30000000 Hz: h_min 19 l_min 22 hd 19
    33000000 Hz: h_min 21 l_min 24 hd 21
    0 uart_tx_v1_d4_p0         P 64 units 2 instr  14
    1 uart_rx_v1_d8_m2_p1      P 32 units 2 instr  32
    2 spi_ctl_v1_m0_h2         P  7 units 5 instr  63
    3 spi_tgt_v1_m0_h3_g6      P  7 units 5 instr  86
    4 i2c_ctl_v1_l6_h4         P  7 units 3 instr 143
    5 i2c_ctl_v1_l5_h5         P 29 units 3 instr 143
    6 i2c_tgt_v1_h19_l22       P  5 units 5 instr 107
    slots 5: all admissible
    |}]
;;

let%expect_test "increment 5: USB-LS TX package 7, divisor and admissibility (pipelined, P >= 5)" =
  let lib = Rom_lib.v2_inc5_with_p () in
  List.iteri lib ~f:(fun i (c, p) ->
    if i >= 6 then (
      let m = Compile.compile_exn c in
      let words = Array.sum (module Int) m.units ~f:(fun u -> Array.length u.code) in
      printf "%d %-24s P %2d units %d instr %3d\n" i m.name p (Array.length m.units) words));
  printf "USB P at 30 MHz %d (cycles per bit %d), at 33 MHz %d\n" (Rom_lib.usb_ls_p ~clock_hz:30_000_000)
    (Rom_lib.usb_ls_p ~clock_hz:30_000_000 + 1) (Rom_lib.usb_ls_p ~clock_hz:33_000_000);
  show ~slots:5 lib;
  [%expect {|
    6 i2c_tgt_v1_h19_l22       P  5 units 5 instr 107
    7 usb_ls_tx_v1             P 19 units 5 instr  27
    USB P at 30 MHz 19 (cycles per bit 20), at 33 MHz 21
    slots 5: all admissible
    |}]
;;
