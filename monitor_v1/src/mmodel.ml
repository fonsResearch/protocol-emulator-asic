(* Reference model of the monitor ISA v1 (doc/contracts/monitor_isa_v1.md sections 1-5) for
   one lane's package context and units, executing a compiled package (Mprog.t). Same cycle
   interface as [Interp] so the two can be compared cycle by cycle. *)
open! Core
module M = Mprog

type ustate =
  { mutable pc : int
  ; mutable k : int
  ; m : int array
  ; mutable reg : int
  ; mutable stopped : bool
  }

type t =
  { p : M.t
  ; us : ustate array
  ; mutable s1_ui : int
  ; mutable s2_ui : int
  ; mutable s1_uio : int
  ; mutable s2_uio : int
  ; hist : int array (* per local observable: bits 0..3 = values 1..4 steps earlier *)
  ; mutable seen : int (* saturates at 4 *)
  }

let bit v k = (v lsr k) land 1 = 1
let sat x = Int.min 4095 x

let restart_unit (p : M.t) i u =
  u.pc <- p.units.(i).start;
  u.k <- 0;
  u.m.(0) <- 0;
  u.m.(1) <- 0;
  u.reg <- 0;
  u.stopped <- false
;;

let restart t =
  Array.iteri t.us ~f:(restart_unit t.p);
  Array.fill t.hist ~pos:0 ~len:16 0;
  t.seen <- 0
;;

let create (p : M.t) =
  let us =
    Array.map p.units ~f:(fun _ -> { pc = 0; k = 0; m = [| 0; 0 |]; reg = 0; stopped = false })
  in
  let t = { p; us; s1_ui = 0; s2_ui = 0; s1_uio = 0; s2_uio = 0; hist = Array.create ~len:16 0; seen = 0 } in
  restart t;
  t
;;

let global t (i : Interp.inputs) g =
  if g < 8
  then bit i.uo_out g
  else if g < 16
  then bit i.uio_out (g - 8)
  else if g < 24
  then bit i.uio_oe (g - 16)
  else if g < 32
  then bit t.s2_ui (g - 24)
  else if g < 40
  then bit t.s2_uio (g - 32)
  else if g < 48
  then bit i.uio_oe (g - 40) && not (bit i.uio_out (g - 40))
  else if g = 48
  then i.pop_ev
  else if g = 49
  then i.push_ev
  else false
;;

let eval_pred t (now : bool array) (pr : M.pred) =
  let lit = function
    | M.Const b -> b
    | M.L l ->
      let v d = if d = 0 then now.(l.obs) else t.seen >= d && bit t.hist.(l.obs) (d - 1) in
      let x = v l.delay
      and y = v (l.delay + 1)
      and valid = t.seen >= l.delay + 1 in
      let r =
        match l.kind with
        | 0 -> x
        | 1 -> valid && x && not y
        | 2 -> valid && (not x) && y
        | _ -> valid && Bool.( <> ) x y
      in
      Bool.( <> ) r l.neg
  in
  let op o a b = if o then a || b else a && b in
  op pr.or2 (op pr.or1 (lit pr.l0) (lit pr.l1)) (lit pr.l2)
;;

