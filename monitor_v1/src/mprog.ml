(* Monitor ISA v1 (doc/contracts/monitor_isa_v1.md sections 3-5): a compiled package. *)
open! Core

type literal =
  { obs : int (* local observable 0..15 *)
  ; kind : int (* 0 level, 1 rise, 2 fall, 3 changed *)
  ; delay : int (* 0..3 *)
  ; neg : bool
  }
[@@deriving sexp, equal, compare]

(* (l0 op1 l1) op2 l2; op = true means OR. Unused literal slots hold a neutral constant via
   [Const]. *)
type lit_or_const =
  | L of literal
  | Const of bool
[@@deriving sexp, equal, compare]

type pred =
  { l0 : lit_or_const
  ; l1 : lit_or_const
  ; l2 : lit_or_const
  ; or1 : bool
  ; or2 : bool
  }
[@@deriving sexp, equal, compare]

type modifier =
  | No_mod
  | And_reg of int
  | Xnor_reg of int
  | And_elapsed of int * int (* mark, window-table index *)
[@@deriving sexp, equal]

type op =
  | Await
  | Await_idle
  | Hold_for
  | Hold_until
  | Skip
  | Take_tx
  | Take_rx
[@@deriving sexp, equal]

let stop_addr = 127

type instr =
  { op : op
  ; pe : int
  ; pr : int
  ; pcond : int
  ; md : modifier
  ; md_pr : bool (* the modifier applies to the requirement predicate *)
  ; md_exp : bool (* the modifier applies to the expect predicate *)
  ; lo : int (* window-table index *)
  ; hi : int
  ; since : int (* 0 anchor, 1 mark 0, 2 mark 1 *)
  ; chk : int (* code-table index; 0 = none *)
  ; early : int
  ; mark : int (* 0 none, 1 mark 0, 2 mark 1 *)
  ; smp : (int * int) option (* register bit, predicate *)
  ; mat : int option (* check index *)
  ; exp : int (* predicate, 0 = none *)
  ; exp_chk : int
  ; bp : int (* branch predicate, 0 = never *)
  ; next : int
  ; alt : int
  ; tsel : int
  }
[@@deriving sexp, equal]

type unit_prog =
  { start : int
  ; guard : (int * int * int * int) option (* predicate, range start, range end, handler *)
  ; code : instr array
  }
[@@deriving sexp, equal]

type t =
  { name : string
  ; remap : int array (* 16 local -> global source *)
  ; preds : pred array (* index 0 = true, 15 = false; 1..14 from the bank *)
  ; windows : int array (* 8 entries, entry 0 = 0 *)
  ; codes : (Lang.role * int) option array (* 16 entries, entry 0 = none *)
  ; units : unit_prog array (* <= 8 *)
  }
[@@deriving sexp, equal]

let pred_true = { l0 = Const true; l1 = Const true; l2 = Const true; or1 = false; or2 = false }
let pred_false = { l0 = Const false; l1 = Const false; l2 = Const false; or1 = false; or2 = false }
