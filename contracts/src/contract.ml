(* Contract language (doc/contracts/language_v0.md) as an OCaml embedded DSL (user decision
   Q1, 2026-10-17: the DSL is the source of truth; [to_text] prints the text view).

   Spike subset: observables over the TT pins, boolean expressions with edge predicates,
   await / hold / skip / raise / loop / repeat. Streams, registers, mark/elapsed and
   sample/match are language features not yet implemented here. *)
open! Core

type role =
  | Fail (* the chip is at fault: guarantee check *)
  | Blame (* the environment is at fault: assumption check *)
[@@deriving sexp, equal, compare]

(* Where an observable comes from. Inputs are seen through the monitor's own 2-flop
   synchroniser (latency 2, doc/interface.md section 3); chip outputs are seen in the cycle
   they are driven. *)
type source =
  | Uo of int (* uo_out[k], chip-driven *)
  | Uio_out of int (* uio_out[k], chip-driven *)
  | Uio_oe of int (* uio_oe[k], chip-driven *)
  | Ui of int (* ui_in[k], synchronised, environment-driven *)
  | Uio_in of int (* uio_in[k], synchronised, environment-driven *)
[@@deriving sexp, equal, compare]

let chip_driven = function
  | Uo _ | Uio_out _ | Uio_oe _ -> true
  | Ui _ | Uio_in _ -> false
;;

type kind =
  | Level (* x *)
  | Rise (* x now 1, previous cycle 0 *)
  | Fall
  | Changed (* stable = not changed *)
[@@deriving sexp, equal, compare]

type expr =
  | True
  | False
  | Atom of string * kind
  | Not of expr
  | And of expr * expr
  | Or of expr * expr
[@@deriving sexp, equal]

type check = role * int [@@deriving sexp, equal]

type stmt =
  | Await_idle of expr
  | Await of
      { e : expr
      ; lo : int
      ; hi : int
      ; timeout : check
      ; early : check option
      }
  | Hold of
      { b : expr
      ; n : int
      ; check : check
      }
  | Skip of int
  | Raise of check
  | Loop of stmt list
  | Repeat of int * stmt list
[@@deriving sexp, equal]

type watcher =
  { wname : string
  ; base : int
  ; body : stmt list
  }
[@@deriving sexp, equal]

type t =
  { name : string
  ; clock_hz : int
  ; observables : (string * source) list
  ; watchers : watcher list
  }
[@@deriving sexp, equal]

(* ---- DSL constructors ---- *)
let v x = Atom (x, Level)
let rise x = Atom (x, Rise)
let fall x = Atom (x, Fall)
let changed x = Atom (x, Changed)
let stable x = Not (Atom (x, Changed))
let ( !! ) e = Not e
let ( &&& ) a b = And (a, b)
let ( ||| ) a b = Or (a, b)
let fail c = Fail, c
let blame c = Blame, c
let await_idle e = Await_idle e
let await ?early e ~within:(lo, hi) ~else_ = Await { e; lo; hi; timeout = else_; early }
let hold b ~for_ ~else_ = Hold { b; n = for_; check = else_ }
let skip n = Skip n
let raise_ c = Raise c
let loop body = Loop body
let repeat n body = Repeat (n, body)
let watcher wname ~base body = { wname; base; body }

(* ---- validation (language section 5, plus spike restrictions) ---- *)
let rec expr_atoms = function
  | True | False -> []
  | Atom (x, _) -> [ x ]
  | Not e -> expr_atoms e
  | And (a, b) | Or (a, b) -> expr_atoms a @ expr_atoms b
;;

let rec consumes = function
  | Await_idle _ | Await _ | Hold _ | Skip _ -> true
  | Raise _ -> false
  | Loop body -> List.exists body ~f:consumes
  | Repeat (n, body) -> n > 0 && List.exists body ~f:consumes
;;

