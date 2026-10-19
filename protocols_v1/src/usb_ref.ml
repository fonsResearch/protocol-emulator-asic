(* USB low-speed TX reference encoder (doc/protocols/usb_ls_v1.md), written from the protocol
   document and USB 2.0, independently of the lane's serializer (spec_v1). One element per bit
   time (= one lane step at P = 39, bit_period = 1). Used for the contract tests, as the
   oracle in co-simulation, and as the source of the proof-side encoder (G7).
   Coding order (USB 2.0): CRC16 over the payload bits, then bit stuffing over SYNC .. CRC,
   then NRZI starting from J. *)
open! Core

type state =
  | J
  | K
  | SE0
[@@deriving sexp, equal]

let show l =
  String.of_list (List.map l ~f:(function J -> 'J' | K -> 'K' | SE0 -> '0'))
;;

(* (dp, dm) for D+ = uio0, D- = uio1; low speed: J = D+ low, D- high *)
let pins = function
  | J -> 0b10
  | K -> 0b01
  | SE0 -> 0b00
;;

let bits_lsb b = List.init 8 ~f:(fun i -> (b lsr i) land 1 = 1)

(* CRC-16/USB over bits in transmission order: x^16 + x^15 + x^2 + 1, initial all ones;
   returns the ones complement in transmission order (16 bits). Reflected form: shift right,
   feedback polynomial 0xA001. *)
let crc16_bits data_bits =
  let crc =
    List.fold data_bits ~init:0xFFFF ~f:(fun crc b ->
      let fb = (crc land 1) lxor Bool.to_int b in
      (crc lsr 1) lxor if fb = 1 then 0xA001 else 0)
  in
  let r = crc lxor 0xFFFF in
  List.init 16 ~f:(fun i -> (r lsr i) land 1 = 1)
;;

let crc16 bytes =
  let b = crc16_bits (List.concat_map bytes ~f:bits_lsb) in
  List.foldi b ~init:0 ~f:(fun i acc x -> if x then acc lor (1 lsl i) else acc)
;;

(* stuffing + NRZI from a starting state and a ones count; returns states and the final state *)
let code ~start ~ones bits =
  let st = ref start
  and n = ref ones
  and out = Queue.create () in
  let emit b =
    if not b then st := (match !st with J -> K | K -> J | SE0 -> J);
    Queue.enqueue out !st
  in
  List.iter bits ~f:(fun b ->
    emit b;
    if b then incr n else n := 0;
    if !n = 6 then (
      emit false;
      n := 0));
  Queue.to_list out, !st, !n
;;

let sync_bits = bits_lsb 0x80

(* line states of one packet: SYNC, PID, payload, CRC16, EOP (SE0 SE0 J).
   [abort_before k]: the TX FIFO runs empty before payload byte k: the bits of PID and bytes
   0..k-1 are sent (with a pending stuffed bit), then J for [abort_j] steps (>= 8), then EOP.
   Returns the states and, for an abort, the index of the first abort J step (where the
   firmware pushes status 2). *)
let packet ?abort_before ?(abort_j = 8) ~pid payload =
  let payload_bits = List.concat_map payload ~f:bits_lsb in
  match abort_before with
  | None ->
    let bits = sync_bits @ bits_lsb pid @ payload_bits @ crc16_bits payload_bits in
    let s, _, _ = code ~start:J ~ones:0 bits in
    s @ [ SE0; SE0; J ], None
  | Some k ->
    let sent = List.concat_map (List.take payload k) ~f:bits_lsb in
    let s, _, _ = code ~start:J ~ones:0 (sync_bits @ bits_lsb pid @ sent) in
    s @ List.init abort_j ~f:(fun _ -> J) @ [ SE0; SE0; J ], Some (List.length s)
;;

(* NRZI decode + unstuffing of the states between SYNC start and EOP (for tests and
   co-simulation): returns the data bits after SYNC, or Error on a stuffing violation *)
let decode states =
  let rec go prev ones acc = function
    | [] | SE0 :: _ -> Ok (List.rev acc)
    | s :: rest ->
      let b = equal_state s prev in
      if ones = 6
      then if b then Error "bit-stuff error" else go s 0 acc rest
      else go s (if b then ones + 1 else 0) (b :: acc) rest
  in
  go J 0 [] states
;;
