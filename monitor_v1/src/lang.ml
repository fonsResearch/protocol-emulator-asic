(* Contract language v1 (doc/contracts/language_v0.md with language_v1.md) as an OCaml
   embedded DSL. One contract = one package for one lane: its watchers run in the lane's steps
   (C1). The compiler (compile.ml) accepts a subset of what [validate] accepts; anything it
   rejects cannot run on chip (monitor_isa_v1.md). *)
open! Core

type role =
  | Fail
  | Blame
[@@deriving sexp, equal, compare]

(* Global sources (monitor_isa_v1.md section 1). Inputs are seen through the monitor's 2-flop
   synchroniser; Drive k = uio_oe[k] && !uio_out[k] (pulls low, ISA v1.0.2). *)
type source =
  | Uo of int
  | Uio_out of int
  | Uio_oe of int
  | Ui of int
  | Uio_in of int
  | Drive of int
  | Tx_pop_ev (* the lane pops a byte from its host TX FIFO in this step *)
  | Rx_push_ev (* the lane pushes a byte to its RX FIFO in this step *)
[@@deriving sexp, equal, compare]

let chip_driven = function
  | Uo _ | Uio_out _ | Uio_oe _ | Drive _ | Tx_pop_ev | Rx_push_ev -> true
  | Ui _ | Uio_in _ -> false
;;

let global_index = function
  | Uo k -> k
  | Uio_out k -> 8 + k
  | Uio_oe k -> 16 + k
  | Ui k -> 24 + k
  | Uio_in k -> 32 + k
  | Drive k -> 40 + k
  | Tx_pop_ev -> 48
  | Rx_push_ev -> 49
;;

type kind =
  | Level
  | Rise
  | Fall
  | Changed
[@@deriving sexp, equal, compare]

type expr =
  | True
  | False
  | Atom of
      { obs : string
      ; kind : kind
      ; delay : int (* x@k, 0..3 *)
      }
  | Reg_bit of int (* watcher register bit 0..15 *)
  | Eq_reg of expr * int (* e equals register bit i (XNOR modifier) *)
  | Elapsed_ge of
      { mark : int (* 0 or 1 *)
      ; t : int
      }
  | Not of expr
  | And of expr * expr
  | Or of expr * expr
[@@deriving sexp, equal]

type check = role * int [@@deriving sexp, equal]

type window =
  { lo : int
  ; hi : int
  ; since : int option (* mark 0 or 1 *)
  ; timeout : check
  ; early : check option
  }
[@@deriving sexp, equal]

type stream =
  | Tx_pop
  | Rx_push
[@@deriving sexp, equal]

type stmt =
  | Await_idle of
      { e : expr
      ; when_ : expr
      }
  | Await of
      { e : expr
      ; when_ : expr
      ; w : window
      }
  | Hold_for of
      { r : expr
      ; when_ : expr
      ; n : int
      ; check : check
      }
  | Hold_until of
      { r : expr
      ; when_ : expr
      ; e : expr
      ; w : window (* w.timeout is also the violation check of r *)
      }
  | Skip of int
  | Take of
      { s : stream
      ; byte : int (* register byte 0 or 1 *)
      ; w : window option (* None: idle, never fires [choice] *)
      }
  | Expect of
      { r : expr
      ; when_ : expr
      ; check : check
      }
  | Sample of
      { bit : int
      ; e : expr
      }
  | Match of { check : check } (* register byte 0 == element pushed to RX in this step *)
  | Mark of int
  | Raise of check
  | If of expr * stmt list * stmt list
  | Loop of stmt list
  | Repeat of int * stmt list
  | Guard of
      { g : expr
      ; body : stmt list
      ; handler : stmt list
      }
[@@deriving sexp, equal]

type watcher =
  { wname : string
  ; base : int
  ; body : stmt list
  }
[@@deriving sexp, equal]

type t =
  { name : string
  ; observables : (string * source) list (* local observables, at most 16 *)
  ; watchers : watcher list (* at most 8 *)
  }
[@@deriving sexp, equal]

