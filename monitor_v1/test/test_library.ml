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
  List.iter [ false, false; false, true; true, false; true, true ] ~f:(fun (cpol, cpha) ->
    report (Library_v1.spi_ctl ~cpol ~cpha ~h:2));
  List.iter [ false, false; false, true; true, false; true, true ] ~f:(fun (cpol, cpha) ->
    report (Library_v1.spi_tgt ~cpol ~cpha ~h_min:3 ~g:6));
  report (Library_v1.i2c_ctl ~l:5 ~h:5 ~tsu:5 ~thold:5);
  report (Library_v1.i2c_ctl ~l:6 ~h:4 ~tsu:3 ~thold:6);
  report (Library_v1.i2c_tgt ~h_min:29 ~l_min:34 ~hd:29);
  report (Library_v1.i2c_tgt ~h_min:4 ~l_min:9 ~hd:4);
  [%expect {|
    uart_tx_v1_d4_p0           units 2 instrs 12+2 preds 3/14 windows 3/7 codes 12/15
    uart_rx_v1_d8_m2_p1        units 2 instrs 21+11 preds 6/14 windows 7/7 codes 15/15
    spi_ctl_v1_m0_h2           units 5 instrs 21+10+12+2+18 preds 11/14 windows 6/7 codes 13/15
    spi_ctl_v1_m1_h2           units 5 instrs 21+11+12+2+18 preds 11/14 windows 6/7 codes 13/15
    spi_ctl_v1_m2_h2           units 5 instrs 21+10+12+2+18 preds 11/14 windows 6/7 codes 13/15
    spi_ctl_v1_m3_h2           units 5 instrs 21+11+12+2+18 preds 11/14 windows 6/7 codes 13/15
    spi_tgt_v1_m0_h3_g6        units 5 instrs 36+17+28+2+3 preds 14/14 windows 6/7 codes 14/15
    spi_tgt_v1_m1_h3_g6        units 5 instrs 36+18+28+2+3 preds 14/14 windows 6/7 codes 14/15
    spi_tgt_v1_m2_h3_g6        units 5 instrs 36+17+28+2+3 preds 14/14 windows 6/7 codes 14/15
    spi_tgt_v1_m3_h3_g6        units 5 instrs 36+18+28+2+3 preds 14/14 windows 6/7 codes 14/15
    i2c_ctl_v1_l5_h5           units 3 instrs 6+14+123 preds 14/14 windows 7/7 codes 12/15
    i2c_ctl_v1_l6_h4           units 3 instrs 6+14+123 preds 14/14 windows 7/7 codes 12/15
    i2c_tgt_v1_h29_l34         units 5 instrs 75+1+4+25+1 preds 13/14 windows 6/7 codes 13/15
    i2c_tgt_v1_h4_l9           units 5 instrs 75+1+4+25+1 preds 13/14 windows 6/7 codes 13/15
    |}]
;;

