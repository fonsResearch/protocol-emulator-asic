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
