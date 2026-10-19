(* USB-LS TX contract (Library_v1.usb_ls_tx) on reference waveforms from Usb_ref, before any
   firmware exists: well-formed packets and aborts must not fire; each hand-made violation must
   fire the intended check. One cycle = one step (tick every cycle). *)
open! Core
open Pemu_protocols_v1
module Interp = Pemu_monitor_v1.Interp
module Lib = Pemu_monitor_v1.Library_v1
open Usb_ref

type step =
  { st : state option (* None = both pins released *)
  ; push : bool
  ; oe : int
  ; raw : int option (* overrides the outputs (SE1) *)
  }

let line ?(oe = 0b11) s = { st = Some s; push = false; oe; raw = None }
let idle n = List.init n ~f:(fun _ -> line J)

(* idle, packet, status push [push_after] steps after the EOP's J (normal) or at the abort's
   first J step, idle *)
let scenario ?abort_before ?(push_after = 1) ~pid payload =
  let states, abort_at = packet ?abort_before ~pid payload in
  let body = List.mapi states ~f:(fun i s -> { (line s) with push = Option.equal Int.equal abort_at (Some i) }) in
  let tail = idle 20 in
  let tail =
    if Option.is_none abort_at
    then List.mapi tail ~f:(fun i x -> if i = push_after - 1 then { x with push = true } else x)
    else tail
  in
  idle 5 @ body @ tail
;;

let run steps =
  let mon = Interp.create (Lib.usb_ls_tx ()) in
  let fired = ref [] in
  List.iteri ({ st = None; push = false; oe = 0; raw = None } :: steps) ~f:(fun c x ->
    let uio_out = match x.raw, x.st with Some r, _ -> r | None, Some s -> pins s | None, None -> 0 in
    let f =
      Interp.step mon
        { rst_sync_n = c > 0; running = c > 0; tick = true; ui_in = 0; uio_in = 0; uo_out = 0; uio_out
        ; uio_oe = x.oe; pop_ev = false; pop_data = 0; push_ev = x.push; push_data = 0 }
    in
    List.iter f ~f:(fun (r, code) ->
      fired := sprintf "%s%02X@%d" (match r with Pemu_monitor_v1.Lang.Fail -> "F" | Blame -> "B") code c :: !fired));
  match List.rev !fired with [] -> "ok" | l -> String.concat ~sep:"," l
;;

let%expect_test "reference encoder: CRC-16/USB check value and SYNC" =
  printf "crc16(\"123456789\") = 0x%04X\n" (crc16 (List.map (String.to_list "123456789") ~f:Char.to_int));
  printf "DATA0 empty: %s\n" (show (fst (packet ~pid:0xC3 [])));
  printf "DATA1 0xFF 0xFF: %s\n" (show (fst (packet ~pid:0x4B [ 0xFF; 0xFF ])));
  [%expect {|
    crc16("123456789") = 0xB4C8
    DATA0 empty: KJKJKJKKKKJKJKKKJKJKJKJKJKJKJKJK00J
    DATA1 0xFF 0xFF: KJKJKJKKKKJJKJJKKKKKKKJJJJJJJKKKKKKKJJJJJJJKKKKKKKJJJ00J
    |}]
;;

let%expect_test "well-formed packets and aborts do not fire" =
  let rng = Random.State.make [| 3 |] in
  for n = 0 to 8 do
    let p = List.init n ~f:(fun _ -> Random.State.int rng 256) in
    printf "N=%d random: %s | all 0xFF: %s | DATA1: %s\n" n (run (scenario ~pid:0xC3 p))
      (run (scenario ~pid:0xC3 (List.init n ~f:(fun _ -> 0xFF))))
      (run (scenario ~push_after:8 ~pid:0x4B p))
  done;
  for k = 0 to 7 do
    printf "abort before byte %d: %s\n" k
      (run (scenario ~abort_before:k ~pid:0xC3 (List.init 8 ~f:(fun i -> 0xF0 lor i))))
  done;
  [%expect {|
    N=0 random: ok | all 0xFF: ok | DATA1: ok
    N=1 random: ok | all 0xFF: ok | DATA1: ok
    N=2 random: ok | all 0xFF: ok | DATA1: ok
    N=3 random: ok | all 0xFF: ok | DATA1: ok
    N=4 random: ok | all 0xFF: ok | DATA1: ok
    N=5 random: ok | all 0xFF: ok | DATA1: ok
    N=6 random: ok | all 0xFF: ok | DATA1: ok
    N=7 random: ok | all 0xFF: ok | DATA1: ok
    N=8 random: ok | all 0xFF: ok | DATA1: ok
    abort before byte 0: ok
    abort before byte 1: ok
    abort before byte 2: ok
    abort before byte 3: ok
    abort before byte 4: ok
    abort before byte 5: ok
    abort before byte 6: ok
    abort before byte 7: ok
    |}]
