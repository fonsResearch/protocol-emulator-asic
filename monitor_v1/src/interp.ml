(* Reference semantics of contract language v1 for one lane's package, interpreted on the DSL
   tree (independent of the compiler and the ISA model). Semantics as in
   doc/contracts/monitor_isa_v1.md sections 1, 2 and 5, which follow language_v0/v1:

   - one call to [step] = one clock cycle: the outcome uses this cycle's values, then the
     state advances;
   - rst_sync_n = 0: everything, including the input synchronisers, returns to reset;
   - lane not running: watchers and the observation history return to reset (restart rule);
     synchronisers keep running;
   - running and tick: a step; every watcher evaluates on this step's observation.

   Firings of one step are returned in watcher order. *)
open! Core
open Lang

type inputs =
  { rst_sync_n : bool
  ; running : bool
  ; tick : bool
  ; ui_in : int
  ; uio_in : int
  ; uo_out : int
  ; uio_out : int
  ; uio_oe : int
  ; pop_ev : bool
  ; pop_data : int
  ; push_ev : bool
  ; push_data : int
  }

type item =
  | S of stmt
  | Back of stmt list (* loop back-edge *)
  | Guard_end

type guard_state =
  { g : expr
  ; handler : stmt list
  ; after : item list (* continuation after the guard statement *)
  }

type wstate =
  { w : watcher
  ; mutable cur : stmt option
  ; mutable cont : item list
  ; mutable k : int
  ; m : int array (* steps since mark 0 / 1 *)
  ; mutable reg : int (* 16 bits *)
  ; mutable guard : guard_state option
  ; mutable stopped : bool
  }

type t =
  { c : Lang.t
  ; ws : wstate array
  ; mutable s1_ui : int
  ; mutable s2_ui : int
  ; mutable s1_uio : int
  ; mutable s2_uio : int
  ; hist : bool list String.Table.t (* previous step values, most recent first, <= 4 *)
  ; mutable seen : int (* steps since restart *)
  }

let sat x = Int.min 4095 x
let bit v k = (v lsr k) land 1 = 1

(* observation of the current cycle *)
type obs =
  { value : string -> bool
  ; inp : inputs
  }

let make_obs t (i : inputs) =
  let value x =
    match List.Assoc.find_exn t.c.observables ~equal:String.equal x with
    | Uo k -> bit i.uo_out k
    | Uio_out k -> bit i.uio_out k
    | Uio_oe k -> bit i.uio_oe k
    | Ui k -> bit t.s2_ui k
    | Uio_in k -> bit t.s2_uio k
    | Drive k -> bit i.uio_oe k && not (bit i.uio_out k)
    | Tx_pop_ev -> i.pop_ev
    | Rx_push_ev -> i.push_ev
  in
  { value; inp = i }
;;

(* value of x d steps earlier (d = 0: now); 0 before it has been observed *)
let value_at t (o : obs) x d =
  if d = 0
  then o.value x
  else if t.seen >= d
  then List.nth (Hashtbl.find t.hist x |> Option.value ~default:[]) (d - 1)
       |> Option.value ~default:false
  else false
;;

let rec eval t (ws : wstate) (o : obs) = function
  | True -> true
  | False -> false
  | Atom { obs = x; kind; delay = d } ->
    let now = value_at t o x d
    and before = value_at t o x (d + 1)
    and valid = t.seen >= d + 1 in
    (match kind with
     | Level -> now
     | Rise -> valid && now && not before
     | Fall -> valid && (not now) && before
     | Changed -> valid && Bool.( <> ) now before)
  | Reg_bit b -> bit ws.reg b
  | Eq_reg (e, b) -> Bool.equal (eval t ws o e) (bit ws.reg b)
  | Elapsed_ge { mark; t = n } -> ws.m.(mark) >= n
  | Not e -> not (eval t ws o e)
  | And (a, b) -> eval t ws o a && eval t ws o b
  | Or (a, b) -> eval t ws o a || eval t ws o b
