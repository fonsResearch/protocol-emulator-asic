(* Compiler: language v1 package (Lang.t) -> monitor ISA v1 package (Mprog.t).
   doc/contracts/monitor_isa_v1.md section 4: instants after a consuming statement fold into
   its completion bundle in the order mark, sample, match, expect, branch. Rejected (with a
   message) when a construct does not fit: predicate shape, table sizes, bundle order, more
   than one guard per watcher, loop bodies not starting with a consuming statement, more than
   126 instructions per unit. *)
open! Core
open Lang
module M = Mprog

exception Reject of string

let reject fmt = ksprintf (fun s -> raise (Reject s)) fmt

(* ---- tables ---- *)
type tables =
  { obs : (string * source) list
  ; mutable preds : M.pred list (* bank entries 1.., in order *)
  ; mutable windows : int list (* entries 1.., entry 0 = 0 *)
  ; mutable codes : (role * int) list (* entries 1.. *)
  }

let index_of l x ~equal =
  List.findi l ~f:(fun _ y -> equal x y) |> Option.map ~f:fst
;;

let window_index t v =
  if v = 0
  then 0
  else (
    match index_of t.windows v ~equal:Int.equal with
    | Some i -> i + 1
    | None ->
      if List.length t.windows >= 7 then reject "window table full (8 entries)";
      t.windows <- t.windows @ [ v ];
      List.length t.windows)
;;

let code_index t (w : watcher) ((r, c) : check) =
  let full = r, w.base + c in
  match index_of t.codes full ~equal:[%equal: role * int] with
  | Some i -> i + 1
  | None ->
    if List.length t.codes >= 15 then reject "code table full (15 entries)";
    t.codes <- t.codes @ [ full ];
    List.length t.codes
;;

let pred_index t (p : M.pred) =
  if M.equal_pred p M.pred_true
  then 0
  else if M.equal_pred p M.pred_false
  then 15
  else (
    match index_of t.preds p ~equal:M.equal_pred with
    | Some i -> i + 1
    | None ->
      if List.length t.preds >= 14 then reject "predicate bank full (14 entries)";
      t.preds <- t.preds @ [ p ];
      List.length t.preds)
;;

(* ---- predicates ---- *)
type nnf =
  | NConst of bool
  | NLit of M.literal
  | NAnd of nnf * nnf
  | NOr of nnf * nnf

let kind_code = function
  | Level -> 0
  | Rise -> 1
  | Fall -> 2
  | Changed -> 3
;;

let rec to_nnf t ~neg = function
  | True -> NConst (not neg)
  | False -> NConst neg
  | Atom { obs; kind; delay } ->
    let i =
      match index_of (List.map t.obs ~f:fst) obs ~equal:String.equal with
      | Some i -> i
      | None -> reject "unknown observable %s" obs
    in
    NLit { obs = i; kind = kind_code kind; delay; neg }
  | Not e -> to_nnf t ~neg:(not neg) e
  | And (a, b) ->
    let a = to_nnf t ~neg a
    and b = to_nnf t ~neg b in
    if neg then NOr (a, b) else NAnd (a, b)
  | Or (a, b) ->
    let a = to_nnf t ~neg a
    and b = to_nnf t ~neg b in
    if neg then NAnd (a, b) else NOr (a, b)
  | Reg_bit _ | Eq_reg _ | Elapsed_ge _ ->
    reject "register or elapsed term inside a predicate (only one top-level modifier)"
;;

let rec simplify = function
  | NAnd (a, b) ->
    (match simplify a, simplify b with
     | NConst false, _ | _, NConst false -> NConst false
     | NConst true, x | x, NConst true -> x
     | a, b -> NAnd (a, b))
  | NOr (a, b) ->
    (match simplify a, simplify b with
     | NConst true, _ | _, NConst true -> NConst true
     | NConst false, x | x, NConst false -> x
     | a, b -> NOr (a, b))
  | x -> x
;;

