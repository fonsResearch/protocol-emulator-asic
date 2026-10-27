(* C3 differential check, part 2 (log/proofs_v2.md section 7.2): host clear_fault after a blame,
   and randomised environments, v2 top RTL against Psim (harness in Test_c3_diff).

   Clear window (C3 analysis, section 7): unit j's blame of step t is recorded on the chip at t + j
   and reaches the lane at t + j + 1; in the A2 harness composition (Psim) it reaches the lane at
   t + 1. With release-on-blame set, a host clear_fault in cycle t + d with 1 <= d <= j clears the
   harness lane's pending blame but comes before the chip's, so the chip lane faults at its next
   step and the harness lane does not. For d = j + 1 the clear wins over the blame arriving in the
   same cycle (ISA v1 clarification), so both clear. The sweep checks that divergence happens
   exactly for 1 <= d <= j. The random part checks the necessary condition: every divergence
   starts after a clear that landed 1 .. slots - 1 cycles after some blame step. *)
open! Core
open Pemu_spec_v1
open Pemu_monitor_v1
module D = Test_c3_diff
module Psim = Pemu_protocols_v1.Psim
module Peers = Pemu_protocols_v1.Peers
module P1 = Programs_v1
module Lib = Library_v1

let slots = 5

type cmp =
  { mon_first : int option (* first cycle where the lane-0 monitor-input streams differ *)
  ; mon_fields : string list (* fields that differ there *)
  ; pins_first : int option
  ; verdict_eq : bool
  ; rx_eq : bool
  }

(* latency from the start of a CTRL write transaction to the clear_fault pulse, in cycles *)
let clear_latency ~k =
  let setup = D.rx_setup () in
  let c =
    D.chip_run ~ctrl_writes:[ 1000, 0x21 ] ~k ~setup ~pkg:1 ~tx_bytes:[] ~peer:D.no_peer
      ~cycles:3000 ()
  in
  match c.clears with
  | [ t ] -> t - 1000
  | l -> raise_s [%message "clear_latency: expected one pulse" (l : int list)]
;;

let compare_runs ~(setup : Psim.setup) ~cycles (c : D.chip_result) (r : Psim.result) pmi =
  let diff_fields (a : Interp.inputs) (b : Interp.inputs) =
    List.filter_map
      [ "running", Bool.equal a.running b.running; "tick", Bool.equal a.tick b.tick
      ; "uio_in", a.uio_in = b.uio_in; "uio_out", a.uio_out = b.uio_out; "uio_oe", a.uio_oe = b.uio_oe
      ; sprintf "pop(%b/%b)" a.pop_ev b.pop_ev, Bool.equal a.pop_ev b.pop_ev && ((not a.pop_ev) || a.pop_data = b.pop_data)
      ; sprintf "push(%b/%b)" a.push_ev b.push_ev, Bool.equal a.push_ev b.push_ev && ((not a.push_ev) || a.push_data = b.push_data) ]
      ~f:(fun (n, ok) -> if ok then None else Some n)
  in
  let fields a b = List.is_empty (diff_fields a b) in
  let mon_first =
    List.find (List.init cycles ~f:Fn.id) ~f:(fun cy ->
      match pmi.(cy), Hashtbl.find c.mon (cy + c.off) with
      | Some a, Some b -> not (fields a b)
      | _ -> false)
  in
  let pm, pf = D.pin_mismatches ~own:setup.own c r ~from:0 ~upto:cycles in
  let verdict_eq =
    [%equal: (int * int) option] (D.psim_first r Fail) c.first_fail
    && [%equal: (int * int) option] (D.psim_first r Blame) c.first_blame
  in
  (* pushes inside the compared window (the chip keeps running during the readback afterwards,
     so its FIFO may hold later bytes; the FIFO is checked only for consistency) *)
  let win =
    List.filter_map (List.init cycles ~f:Fn.id) ~f:(fun cy ->
      match Hashtbl.find c.mon (cy + c.off) with
      | Some b when b.push_ev -> Some b.push_data
      | _ -> None)
  in
  let fifo_ok = List.is_prefix c.rx ~prefix:(List.take win 8) ~equal:Int.equal in
  if not fifo_ok then printf "    FIFO readback inconsistent with the recorded pushes\n";
  let rx_eq = [%equal: int list] (Psim.pushes r) win in
  let mon_fields =
    match mon_first with
    | None -> []
    | Some cy -> diff_fields (Option.value_exn pmi.(cy)) (Hashtbl.find_exn c.mon (cy + c.off))
  in
  { mon_first; mon_fields; pins_first = (if pm = 0 then None else pf); verdict_eq; rx_eq }
