(* Reference semantics of the contract language (doc/contracts/language_v0.md section 4),
   interpreted directly on the DSL tree. Independent of [Program] (flattening, folding), so
   differential runs against the circuits check the compiler too.

   Cycle model, identical to the circuits:
   - [step] is given the raw pins and chip outputs of the current cycle and returns the
     verdict of that cycle (combinational view), then advances to the next cycle.
   - While [rst_sync_n] = 0 nothing fires and all state returns to its reset value.
   - Inputs are observed through a 2-flop synchroniser (s2), reset to 0. *)
open! Core
open Contract

type pins =
  { rst_sync_n : bool
  ; ui_in : int
  ; uio_in : int
  ; uo_out : int
  ; uio_out : int
  ; uio_oe : int
  }

type verdict =
  { fail_now : bool
  ; blame_now : bool
  ; fail_flag : bool
  ; blame_flag : bool
  ; first_fail : int option (* full cause code *)
  ; first_blame : int option
  }
[@@deriving sexp_of, equal]

type item =
  | S of stmt
  | Back of stmt list (* loop back-edge: re-enter this body *)

type wstate =
  { w : watcher
  ; mutable cur : stmt option (* current consuming statement *)
  ; mutable k : int (* cycles since anchor *)
  ; mutable cont : item list
  ; mutable stopped : bool
  }

type t =
  { c : Contract.t
  ; ws : wstate array
  ; mutable s1_ui : int
  ; mutable s2_ui : int
  ; mutable s1_uio : int
  ; mutable s2_uio : int
  ; prev : bool String.Table.t
  ; mutable prev_valid : bool
  ; mutable fail_flag : bool
  ; mutable blame_flag : bool
  ; mutable first_fail : int option
  ; mutable first_blame : int option
  }

(* Walk the continuation to the next consuming statement. *)
type advance =
  | Next of stmt * item list
  | Fired of check
  | Ended

let rec advance = function
  | [] -> Ended
  | S (Raise ck) :: _ -> Fired ck
  | S (Loop body) :: _ as l ->
    (* the loop never exits: replace the rest of the continuation *)
    ignore (l : item list);
    advance (List.map body ~f:(fun s -> S s) @ [ Back body ])
  | S (Repeat (n, body)) :: rest ->
    advance (List.concat (List.init n ~f:(fun _ -> List.map body ~f:(fun s -> S s))) @ rest)
  | S s :: rest -> Next (s, rest)
  | Back body :: _ -> advance (List.map body ~f:(fun s -> S s) @ [ Back body ])
;;

let init_watcher ws =
  ws.k <- 0;
  ws.stopped <- false;
  match advance (List.map ws.w.body ~f:(fun s -> S s)) with
  | Next (s, rest) ->
    ws.cur <- Some s;
    ws.cont <- rest
  | Ended ->
    ws.cur <- None;
    ws.cont <- [];
    ws.stopped <- true
  | Fired _ -> raise_s [%message "watcher starts with raise" ws.w.wname]
;;

let reset t =
  Array.iter t.ws ~f:init_watcher;
  t.s1_ui <- 0;
  t.s2_ui <- 0;
  t.s1_uio <- 0;
  t.s2_uio <- 0;
  Hashtbl.clear t.prev;
  t.prev_valid <- false;
  t.fail_flag <- false;
  t.blame_flag <- false;
  t.first_fail <- None;
  t.first_blame <- None
;;

let create c =
  let c = validate_exn c in
  let ws =
    Array.of_list_map c.watchers ~f:(fun w ->
      { w; cur = None; k = 0; cont = []; stopped = false })
  in
  let t =
    { c
    ; ws
    ; s1_ui = 0
    ; s2_ui = 0
    ; s1_uio = 0
    ; s2_uio = 0
    ; prev = String.Table.create ()
    ; prev_valid = false
    ; fail_flag = false
    ; blame_flag = false
    ; first_fail = None
    ; first_blame = None
    }
  in
  reset t;
  t