let rec leaves op = function
  | NAnd (a, b) when Bool.equal op false -> leaves op a @ leaves op b
  | NOr (a, b) when Bool.equal op true -> leaves op a @ leaves op b
  | x -> [ x ]
;;

let pred_of_nnf n : M.pred =
  match simplify n with
  | NConst true -> M.pred_true
  | NConst false -> M.pred_false
  | NLit l -> { l0 = L l; l1 = Const true; l2 = Const true; or1 = false; or2 = false }
  | (NAnd _ | NOr _) as n ->
    let top_or =
      match n with
      | NOr _ -> true
      | _ -> false
    in
    let ls = leaves top_or n in
    let lit = function
      | NLit l -> Some l
      | _ -> None
    in
    (match ls with
     | [ a; b ] when Option.is_some (lit a) && Option.is_some (lit b) ->
       let neutral = M.Const (not top_or) in
       { l0 = L (Option.value_exn (lit a)); l1 = L (Option.value_exn (lit b)); l2 = neutral
       ; or1 = top_or; or2 = top_or }
     | [ a; b; c ] when List.for_all [ a; b; c ] ~f:(fun x -> Option.is_some (lit x)) ->
       { l0 = L (Option.value_exn (lit a)); l1 = L (Option.value_exn (lit b))
       ; l2 = L (Option.value_exn (lit c)); or1 = top_or; or2 = top_or }
     | [ x; y ] ->
       (* one side a literal, the other a two-literal term of the other operator *)
       let inner, single =
         match lit x, lit y with
         | Some _, None -> y, x
         | None, Some _ -> x, y
         | _ -> reject "predicate does not fit (l0 op l1) op l2"
       in
       let inner_or =
         match inner with
         | NOr _ -> true
         | NAnd _ -> false
         | _ -> reject "predicate shape"
       in
       (match leaves inner_or inner with
        | [ a; b ] when Option.is_some (lit a) && Option.is_some (lit b) ->
          { l0 = L (Option.value_exn (lit a)); l1 = L (Option.value_exn (lit b))
          ; l2 = L (Option.value_exn (lit single)); or1 = inner_or; or2 = top_or }
        | _ -> reject "predicate does not fit (l0 op l1) op l2")
     | _ -> reject "predicate has more than 3 literals")
;;

let pred t e = pred_index t (pred_of_nnf (to_nnf t ~neg:false e))

(* requirement predicate with an optional top-level unit-local modifier *)
let pred_mod t e : int * M.modifier =
  match e with
  | Eq_reg (x, b) -> pred t x, Xnor_reg b
  | Reg_bit b -> 0, And_reg b
  | And (x, Reg_bit b) | And (Reg_bit b, x) -> pred t x, And_reg b
  | Elapsed_ge { mark; t = n } -> 0, And_elapsed (mark, window_index t n)
  | And (x, Elapsed_ge { mark; t = n }) | And (Elapsed_ge { mark; t = n }, x) ->
    pred t x, And_elapsed (mark, window_index t n)
  | x -> pred t x, No_mod
;;

(* ---- code generation ---- *)
let blank : M.instr =
  { op = Skip; pe = 0; pr = 0; pcond = 0; md = No_mod; md_pr = false; md_exp = false; lo = 0; hi = 0; since = 0; chk = 0
  ; early = 0; mark = 0; smp = None; mat = None; exp = 0; exp_chk = 0; bp = 0
  ; next = M.stop_addr; alt = M.stop_addr; tsel = 0 }
;;

type wstate =
  { code : M.instr ref Queue.t
  ; stage : int ref Queue.t (* bundle slot last used: 1 mark .. 5 branch *)
  ; mutable open_ : int list
  ; mutable guard : (int * int * int * int) option
  }

let get ws a = Queue.get ws.code a
let stage ws a = Queue.get ws.stage a

let new_instr ws i =
  let a = Queue.length ws.code in
  if a >= M.stop_addr then reject "more than 126 instructions in one unit";
  Queue.enqueue ws.code (ref i);
  Queue.enqueue ws.stage (ref 0);
  List.iter ws.open_ ~f:(fun e -> (get ws e) := { !(get ws e) with next = a });
  ws.open_ <- [ a ];
  a
