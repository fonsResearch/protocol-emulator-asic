(* Check-witness obligation (plan step 9 follow-up, user decision 2026-11-10; log/witness_v2.md).

   For every distinct check (role, code) of every shipped ROM package (Rom_lib.v2_inc5, 8
   packages), one harness w2_<pkg>_<F|B><code> whose bad signal is "the monitor reports this check
   as part of its first verdict, with the package's environment assumptions holding so far"
   (Ag_pkg `Cover mode):
     blame checks: the shipped firmware on the spec lane, free peer (uio_in) and host streams;
                   a witness is a peer behaviour the contract blames with this code;
     fail checks:  free chip outputs (Ag_pkg ~free_chip), free peer; a witness is a chip
                   behaviour the contract reports with this code (the shipped firmware cannot
                   produce one: its U proof says no fail without an earlier blame).
   FAIL with a replayed counterexample = the check is witnessed (it can fire, and the trace shows
   how). PASS = the check can never fire first: a dead check. *)
open! Core
module Lang = Pemu_monitor_v1.Lang
module Lib = Pemu_monitor_v1.Library_v1
module P1 = Pemu_spec_v1.Programs_v1

type pkg =
  { pname : string
  ; rom : int
  ; contract : Lang.t
  ; harness : debug:bool option -> mode:[ `Cover of Lang.role * int ] -> free_chip:bool -> name:string -> Hardcaml.Circuit.t
  }

let packages () =
  let h ?rx_never_full ?pop_pcs ?od_wired ?i2c_env ~prog ~contract ~own ~od ~cfg ~cfg2 () ~debug ~mode ~free_chip ~name =
    let mode = match mode with `Cover rc -> `Cover rc in
    Ag_pkg.harness ?debug ?rx_never_full ?pop_pcs ?od_wired ?i2c_env ~free_chip ~mode ~prog ~contract ~own ~od ~cfg
      ~cfg2 ~name ()
  in
  let p pname rom contract harness = { pname; rom; contract; harness } in
  let ictl (l, hh, tsu, thold) =
    let contract = Lib.i2c_ctl ~l ~h:hh ~tsu ~thold in
    contract
    , h ~rx_never_full:true ~od_wired:P1.i2c_own ~prog:(P1.i2c_ctl ~l ~h:hh ~tsu ~thold) ~contract ~own:P1.i2c_own
        ~od:P1.i2c_od ~cfg:0 ~cfg2:0 ()
  in
  let fm_c, fm_h = ictl (6, 4, 3, 6)
  and sm_c, sm_h = ictl (5, 5, 5, 5) in
  let tgt_c = Lib.i2c_tgt ~h_min:19 ~l_min:22 ~hd:19 in
  let c0 = Lib.uart_tx ~d:4 ~pin:0
  and c1 = Lib.uart_rx ~d:8 ~m:2 ~pin:1
  and c2 = Lib.spi_ctl ~cpol:false ~cpha:false ~h:2
  and c3 = Lib.spi_tgt ~cpol:false ~cpha:false ~h_min:3 ~g:6
  and c7 = Lib.usb_ls_tx () in
  [ p "uart_tx" 0 c0 (h ~prog:(P1.uart_tx ~d:4) ~contract:c0 ~own:1 ~od:0 ~cfg:0 ~cfg2:0 ())
  ; p "uart_rx" 1 c1 (h ~rx_never_full:true ~prog:(P1.uart_rx ~d:8 ~pin:1) ~contract:c1 ~own:0 ~od:0 ~cfg:0 ~cfg2:0 ())
  ; p "spi_ctl" 2 c2
      (h ~rx_never_full:true ~prog:(P1.spi_ctl ~cpol:false ~cpha:false) ~contract:c2 ~own:P1.spi_own_ctl ~od:0
         ~cfg:P1.spi_cfg_ctl ~cfg2:P1.spi_cfg2_ctl ())
  ; p "spi_tgt" 3 c3
      (h ~rx_never_full:true ~pop_pcs:[ 2 ] ~prog:(P1.spi_tgt ~cpol:false ~cpha:false) ~contract:c3
         ~own:P1.spi_own_tgt ~od:0 ~cfg:0 ~cfg2:0 ())
  ; p "i2c_ctl_fm" 4 fm_c fm_h
  ; p "i2c_ctl_sm" 5 sm_c sm_h
  ; p "i2c_tgt" 6 tgt_c
      (h ~rx_never_full:true ~pop_pcs:[ 2 ] ~od_wired:P1.i2c_own ~i2c_env:(19, 2, 3) ~prog:(P1.i2c_tgt ~addr:0x50)
         ~contract:tgt_c ~own:P1.i2c_own ~od:P1.i2c_od ~cfg:0 ~cfg2:0 ())
  ; p "usb" 7 c7
      (h ~rx_never_full:true ~prog:P1.usb_ls_tx ~contract:c7 ~own:P1.usb_own ~od:0 ~cfg:P1.usb_cfg ~cfg2:0 ())
  ]
;;

(* the harness contracts must be the taped-out ones *)
let check_against_rom () =
  let rom = Pemu_rtl_v1.Rom_lib.v2_inc5 () in
  List.iter (packages ()) ~f:(fun p ->
    if not (Poly.equal p.contract (List.nth_exn rom p.rom))
    then failwithf "witness_v2: %s differs from ROM package %d" p.pname p.rom ())
;;

(* every check of a contract: (watcher, statement kind, (role, global code)); global code =
   watcher base + local code, as reported in the verdict *)
let checks (c : Lang.t) =
  let out = ref [] in
  List.iter c.watchers ~f:(fun w ->
    let add s ((r, k) : Lang.check) = out := (w.wname, s, (r, w.base + k)) :: !out in
    let win s (x : Lang.window) =
      add s x.timeout;
      Option.iter x.early ~f:(add (s ^ ".early"))
    in
    let rec go (l : Lang.stmt list) =
      List.iter l ~f:(fun (st : Lang.stmt) ->
        let k = Cmut.stmt_kind st in
        match st with
        | Await { w = x; _ } | Hold_until { w = x; _ } | Take { w = Some x; _ } -> win k x
        | Hold_for { check; _ } | Expect { check; _ } | Match { check } -> add k check
        | Raise ch -> add k ch
        | If (_, a, b) -> go a; go b
        | Loop b | Repeat (_, b) -> go b
        | Guard { body; handler; _ } -> go body; go handler
        | _ -> ())
    in
    go w.body);
  List.rev !out
;;

let distinct c =
  List.dedup_and_sort (List.map (checks c) ~f:(fun (_, _, ch) -> ch)) ~compare:[%compare: Lang.role * int]
;;

let role_char : Lang.role -> string = function Fail -> "F" | Blame -> "B"
let name p ((r, c) : Lang.check) = sprintf "w2_%s_%s%02X" p.pname (role_char r) c

let all_names () =
  List.concat_map (packages ()) ~f:(fun p -> List.map (distinct p.contract) ~f:(fun ch -> p, ch, name p ch))
;;

let build ?debug p ((r, c) as ch : Lang.check) =
  p.harness ~debug ~mode:(`Cover (r, c)) ~free_chip:(match r with Fail -> true | Blame -> false) ~name:(name p ch)
;;

let find ?debug nm =
  match List.find (all_names ()) ~f:(fun (_, _, n) -> String.equal n nm) with
  | Some (p, ch, _) -> build ?debug p ch
  | None -> failwithf "witness_v2: unknown harness %s" nm ()
;;
