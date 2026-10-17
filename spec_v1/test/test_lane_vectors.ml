(* Known-answer vectors for the ISA v1 serializer, run end to end through the lane pins of the
   reference model (the circuit is tied to the model by test_lane_diff). *)
open! Core
open Pemu_spec_v1

(* run [prog] with [bytes] fed through the host TX FIFO; return per-cycle (uio_out, uio_oe) *)
let run ~prog ~cfg ~cfg2 ~bytes ~cycles =
  let m = Lane_model.create (Isa1.assemble prog) in
  let pending = Queue.of_list bytes in
  let level = ref 0 in
  (* explicit ascending loop: List.init does not guarantee application order *)
  let acc = ref [] in
  for c = 0 to cycles - 1 do
    (* no host push during reset: the reset cycle clears the FIFOs *)
    let push = c > 0 && (not (Queue.is_empty pending)) && !level < 8 in
    let inp : Lane_model.inputs =
      { rst_sync_n = c > 0; tick = true; run = c > 0; loaded = true; len = List.length prog
      ; own = 0xFF; od = 0; cfg; cfg2; pins = 0; tx_push = push
      ; tx_wdata = (if push then Queue.peek_exn pending else 0); rx_pop = false
      ; blame_in = false; clear_fault = false }
    in
    if push then ignore (Queue.dequeue_exn pending : int);
    let o = Lane_model.step m inp in
    level := o.tx_level + (if push then 1 else 0) - (if o.pop_ev then 1 else 0);
    acc := (o.uio_out, o.uio_oe) :: !acc
  done;
  List.rev !acc
;;

let frame_prog n =
  Isa1.
    [ Ldi (L Lc, n); Ldi (L R1, 1); Ser (Period R1); Ser Crci; Pop R0; Ser (Sendc R0); Djnz 4
    ; Ser Crcs; Ser Idle; Jmp 8 ]
;;

let reflect v w = List.fold (List.init w ~f:Fn.id) ~init:0 ~f:(fun a k -> a lor (((v lsr k) land 1) lsl (w - 1 - k)))

let%expect_test "CRC-16/USB and CRC-5/USB check values over \"123456789\"" =
  let bytes = String.to_list "123456789" |> List.map ~f:Char.to_int in
  List.iter [ "crc16", 0x60, 16; "crc5", 0x20, 5 ] ~f:(fun (name, cfg, w) ->
    let tr = run ~prog:(frame_prog 9) ~cfg ~cfg2:0 ~bytes ~cycles:400 in
    let bits = List.filter_map tr ~f:(fun (o, oe) -> if oe land 1 = 1 then Some (o land 1) else None) in
    let data = List.take bits 72 and crc = List.drop bits 72 in
    let bytes_back =
      List.chunks_of data ~length:8
      |> List.map ~f:(fun l -> List.foldi l ~init:0 ~f:(fun k a b -> a lor (b lsl k)))
    in
    (* CRC sent MSb first; value as received LSb first = reflection *)
    let crc_msb_first = List.fold crc ~init:0 ~f:(fun a b -> (a lsl 1) lor b) in
    printf "%s: nbits %d data_ok %b crc_received 0x%X\n" name (List.length bits)
      (List.equal Int.equal bytes_back bytes) (reflect crc_msb_first w));
  [%expect {|
    crc16: nbits 88 data_ok true crc_received 0xB4C8
    crc5: nbits 77 data_ok true crc_received 0x19
    |}]
;;

let%expect_test "USB low-speed pair: SYNC, stuffing on 0xFF, EOP" =
  (* pair mode, NRZI, stuffing; D+ = pin 0, D- = pin 1; low-speed J = D- high *)
  let prog = Isa1.[ Ldi (L Lc, 2); Ldi (L R1, 1); Ser (Period R1); Pop R0; Ser (Send R0); Djnz 3; Ser Eop; Ser Idle; Jmp 7 ] in
  let tr = run ~prog ~cfg:0x1A ~cfg2:0x00 ~bytes:[ 0x80; 0xFF ] ~cycles:40 in
  let sym =
    List.filter_map tr ~f:(fun (o, oe) ->
      if oe land 3 = 3
      then Some (match o land 3 with 0b10 -> "J" | 0b01 -> "K" | 0b00 -> "0" | _ -> "1")
      else None)
  in
  print_endline (String.concat sym);
  [%expect {| KJKJKJKKKKKKKJJJJ00J |}]
;;
