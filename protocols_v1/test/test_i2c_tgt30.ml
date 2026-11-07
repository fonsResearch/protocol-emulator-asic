(* Increment 3 (log/increments_v2.md section 3): the I2C target Sm package on the 30 MHz v2
   clock. Divisor choice: P >= 4 (5-slot admission), and the contract's hd must cover the
   firmware's polling START detection (about 7 steps, doc/protocols/i2c_v1.md 5.4), else a
   controller with a short tHD;STA is missed silently (no firing). Measured here over P. *)
open! Core
open Pemu_protocols_v1
module P1 = Pemu_spec_v1.Programs_v1
module Lib = Pemu_monitor_v1.Library_v1
open Peers

let u_ok (r : Psim.result) =
  let f = Psim.firings r in
  let first_blame = List.find_map f ~f:(fun (c, ro, _) -> match ro with Blame -> Some c | Fail -> None) in
  List.for_all f ~f:(fun (c, ro, _) ->
    match ro, first_blame with
    | Blame, _ -> true
    | Fail, Some b -> b <= c
    | Fail, None -> false)
;;

let hex l = String.concat ~sep:" " (List.map l ~f:(sprintf "%02X"))

(* UM10204 Sm minima in cycles at 30 MHz, rounded up: tLOW 4.7 us, tHIGH 4.0, tHD;STA 4.0,
   tSU;STA 4.7, tSU;STO 4.0, tBUF 4.7; tSU;DAT 250 ns = 7.5 -> 8; dh 1 cycle (tHD;DAT >= 0) *)
let sm30 = { tlow = 141; thigh = 120; thd_sta = 120; tsu_sta = 141; tsu_sto = 120; tbuf = 141; dh = 1; su = 8 }

(* doc/protocols/i2c_v1.md 3.2 rule: floor(minimum / step) - 1 *)
let params ~p (t : i2c_ctl_timing) =
  let f c = Int.max 2 ((c / (p + 1)) - 1) in
  f t.thigh, f t.tlow, f t.thd_sta
;;

let setup ~p t =
  let h_min, l_min, hd = params ~p t in
  { Psim.prog = P1.i2c_tgt ~addr:0x50; own = P1.i2c_own; od = P1.i2c_od; cfg = 0; cfg2 = 0; p
  ; contract = Lib.i2c_tgt ~h_min ~l_min ~hd; open_drain_wired_and = P1.i2c_own }
;;

let txs =
  [ `W (0x50, [ 0x11; 0x22; 0x33 ]), false; `W (0x50, [ 0x44 ]), true; `R (0x50, 2), false; `R (0x51, 1), false
  ; `W (0x52, [ 0xAA ]), false; `R (0x50, 1), false ]
;;

let host = [ 0x50; 0xA1; 0x36; 0x0E ]
let good = [ 0x11; 0x22; 0x33; 0x44 ]
let good_bus = "S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RA1 R36 P S A51R- RFF P S A52W- WAA- P S A50R+ R0E P"

let firing_tag (r : Psim.result) =
  match List.filter (Psim.firings r) ~f:(fun (cy, _, _) -> cy > 20) with
  | [] -> ""
  | (_, ro, k) :: _ -> sprintf "/%s%02X" (match ro with Fail -> "F" | Blame -> "B") k
;;

let run ?(t_ctl = Fn.id) ~p ~cycles () =
  let c = i2c_controller ~t:(t_ctl sm30) txs in
  let r = Psim.run ~tx_bytes:host ~setup:(setup ~p sm30) ~cycles ~peer:c.cdrive () in
  let ok = [%equal: int list] (Psim.pushes r) good && String.equal (c.clog ()) good_bus in
  c, r, ok
;;