;;

type advance =
  | Next of stmt * item list
  | Fired of check
  | Ended

(* Walk to the next consuming statement, executing instants on observation [o] (the
   completion step). [o] = None at restart: no instants may be met (validation). *)
let rec advance t ws (o : obs option) items =
  let instant () =
    match o with
    | Some o -> o
    | None -> raise_s [%message "instant statement before the first step" ws.w.wname]
  in
  match items with
  | [] -> Ended
  | Guard_end :: rest ->
    ws.guard <- None;
    advance t ws o rest
  | Back body :: _ -> advance t ws o (List.map body ~f:(fun s -> S s) @ [ Back body ])
  | S s :: rest ->
    (match s with
     | Await_idle _ | Await _ | Hold_for _ | Hold_until _ | Skip _ | Take _ -> Next (s, rest)
     | Loop body -> advance t ws o (List.map body ~f:(fun s -> S s) @ [ Back body ])
     | Repeat (n, body) ->
       advance t ws o (List.concat (List.init n ~f:(fun _ -> List.map body ~f:(fun s -> S s))) @ rest)
     | Guard { g; body; handler } ->
       ws.guard <- Some { g; handler; after = rest };
       advance t ws o (List.map body ~f:(fun s -> S s) @ (Guard_end :: rest))
     | Mark a ->
       ignore (instant () : obs);
       ws.m.(a) <- 0;
       advance t ws o rest
     | Sample { bit = b; e } ->
       let o' = instant () in
       let v = eval t ws o' e in
       ws.reg <- (if v then ws.reg lor (1 lsl b) else ws.reg land lnot (1 lsl b));
       advance t ws o rest
     | Match { check } ->
       let o' = instant () in
       if o'.inp.push_ev && o'.inp.push_data land 0xFF = ws.reg land 0xFF
       then advance t ws o rest
       else Fired check
     | Expect { r; when_; check } ->
       let o' = instant () in
       if (not (eval t ws o' when_)) || eval t ws o' r then advance t ws o rest else Fired check
     | Raise ck ->
       ignore (instant () : obs);
       Fired ck
     | If (b, th, el) ->
       let o' = instant () in
       let branch = if eval t ws o' b then th else el in
       advance t ws o (List.map branch ~f:(fun s -> S s) @ rest))
;;

let restart_watcher t ws =
  ws.k <- 0;
  ws.m.(0) <- 0;
  ws.m.(1) <- 0;
  ws.reg <- 0;
  ws.guard <- None;
  ws.stopped <- false;
  match advance t ws None (List.map ws.w.body ~f:(fun s -> S s)) with
  | Next (s, rest) ->
    ws.cur <- Some s;
    ws.cont <- rest
  | Ended | Fired _ ->
    ws.cur <- None;
    ws.cont <- [];
    ws.stopped <- true
;;

let restart t =
  Array.iter t.ws ~f:(restart_watcher t);
  Hashtbl.clear t.hist;
  t.seen <- 0
;;

let create c =
  let c = validate_exn c in
  let ws =
    Array.of_list_map c.watchers ~f:(fun w ->
      { w; cur = None; cont = []; k = 0; m = [| 0; 0 |]; reg = 0; guard = None; stopped = false })
  in
  let t =
    { c; ws; s1_ui = 0; s2_ui = 0; s1_uio = 0; s2_uio = 0; hist = String.Table.create (); seen = 0 }
  in
  restart t;
  t
;;

let step_watcher t (o : obs) ws =
  if ws.stopped
  then None
  else (
    ws.k <- sat (ws.k + 1);
    ws.m.(0) <- sat (ws.m.(0) + 1);
    ws.m.(1) <- sat (ws.m.(1) + 1);
    match ws.guard with
    | Some gs when eval t ws o gs.g ->
      (* body abandoned; the handler runs from the next step, anchor = this step *)
      ws.guard <- None;
      ws.k <- 0;
      (match advance t ws None (List.map gs.handler ~f:(fun s -> S s) @ gs.after) with
       | Next (s, rest) ->
         ws.cur <- Some s;
         ws.cont <- rest;
         None
       | Ended | Fired _ ->
         ws.stopped <- true;
         None)
    | _ ->
      let s = Option.value_exn ws.cur in
      let kappa (w : window) =
        match w.since with
        | None -> ws.k
        | Some a -> ws.m.(a)
      in
      let ev e = eval t ws o e in
      let await_like e_val (w : window) =
        let k = kappa w in
        if e_val && k >= w.lo
        then `Complete
        else if e_val && k < w.lo && Option.is_some w.early
        then `Fire (Option.value_exn w.early)
        else if (not e_val) && k >= w.hi
        then `Fire w.timeout
        else `Stay
      in
      let outcome =
        match s with
        | Await_idle { e; when_ } -> if ev e && ev when_ then `Complete else `Stay
        | Await { e; when_; w } -> await_like (ev e && ev when_) w
        | Hold_for { r; when_; n; check } ->
          if ev when_ && not (ev r) then `Fire check else if ws.k >= n then `Complete else `Stay
        | Hold_until { r; when_; e; w } ->
          let k = kappa w in
          let e_val = ev e && ev when_ in
          if e_val && k >= w.lo
          then `Complete
          else if e_val && k < w.lo && Option.is_some w.early
          then `Fire (Option.value_exn w.early)
          else if ev when_ && not (ev r)
          then `Fire w.timeout
          else if k >= w.hi
          then `Fire w.timeout
          else `Stay
        | Skip n -> if ws.k >= n then `Complete else `Stay
        | Take { s = st; byte; w } ->
          let e_val =
            match st with
            | Tx_pop -> o.inp.pop_ev
            | Rx_push -> o.inp.push_ev
          in
          let r =
            match w with
            | Some w -> await_like e_val w
            | None -> if e_val then `Complete else `Stay
          in
          (match r with
           | `Complete ->
             let d =
               (match st with
                | Tx_pop -> o.inp.pop_data
                | Rx_push -> o.inp.push_data)
               land 0xFF
             in
             ws.reg <- (ws.reg land lnot (0xFF lsl (8 * byte))) lor (d lsl (8 * byte));
             `Complete
           | x -> x)
        | _ -> assert false
      in
      match outcome with
      | `Stay -> None
      | `Fire ck ->
        ws.stopped <- true;
        Some ck
      | `Complete ->
        ws.k <- 0;
        (match advance t ws (Some o) ws.cont with
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

(* One cycle. Returns the firings of this cycle as (role, full code), in watcher order. *)
let step t (i : inputs) =
  if not i.rst_sync_n
  then (
    restart t;
    t.s1_ui <- 0;
    t.s2_ui <- 0;
    t.s1_uio <- 0;
    t.s2_uio <- 0;
    [])
  else (
    let o = make_obs t i in
    let fired =
      if not i.running
      then (
        restart t;
        [])
      else if i.tick
      then (
        let f =
          Array.to_list t.ws
          |> List.filter_map ~f:(fun ws ->
            Option.map (step_watcher t o ws) ~f:(fun (r, c) -> r, ws.w.base + c))
        in
        List.iter t.c.observables ~f:(fun (x, _) ->
          let h = Hashtbl.find t.hist x |> Option.value ~default:[] in
          Hashtbl.set t.hist ~key:x ~data:(List.take (o.value x :: h) 4));
        t.seen <- t.seen + 1;
        f)
      else []
    in
    t.s2_ui <- t.s1_ui;
    t.s1_ui <- i.ui_in;
    t.s2_uio <- t.s1_uio;
    t.s1_uio <- i.uio_in;
    fired)
;;