;;

let fold_instant ws ~slot ~name f =
  if List.is_empty ws.open_ then reject "%s after a statement that never completes" name;
  List.iter ws.open_ ~f:(fun e ->
    if !(stage ws e) >= slot then reject "cannot fold %s: bundle order mark, sample, match, expect, branch" name;
    (get ws e) := f !(get ws e);
    stage ws e := slot)
;;

let set_mod (i : M.instr) md =
  match i.md, md with
  | _, M.No_mod -> i
  | M.No_mod, md -> { i with md }
  | a, b when M.equal_modifier a b -> i
  | _ -> reject "two different register/elapsed modifiers in one instruction"
;;

let rec starts_with_consuming = function
  | (Await_idle _ | Await _ | Hold_for _ | Hold_until _ | Skip _ | Take _) :: _ -> true
  | (Loop b | Guard { body = b; _ }) :: _ -> starts_with_consuming b
  | Repeat (n, b) :: _ -> n > 0 && starts_with_consuming b
  | _ -> false
;;

let window_fields t w (win : window) (i : M.instr) =
  { i with
    lo = window_index t win.lo
  ; hi = window_index t win.hi
  ; since = (match win.since with None -> 0 | Some m -> m + 1)
  ; chk = code_index t w win.timeout
  ; early = (match win.early with None -> 0 | Some ck -> code_index t w ck)
  }
;;

let rec compile_stmts t (w : watcher) ws stmts = List.iter stmts ~f:(compile_stmt t w ws)