let%expect_test "I2C target Sm at 30 MHz, controller at UM10204 minima, P = 4..16" =
  List.iter [ 4; 6; 8; 10; 12; 14; 16 ] ~f:(fun p ->
    let c, r, ok = run ~p ~cycles:150_000 () in
    let h_min, l_min, hd = params ~p sm30 in
    printf "P=%2d (h_min %d l_min %d hd %d) done %b ok %b firings [%s] U %b mm %d\n" p h_min l_min hd (c.cdone ()) ok
      (Psim.show_firings r) (u_ok r) r.model_mismatch);
  [%expect {|
    P= 4 (h_min 23 l_min 27 hd 23) done true ok true firings [] U true mm 0
    P= 6 (h_min 16 l_min 19 hd 16) done true ok true firings [] U true mm 0
    P= 8 (h_min 12 l_min 14 hd 12) done true ok true firings [] U true mm 0
    P=10 (h_min 9 l_min 11 hd 9) done true ok true firings [] U true mm 0
    P=12 (h_min 8 l_min 9 hd 8) done true ok true firings [] U true mm 0
    P=14 (h_min 7 l_min 8 hd 7) done true ok false firings [] U true mm 0
    P=16 (h_min 6 l_min 7 hd 6) done true ok false firings [] U true mm 0
    |}]
;;

(* A silent miss is BAD without a firing: the target lost a transaction and the monitor did not
   see it (ACK iff address match is [O]). BAD with a blame is acceptable (controller fault). *)
let%expect_test "I2C target Sm at 30 MHz: START/Sr hold-time sweep (cycles; UM10204 min 120)" =
  List.iter [ 4; 6; 8; 10; 12; 14; 16 ] ~f:(fun p ->
    let line =
      List.map [ 20; 30; 40; 50; 60; 70; 80; 90; 100; 110; 120 ] ~f:(fun thd_sta ->
        let _, r, ok = run ~t_ctl:(fun t -> { t with thd_sta }) ~p ~cycles:150_000 () in
        sprintf "%d:%s%s%s" thd_sta (if ok then "ok" else "BAD") (firing_tag r) (if u_ok r then "" else "/U!"))
    in
    printf "P=%2d hd=%d(%d cy) %s\n" p (let _, _, hd = params ~p sm30 in hd)
      (let _, _, hd = params ~p sm30 in hd * (p + 1)) (String.concat ~sep:" " line));
  [%expect {|
    P= 4 hd=23(115 cy) 20:BAD/B82 30:ok/B82 40:ok/B82 50:ok/B82 60:ok/B82 70:ok/B82 80:ok/B82 90:ok/B82 100:ok/B82 110:ok/B82 120:ok
    P= 6 hd=16(112 cy) 20:BAD/B82 30:BAD/B82 40:BAD/B82 50:ok/B82 60:ok/B82 70:ok/B82 80:ok/B82 90:ok/B82 100:ok/B82 110:ok/B82 120:ok
    P= 8 hd=12(108 cy) 20:BAD/B82 30:BAD/B82 40:BAD/B82 50:BAD/B82 60:BAD/B82 70:ok/B82 80:ok/B82 90:ok/B82 100:ok/B82 110:ok 120:ok
    P=10 hd=9(99 cy) 20:BAD/B82 30:BAD/B82 40:BAD/B82 50:BAD/B82 60:BAD/B82 70:BAD/B82 80:BAD/B82 90:ok/B82 100:ok 110:ok 120:ok
    P=12 hd=8(104 cy) 20:BAD/B82 30:BAD/B82 40:BAD/B82 50:BAD/B82 60:BAD/B82 70:BAD/B82 80:ok/B82 90:ok/B82 100:ok/B82 110:ok 120:ok
    P=14 hd=7(105 cy) 20:BAD/B82 30:BAD/B82 40:BAD/B82 50:BAD/B82 60:BAD/B82 70:BAD/B82 80:BAD/B82 90:BAD/B82 100:BAD/B82 110:BAD 120:BAD
    P=16 hd=6(102 cy) 20:BAD/B82 30:BAD/B82 40:BAD/B82 50:BAD/B82 60:BAD/B82 70:BAD/B82 80:BAD/B82 90:BAD/B82 100:BAD/B82 110:BAD 120:BAD
    |}]
