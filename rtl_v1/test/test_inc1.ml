(* Increment 1 (log/increments_v2.md): the I2C controller packages (ROM 4 = Fm, 5 = Sm) on the v2
   top RTL with library Rom_lib.v2_inc1, at their documented 33 MHz divisors (Fm P = 8, Sm P = 32),
   against Psim with the I2C target peer on the wired-AND bus. Same comparison as the C3 tests
   (Test_c3_env.compare_runs): lane-0 monitor-input stream, owned pins, verdict, pushes.
   Host stream (7 bytes, fits the TX FIFO, preloaded on the chip): write 3 bytes to 0x50, then
   read 2 bytes from 0x50. *)
open! Core
open Pemu_spec_v1
open Pemu_monitor_v1
open Pemu_rtl_v1
module D = Test_c3_diff
module E = Test_c3_env
module Psim = Pemu_protocols_v1.Psim
module Peers = Pemu_protocols_v1.Peers
module P1 = Programs_v1
module Lib = Library_v1

let lib = List.map (Rom_lib.v2_inc1 ()) ~f:Compile.compile_exn
let p_of i = snd (List.nth_exn (Rom_lib.v2_inc1_with_p ()) i)
let host = [ 0xA0; 0x03; 0x11; 0x22; 0x33; 0xA1; 0x02 ]

let ctl_setup ~p ~l ~h ~tsu ~thold =
  { Psim.prog = P1.i2c_ctl ~l ~h ~tsu ~thold; own = P1.i2c_own; od = P1.i2c_od; cfg = 0; cfg2 = 0; p
  ; contract = Lib.i2c_ctl ~l ~h ~tsu ~thold; open_drain_wired_and = P1.i2c_own }
;;

(* every fail has a blame in the same or an earlier cycle *)
let u_ok (r : Psim.result) =
  let f = Psim.firings r in
  let b = List.find_map f ~f:(fun (c, ro, _) -> if Lang.equal_role ro Blame then Some c else None) in
  List.for_all f ~f:(fun (c, ro, _) ->
    match ro, b with Blame, _ -> true | Fail, Some b -> b <= c | Fail, None -> false)
;;

let run ?verdict_pipe ~k ~name ~pkg ~setup ~peer ~cycles () =
  let c = D.chip_run ~lib ?verdict_pipe ~k ~setup ~pkg ~tx_bytes:host ~peer:(peer ()) ~cycles () in
  let r, pmi = E.psim_run ~clear_at:[] ~setup ~tx_bytes:host ~peer ~cycles in
  let x = E.compare_runs ~setup ~cycles c r pmi in
  printf "%-34s mon-in %-7s pins %-7s verdict %s pushes %s [%s] | psim [%s] U %b\n" name (E.show_o x.mon_first)
    (E.show_o x.pins_first) (if x.verdict_eq then "=" else "DIFF") (if x.rx_eq then "=" else "DIFF")
    (String.concat ~sep:" " (List.map (Psim.pushes r) ~f:(sprintf "%02X")))
    (Psim.show_firings r) (u_ok r)
;;