(* ---- constructors ---- *)
let at ?(delay = 0) x = Atom { obs = x; kind = Level; delay }
let v x = at x
let rise ?(delay = 0) x = Atom { obs = x; kind = Rise; delay }
let fall ?(delay = 0) x = Atom { obs = x; kind = Fall; delay }
let changed ?(delay = 0) x = Atom { obs = x; kind = Changed; delay }
let stable ?delay x = Not (changed ?delay x)
let ( !! ) e = Not e
let ( &&& ) a b = And (a, b)
let ( ||| ) a b = Or (a, b)
let fail c = Fail, c
let blame c = Blame, c
let win ?since ?early lo hi ~else_ = { lo; hi; since; timeout = else_; early }
let await_idle ?(when_ = True) e = Await_idle { e; when_ }
let await ?(when_ = True) e w = Await { e; when_; w }
let hold ?(when_ = True) r ~for_ ~else_ = Hold_for { r; when_; n = for_; check = else_ }
let hold_until ?(when_ = True) r e w = Hold_until { r; when_; e; w }
let skip n = Skip n
let take ?(byte = 0) s w = Take { s; byte; w = Some w }
let take_idle ?(byte = 0) s = Take { s; byte; w = None }
let eq_reg e i = Eq_reg (e, i)
let expect ?(when_ = True) r ~else_ = Expect { r; when_; check = else_ }
let sample bit e = Sample { bit; e }
let match_rx ~else_ = Match { check = else_ }
let mark a = Mark a
let raise_ c = Raise c
let if_ b t e = If (b, t, e)
let loop b = Loop b
let repeat n b = Repeat (n, b)
let guard g body ~on = Guard { g; body; handler = on }
let watcher wname ~base body = { wname; base; body }

(* ---- validation (language v0 section 5, v1 C1-C6) ---- *)
let rec atoms = function
  | True | False | Reg_bit _ | Elapsed_ge _ -> []
  | Atom { obs; delay; _ } -> [ obs, delay ]
  | Not e | Eq_reg (e, _) -> atoms e
  | And (a, b) | Or (a, b) -> atoms a @ atoms b
;;

let rec consumes = function
  | Await_idle _ | Await _ | Hold_for _ | Hold_until _ | Skip _ | Take _ -> true
  | Expect _ | Sample _ | Match _ | Mark _ | Raise _ -> false
  | If (_, a, b) -> List.exists a ~f:consumes && List.exists b ~f:consumes
  | Loop b | Guard { body = b; _ } -> List.exists b ~f:consumes
  | Repeat (n, b) -> n > 0 && List.exists b ~f:consumes
;;

(* the first statement executed is consuming (instants need an anchor step) *)
let rec starts_consuming = function
  | [] -> false
  | s :: _ ->
    (match s with
     | Await_idle _ | Await _ | Hold_for _ | Hold_until _ | Skip _ | Take _ -> true
     | Loop b -> starts_consuming b
     | Repeat (n, b) -> n > 0 && starts_consuming b
     | Guard { body; _ } -> starts_consuming body
     | If _ | Expect _ | Sample _ | Match _ | Mark _ | Raise _ -> false)
;;

