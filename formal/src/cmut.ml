(* Contract mutants (plan step 9, contract-error tolerance), on the Lang source of the five
   packages with unbounded A2 proofs: uart_tx (ROM 0), uart_rx (1), spi_ctl m0 (2), spi_tgt m0 (3),
   usb_ls_tx (7).

   Operators (per statement, DFS preorder over watchers and nested bodies):
     win_lo_up / win_lo_down / win_hi_up / win_hi_down   window bound +-1 (Await, Hold_until, Take)
     hold_up / hold_down                                Hold_for length +-1
     drop_check   Await -> Await_idle; Hold_until -> Await_idle on its end condition; Hold_for n ->
                  Skip n; Take window -> none; Expect / Match / Raise removed
     role_swap    fail <-> blame on the statement's check (window timeout for windowed statements)
     code_bump    the check's code + 1
     negate       Expect r -> Expect (not r)
   Widening, dropping and fail -> blame weaken a guarantee or an assumption; narrowing and
   negation strengthen. A mutant must still validate, compile and fit 5 slots; others are
   reported INVALID and excluded.

   Oracles: A2-U (the package's U proof with the shipped firmware; kills when it FAILs), A2-N (the
   package's firmware-mutant negatives; kills when one no longer FAILs), SV (Psim directed
   scenarios with peer and firmware faults; kills when any firing differs from the shipped
   contract's). *)
open! Core
module Lang = Pemu_monitor_v1.Lang
module Lib = Pemu_monitor_v1.Library_v1
module P1 = Pemu_spec_v1.Programs_v1

type op =
  | Win_lo_up
  | Win_lo_down
  | Win_hi_up
  | Win_hi_down
  | Hold_up
  | Hold_down
  | Drop_check
  | Role_swap
  | Code_bump
  | Negate
[@@deriving sexp_of, equal, enumerate]

let op_to_string o = Sexp.to_string (sexp_of_op o) |> String.lowercase

type site =
  { index : int
  ; op : op
  ; watcher : string
  ; stmt : string
  }

let stmt_kind : Lang.stmt -> string = function
  | Await _ -> "await" | Await_idle _ -> "await_idle" | Hold_for _ -> "hold_for" | Hold_until _ -> "hold_until"
  | Skip _ -> "skip" | Take _ -> "take" | Expect _ -> "expect" | Sample _ -> "sample" | Match _ -> "match"
  | Mark _ -> "mark" | Raise _ -> "raise" | If _ -> "if" | Loop _ -> "loop" | Repeat _ -> "repeat" | Guard _ -> "guard"
;;

let win_ops (w : Lang.window) =
  [ Win_lo_up ] @ (if w.lo > 0 then [ Win_lo_down ] else []) @ [ Win_hi_up ]
  @ (if w.hi > w.lo then [ Win_hi_down ] else []) @ [ Role_swap; Code_bump ]
;;

let ops_of : Lang.stmt -> op list = function
  | Await { w; _ } | Hold_until { w; _ } | Take { w = Some w; _ } -> win_ops w @ [ Drop_check ]
  | Hold_for { n; _ } -> [ Hold_up ] @ (if n > 1 then [ Hold_down ] else []) @ [ Drop_check; Role_swap; Code_bump ]
  | Expect _ -> [ Drop_check; Role_swap; Code_bump; Negate ]
  | Match _ | Raise _ -> [ Drop_check; Role_swap; Code_bump ]
  | _ -> []
;;

let flip ((r, c) : Lang.check) : Lang.check = (match r with Fail -> Blame | Blame -> Fail), c
let bump ((r, c) : Lang.check) : Lang.check = r, c + 1

let on_window op (w : Lang.window) : Lang.window =
  match op with
  | Win_lo_up -> { w with lo = w.lo + 1 }
  | Win_lo_down -> { w with lo = w.lo - 1 }
  | Win_hi_up -> { w with hi = w.hi + 1 }
  | Win_hi_down -> { w with hi = w.hi - 1 }
  | Role_swap -> { w with timeout = flip w.timeout }
  | Code_bump -> { w with timeout = bump w.timeout }
  | _ -> assert false
;;

(* the statement after the mutation: [] = removed *)
let apply op (s : Lang.stmt) : Lang.stmt list =
  match s, op with
  | Await { e; when_; _ }, Drop_check -> [ Await_idle { e; when_ } ]
  | Await a, _ -> [ Await { a with w = on_window op a.w } ]
  | Hold_until { e; when_; _ }, Drop_check -> [ Await_idle { e; when_ } ]
  | Hold_until h, _ -> [ Hold_until { h with w = on_window op h.w } ]
  | Take t, Drop_check -> [ Take { t with w = None } ]
  | Take ({ w = Some w; _ } as t), _ -> [ Take { t with w = Some (on_window op w) } ]
  | Hold_for h, Hold_up -> [ Hold_for { h with n = h.n + 1 } ]
  | Hold_for h, Hold_down -> [ Hold_for { h with n = h.n - 1 } ]
  | Hold_for h, Drop_check -> [ Skip h.n ]
  | Hold_for h, Role_swap -> [ Hold_for { h with check = flip h.check } ]
  | Hold_for h, Code_bump -> [ Hold_for { h with check = bump h.check } ]
  | (Expect _ | Match _ | Raise _), Drop_check -> []
  | Expect x, Role_swap -> [ Expect { x with check = flip x.check } ]
  | Expect x, Code_bump -> [ Expect { x with check = bump x.check } ]
  | Expect x, Negate -> [ Expect { x with r = Not x.r } ]
  | Match { check }, Role_swap -> [ Match { check = flip check } ]
  | Match { check }, Code_bump -> [ Match { check = bump check } ]
  | Raise c, Role_swap -> [ Raise (flip c) ]
  | Raise c, Code_bump -> [ Raise (bump c) ]
  | _ -> raise_s [%message "Cmut.apply: operator not applicable" (op : op) (stmt_kind s)]
;;

(* one traversal for both enumeration and application: [target] = site index to mutate *)
let traverse ?target (c : Lang.t) =
  let n = ref 0 and sites = ref [] in
  let rec stmts wname l = List.concat_map l ~f:(stmt wname)
  and stmt wname s =
    let mine = List.map (ops_of s) ~f:(fun op -> let i = !n in incr n; i, op) in
    List.iter mine ~f:(fun (index, op) -> sites := { index; op; watcher = wname; stmt = stmt_kind s } :: !sites);
    let s' : Lang.stmt =
      match s with
      | If (e, a, b) -> let a = stmts wname a in If (e, a, stmts wname b)
      | Loop b -> Loop (stmts wname b)
      | Repeat (k, b) -> Repeat (k, stmts wname b)
      | Guard { g; body; handler } -> let body = stmts wname body in Guard { g; body; handler = stmts wname handler }
      | s -> s
    in
    match List.find mine ~f:(fun (i, _) -> [%equal: int option] (Some i) target) with
    | Some (_, op) -> apply op s'
    | None -> [ s' ]
  in
  let watchers = List.map c.watchers ~f:(fun w -> { w with body = stmts w.wname w.body }) in
  { c with watchers }, List.rev !sites
;;

let sites c = snd (traverse c)
let mutant c i = fst (traverse ~target:i c)

(* ---- packages ---- *)
type pkg =
  { pname : string
  ; rom : int
  ; contract : Lang.t
  ; u : name:string -> contract:Lang.t -> Hardcaml.Circuit.t
  ; negs : (string * (name:string -> contract:Lang.t -> Hardcaml.Circuit.t)) list
  }

let packages () =
  let tx ?(prog = P1.uart_tx ~d:4) ~name ~contract () =
    Ag_pkg.harness ~mode:`U ~prog ~contract ~own:1 ~od:0 ~cfg:0 ~cfg2:0 ~name ()
  and rx ?(prog = P1.uart_rx ~d:8 ~pin:1) ~name ~contract () =
    Ag_pkg.harness ~rx_never_full:true ~mode:`U ~prog ~contract ~own:0 ~od:0 ~cfg:0 ~cfg2:0 ~name ()
  and ctl ?(prog = P1.spi_ctl ~cpol:false ~cpha:false) ~name ~contract () =
    Ag_pkg.harness ~rx_never_full:true ~mode:`U ~prog ~contract ~own:P1.spi_own_ctl ~od:0 ~cfg:P1.spi_cfg_ctl
      ~cfg2:P1.spi_cfg2_ctl ~name ()
  and tgt ?(prog = P1.spi_tgt ~cpol:false ~cpha:false) ~name ~contract () =
    Ag_pkg.harness ~rx_never_full:true ~pop_pcs:[ 2 ] ~mode:`U ~prog ~contract ~own:P1.spi_own_tgt ~od:0 ~cfg:0
      ~cfg2:0 ~name ()
  and usb ?(prog = P1.usb_ls_tx) ~name ~contract () =
    Ag_pkg.harness ~rx_never_full:true ~mode:`U ~prog ~contract ~own:P1.usb_own ~od:0 ~cfg:P1.usb_cfg ~cfg2:0
      ~name ()
  in
  [ { pname = "uart_tx"; rom = 0; contract = Lib.uart_tx ~d:4 ~pin:0; u = (fun ~name ~contract -> tx ~name ~contract ())
    ; negs = [ "badstart", fun ~name ~contract -> tx ~prog:(P1.uart_tx_bad_start ~d:4) ~name ~contract () ] }
  ; { pname = "uart_rx"; rom = 1; contract = Lib.uart_rx ~d:8 ~m:2 ~pin:1; u = (fun ~name ~contract -> rx ~name ~contract ())
    ; negs = [ "late", fun ~name ~contract -> rx ~prog:Ag_pkg.uart_rx_late_mutant ~name ~contract () ] }
  ; { pname = "spi_ctl"; rom = 2; contract = Lib.spi_ctl ~cpol:false ~cpha:false ~h:2
    ; u = (fun ~name ~contract -> ctl ~name ~contract ())
    ; negs = [ "lsbin", fun ~name ~contract -> ctl ~prog:(Ag_pkg.spi_ctl_lsbin ~cpol:false ~cpha:false) ~name ~contract () ] }
  ; { pname = "spi_tgt"; rom = 3; contract = Lib.spi_tgt ~cpol:false ~cpha:false ~h_min:3 ~g:6
    ; u = (fun ~name ~contract -> tgt ~name ~contract ())
    ; negs = [ "nomov", fun ~name ~contract -> tgt ~prog:(Ag_pkg.spi_tgt_nomov ~cpol:false ~cpha:false) ~name ~contract () ] }
  ; { pname = "usb"; rom = 7; contract = Lib.usb_ls_tx (); u = (fun ~name ~contract -> usb ~name ~contract ())
    ; negs =
        [ ("sync", fun ~name ~contract -> usb ~prog:(Ag_pkg.usb_mut ~from:(Ldi (L Sr, 0x80)) ~to_:(Ldi (L Sr, 0x81))) ~name ~contract ())
        ; ("nopush", fun ~name ~contract -> usb ~prog:(Ag_pkg.usb_mut ~from:(Push R3) ~to_:Nop) ~name ~contract ())
        ] }
  ]
;;

let pkg_by name = List.find_exn (packages ()) ~f:(fun p -> String.equal p.pname name)

(* INVALID reason, if any *)
let invalid (c : Lang.t) =
  match Lang.validate c with
  | Error es -> Some ("validate: " ^ String.concat ~sep:"; " es)
  | Ok _ ->
    (match Pemu_monitor_v1.Compile.compile c with
     | Error e -> Some ("compile: " ^ e)
     | Ok m -> if Array.length m.units > 5 then Some "more than 5 units" else None)
;;

(* harness names m2c_<pkg>_<index>__<u|neg> (replay via Registry.find) *)
let harness_name p i h = sprintf "m2c_%s_%d__%s" p.pname i h

let harnesses p i =
  let contract = mutant p.contract i in
  ("A2U", harness_name p i "u", fun () -> p.u ~name:(harness_name p i "u") ~contract)
  :: List.map p.negs ~f:(fun (n, f) -> "A2N", harness_name p i n, fun () -> f ~name:(harness_name p i n) ~contract)
;;

let find name =
  match String.chop_prefix name ~prefix:"m2c_" with
  | None -> failwithf "Cmut.find: %s" name ()
  | Some rest ->
    let k = Option.value_exn (String.substr_index rest ~pattern:"__") in
    let pi = String.prefix rest k and h = String.drop_prefix rest (k + 2) in
    let pn, i = Option.value_exn (String.rsplit2 pi ~on:'_') in
    let p = pkg_by pn in
    let _, _, build = List.find_exn (harnesses p (Int.of_string i)) ~f:(fun (_, n, _) -> String.equal n name) in
    ignore h;
    build ()
;;
