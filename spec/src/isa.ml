(* ISA v0.1 encoding (doc/isa/isa_v0.md section 4). *)
open! Core

let imem_depth = 64
let pc_width = 6

type t =
  | Jmp of int (* target 0..63 *)
  | Out of int (* value 0..255 *)
  | Outb of int (* pin 0..7 *)
  | Ldi of int
  | In
  | Wait of int (* k 0..4095, takes k+1 cycles *)
  | Ldc of int
  | Djnz of int (* target 0..63 *)
  | Reserved of int (* opcode 8..15, behaves as a 1-cycle NOP *)
[@@deriving sexp_of, equal]

let check name v lo hi =
  if v < lo || v > hi
  then raise_s [%message "Isa operand out of range" name (v : int) (lo : int) (hi : int)]
;;

(* Encoding always emits 0 in "must be 0" bits (section 4). *)
let encode = function
  | Jmp t ->
    check "Jmp" t 0 63;
    t
  | Out v ->
    check "Out" v 0 255;
    0x1000 lor v
  | Outb p ->
    check "Outb" p 0 7;
    0x2000 lor p
  | Ldi v ->
    check "Ldi" v 0 255;
    0x3000 lor v
  | In -> 0x4000
  | Wait k ->
    check "Wait" k 0 4095;
    0x5000 lor k
  | Ldc v ->
    check "Ldc" v 0 255;
    0x6000 lor v
  | Djnz t ->
    check "Djnz" t 0 63;
    0x7000 lor t
  | Reserved op ->
    check "Reserved" op 8 15;
    op lsl 12
;;

(* Decoding ignores "must be 0" bits, as the machine does. *)
let decode w =
  let op = (w lsr 12) land 0xf
  and arg = w land 0xfff in
  match op with
  | 0x0 -> Jmp (arg land 0x3f)
  | 0x1 -> Out (arg land 0xff)
  | 0x2 -> Outb (arg land 0x7)
  | 0x3 -> Ldi (arg land 0xff)
  | 0x4 -> In
  | 0x5 -> Wait arg
  | 0x6 -> Ldc (arg land 0xff)
  | 0x7 -> Djnz (arg land 0x3f)
  | op -> Reserved op
;;

(* Place a program at address 0; remaining words are 0 (= JMP 0). *)
let assemble (prog : t list) =
  if List.length prog > imem_depth
  then raise_s [%message "program too long" (List.length prog : int)];
  let a = Array.create ~len:imem_depth 0 in
  List.iteri prog ~f:(fun i ins -> a.(i) <- encode ins);
  a
;;