;;

let%expect_test "violations fire the intended check" =
  let base = scenario ~pid:0xC3 [ 0x12; 0xFF; 0x00 ] in
  let start = 5 in
  let set i f l = List.mapi l ~f:(fun j x -> if j = i then f x else x) in
  let states, _ = packet ~pid:0xC3 [ 0x12; 0xFF; 0x00 ] in
  let eop = start + List.length states - 3 in
  let cases =
    [ "SYNC: 8th state J instead of K", set (start + 7) (fun x -> { x with st = Some J }) base
    ; "stuffed bit missing (encoder without stuffing)",
      (let bits = sync_bits @ bits_lsb 0xC3 @ List.concat_map [ 0xFF; 0xFF ] ~f:bits_lsb in
       let st = ref J in
       let s = List.map bits ~f:(fun b -> if not b then st := (match !st with J -> K | _ -> J); !st) in
       idle 5 @ List.map (s @ [ SE0; SE0; J ]) ~f:line @ [ { (line J) with push = true } ] @ idle 10)
    ; "EOP: one SE0 step", set (eop + 1) (fun x -> { x with st = Some J }) base
    ; "EOP: three SE0 steps", set (eop + 2) (fun x -> { x with st = Some SE0 }) base
    ; "SE1 inside the packet", set (start + 12) (fun x -> { x with raw = Some 0b11 }) base
    ; "D- not driven for one step", set (start + 12) (fun x -> { x with oe = 0b01 }) base
    ; "no status push", List.map base ~f:(fun x -> { x with push = false })
    ; "push inside the packet, line continues", set (start + 12) (fun x -> { x with push = true }) base
    ; ( "abort with a J run of 6 steps"
      , let s, a = packet ~abort_before:1 ~abort_j:6 ~pid:0xC3 [ 0x12; 0x34 ] in
        idle 5 @ List.mapi s ~f:(fun i st -> { (line st) with push = Option.equal Int.equal a (Some i) }) @ idle 10 )
    ; "gap of 9 J steps mid-packet, no push",
      (let s, _ = packet ~pid:0xC3 [ 0x00; 0x00 ] in
       let s = List.take s 20 @ List.init 9 ~f:(fun _ -> J) @ List.drop s 20 in
       idle 5 @ List.map s ~f:line @ [ { (line J) with push = true } ] @ idle 10)
    ; "payload of 12 bytes (data phase too long)", scenario ~pid:0xC3 (List.init 12 ~f:(fun _ -> 0xFF))
    ]
  in
  List.iter cases ~f:(fun (name, steps) -> printf "%-46s %s\n" name (run steps));
  [%expect {|
    SYNC: 8th state J instead of K                 FA3@13
    stuffed bit missing (encoder without stuffing) FB1@26
    EOP: one SE0 step                              FA5@64
    EOP: three SE0 steps                           FA2@65
    SE1 inside the packet                          FD1@18
    D- not driven for one step                     F91@18
    no status push                                 FC2@73
    push inside the packet, line continues         FB2@20
    abort with a J run of 6 steps                  FB2@36
    gap of 9 J steps mid-packet, no push           FB1@33
    payload of 12 bytes (data phase too long)      FA4@116
    |}]
;;

let%expect_test "start-up convention: reset outputs, then J undriven, then driven" =
  let released = { st = None; push = false; oe = 0; raw = None } in
  let j_undriven = { (line J) with oe = 0 } in
  let pkt = scenario ~pid:0xC3 [ 0x5A ] in
  printf "start-up ok:              %s\n" (run (released :: j_undriven :: pkt));
  printf "third step still undriven: %s\n" (run (released :: j_undriven :: j_undriven :: pkt));
  [%expect {|
    start-up ok:              ok
    third step still undriven: F91@3
    |}]
;;

(* ---- co-simulation: lane model running Programs_v1.usb_ls_tx (P = 39), monitor, host ---- *)
module P1 = Pemu_spec_v1.Programs_v1

let setup =
  { Psim.prog = P1.usb_ls_tx; own = P1.usb_own; od = 0; cfg = P1.usb_cfg; cfg2 = 0; p = 39
  ; contract = Lib.usb_ls_tx (); open_drain_wired_and = 0 }
;;

(* run-length decode of the driven line per cycle into bit-time states; checks that every run is
   a whole number of 40-cycle bits *)