;;

(* ---- the shipped divisor, P = 4 ---- *)

let run4 ?(t_ctl = Fn.id) ?(prog = Fn.id) ?tx_times ~cycles () =
  let c = i2c_controller ~t:(t_ctl sm30) txs in
  let s = setup ~p:4 sm30 in
  let r = Psim.run ~tx_bytes:host ?tx_times ~setup:{ s with prog = prog s.prog } ~cycles ~peer:c.cdrive () in
  printf "  bus: %s\n  pushes: %s firings [%s] U %b mm %d\n" (c.clog ()) (hex (Psim.pushes r)) (Psim.show_firings r)
    (u_ok r) r.model_mismatch;
  r
;;

let%expect_test "P=4 Sm 30 MHz: read bytes late (stretching), 0 / 60000 / 120000 cycles" =
  List.iter [ 0; 60_000; 120_000 ] ~f:(fun d ->
    printf "delay %d:\n" d;
    let r = run4 ~tx_times:[ 0; d; d; d ] ~cycles:300_000 () in
    let runs = ref [] and cur = ref 0 in
    Array.iter r.outs ~f:(fun (_, oe) ->
      if (oe lsr 2) land 1 = 1 then incr cur else if !cur > 0 then (runs := !cur :: !runs; cur := 0));
    printf "  lane SCL pulls: %d, longest %d cycles\n" (List.length !runs) (List.fold !runs ~init:0 ~f:Int.max));
  [%expect {|
    delay 0:
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RA1 R36 P S A51R- RFF P S A52W- WAA- P S A50R+ R0E P
      pushes: 11 22 33 44 firings [] U true mm 0
      lane SCL pulls: 0, longest 0 cycles
    delay 60000:
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RA1 R36 P S A51R- RFF P S A52W- WAA- P S A50R+ R0E P
      pushes: 11 22 33 44 firings [] U true mm 0
      lane SCL pulls: 1, longest 42320 cycles
    delay 120000:
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RA1 R36 P S A51R- RFF P S A52W- WAA- P S A50R+ R0E P
      pushes: 11 22 33 44 firings [] U true mm 0
      lane SCL pulls: 1, longest 102325 cycles
    |}]
;;

let%expect_test "P=4 Sm 30 MHz: controller misbehaviour is blamed" =
  List.iter
    [ "tlow 120 (< 141)", (fun t -> { t with tlow = 120 }); "thigh 100 (< 120)", (fun t -> { t with thigh = 100 })
    ; "late data (dh 150 > tlow)", (fun t -> { t with dh = 150 }); "thd_sta 60", (fun t -> { t with thd_sta = 60 }) ]
    ~f:(fun (n, f) ->
      printf "%s:\n" n;
      ignore (run4 ~t_ctl:f ~cycles:150_000 () : Psim.result));
  [%expect {|
    tlow 120 (< 141):
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RA1 R36 P S A51R- RFF P S A52W- WAA- P S A50R+ R0E P
      pushes: 11 22 33 44 firings [B71@641] U true mm 0
    thigh 100 (< 120):
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RA1 R36 P S A51R- RFF P S A52W- WAA- P S A50R+ R0E P
      pushes: 11 22 33 44 firings [B72@761] U true mm 0
    late data (dh 150 > tlow):
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RA1 R36 P S A51R- RFF P S A52W- WAA- P S A50R+ R0E P
      pushes: 11 22 33 44 firings [B83@671,F51@2816] U true mm 0
    thd_sta 60:
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RA1 R36 P S A51R- RFF P S A52W- WAA- P S A50R+ R0E P
      pushes: 11 22 33 44 firings [B82@461] U true mm 0
    |}]
;;

let mutate_at prog ~at ~f =
  let a = Array.of_list prog in
  match Array.findi a ~f:(fun i _ -> at a i) with
  | Some (i, x) -> a.(i) <- f x; Array.to_list a
  | None -> raise_s [%message "mutant site not found"]