;;

let psim_run ~clear_at ~setup ~tx_bytes ~peer ~cycles =
  let pmi = Array.create ~len:cycles None in
  let on_cycle cy mi _ = pmi.(cy) <- Some mi in
  let r = Psim.run ~on_cycle ~clear_at ~tx_bytes ~rx_pop_every:1_000_000_000 ~setup ~cycles ~peer:(peer ()) () in
  r, pmi
;;

(* one scenario with an optional clear landing at Psim time [clear] *)
let scenario ~k ~lat ?clear ~setup ~pkg ~tx_bytes ~peer ~cycles () =
  let ctrl_writes = match clear with None -> [] | Some t -> [ t - lat, 0x21 ] in
  let c = D.chip_run ~ctrl_writes ~k ~setup ~pkg ~tx_bytes ~peer:(peer ()) ~cycles () in
  let r, pmi = psim_run ~clear_at:c.clears ~setup ~tx_bytes ~peer ~cycles in
  (match clear with
   | Some t when not ([%equal: int list] c.clears [ t ]) ->
     raise_s [%message "clear pulse misplaced" (t : int) (c.clears : int list)]
   | _ -> ());
  c, r, compare_runs ~setup ~cycles c r pmi
;;

let diverged x = Option.is_some x.mon_first || Option.is_some x.pins_first || not (x.verdict_eq && x.rx_eq)
let show_o = function None -> "=" | Some cy -> sprintf "@%d" cy

let blame_steps (r : Psim.result) =
  List.filter_map (Psim.firings r) ~f:(fun (cy, ro, _) -> if Lang.equal_role ro Blame then Some cy else None)
;;

let frames ?(bytes = [ 0x55; 0xA5; 0x00; 0xFF; 0x3C; 0x81; 0x7E; 0x01 ]) bp =
  Peers.frames_of ~bp ~st0:2000 bytes ~gap:(fun b -> 3 + (b * 7 % 400))
;;

let sweep ~k ~lat ~name ~setup ~pkg ~tx_bytes ~peer ~cycles =
  let c, r, x = scenario ~k ~lat ~setup ~pkg ~tx_bytes ~peer ~cycles () in
  let t = match D.psim_first r Blame with Some (_, t) -> t | None -> failwith "no blame" in
  let j = (c.first_units lsr 4) land 7 in
  printf "%s: no clear: diverged %b; first blame %s, unit j = %d\n" name (diverged x)
    (D.show_opt (D.psim_first r Blame)) j;
  let bad = ref 0 in
  List.iter [ -40; 0; 1; 2; 3; 4; 5; 6; 10; 40; 70; 200 ] ~f:(fun d ->
    let _, _, x = scenario ~k ~lat ~clear:(t + d) ~setup ~pkg ~tx_bytes ~peer ~cycles () in
    let predicted = d >= 1 && d <= j in
    if Bool.( <> ) predicted (diverged x) then incr bad;
    printf "  d %4d: mon-in %-7s pins %-7s verdict %s rx %s | predicted %-8s observed %s\n" d (show_o x.mon_first)
      (show_o x.pins_first) (if x.verdict_eq then "=" else "DIFF") (if x.rx_eq then "=" else "DIFF")
      (if predicted then "diverge" else "equal") (if diverged x then "diverge" else "equal"));
  printf "  prediction mismatches: %d\n" !bad
;;