let validate (c : t) =
  let errs = ref [] in
  let err fmt = ksprintf (fun s -> errs := s :: !errs) fmt in
  if List.length c.observables > 16 then err "more than 16 observables";
  if List.length c.watchers > 8 then err "more than 8 watchers";
  let src x = List.Assoc.find c.observables ~equal:String.equal x in
  (* WF3 (v1.1, user decision 2026-10-18): a code identifies a watcher and a check family.
     Several sites may share a code only within one watcher and only if they have the same
     kind and outcome, the same requirement and the same condition, up to register-bit
     indices of [Eq_reg]; hold and window lengths may differ. The site is recovered offline
     by replaying the trace through the reference interpreter. *)
  let rec norm = function
    | Eq_reg (e, _) -> Eq_reg (norm e, 0)
    | Not e -> Not (norm e)
    | And (a, b) -> And (norm a, norm b)
    | Or (a, b) -> Or (norm a, norm b)
    | e -> e
  in
  let codes = Hashtbl.create (module Int) in
  let check_code ?(family = "", True, True) (w : watcher) (_, code) =
    let full = w.base + code in
    if full < 1 || full > 255 then err "%s: code %d out of range 1..255" w.wname full;
    let kind, r, c = family in
    let sig_ = w.wname, kind, norm r, norm c in
    match Hashtbl.find codes full with
    | None -> Hashtbl.set codes ~key:full ~data:sig_
    | Some (wn, k, r', c') ->
      if not (String.equal wn w.wname && String.equal k kind && String.(kind <> "")
              && equal_expr (norm r) r' && equal_expr (norm c) c')
      then err "%s: code 0x%02x shared by checks of different families (WF3)" w.wname full
  in
  let check_expr (w : watcher) e =
    List.iter (atoms e) ~f:(fun (x, d) ->
      if Option.is_none (src x) then err "%s: unknown observable %s" w.wname x;
      if d < 0 || d > 3 then err "%s: delay %d of %s out of 0..3" w.wname d x)
  in
  (* WF1/WF2 on the required expression only (C2) *)
  let check_role (w : watcher) role e =
    check_expr w e;
    List.iter (atoms e) ~f:(fun (x, _) ->
      match src x, role with
      | Some s, Fail when not (chip_driven s) ->
        err "%s: fail check requires environment observable %s (WF1)" w.wname x
      | Some s, Blame when chip_driven s ->
        err "%s: blame check requires chip observable %s (WF2)" w.wname x
      | _ -> ())
  in
  let check_window ?(kind = "await") ?(cond = True) w (win : window) req =
    if win.lo < 0 || win.hi < win.lo || win.hi > 4095 then err "%s: bad window" w.wname;
    (match win.since with
     | Some m when m <> 0 && m <> 1 -> err "%s: since mark %d" w.wname m
     | _ -> ());
    check_code ~family:(kind ^ "/timeout", req, cond) w win.timeout;
    check_role w (fst win.timeout) req;
    Option.iter win.early ~f:(fun ck ->
      check_code ~family:(kind ^ "/early", req, cond) w ck;
      check_role w (fst ck) req)
  in
  let rec walk ~in_guard ~in_handler (w : watcher) stmts =
    List.iter stmts ~f:(fun s ->
      match s with
      | Await_idle { e; when_ } ->
        check_expr w e;
        check_expr w when_
      | Await { e; when_; w = win } ->
        check_expr w when_;
        check_window ~cond:when_ w win e
      | Hold_for { r; when_; n; check } ->
        if n < 1 || n > 4095 then err "%s: hold n" w.wname;
        check_expr w when_;
        check_code ~family:("hold", r, when_) w check;
        check_role w (fst check) r
      | Hold_until { r; when_; e; w = win } ->
        check_expr w when_;
        check_window ~kind:"hold_until" ~cond:when_ w win (And (r, e))
      | Skip n -> if n < 1 || n > 4095 then err "%s: skip n" w.wname
      | Take { byte; w = win; _ } ->
        if byte <> 0 && byte <> 1 then err "%s: take byte" w.wname;
        Option.iter win ~f:(fun win ->
          check_window ~kind:"take" w win True;
          (* streams are chip-driven (the lane pops and pushes) *)
          if equal_role (fst win.timeout) Blame
          then err "%s: blame check on a chip stream (WF2)" w.wname)
      | Expect { r; when_; check } ->
        check_expr w when_;
        check_code ~family:("expect", r, when_) w check;
        check_role w (fst check) r
      | Sample { bit; e } ->
        if bit < 0 || bit > 15 then err "%s: sample bit" w.wname;
        check_expr w e
      | Match { check } ->
        check_code ~family:("match", True, True) w check;
        if equal_role (fst check) Blame then err "%s: blame match on a chip stream" w.wname
      | Mark a -> if a <> 0 && a <> 1 then err "%s: mark %d" w.wname a
      | Raise ck -> check_code w ck
      | If (b, t, e) ->
        check_expr w b;
        if not (starts_consuming t && starts_consuming e)
        then err "%s: if branches must start with a consuming statement" w.wname;
        walk ~in_guard ~in_handler w t;
        walk ~in_guard ~in_handler w e
      | Loop b ->
        if not (List.exists b ~f:consumes) then err "%s: zero-time loop" w.wname;
        walk ~in_guard ~in_handler w b
      | Repeat (n, b) ->
        if n < 1 || not (List.exists b ~f:consumes) then err "%s: bad repeat" w.wname;
        walk ~in_guard ~in_handler w b
      | Guard { g; body; handler } ->
        if in_guard || in_handler then err "%s: nested guard (one level, C4)" w.wname;
        check_expr w g;
        if not (starts_consuming body && starts_consuming handler)
        then err "%s: guard body and handler must start with a consuming statement" w.wname;
        walk ~in_guard:true ~in_handler w body;
        walk ~in_guard ~in_handler:true w handler)
  in
  List.iter c.watchers ~f:(fun w ->
    if not (starts_consuming w.body)
    then err "%s: must start with a consuming statement" w.wname;
    walk ~in_guard:false ~in_handler:false w w.body);
  match !errs with
  | [] -> Ok c
  | es -> Error (List.rev es)
;;

let validate_exn c =
  match validate c with
  | Ok c -> c
  | Error es -> raise_s [%message "invalid contract" c.name (es : string list)]
;;