(* WF3 v1.1: codes label check families within one watcher. *)
let%expect_test "WF3 check families" =
  let open Lang in
  let mk name watchers =
    { name; observables = [ "a", Uio_out 0; "b", Uio_out 1; "pop", Tx_pop_ev ]; watchers }
  in
  let show c =
    match validate c with
    | Ok _ -> printf "%-22s accepted\n" c.name
    | Error es -> printf "%-22s rejected: %s\n" c.name (List.hd_exn es)
  in
  let w ?(base = 0x10) n body = watcher n ~base body in
  show (mk "eq_reg_index_differs" [ w "x" [ take_idle Tx_pop; hold (eq_reg (v "a") 0) ~for_:2 ~else_:(fail 1); hold (eq_reg (v "a") 5) ~for_:3 ~else_:(fail 1) ] ]);
  show (mk "same_hold_twice" [ w "x" [ take_idle Tx_pop; hold (v "a") ~for_:2 ~else_:(fail 1); skip 1; hold (v "a") ~for_:7 ~else_:(fail 1) ] ]);
  show (mk "requirement_differs" [ w "x" [ take_idle Tx_pop; hold (v "a") ~for_:2 ~else_:(fail 1); hold (v "b") ~for_:2 ~else_:(fail 1) ] ]);
  show (mk "kind_differs" [ w "x" [ take_idle Tx_pop; hold (v "a") ~for_:2 ~else_:(fail 1); expect (v "a") ~else_:(fail 1) ] ]);
  show (mk "condition_differs" [ w "x" [ take_idle Tx_pop; hold (v "a") ~for_:2 ~else_:(fail 1); hold ~when_:(v "b") (v "a") ~for_:2 ~else_:(fail 1) ] ]);
  show (mk "early_vs_timeout" [ w "x" [ take_idle Tx_pop; await (v "a") (win ~early:(fail 1) 2 4 ~else_:(fail 1)) ] ]);
  show (mk "across_watchers" [ w "x" [ take_idle Tx_pop; hold (v "a") ~for_:2 ~else_:(fail 1) ]; w "y" ~base:0x10 [ take_idle Tx_pop; hold (v "a") ~for_:2 ~else_:(fail 1) ] ]);
  show (mk "raise_twice" [ w "x" [ take_idle Tx_pop; raise_ (fail 1); skip 1; raise_ (fail 1) ] ]);
  [%expect {|
    eq_reg_index_differs   accepted
    same_hold_twice        accepted
    requirement_differs    rejected: x: code 0x11 shared by checks of different families (WF3)
    kind_differs           rejected: x: code 0x11 shared by checks of different families (WF3)
    condition_differs      rejected: x: code 0x11 shared by checks of different families (WF3)
    early_vs_timeout       rejected: x: code 0x11 shared by checks of different families (WF3)
    across_watchers        rejected: y: code 0x11 shared by checks of different families (WF3)
    raise_twice            rejected: x: code 0x11 shared by checks of different families (WF3)
    |}]
;;

(* Site resolution: a per-bit family shares one code; the interpreter names the bit. *)
let%expect_test "WF3 site resolution" =
  let open Lang in
  let c =
    { name = "bits"
    ; observables = [ "a", Uio_out 0; "pop", Tx_pop_ev ]
    ; watchers =
        [ watcher "bits" ~base:0x10
            [ loop ([ take_idle ~byte:1 Tx_pop ]
                    @ List.init 8 ~f:(fun k -> hold (eq_reg (v "a") (15 - k)) ~for_:1 ~else_:(fail 1))) ]
        ]
    }
  in
  let run ~bad =
    let t = Interp.create c in
    let b = 0xA5 in
    let base = { Interp.rst_sync_n = true; running = true; tick = true; ui_in = 0; uio_in = 0; uo_out = 0
               ; uio_out = 0; uio_oe = 0; pop_ev = false; pop_data = 0; push_ev = false; push_data = 0 } in
    let out = ref [] in
    let feed i = out := !out @ Interp.step t i in
    feed base;
    feed { base with pop_ev = true; pop_data = b };
    for k = 0 to 7 do
      let bit = (b lsr (7 - k)) land 1 in
      let bit = if k = bad then 1 - bit else bit in
      feed { base with uio_out = bit }
    done;
    match !out with
    | [] -> printf "bad bit %d: no firing\n" bad
    | (_, code) :: _ ->
      let w, n, _ = Option.value_exn (Interp.fired_site t ~code) in
      printf "bad bit %d: code 0x%02x watcher %s site ordinal %d\n" bad code w n
  in
  List.iter [ 0; 5; 7 ] ~f:(fun bad -> run ~bad);
  [%expect {|
    bad bit 0: code 0x11 watcher bits site ordinal 0
    bad bit 5: code 0x11 watcher bits site ordinal 5
    bad bit 7: code 0x11 watcher bits site ordinal 7
    |}]
;;