let validate (c : t) =
  let errs = ref [] in
  let err fmt = ksprintf (fun s -> errs := s :: !errs) fmt in
  let src x = List.Assoc.find c.observables ~equal:String.equal x in
  let codes = Hash_set.create (module Int) in
  let check_code (w : watcher) (_, code) =
    let full = w.base + code in
    if full < 0 || full > 255 then err "%s: code %d out of 8-bit range" w.wname full;
    if Hash_set.mem codes full then err "%s: duplicate code 0x%02x (WF3)" w.wname full;
    Hash_set.add codes full
  in
  (* WF1/WF2: a [fail] check may only require chip-driven observables; a [blame] check only
     environment-driven ones. The "required" expression is [b] of a hold and [e] of an await
     (the event whose absence or timing fires the check). *)
  let check_role (w : watcher) role e =
    List.iter (expr_atoms e) ~f:(fun x ->
      match src x with
      | None -> err "%s: unknown observable %s" w.wname x
      | Some s ->
        (match role with
         | Fail when not (chip_driven s) ->
           err "%s: fail check requires environment observable %s (WF1)" w.wname x
         | Blame when chip_driven s ->
           err "%s: blame check requires chip observable %s (WF2)" w.wname x
         | _ -> ()))
  in
  let rec walk (w : watcher) = function
    | Await_idle e ->
      List.iter (expr_atoms e) ~f:(fun x ->
        if Option.is_none (src x) then err "%s: unknown observable %s" w.wname x)
    | Await { e; lo; hi; timeout; early } ->
      if lo < 1 || hi < lo then err "%s: await window [%d,%d] invalid" w.wname lo hi;
      check_code w timeout;
      check_role w (fst timeout) e;
      Option.iter early ~f:(fun ck ->
        check_code w ck;
        check_role w (fst ck) e)
    | Hold { b; n; check } ->
      if n < 1 then err "%s: hold for %d < 1" w.wname n;
      check_code w check;
      check_role w (fst check) b
    | Skip n -> if n < 1 then err "%s: skip %d < 1" w.wname n
    | Raise ck -> check_code w ck
    | Loop body ->
      if not (List.exists body ~f:consumes) then err "%s: zero-time loop" w.wname;
      List.iter body ~f:(walk w)
    | Repeat (n, body) ->
      if n < 1 then err "%s: repeat %d < 1" w.wname n;
      List.iter body ~f:(walk w)
  in
  List.iter c.watchers ~f:(fun w ->
    (match w.body with
     | Raise _ :: _ -> err "%s: watcher may not start with raise" w.wname
     | _ -> ());
    List.iter w.body ~f:(walk w));
  match List.rev !errs with
  | [] -> Ok ()
  | es -> Error es
;;

let validate_exn c =
  match validate c with
  | Ok () -> c
  | Error es -> raise_s [%message "invalid contract" (c.name : string) (es : string list)]
;;

(* ---- text view (language section 3) ---- *)
let source_to_string = function
  | Uo k -> sprintf "out uo[%d]" k
  | Uio_out k -> sprintf "out uio_out[%d]" k
  | Uio_oe k -> sprintf "out uio_oe[%d]" k
  | Ui k -> sprintf "in ui[%d]" k
  | Uio_in k -> sprintf "in uio[%d]" k
;;

let rec expr_to_string = function
  | True -> "true"
  | False -> "false"
  | Atom (x, Level) -> x
  | Atom (x, Rise) -> "rise " ^ x
  | Atom (x, Fall) -> "fall " ^ x
  | Not (Atom (x, Changed)) -> "stable " ^ x
  | Atom (x, Changed) -> "changed " ^ x
  | Not e -> "!" ^ paren e
  | And (a, b) -> paren a ^ " && " ^ paren b
  | Or (a, b) -> paren a ^ " || " ^ paren b

and paren e =
  match e with
  | And _ | Or _ -> "(" ^ expr_to_string e ^ ")"
  | _ -> expr_to_string e
;;

let check_to_string (r, c) =
  sprintf "else %s %d" (match r with Fail -> "fail" | Blame -> "blame") c
;;

let to_text (c : t) =
  let b = Buffer.create 1024 in
  let p ind fmt = ksprintf (fun s -> Buffer.add_string b (String.make ind ' ' ^ s ^ "\n")) fmt in
  p 0 "contract %s clock %d" c.name c.clock_hz;
  List.iter c.observables ~f:(fun (n, s) ->
    let s = source_to_string s in
    let kw, pin = String.lsplit2_exn s ~on:' ' in
    p 2 "%s %s = %s" kw n pin);
  let rec st ind = function
    | Await_idle e -> p ind "await %s idle" (expr_to_string e)
    | Await { e; lo; hi; timeout; early } ->
      p
        ind
        "await %s within [%d, %d] %s%s"
        (expr_to_string e)
        lo
        hi
        (check_to_string timeout)
        (match early with None -> "" | Some ck -> " early " ^ check_to_string ck)
    | Hold { b; n; check } -> p ind "hold %s for %d %s" (expr_to_string b) n (check_to_string check)
    | Skip n -> p ind "skip %d" n
    | Raise (r, c) -> p ind "raise %s %d" (match r with Fail -> "fail" | Blame -> "blame") c
    | Loop body ->
      p ind "loop {";
      List.iter body ~f:(st (ind + 2));
      p ind "}"
    | Repeat (n, body) ->
      p ind "repeat %d {" n;
      List.iter body ~f:(st (ind + 2));
      p ind "}"
  in
  List.iter c.watchers ~f:(fun w ->
    p 2 "watcher %s base 0x%02x {" w.wname w.base;
    List.iter w.body ~f:(st 4);
    p 2 "}");
  p 0 "end";
  Buffer.contents b
;;
