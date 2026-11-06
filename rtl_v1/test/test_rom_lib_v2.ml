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