let step_unit t (i : Interp.inputs) ~(bank : bool array) idx u =
  let p = t.p in
  let up = p.units.(idx) in
  if u.stopped
  then None
  else (
    u.k <- sat (u.k + 1);
    u.m.(0) <- sat (u.m.(0) + 1);
    u.m.(1) <- sat (u.m.(1) + 1);
    let guard_hit =
      match up.guard with
      | Some (g, gs, ge, h) when u.pc >= gs && u.pc <= ge && bank.(g) ->
        u.pc <- h;
        u.k <- 0;
        true
      | _ -> false
    in
    if guard_hit
    then None
    else (
      let ins = up.code.(u.pc) in
      let pb x = bank.(x) in
      let modv () =
        match ins.md with
        | No_mod -> fun v -> v
        | And_reg b -> fun v -> v && bit u.reg b
        | Xnor_reg b -> fun v -> Bool.equal v (bit u.reg b)
        | And_elapsed (m, j) -> fun v -> v && u.m.(m) >= p.windows.(j)
      in
      let kappa = match ins.since with 0 -> u.k | s -> u.m.(s - 1) in
      let lo = p.windows.(ins.lo)
      and hi = p.windows.(ins.hi) in
      let code ix = Option.value_exn p.codes.(ix) in
      let e_val () = pb ins.pe && pb ins.pcond in
      let r_val () =
        (not (pb ins.pcond)) || (if ins.md_pr then modv () (pb ins.pr) else pb ins.pr)
      in
      let await_like ev =
        if ev && kappa >= lo
        then `Complete
        else if ev && kappa < lo && ins.early <> 0
        then `Fire (code ins.early)
        else if (not ev) && kappa >= hi && ins.chk <> 0
        then `Fire (code ins.chk)
        else `Stay
      in
      let outcome =
        match ins.op with
        | Await -> await_like (e_val ())
        | Await_idle -> if e_val () then `Complete else `Stay
        | Hold_for -> if not (r_val ()) then `Fire (code ins.chk) else if u.k >= hi then `Complete else `Stay
        | Hold_until ->
          let ev = e_val () in
          if ev && kappa >= lo
          then `Complete
          else if ev && kappa < lo && ins.early <> 0
          then `Fire (code ins.early)
          else if not (r_val ())
          then `Fire (code ins.chk)
          else if kappa >= hi
          then `Fire (code ins.chk)
          else `Stay
        | Skip -> if u.k >= hi then `Complete else `Stay
        | Take_tx | Take_rx ->
          let ev, d =
            match ins.op with
            | Take_tx -> i.pop_ev, i.pop_data
            | _ -> i.push_ev, i.push_data
          in
          (match await_like ev with
           | `Complete ->
             let sh = 8 * ins.tsel in
             u.reg <- (u.reg land lnot (0xFF lsl sh)) lor ((d land 0xFF) lsl sh);
             `Complete
           | x -> x)
      in
      match outcome with
      | `Stay -> None
      | `Fire ck ->
        u.stopped <- true;
        Some ck
      | `Complete ->
        (* completion bundle: mark, sample, match, expect, successor *)
        if ins.mark <> 0 then u.m.(ins.mark - 1) <- 0;
        Option.iter ins.smp ~f:(fun (b, pr) ->
          u.reg <- (if pb pr then u.reg lor (1 lsl b) else u.reg land lnot (1 lsl b)));
        let fired =
          match ins.mat with
          | Some c when not (i.push_ev && i.push_data land 0xFF = u.reg land 0xFF) -> Some (code c)
          | _ ->
            let ev = if ins.md_exp then modv () (pb ins.exp) else pb ins.exp in
            if (ins.exp <> 0 || ins.md_exp) && not ev then Some (code ins.exp_chk) else None
        in
        (match fired with
         | Some ck ->
           u.stopped <- true;
           Some ck
         | None ->
           u.k <- 0;
           let nxt = if ins.bp <> 0 && pb ins.bp then ins.alt else ins.next in
           if nxt = M.stop_addr then u.stopped <- true else u.pc <- nxt;
           None)))
;;

let step t (i : Interp.inputs) =
  if not i.rst_sync_n
  then (
    restart t;
    t.s1_ui <- 0;
    t.s2_ui <- 0;
    t.s1_uio <- 0;
    t.s2_uio <- 0;
    [])
  else (
    let fired =
      if not i.running
      then (
        restart t;
        [])
      else if i.tick
      then (
        let now = Array.init 16 ~f:(fun k -> global t i t.p.remap.(k)) in
        let bank = Array.map t.p.preds ~f:(eval_pred t now) in
        let f = Array.to_list t.us |> List.filter_mapi ~f:(fun idx u -> step_unit t i ~bank idx u) in
        Array.iteri now ~f:(fun k v -> t.hist.(k) <- ((t.hist.(k) lsl 1) lor Bool.to_int v) land 0xF);
        t.seen <- Int.min 4 (t.seen + 1);
        f)
      else []
    in
    t.s2_ui <- t.s1_ui;
    t.s1_ui <- i.ui_in;
    t.s2_uio <- t.s1_uio;
    t.s1_uio <- i.uio_in;
    fired)
;;