let%expect_test "increment 1: I2C controller on the v2 top at its 33 MHz divisors" =
  let k = List.hd_exn (D.calibrate ()) in
  let fm = ctl_setup ~p:(p_of 4) ~l:6 ~h:4 ~tsu:3 ~thold:6
  and sm = ctl_setup ~p:(p_of 5) ~l:5 ~h:5 ~tsu:5 ~thold:5 in
  printf "Fm P = %d, Sm P = %d\n" fm.p sm.p;
  let tgt ?dd ?nack_write ?stretch () () =
    (Peers.i2c_target ~addr:0x50 ~read_data:[ 0xC3; 0x5A ] ?dd ?nack_write ?stretch ()).drive
  in
  run ~k ~name:"Fm clean" ~pkg:4 ~setup:fm ~peer:(tgt ()) ~cycles:12_000 ();
  run ~k ~name:"Fm clock stretch 200" ~pkg:4 ~setup:fm ~peer:(tgt ~stretch:200 ()) ~cycles:14_000 ();
  run ~k ~name:"Fm target NACKs write byte 1" ~pkg:4 ~setup:fm ~peer:(tgt ~nack_write:1 ()) ~cycles:12_000 ();
  List.iter [ 30; 50; 70 ] ~f:(fun dd ->
    run ~k ~name:(sprintf "Fm target data delay %d" dd) ~pkg:4 ~setup:fm ~peer:(tgt ~dd ()) ~cycles:12_000 ());
  run ~k ~name:"Sm clean" ~pkg:5 ~setup:sm ~peer:(tgt ()) ~cycles:40_000 ();
  run ~k ~name:"Sm clock stretch 600" ~pkg:5 ~setup:sm ~peer:(tgt ~stretch:600 ()) ~cycles:44_000 ();
  run ~verdict_pipe:true ~k ~name:"Fm data delay 70 + vpipe" ~pkg:4 ~setup:fm ~peer:(tgt ~dd:70 ()) ~cycles:12_000 ();
  run ~verdict_pipe:true ~k ~name:"Fm clean + vpipe" ~pkg:4 ~setup:fm ~peer:(tgt ()) ~cycles:12_000 ();
  [%expect {|
    Fm P = 8, Sm P = 32
    Fm clean                           mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    Fm clock stretch 200               mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    Fm target NACKs write byte 1       mon-in =       pins =       verdict = pushes = [02 C3 5A 00] | psim [] U true
    Fm target data delay 30            mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    Fm target data delay 50            mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    Fm target data delay 70            mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [B77@5950] U true
    Sm clean                           mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    Sm clock stretch 600               mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    Fm data delay 70 + vpipe           mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [B77@5950] U true
    Fm clean + vpipe                   mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    |}]
;;

let%expect_test "increment 1: I2C controller at the 30 MHz divisors (variant v2-inc1-30mhz)" =
  let k = List.hd_exn (D.calibrate ()) in
  let p30 i = snd (List.nth_exn (Rom_lib.v2_inc1_with_p_at ~clock_hz:30_000_000) i) in
  let fm = ctl_setup ~p:(p30 4) ~l:6 ~h:4 ~tsu:3 ~thold:6
  and sm = ctl_setup ~p:(p30 5) ~l:5 ~h:5 ~tsu:5 ~thold:5 in
  printf "Fm P = %d, Sm P = %d\n" fm.p sm.p;
  let tgt ?dd ?nack_write ?stretch () () =
    (Peers.i2c_target ~addr:0x50 ~read_data:[ 0xC3; 0x5A ] ?dd ?nack_write ?stretch ()).drive
  in
  run ~k ~name:"Fm clean" ~pkg:4 ~setup:fm ~peer:(tgt ()) ~cycles:12_000 ();
  run ~k ~name:"Fm clock stretch 200" ~pkg:4 ~setup:fm ~peer:(tgt ~stretch:200 ()) ~cycles:14_000 ();
  run ~k ~name:"Fm target NACKs write byte 1" ~pkg:4 ~setup:fm ~peer:(tgt ~nack_write:1 ()) ~cycles:12_000 ();
  List.iter [ 30; 50; 70 ] ~f:(fun dd ->
    run ~k ~name:(sprintf "Fm target data delay %d" dd) ~pkg:4 ~setup:fm ~peer:(tgt ~dd ()) ~cycles:12_000 ());
  run ~k ~name:"Sm clean" ~pkg:5 ~setup:sm ~peer:(tgt ()) ~cycles:40_000 ();
  run ~k ~name:"Sm clock stretch 600" ~pkg:5 ~setup:sm ~peer:(tgt ~stretch:600 ()) ~cycles:44_000 ();
  run ~verdict_pipe:true ~k ~name:"Fm clean + vpipe" ~pkg:4 ~setup:fm ~peer:(tgt ()) ~cycles:12_000 ();
  [%expect {|
    Fm P = 7, Sm P = 29
    Fm clean                           mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    Fm clock stretch 200               mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    Fm target NACKs write byte 1       mon-in =       pins =       verdict = pushes = [02 C3 5A 00] | psim [] U true
    Fm target data delay 30            mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    Fm target data delay 50            mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    Fm target data delay 70            mon-in =       pins =       verdict = pushes = [00 E1 AD 00] | psim [B77@1065] U true
    Sm clean                           mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    Sm clock stretch 600               mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    Fm clean + vpipe                   mon-in =       pins =       verdict = pushes = [00 C3 5A 00] | psim [] U true
    |}]
;;
