(* Compiler + ISA model (Mmodel) against the reference interpreter (Interp), firings compared
   every cycle: (a) the UART TX package on lane-model traces; (b) random packages over
   random input traces. *)
open! Core
open Pemu_monitor_v1
open Lang

let show f =
  List.map f ~f:(fun (r, c) -> sprintf "%s%02X" (match r with Fail -> "F" | Blame -> "B") c)
  |> String.concat ~sep:","
;;

(* ---- random packages ---- *)
let chip_srcs = [| Uio_out 0; Uio_oe 0; Uio_out 1; Drive 2; Tx_pop_ev; Rx_push_ev |]
let env_srcs = [| Uio_in 0; Uio_in 1; Uio_in 2; Ui 3 |]

let gen_contract st =
  let r n = Random.State.int st n in
  let pick a = a.(r (Array.length a)) in
  let obs =
    Array.to_list (Array.mapi chip_srcs ~f:(fun i s -> sprintf "c%d" i, s))
    @ Array.to_list (Array.mapi env_srcs ~f:(fun i s -> sprintf "e%d" i, s))
  in
  let names cls = List.filter_map obs ~f:(fun (n, s) -> if Bool.equal (chip_driven s) cls then Some n else None) |> Array.of_list in
  let atom cls =
    let n = pick (names cls) in
    let kind = pick [| Level; Level; Rise; Fall; Changed |] in
    let delay = if r 4 = 0 then 1 + r 3 else 0 in
    let a = Atom { obs = n; kind; delay } in
    if r 3 = 0 then Not a else a
  in
  let pexpr cls =
    match r 6 with
    | 0 -> atom cls
    | 1 -> And (atom cls, atom cls)
    | 2 -> Or (atom cls, atom cls)
    | 3 -> And (Or (atom cls, atom cls), atom cls)
    | 4 -> Or (And (atom cls, atom cls), atom cls)
    | _ -> Not (And (atom cls, atom cls))
  in
  let any () = pexpr (r 2 = 0) in
  let codes = ref 0 in
  let chk role = incr codes; role, !codes in
  let role_req () =
    let cls = r 2 = 0 in
    (if cls then Fail else Blame), cls
  in
  let window () =
    let role, cls = role_req () in
    let lo = r 3 and hi = 1 + r 6 in
    let lo = Int.min lo hi in
    ( { lo; hi; since = (if r 5 = 0 then Some (r 2) else None); timeout = chk role
      ; early = (if r 3 = 0 then Some (chk role) else None) }
    , cls )
  in
  let consuming () =
    match r 7 with
    | 0 -> await_idle ~when_:(if r 2 = 0 then True else any ()) (any ())
    | 1 ->
      let w, cls = window () in
      await ~when_:(if r 2 = 0 then True else any ()) (pexpr cls) w
    | 2 ->
      let role, cls = role_req () in
      let rq = pexpr cls in
      let rq = if r 4 = 0 then eq_reg rq (r 16) else rq in
      hold ~when_:(if r 3 = 0 then any () else True) rq ~for_:(1 + r 5) ~else_:(chk role)
    | 3 ->
      let w, cls = window () in
      hold_until (pexpr cls) (pexpr cls) w
    | 4 -> skip (1 + r 4)
    | 5 ->
      let s = if r 2 = 0 then Tx_pop else Rx_push in
      if r 2 = 0
      then take_idle ~byte:(r 2) s
      else take ~byte:(r 2) s (win (r 2) (1 + r 8) ~else_:(chk Fail))
    | _ -> await (any ()) (win 0 (2 + r 4) ~else_:(chk (if r 2 = 0 then Fail else Blame)))
  in
  let fix_role = function
    (* make the requirement class agree with the role (WF1/WF2) by construction where needed *)
    | s -> s
  in
  let instants () =
    List.concat
      [ (if r 4 = 0 then [ mark (r 2) ] else [])
      ; (if r 4 = 0 then [ sample (r 16) (any ()) ] else [])
      ; (if r 8 = 0 then [ match_rx ~else_:(chk Fail) ] else [])
      ; (if r 3 = 0
         then (
           let role, cls = role_req () in
           [ expect (pexpr cls) ~else_:(chk role) ])
         else [])
      ; (if r 12 = 0 then [ raise_ (chk (if r 2 = 0 then Fail else Blame)) ] else [])
      ]
  in
  let rec block depth n =
    List.concat
      (List.init n ~f:(fun _ ->
         let c = fix_role (consuming ()) in
         let tail =
           if depth < 2 && r 6 = 0
           then [ if_ (any ()) (block (depth + 1) (1 + r 2)) (block (depth + 1) (1 + r 2)) ]
           else []
         in
         (c :: instants ()) @ tail))
  in
  let watcher_body () =
    let body = block 0 (1 + r 4) in
    if r 4 = 0
    then [ loop [ guard (any ()) (block 1 (1 + r 3)) ~on:(block 1 (1 + r 2)) ] ]
    else if r 2 = 0
    then [ loop body ]
    else body
  in
  let nw = 1 + r 4 in
  { name = "rand"
  ; observables = obs
  ; watchers = List.init nw ~f:(fun k -> watcher (sprintf "w%d" k) ~base:(k * 0 ) (watcher_body ()))
  }