let%expect_test "C3: host clear_fault around a blame (release on blame set)" =
  let k = List.hd_exn (D.calibrate ()) in
  let lat = clear_latency ~k in
  printf "clear latency %d cycles\n" lat;
  let peer () =
    let bp = D.uart_bp /. 1.08 in
    Peers.sender ~pin:1 ~bp ~frames:(frames bp) ~defect:No_defect
  in
  sweep ~k ~lat ~name:"uart_rx 8% fast" ~setup:{ (D.rx_setup ()) with cfg = 1 } ~pkg:1 ~tx_bytes:[] ~peer
    ~cycles:30_000;
  let peer () =
    (Peers.spi_target ~cpol:false ~cpha:false ~tco:3 ~send:D.peer_bytes ~miso_glitch:(3, 4) ~glitch_len:10 ()).drive
  in
  sweep ~k ~lat ~name:"spi_ctl MISO hold glitch (frame 3, bit 4)"
    ~setup:{ D.ctl_setup with cfg = D.ctl_setup.cfg lor 1 } ~pkg:2 ~tx_bytes:D.host_bytes ~peer ~cycles:6000;
  [%expect {|
    clear latency 194 cycles
    uart_rx 8% fast: no clear: diverged false; first blame 32@4421, unit j = 0
      d  -40: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    0: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    1: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    2: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    3: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    4: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    5: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    6: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d   10: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d   40: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d   70: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d  200: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      prediction mismatches: 0
    spi_ctl MISO hold glitch (frame 3, bit 4): no clear: diverged false; first blame 91@1145, unit j = 4
      d  -40: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    0: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    1: mon-in @1154   pins @1154   verdict = rx DIFF | predicted diverge  observed diverge
      d    2: mon-in @1154   pins @1154   verdict = rx DIFF | predicted diverge  observed diverge
      d    3: mon-in @1154   pins @1154   verdict = rx DIFF | predicted diverge  observed diverge
      d    4: mon-in @1154   pins @1154   verdict = rx DIFF | predicted diverge  observed diverge
      d    5: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d    6: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d   10: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d   40: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d   70: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      d  200: mon-in =       pins =       verdict = rx = | predicted equal    observed equal
      prediction mismatches: 0
    |}]
;;

