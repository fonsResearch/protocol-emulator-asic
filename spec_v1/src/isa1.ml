(* ISA v1 (doc/isa/isa_v1.md section 5): instruction type, encoding, decoding, assembler. *)
open! Core

let imem_depth = 256

type reg8 =
  | R0
  | R1
  | R2
  | R3
  | Sr
  | Lc
[@@deriving sexp, equal, compare, enumerate]

(* destination codes for LDI: r0..r3, sr, lc, to_lo, xo *)
type ldi_dst =
  | L of reg8
  | To_lo
  | Xo
[@@deriving sexp, equal]

(* MOV destinations: r0..r3, sr, lc, out, oe; sources: r0..r3, sr, lc, pins, ser_status *)
type mov_dst =
  | M of reg8
  | Out_reg
  | Oe_reg
[@@deriving sexp, equal]

type mov_src =
  | S of reg8
  | Pins
  | Ser_status
[@@deriving sexp, equal]

type cmp_src =
  | C of reg8
  | Cpins
[@@deriving sexp, equal]

type pin_op =
  | Out_lsb
  | Out_msb
  | In_lsb
  | In_msb
[@@deriving sexp, equal]

type pin_cond =
  | Low
  | High
  | Rising
  | Falling
[@@deriving sexp, equal]

type ser_op =
  | Send of reg8
  | Crci
  | Crcs
  | Eop
  | Period of reg8
  | Idle
  | Sendc of reg8
[@@deriving sexp, equal]

type t =
  | Jmp of int
  | Br of int * int (* condition 0..15, target *)
  | Out of int
  | Oen of int
  | Pin of int * pin_op
  | Wait of int
  | Wtp of int * pin_cond
  | Ldi of ldi_dst * int
  | Mov of mov_dst * mov_src
  | Cmp of cmp_src * int
  | Addi of reg8 * int
  | Pop of reg8 (* R0..R3, Sr only *)
  | Push of reg8
  | Ser of ser_op
  | Djnz of int
  | Nop
  | Halt
  | Clrt
[@@deriving sexp, equal]

let reg_code = function
  | R0 -> 0
  | R1 -> 1
  | R2 -> 2
  | R3 -> 3
  | Sr -> 4
  | Lc -> 5
;;

let reg_of_code = function
  | 0 -> Some R0
  | 1 -> Some R1
  | 2 -> Some R2
  | 3 -> Some R3
  | 4 -> Some Sr
  | 5 -> Some Lc
  | _ -> None
;;

let check name v lo hi =
  if v < lo || v > hi then raise_s [%message "operand out of range" name (v : int) (lo : int) (hi : int)]
;;

let pin_op_code = function Out_lsb -> 0 | Out_msb -> 1 | In_lsb -> 2 | In_msb -> 3
let pin_cond_code = function Low -> 0 | High -> 1 | Rising -> 2 | Falling -> 3

let w op arg = (op lsl 12) lor arg

let encode = function
  | Jmp t -> check "t" t 0 255; w 0x0 t
  | Br (c, t) -> check "c" c 0 15; check "t" t 0 255; w 0x1 ((c lsl 8) lor t)
  | Out v -> check "v" v 0 255; w 0x2 v
  | Oen v -> check "v" v 0 255; w 0x3 v
  | Pin (p, a) -> check "p" p 0 7; w 0x4 ((pin_op_code a lsl 4) lor p)
  | Wait k -> check "k" k 0 4095; w 0x5 k
  | Wtp (p, c) -> check "p" p 0 7; w 0x6 ((pin_cond_code c lsl 4) lor p)
  | Ldi (d, v) ->
    check "v" v 0 255;
    let dc = match d with L r -> reg_code r | To_lo -> 6 | Xo -> 7 in
    w 0x7 ((dc lsl 8) lor v)
  | Mov (d, s) ->
    let dc = match d with M r -> reg_code r | Out_reg -> 6 | Oe_reg -> 7 in
    let sc = match s with S r -> reg_code r | Pins -> 6 | Ser_status -> 7 in
    w 0x8 ((dc lsl 8) lor (sc lsl 4))
  | Cmp (s, v) ->
    check "v" v 0 255;
    let sc = match s with C r -> reg_code r | Cpins -> 6 in
    w 0x9 ((sc lsl 8) lor v)
  | Addi (d, v) -> check "v" v 0 255; w 0xA ((reg_code d lsl 8) lor v)
  | Pop x -> check "x" (reg_code x) 0 4; w 0xB ((0 lsl 10) lor reg_code x)
  | Push x -> check "x" (reg_code x) 0 4; w 0xB ((1 lsl 10) lor reg_code x)
  | Ser op ->
    let a, x =
      match op with
      | Send r -> 0, reg_code r
      | Crci -> 1, 0
      | Crcs -> 2, 0
      | Eop -> 3, 0
      | Period r -> 4, reg_code r
      | Idle -> 5, 0
      | Sendc r -> 6, reg_code r
    in
    check "x" x 0 4;
    w 0xC ((a lsl 9) lor x)
  | Djnz t -> check "t" t 0 255; w 0xD t
  | Nop -> w 0xE 0
  | Halt -> w 0xE 1
  | Clrt -> w 0xE 2
;;

let assemble prog =
  let a = Array.create ~len:imem_depth 0 in
  List.iteri prog ~f:(fun i ins -> a.(i) <- encode ins);
  a
;;
