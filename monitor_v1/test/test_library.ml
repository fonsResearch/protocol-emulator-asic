(* Library packages: validation, compilation and ISA resource use (8 units, 14 predicates,
   7 windows, 15 codes per package). *)
open! Core
open Pemu_monitor_v1

let report (c : Lang.t) =
  match Compile.compile c with
  | Error e -> printf "%-26s REJECTED %s\n" c.name e
  | Ok p ->
    let preds =
      Array.count p.preds ~f:(fun x ->
        not (Mprog.equal_pred x Mprog.pred_false || Mprog.equal_pred x Mprog.pred_true))
    in
    let wins = Array.count p.windows ~f:(fun w -> w <> 0) in
    let codes = Array.count p.codes ~f:Option.is_some in
    printf "%-26s units %d instrs %s preds %d/14 windows %d/7 codes %d/15\n" c.name
      (Array.length p.units)
      (Array.to_list p.units |> List.map ~f:(fun u -> Int.to_string (Array.length u.code)) |> String.concat ~sep:"+")
      preds wins codes
;;

let%expect_test "library packages" =
  report (Library_v1.uart_tx ~d:4 ~pin:0);
  report (Library_v1.uart_rx ~d:8 ~m:2 ~pin:1);
  [%expect {|
    uart_tx_v1_d4_p0           units 2 instrs 12+2 preds 3/14 windows 3/7 codes 12/15
    uart_rx_v1_d8_m2_p1        units 2 instrs 21+11 preds 6/14 windows 7/7 codes 15/15
    |}]
;;