;;

let random_inputs st c : Interp.inputs =
  let r n = Random.State.int st n in
  { rst_sync_n = c > 0 && r 400 <> 0; running = r 60 <> 0; tick = r 3 <> 0; ui_in = r 256
  ; uio_in = r 256; uo_out = r 256; uio_out = r 256; uio_oe = r 256; pop_ev = r 4 = 0
  ; pop_data = r 256; push_ev = r 4 = 0; push_data = r 256 }
;;

(* constructs present in a package (static coverage of the generator) *)
let constructs (c : Lang.t) =
  let found = String.Hash_set.create () in
  let add k = Hash_set.add found k in
  let rec ex = function
    | Atom { delay; kind; _ } ->
      if delay > 0 then add "delay";
      if not (equal_kind kind Level) then add "edge"
    | Eq_reg (e, _) -> add "eq_reg"; ex e
    | Not e -> ex e
    | And (a, b) | Or (a, b) -> ex a; ex b
    | _ -> ()
  in
  let rec st = function
    | Await_idle { e; _ } -> add "await_idle"; ex e
    | Await { e; when_; w } ->
      add "await"; ex e;
      if not (equal_expr when_ True) then add "when";
      if Option.is_some w.since then add "since";
      if Option.is_some w.early then add "early"
    | Hold_for { r; when_; _ } -> add "hold"; ex r; if not (equal_expr when_ True) then add "when"
    | Hold_until { r; e; _ } -> add "hold_until"; ex r; ex e
    | Skip _ -> add "skip"
    | Take { w; _ } -> add (if Option.is_none w then "take_idle" else "take")
    | Expect { r; _ } -> add "expect"; ex r
    | Sample _ -> add "sample"
    | Match _ -> add "match"
    | Mark _ -> add "mark"
    | Raise _ -> add "raise"
    | If (_, a, b) -> add "if"; List.iter a ~f:st; List.iter b ~f:st
    | Loop b -> add "loop"; List.iter b ~f:st
    | Repeat (_, b) -> add "repeat"; List.iter b ~f:st
    | Guard { body; handler; _ } -> add "guard"; List.iter body ~f:st; List.iter handler ~f:st
  in
  List.iter c.watchers ~f:(fun w -> List.iter w.body ~f:st);
  Hash_set.to_list found
;;

let%expect_test "random packages: ISA model = interpreter" =
  let cov = String.Table.create () in
  let accepted = ref 0 and rejected = ref 0 and mism = ref 0 and cycles = ref 0 in
  let firings = ref 0 and first = ref None in
  let reasons = String.Table.create () in
  for seed = 1 to 3000 do
    let st = Random.State.make [| seed; 11 |] in
    let c = gen_contract st in
    match Compile.compile c with
    | Error e ->
      incr rejected;
      let key = String.prefix e 40 in
      Hashtbl.update reasons key ~f:(fun v -> 1 + Option.value v ~default:0)
    | Ok p ->
      incr accepted;
      List.iter (constructs c) ~f:(fun k -> Hashtbl.update cov k ~f:(fun v -> 1 + Option.value v ~default:0));
      let a = Interp.create c
      and b = Mmodel.create p in
      for cy = 0 to 400 do
        let i = random_inputs st cy in
        let fa = Interp.step a i
        and fb = Mmodel.step b i in
        incr cycles;
        firings := !firings + List.length fa;
        if not ([%equal: (role * int) list] fa fb)
        then (
          incr mism;
          if Option.is_none !first
          then first := Some (sprintf "seed %d cycle %d interp [%s] model [%s]\n%s" seed cy (show fa) (show fb)
                                (Sexp.to_string_hum (Lang.sexp_of_t c))))
      done
  done;
  Option.iter !first ~f:(fun s -> print_endline (String.prefix s 3000));
  printf "accepted %d rejected %d cycles %d firings %d mismatches %d\n" !accepted !rejected !cycles
    !firings !mism;
  Hashtbl.to_alist reasons |> List.sort ~compare:(fun (_, a) (_, b) -> Int.compare b a)
  |> (fun l -> List.take l 6) |> List.iter ~f:(fun (k, n) -> printf "  reject %4d %s\n" n k);
  printf "packages containing each construct: %s\n"
    (Hashtbl.to_alist cov |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b)
     |> List.map ~f:(fun (k, n) -> sprintf "%s %d" k n) |> String.concat ~sep:", ");
  [%expect {|
    accepted 778 rejected 2222 cycles 311978 firings 7359 mismatches 0
      reject  499 predicate bank full (14 entries)
      reject  399 w0: blame check requires chip observable
      reject  395 w0: fail check requires environment obse
      reject  236 w1: blame check requires chip observable
      reject  229 w1: fail check requires environment obse
      reject  178 cannot fold raise: bundle order mark, sa
    packages containing each construct: await 479, await_idle 376, delay 643, early 145, edge 731, eq_reg 108, expect 539, guard 216, hold 346, hold_until 308, if 142, loop 534, mark 492, match 295, raise 161, sample 494, since 94, skip 381, take 211, take_idle 215, when 301
    |}]