and compile_stmt t w ws s =
  match s with
  | Await_idle { e; when_ } ->
    ignore (new_instr ws { blank with op = Await_idle; pe = pred t e; pcond = pred t when_ } : int)
  | Await { e; when_; w = win } ->
    ignore
      (new_instr ws (window_fields t w win { blank with op = Await; pe = pred t e; pcond = pred t when_ })
        : int)
  | Hold_for { r; when_; n; check } ->
    let pr, md = pred_mod t r in
    ignore
      (new_instr
         ws
         { blank with
           op = Hold_for; pr; md; md_pr = not (M.equal_modifier md No_mod); pcond = pred t when_
         ; hi = window_index t n
         ; chk = code_index t w check }
        : int)
  | Hold_until { r; when_; e; w = win } ->
    let pr, md = pred_mod t r in
    ignore
      (new_instr
         ws
         (window_fields t w win
            { blank with
              op = Hold_until; pr; md; md_pr = not (M.equal_modifier md No_mod); pe = pred t e
            ; pcond = pred t when_ })
        : int)
  | Skip n -> ignore (new_instr ws { blank with op = Skip; hi = window_index t n } : int)
  | Take { s = st; byte; w = win } ->
    let op : M.op =
      match st with
      | Tx_pop -> Take_tx
      | Rx_push -> Take_rx
    in
    let i = { blank with op; tsel = byte } in
    let i = match win with None -> i | Some win -> window_fields t w win i in
    ignore (new_instr ws i : int)
  | Mark a -> fold_instant ws ~slot:1 ~name:"mark" (fun i -> { i with mark = a + 1 })
  | Sample { bit; e } ->
    let p = pred t e in
    fold_instant ws ~slot:2 ~name:"sample" (fun i -> { i with smp = Some (bit, p) })
  | Match { check } ->
    let c = code_index t w check in
    fold_instant ws ~slot:3 ~name:"match" (fun i -> { i with mat = Some c })
  | Expect { r; when_; check } ->
    let c = code_index t w check in
    let p, md =
      match when_ with
      | True -> pred_mod t r
      | _ ->
        (match r with
         | Reg_bit _ | Eq_reg _ | Elapsed_ge _ | And _ ->
           (* !when || r must fit a bank predicate; modifiers only without a condition *)
           pred t (Or (Not when_, r)), M.No_mod
         | _ -> pred t (Or (Not when_, r)), M.No_mod)
    in
    (* expect true is a no-op: index 0 means "none" in the bundle *)
    if p = 0 && M.equal_modifier md No_mod
    then ()
    else
      fold_instant ws ~slot:4 ~name:"expect" (fun i ->
        let i = set_mod { i with exp = p; exp_chk = c } md in
        { i with md_exp = not (M.equal_modifier md No_mod) })
  | Raise ck ->
    let c = code_index t w ck in
    fold_instant ws ~slot:4 ~name:"raise" (fun i -> { i with exp = 15; exp_chk = c })
  | If (b, th, el) ->
    let p = pred t b in
    if p = 0
    then compile_stmts t w ws th
    else if p = 15
    then compile_stmts t w ws el
    else (
      let ends = ws.open_ in
      if List.is_empty ends then reject "if after a statement that never completes";
      List.iter ends ~f:(fun e -> if !(stage ws e) >= 5 then reject "two branches in one bundle");
      ws.open_ <- [];
      let entry_t = Queue.length ws.code in
      compile_stmts t w ws th;
      let ends_t = ws.open_ in
      ws.open_ <- [];
      let entry_e = Queue.length ws.code in
      compile_stmts t w ws el;
      let ends_e = ws.open_ in
      List.iter ends ~f:(fun e ->
        (get ws e) := { !(get ws e) with bp = p; alt = entry_t; next = entry_e };
        stage ws e := 5);
      ws.open_ <- ends_t @ ends_e)
  | Loop body ->
    if not (starts_with_consuming body) then reject "loop body must start with a consuming statement";
    let entry = Queue.length ws.code in
    compile_stmts t w ws body;
    List.iter ws.open_ ~f:(fun e -> (get ws e) := { !(get ws e) with next = entry });
    ws.open_ <- []
  | Repeat (n, body) ->
    for _ = 1 to n do
      compile_stmts t w ws body
    done
  | Guard { g; body; handler } ->
    if Option.is_some ws.guard then reject "more than one guard in a watcher";
    let gp = pred t g in
    let gstart = Queue.length ws.code in
    compile_stmts t w ws body;
    let gend = Queue.length ws.code - 1 in
    let ends_body = ws.open_ in
    ws.open_ <- [];
    let hentry = Queue.length ws.code in
    compile_stmts t w ws handler;
    ws.open_ <- ends_body @ ws.open_;
    ws.guard <- Some (gp, gstart, gend, hentry)
;;

let compile_watcher t (w : watcher) : M.unit_prog =
  let ws = { code = Queue.create (); stage = Queue.create (); open_ = []; guard = None } in
  compile_stmts t w ws w.body;
  { start = 0; guard = ws.guard; code = Queue.to_array ws.code |> Array.map ~f:( ! ) }
;;

let compile (c : Lang.t) : (M.t, string) Result.t =
  match validate c with
  | Error es -> Error (String.concat ~sep:"; " es)
  | Ok c ->
    (try
       let t = { obs = c.observables; preds = []; windows = []; codes = [] } in
       let units = Array.of_list_map c.watchers ~f:(compile_watcher t) in
       let remap = Array.create ~len:16 0 in
       List.iteri c.observables ~f:(fun i (_, s) -> remap.(i) <- global_index s);
       let preds =
         Array.init 16 ~f:(fun i ->
           if i = 0
           then M.pred_true
           else if i = 15
           then M.pred_false
           else Option.value (List.nth t.preds (i - 1)) ~default:M.pred_false)
       in
       let windows = Array.init 8 ~f:(fun i -> if i = 0 then 0 else Option.value (List.nth t.windows (i - 1)) ~default:0) in
       let codes = Array.init 16 ~f:(fun i -> if i = 0 then None else List.nth t.codes (i - 1)) in
       Ok { M.name = c.name; remap; preds; windows; codes; units }
     with
     | Reject s -> Error s)
;;

let compile_exn c =
  match compile c with
  | Ok p -> p
  | Error s -> raise_s [%message "compile" c.name s]
;;