let line_of (r : Psim.result) =
  let st (o, oe) =
    if oe land 3 <> 3 then None
    else match o land 3 with 0b10 -> Some J | 0b01 -> Some K | 0b00 -> Some SE0 | _ -> Some SE0
  in
  let runs = ref [] in
  Array.iter r.outs ~f:(fun x ->
    let s = st x in
    match !runs with
    | (s', n) :: rest when Option.equal equal_state s s' -> runs := (s', n + 1) :: rest
    | _ -> runs := (s, 1) :: !runs);
  let runs = List.rev !runs in
  let bad = List.filter (List.drop (List.drop_last_exn runs) 2) ~f:(fun (_, n) -> n mod 40 <> 0) in
  runs, bad
;;

(* packets = maximal stretches from a K that follows idle J to the J after SE0 SE0 *)
let packets runs =
  let bits = List.concat_map runs ~f:(fun (s, n) -> match s with Some s -> List.init (n / 40) ~f:(fun _ -> s) | None -> []) in
  let rec go acc cur = function
    | [] -> List.rev acc
    | SE0 :: SE0 :: J :: rest -> go (List.rev (J :: SE0 :: SE0 :: cur) :: acc) [] rest
    | J :: rest when List.is_empty cur -> go acc [] rest
    | s :: rest -> go acc (s :: cur) rest
  in
  go [] [] bits
;;

let cosim ?tx_times ~cycles host expected =
  let r = Psim.run ~tx_bytes:host ?tx_times ~setup ~cycles ~peer:(fun _ -> { Psim.drive_oe = 0; drive_val = 0 }) () in
  let runs, bad = line_of r in
  let got = packets runs in
  printf "  firings [%s] model_mismatch %d status %s; non-integral runs %d\n" (Psim.show_firings r) r.model_mismatch
    (String.concat ~sep:" " (List.map (Psim.pushes r) ~f:(sprintf "%d"))) (List.length bad);
  List.iteri got ~f:(fun i p ->
    let ok = match List.nth expected i with Some e -> List.equal equal_state e p | None -> false in
    printf "  packet %d: %d bits, equals reference %b%s\n" i (List.length p) ok
      (match List.nth expected i with Some e when not ok -> "\n    got " ^ show p ^ "\n    ref " ^ show e | _ -> ""));
  if List.length got <> List.length expected then printf "  packets: got %d, expected %d\n" (List.length got) (List.length expected)
;;

let%expect_test "co-simulation: packets equal the reference encoder" =
  let pk pid pl = fst (packet ~pid pl) in
  let ps = [ 0xC3, []; 0x4B, [ 0x01; 0x02; 0x03 ]; 0xC3, List.init 8 ~f:(fun i -> (37 * i) land 0xFF); 0x4B, List.init 8 ~f:(fun _ -> 0xFF) ] in
  let host = List.concat_map ps ~f:(fun (pid, pl) -> pid :: List.length pl :: pl) in
  cosim ~cycles:40_000 host (List.map ps ~f:(fun (p, l) -> pk p l));
  [%expect {|
    firings [] model_mismatch 0 status 0 0 0 0; non-integral runs 0
    packet 0: 35 bits, equals reference true
    packet 1: 59 bits, equals reference true
    packet 2: 99 bits, equals reference true
    packet 3: 110 bits, equals reference true
    |}]
;;

let%expect_test "co-simulation: TX underrun aborts with status 2, then the next packet is sent" =
  (* header and 2 payload bytes at once; bytes 3.. and the next packet only much later *)
  let host = [ 0xC3; 4; 0x11; 0x22; 0x33; 0x44; 0x4B; 1; 0x55 ] in
  let tx_times = [ 0; 0; 0; 0; 20_000; 20_000; 20_000; 20_000; 20_000 ] in
  cosim ~tx_times ~cycles:40_000 host [ fst (packet ~abort_before:2 ~abort_j:9 ~pid:0xC3 [ 0x11; 0x22; 0x33; 0x44 ]); fst (packet ~pid:0x4B [ 0x55 ]) ];
  [%expect {|
    firings [] model_mismatch 0 status 2 0; non-integral runs 0
    packet 0: 44 bits, equals reference true
    packet 1: 43 bits, equals reference true
    |}]
;;

let%expect_test "co-simulation: N > 8 pushes status 1 and halts" =
  cosim ~cycles:10_000 [ 0xC3; 9; 1; 2; 3 ] [];
  [%expect {| firings [] model_mismatch 0 status 1; non-integral runs 0 |}]
;;