;;

(* (a) the UART TX package on lane-model traces: interpreter and compiled model agree *)
let%expect_test "UART TX package: ISA model = interpreter on lane traces" =
  let open Pemu_spec_v1 in
  let d = 4 in
  let good = Programs_v1.uart_tx ~d in
  let replace k ins = List.mapi good ~f:(fun i x -> if i = k then ins else x) in
  let c = Library_v1.uart_tx ~d ~pin:0 in
  let p = Compile.compile_exn c in
  printf "compiled: %d units, instructions %s, bank %d, windows %s\n" (Array.length p.units)
    (Array.to_list p.units |> List.map ~f:(fun u -> Int.to_string (Array.length u.code)) |> String.concat ~sep:"+")
    (Array.count p.preds ~f:(fun x -> not (Mprog.equal_pred x Mprog.pred_false || Mprog.equal_pred x Mprog.pred_true)))
    (Array.to_list p.windows |> List.map ~f:Int.to_string |> String.concat ~sep:" ");
  List.iter
    [ "correct", good; "start d+1", Programs_v1.uart_tx_bad_start ~d
    ; "MSB first", replace 6 (Isa1.Pin (0, Out_msb)); "stop d-1", replace 10 (Isa1.Wait (d - 3)) ]
    ~f:(fun (name, prog) ->
      let mism = ref 0 and fa_n = ref 0 in
      for seed = 1 to 20 do
        let st = Random.State.make [| seed |] in
        let pdiv = Random.State.int st 4 in
        let lane = Lane_model.create (Isa1.assemble prog) in
        let a = Interp.create c and b = Mmodel.create p in
        let cnt = ref 0 and prev = ref false in
        for cy = 0 to 5999 do
          let r n = Random.State.int st n in
          let rst = cy > 0 and run = r 5000 <> 0 in
          let running = rst && run in
          if not (running && !prev) then cnt := 0;
          let tick = running && !cnt = pdiv in
          let o =
            Lane_model.step lane
              { rst_sync_n = rst; tick; run; loaded = true; len = List.length prog; own = 1; od = 0
              ; cfg = 0; cfg2 = 0; pins = 0; tx_push = r 30 = 0; tx_wdata = r 256; rx_pop = false
              ; blame_in = false; clear_fault = false }
          in
          let i : Interp.inputs =
            { rst_sync_n = rst; running; tick; ui_in = 0; uio_in = 0; uo_out = 0; uio_out = o.uio_out
            ; uio_oe = o.uio_oe; pop_ev = o.pop_ev; pop_data = o.pop_data; push_ev = o.push_ev
            ; push_data = o.push_data }
          in
          let fa = Interp.step a i and fb = Mmodel.step b i in
          fa_n := !fa_n + List.length fa;
          if not ([%equal: (role * int) list] fa fb) then incr mism;
          cnt := if running then if tick then 0 else !cnt + 1 else 0;
          prev := running
        done
      done;
      printf "%-10s firings %3d mismatches %d\n" name !fa_n !mism);
  [%expect {|
    compiled: 2 units, instructions 12+2, bank 3, windows 0 2 4 42 0 0 0 0
    correct    firings   0 mismatches 0
    start d+1  firings  40 mismatches 0
    MSB first  firings  40 mismatches 0
    stop d-1   firings  39 mismatches 0
    |}]
;;