;;

let bit v k = (v lsr k) land 1 = 1

let value t (p : pins) x =
  match List.Assoc.find_exn t.c.observables ~equal:String.equal x with
  | Uo k -> bit p.uo_out k
  | Uio_out k -> bit p.uio_out k
  | Uio_oe k -> bit p.uio_oe k
  | Ui k -> bit t.s2_ui k
  | Uio_in k -> bit t.s2_uio k
;;

let rec eval t p = function
  | True -> true
  | False -> false
  | Atom (x, kind) ->
    let now = value t p x in
    let before = Hashtbl.find t.prev x |> Option.value ~default:false in
    (match kind with
     | Level -> now
     | Rise -> t.prev_valid && now && not before
     | Fall -> t.prev_valid && (not now) && before
     | Changed -> t.prev_valid && Bool.( <> ) now before)
  | Not e -> not (eval t p e)
  | And (a, b) -> eval t p a && eval t p b
  | Or (a, b) -> eval t p a || eval t p b
;;

(* Decide one watcher's outcome for the current cycle; mutate its state for the next. *)
let step_watcher t p ws =
  if ws.stopped
  then None
  else (
    let s = Option.value_exn ws.cur in
    ws.k <- ws.k + 1;
    let k = ws.k in
    let outcome =
      match s with
      | Await_idle e -> if eval t p e then `Complete else `Stay
      | Await { e; lo; hi; timeout; early } ->
        let ev = eval t p e in
        if ev && k >= lo
        then `Complete
        else if ev && k < lo && Option.is_some early
        then `Fire (Option.value_exn early)
        else if (not ev) && k >= hi
        then `Fire timeout
        else `Stay
      | Hold { b; n; check } ->
        if not (eval t p b) then `Fire check else if k >= n then `Complete else `Stay
      | Skip n -> if k >= n then `Complete else `Stay
      | Raise _ | Loop _ | Repeat _ -> assert false
    in
    match outcome with
    | `Stay -> None
    | `Fire ck ->
      ws.stopped <- true;
      Some ck
    | `Complete ->
      ws.k <- 0;
      (match advance ws.cont with
       | Next (s', rest) ->
         ws.cur <- Some s';
         ws.cont <- rest;
         None
       | Ended ->
         ws.stopped <- true;
         None
       | Fired ck ->
         ws.stopped <- true;
         Some ck))
;;

let step t (p : pins) =
  if not p.rst_sync_n
  then (
    reset t;
    { fail_now = false
    ; blame_now = false
    ; fail_flag = false
    ; blame_flag = false
    ; first_fail = None
    ; first_blame = None
    })
  else (
    let fired =
      Array.filter_map t.ws ~f:(fun ws ->
        Option.map (step_watcher t p ws) ~f:(fun (r, c) -> r, ws.w.base + c))
    in
    let first role =
      Array.find fired ~f:(fun (r, _) -> equal_role r role) |> Option.map ~f:snd
    in
    let fail_now = Option.is_some (first Fail)
    and blame_now = Option.is_some (first Blame) in
    if Option.is_none t.first_fail then t.first_fail <- first Fail;
    if Option.is_none t.first_blame then t.first_blame <- first Blame;
    t.fail_flag <- t.fail_flag || fail_now;
    t.blame_flag <- t.blame_flag || blame_now;
    let v =
      { fail_now
      ; blame_now
      ; fail_flag = t.fail_flag
      ; blame_flag = t.blame_flag
      ; first_fail = t.first_fail
      ; first_blame = t.first_blame
      }
    in
    (* advance observation state *)
    List.iter t.c.observables ~f:(fun (x, _) -> Hashtbl.set t.prev ~key:x ~data:(value t p x));
    t.prev_valid <- true;
    t.s2_ui <- t.s1_ui;
    t.s1_ui <- p.ui_in;
    t.s2_uio <- t.s1_uio;
    t.s1_uio <- p.uio_in;
    v)
;;