let%expect_test "C3: randomised environments with one host clear each" =
  let k = List.hd_exn (D.calibrate ()) in
  let lat = clear_latency ~k in
  let rs = Random.State.make [| 2026; 10; 27 |] in
  let ri lo hi = lo + Random.State.int rs (hi - lo + 1) in
  let n = ref 0 and div = ref 0 and unexplained = ref 0 and blamed = ref 0 in
  let check ~name ~setup ~pkg ~tx_bytes ~peer ~cycles =
    (* clear placed near a blame of a no-clear run half of the time, elsewhere otherwise *)
    let r0, _ = psim_run ~clear_at:[] ~setup ~tx_bytes ~peer ~cycles in
    let bs = blame_steps r0 in
    let clear =
      match bs with
      | b :: _ when Random.State.bool rs && b > lat + 20 -> b + ri 0 (slots + 1)
      | _ -> ri (lat + 20) (cycles - 500)
    in
    let c, r, x = scenario ~k ~lat ~clear ~setup ~pkg ~tx_bytes ~peer ~cycles () in
    if not x.rx_eq
    then printf "    rx psim [%s] (%d pushes) chip [%s]\n"
           (String.concat ~sep:" " (List.map (List.take (Psim.pushes r) 10) ~f:(sprintf "%02X")))
           (List.length (Psim.pushes r)) (String.concat ~sep:" " (List.map c.rx ~f:(sprintf "%02X")));
    incr n;
    if not (List.is_empty bs) then incr blamed;
    let d = diverged x in
    let in_window = List.exists (blame_steps r) ~f:(fun b -> clear - b >= 1 && clear - b <= slots - 1) in
    if d then incr div;
    if d && not in_window then incr unexplained;
    printf "%-44s clear %5d %s | mon-in %-7s pins %-7s verdict %s rx %s%s\n" name clear
      (if in_window then "in-window " else "          ") (show_o x.mon_first) (show_o x.pins_first)
      (if x.verdict_eq then "=" else "DIFF") (if x.rx_eq then "=" else "DIFF")
      (if d && not in_window then "  UNEXPLAINED" else "");
    if d && not in_window
    then (
      let _, _, x0 = scenario ~k ~lat ~setup ~pkg ~tx_bytes ~peer ~cycles () in
      printf "    first diff fields [%s]; without the clear: mon-in %s [%s] pins %s\n"
        (String.concat ~sep:"," x.mon_fields) (show_o x0.mon_first) (String.concat ~sep:"," x0.mon_fields)
        (show_o x0.pins_first))
  in
  for i = 1 to 6 do
    let f = 0.90 +. (0.20 *. Random.State.float rs 1.0) in
    let defect =
      match ri 0 2 with
      | 0 -> Peers.No_defect
      | 1 -> Glitch (ri 0 7, ri 0 2000, ri 5 120)
      | _ -> Short_stop (ri 0 7)
    in
    let bytes = List.init 8 ~f:(fun _ -> ri 0 255) in
    let cfg = ri 0 1 in
    let setup = { (D.rx_setup ()) with cfg } in
    let peer () = let bp = D.uart_bp /. f in Peers.sender ~pin:1 ~bp ~frames:(frames ~bytes bp) ~defect in
    check ~name:(sprintf "uart_rx %d: rate x%.3f rob %d %s" i f cfg
                   (match defect with No_defect -> "ok" | Glitch _ -> "glitch" | Short_stop _ -> "short-stop"))
      ~setup ~pkg:1 ~tx_bytes:[] ~peer ~cycles:30_000
  done;
  for i = 1 to 6 do
    let hp = ri 24 64 in
    let defect =
      match ri 0 4 with
      | 0 -> Peers.Ctl_ok
      | 1 -> Early_rise (ri 0 7, ri 2 14)
      | 2 -> Mosi_at_sample (ri 0 7, ri 0 7)
      | 3 -> Bad_idle (ri 0 7)
      | _ -> Fast_pair (ri 0 7, ri 0 14)
    in
    let cfg = ri 0 1 in
    let setup = { D.tgt_setup with cfg } in
    let gap = ri 100 300 in
    let mk () =
      Peers.spi_controller ~cpol:false ~cpha:false ~hp ~setup:hp ~hold:hp ~gap ~mdly:2 ~t0:300
        ~bytes:D.peer_bytes ~defect ()
    in
    let p0 = mk () in
    let cycles = p0.frames_end + 200 in
    check ~name:(sprintf "spi_tgt %d: hp %d rob %d %s" i hp cfg
                   (match defect with Ctl_ok -> "ok" | Early_rise _ -> "early-rise" | Mosi_at_sample _ -> "mosi-at-sample"
                                      | Bad_idle _ -> "bad-idle" | Fast_pair _ -> "fast-pair"))
      ~setup ~pkg:3 ~tx_bytes:D.host_bytes ~peer:(fun () -> (mk ()).cdrive) ~cycles
  done;
  for i = 1 to 4 do
    let tco = ri 0 20 in
    check ~name:(sprintf "spi_ctl %d: tco %d" i tco) ~setup:D.ctl_setup ~pkg:2 ~tx_bytes:D.host_bytes
      ~peer:(fun () -> (Peers.spi_target ~cpol:false ~cpha:false ~tco ~send:D.peer_bytes ()).drive) ~cycles:6000
  done;
  printf "cases %d, with a blame %d, diverged %d, unexplained %d\n" !n !blamed !div !unexplained;
  [%expect {|
    uart_rx 1: rate x1.075 rob 1 short-stop      clear  4945 in-window  | mon-in =       pins =       verdict = rx =
    uart_rx 2: rate x1.068 rob 1 short-stop      clear  8709            | mon-in =       pins =       verdict = rx =
    uart_rx 3: rate x0.962 rob 1 ok              clear  5435            | mon-in =       pins =       verdict = rx =
    uart_rx 4: rate x1.024 rob 1 short-stop      clear 17294 in-window  | mon-in =       pins =       verdict = rx =
    uart_rx 5: rate x1.027 rob 0 short-stop      clear  6826            | mon-in =       pins =       verdict = rx =
    uart_rx 6: rate x1.011 rob 1 short-stop      clear 22886            | mon-in =       pins =       verdict = rx =
    spi_tgt 1: hp 57 rob 0 fast-pair             clear  1012            | mon-in =       pins =       verdict = rx =
    spi_tgt 2: hp 56 rob 1 ok                    clear  1343            | mon-in =       pins =       verdict = rx =
    spi_tgt 3: hp 35 rob 0 bad-idle              clear  3411            | mon-in =       pins =       verdict = rx =
    spi_tgt 4: hp 40 rob 1 ok                    clear   599            | mon-in =       pins =       verdict = rx =
    spi_tgt 5: hp 34 rob 1 early-rise            clear   489            | mon-in =       pins =       verdict = rx =
    spi_tgt 6: hp 44 rob 1 bad-idle              clear  6277 in-window  | mon-in =       pins =       verdict = rx =
    spi_ctl 1: tco 0                             clear  1772            | mon-in =       pins =       verdict = rx =
    spi_ctl 2: tco 9                             clear  2496            | mon-in =       pins =       verdict = rx =
    spi_ctl 3: tco 16                            clear   922            | mon-in =       pins =       verdict = rx =
    spi_ctl 4: tco 5                             clear  4813            | mon-in =       pins =       verdict = rx =
    cases 16, with a blame 11, diverged 0, unexplained 0
    |}]
;;