;;

let%expect_test "P=4 Sm 30 MHz: firmware mutants fail (read bytes late, so the target stretches)" =
  let open Pemu_spec_v1.Isa1 in
  let nth a i = if i >= 0 && i < Array.length a then Some a.(i) else None in
  let eqi x y = match x with Some x -> [%equal: t] x y | None -> false in
  let mutants =
    [ "write ACK missing", (fun p -> mutate_at p ~at:(fun a i -> eqi (nth a i) (Out 0x04) && eqi (nth a (i + 1)) (Push Sr)) ~f:(fun _ -> Nop))
    ; "write bits LSB-first", (fun p -> mutate_at p ~at:(fun a i -> eqi (nth a i) (Pin (3, In_msb)) && eqi (nth a (i + 1)) (Wtp (2, Low))) ~f:(fun _ -> Pin (3, In_lsb)))
    ; "read bits LSB-first", (fun p -> List.map p ~f:(fun x -> if [%equal: t] x (Pin (3, Out_msb)) then Pin (3, Out_lsb) else x))
    ; "stretch in high phase", (fun p -> mutate_at p ~at:(fun a i -> eqi (nth a i) (Wtp (2, Low)) && (match nth a (i + 1) with Some (Br (5, _)) -> true | _ -> false)) ~f:(fun _ -> Wtp (2, High)))
    ; "read data changes in high phase", (fun p ->
        let a = Array.of_list p in
        (match Array.findi a ~f:(fun i _ -> eqi (nth a i) (Wtp (2, High)) && eqi (nth a (i + 1)) (Wtp (2, Low)) && eqi (nth a (i + 2)) (Pin (3, Out_msb))) with
         | Some (i, _) -> a.(i + 1) <- Pin (3, Out_msb); a.(i + 2) <- Wtp (2, Low)
         | None -> raise_s [%message "site"]);
        Array.to_list a)
    ; "ACKs address 0x51 [O]", (fun p -> List.map p ~f:(fun x -> match x with Cmp (C Sr, v) when v lsr 1 = 0x50 -> Cmp (C Sr, (0x51 lsl 1) lor (v land 1)) | x -> x))
    ]
  in
  List.iter mutants ~f:(fun (n, m) ->
    printf "%s:\n" n;
    ignore (run4 ~prog:m ~tx_times:[ 0; 60_000; 60_000; 60_000 ] ~cycles:300_000 () : Psim.result));
  [%expect {|
    write ACK missing:
      bus: S A50W+ W11- W22- W33- P S A50W+ W44- Sr A50R+ RA1 R36 P S A51R- RFF P S A52W- WAA- P S A50R+ R0E P
      pushes: 11 22 33 44 firings [F54@5046] U false mm 0
    write bits LSB-first:
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RA1 R36 P S A51R- RFF P S A52W- WAA- P S A50R+ R0E P
      pushes: 88 44 CC 22 firings [F57@4921] U false mm 0
    read bits LSB-first:
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ R85 R6C P S A51R- RFF P S A52W- WAA- P S A50R+ R70 P
      pushes: 11 22 33 44 firings [F55@60541] U false mm 0
    stretch in high phase:
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ RA1 R6D P S A51R- RFF P S A52W- WAA- P S A50R- RFF P
      pushes: 11 22 33 44 firings [F61@17596,B72@17601] U false mm 0
    read data changes in high phase:
      bus: S A50W+ W11+ W22+ W33+ P S A50W+ W44+ Sr A50R+ R43 R6C P S A51R- RFF P S A52W- WAA- P S A50R+ R1C P
      pushes: 11 22 33 44 firings [F61@60051,B82@60146,F51@60286] U false mm 0
    ACKs address 0x51 [O]:
      bus: S A50W- W11- W22- W33- P S A50W- W44- Sr A50R- RFF RFF P S A51R+ RA1 P S A52W- WAA- P S A50R- RFF P
      pushes:  firings [] U true mm 0
    |}]
;;
