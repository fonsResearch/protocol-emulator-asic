(* Compilation of a contract to flat monitor programs, one per watcher.

   A flat program is an array of consuming instructions. The zero-time statements of the
   language (raise, end of watcher, loop back-edges) are folded into each instruction's
   [on_complete] action, so the engine never executes more than one instruction per cycle
   per watcher (K_chain = 1 in this spike).

   Predicates are restricted to a conjunction of at most two literals over observable atoms
   (or constant true/false); [compile] rejects anything else. *)
open! Core
open Contract

type literal =
  { obs : int (* index into [observables] *)
  ; kind : kind
  ; neg : bool
  }
[@@deriving sexp, equal]

type pred =
  | P_true
  | P_false
  | P_and of literal list (* 1 or 2 literals *)
[@@deriving sexp, equal]

type action =
  | Goto of int
  | Fire of check (* raise at the completion cycle, then stop *)
  | Stop (* end of watcher: stop silently *)
[@@deriving sexp, equal]

type op =
  | Await_idle
  | Await of
      { lo : int
      ; hi : int
      ; timeout : check
      ; early : check option
      }
  | Hold of
      { n : int
      ; check : check
      }
  | Skip of int
[@@deriving sexp, equal]

type instr =
  { op : op
  ; pred : pred
  ; on_complete : action
  }
[@@deriving sexp, equal]

type watcher_prog =
  { wname : string
  ; base : int
  ; instrs : instr array
  }
[@@deriving sexp, equal]

type t =
  { contract : string
  ; observables : (string * source) array
  ; watchers : watcher_prog array
  }
[@@deriving sexp, equal]

let max_window (p : t) =
  Array.fold p.watchers ~init:1 ~f:(fun acc w ->
    Array.fold w.instrs ~init:acc ~f:(fun acc i ->
      match i.op with
      | Await_idle -> acc
      | Await { hi; _ } -> Int.max acc hi
      | Hold { n; _ } -> Int.max acc n
      | Skip n -> Int.max acc n))
;;

(* ---- predicate normalisation ---- *)
let compile_pred obs_index e =
  let lit ~neg x kind = { obs = obs_index x; kind; neg } in
  let rec literals = function
    | Atom (x, k) -> Some [ lit ~neg:false x k ]
    | Not (Atom (x, k)) -> Some [ lit ~neg:true x k ]
    | Not (Not e) -> literals e
    | And (a, b) ->
      (match literals a, literals b with
       | Some la, Some lb -> Some (la @ lb)
       | _ -> None)
    | _ -> None
  in
  match e with
  | True -> P_true
  | False -> P_false
  | Not True -> P_false
  | Not False -> P_true
  | _ ->
    (match literals e with
     | Some ls when List.length ls <= 2 -> P_and ls
     | _ ->
       raise_s
         [%message
           "predicate outside the spike engine's form (conjunction of <= 2 literals)"
             ~expr:(expr_to_string e : string)])
;;

(* ---- flattening ----
   Items are emitted in order with symbolic successors; a back-edge or end-of-body is
   represented by [Jump target] / [End] placeholder items, removed by threading. *)
type item =
  | I of instr (* on_complete = Goto (next index) for now; fixed by threading *)
  | R of check (* raise *)
  | J of int (* jump to item index *)
  | E (* end of watcher *)

let flatten obs_index body =
  let items = Queue.create () in
  let emit x =
    Queue.enqueue items x;
    Queue.length items - 1
  in
  let rec stmt s =
    match (s : stmt) with
    | Await_idle e ->
      ignore (emit (I { op = Await_idle; pred = compile_pred obs_index e; on_complete = Stop }) : int)
    | Await { e; lo; hi; timeout; early } ->
      ignore
        (emit
           (I
              { op = Await { lo; hi; timeout; early }
              ; pred = compile_pred obs_index e
              ; on_complete = Stop
              })
         : int)
    | Hold { b; n; check } ->
      ignore
        (emit (I { op = Hold { n; check }; pred = compile_pred obs_index b; on_complete = Stop })
         : int)
    | Skip n -> ignore (emit (I { op = Skip n; pred = P_true; on_complete = Stop }) : int)
    | Raise ck -> ignore (emit (R ck) : int)
    | Repeat (n, body) ->
      for _ = 1 to n do
        List.iter body ~f:stmt
      done
    | Loop body ->
      let start = Queue.length items in
      List.iter body ~f:stmt;
      ignore (emit (J start) : int)
  in
  List.iter body ~f:stmt;
  ignore (emit E : int);
  Queue.to_array items
;;

(* Resolve the action taken when control reaches item [k]. *)
let rec resolve items ~seen k =
  if Set.mem seen k then raise_s [%message "zero-time loop in watcher"];
  match items.(k) with
  | I _ -> `Instr k
  | R ck -> `Fire ck
  | E -> `Stop
  | J t -> resolve items ~seen:(Set.add seen k) t
;;

let compile_watcher obs_index (w : Contract.watcher) =
  let items = flatten obs_index w.body in
  (* map item index of each instruction to its final instruction index *)
  let idx = Array.create ~len:(Array.length items) (-1) in
  let n = ref 0 in
  Array.iteri items ~f:(fun k it ->
    match it with
    | I _ ->
      idx.(k) <- !n;
      incr n
    | _ -> ());
  let action_at k =
    if k >= Array.length items
    then Stop
    else (
      match resolve items ~seen:Int.Set.empty k with
      | `Instr j -> Goto idx.(j)
      | `Fire ck -> Fire ck
      | `Stop -> Stop)
  in
  let instrs =
    Array.filter_mapi items ~f:(fun k it ->
      match it with
      | I ins -> Some { ins with on_complete = action_at (k + 1) }
      | _ -> None)
  in
  (* entry: the first item must be an instruction (validation forbids a leading raise). An
     empty watcher becomes "await false idle": never completes, never fires. *)
  let instrs =
    match action_at 0 with
    | Goto 0 -> instrs
    | Goto _ -> assert false
    | Stop -> [| { op = Await_idle; pred = P_false; on_complete = Stop } |]
    | Fire _ -> raise_s [%message "watcher starts with raise" w.wname]
  in
  { wname = w.wname; base = w.base; instrs }
;;

let compile (c : Contract.t) =
  let c = validate_exn c in
  let observables = Array.of_list c.observables in
  let obs_index x =
    match Array.findi observables ~f:(fun _ (n, _) -> String.equal n x) with
    | Some (i, _) -> i
    | None -> raise_s [%message "unknown observable" x]
  in
  { contract = c.name
  ; observables
  ; watchers = Array.of_list_map c.watchers ~f:(compile_watcher obs_index)
  }
;;
