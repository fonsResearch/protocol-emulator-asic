(* Formal oracles of the v2 mutation campaign (plan step 9), per mutated unit. Each harness is
   one of the project's proof harnesses, built with the mutation active (hooks in A1_lane,
   Ag_pkg and Mon_ref). Circuit names: m2_<unit>_<index>__<base>, index "id" = identity copy.

   unit       oracle  harnesses (engine)
   lane_rtl   A1      a1_lane_fetch (L1), a1_lane_dp (L2)                       dprove
   lane_spec  A1      a1_lane_dp (L2), a1_lane_spec_indep (L3, mutant in both copies) dprove
              A2      a2_uart_tx_d4_u, a2_spi_ctl_m0_u (package U proofs)       dprove
   mon_lane   R1      r1v2p_s5_u0 .. u4 (shipped 5 slots, pipelined, ticks >= 6 apart),
                      canonical scope (own front end, no only_unit)             ind *)
open! Core
open Hardcaml
module P1 = Pemu_spec_v1.Programs_v1
module Lib = Pemu_monitor_v1.Library_v1

type t =
  { oracle : string
  ; base : string
  ; engine : string
  ; build : ?debug:bool -> name:string -> unit -> Circuit.t
  }

let a1 base f = { oracle = "A1"; base; engine = "dprove"; build = (fun ?debug ~name () -> f ?debug ~name ()) }

let a2_uart_tx =
  { oracle = "A2"; base = "a2_uart_tx_d4_u"; engine = "dprove"
  ; build =
      (fun ?debug ~name () ->
        Ag_pkg.harness ?debug ~mode:`U ~prog:(P1.uart_tx ~d:4) ~contract:(Lib.uart_tx ~d:4 ~pin:0) ~own:1 ~od:0
          ~cfg:0 ~cfg2:0 ~name ())
  }
;;

let a2_spi_ctl =
  { oracle = "A2"; base = "a2_spi_ctl_m0_u"; engine = "dprove"
  ; build =
      (fun ?debug ~name () ->
        Ag_pkg.harness ?debug ~rx_never_full:true ~mode:`U ~prog:(P1.spi_ctl ~cpol:false ~cpha:false)
          ~contract:(Lib.spi_ctl ~cpol:false ~cpha:false ~h:2) ~own:P1.spi_own_ctl ~od:0 ~cfg:P1.spi_cfg_ctl
          ~cfg2:P1.spi_cfg2_ctl ~name ())
  }
;;

(* R1 on mutants is bounded (R1b): the canonical scope gives the lane its own front end, which
   the shipped R1 invariants do not cover (k-induction is undecided on the identity copy), so the
   claim alone is checked by BMC from reset (engine bmc, BMC_F frames, set by the runner). *)
let r1 j =
  { oracle = "R1b"; base = sprintf "r1v2p_s5_u%d" j; engine = "bmc"
  ; build =
      (fun ?debug ~name () -> Mon_ref.harness ?debug ~claim_only:true ~slots:5 ~pipe:true ~spacing:6 ~j ~name ())
  }
;;

(* Survivor triage (not a kill oracle): the mutant monitor lane against the unmutated one, same
   inputs, same package tables and present bits (free constants: registers free_* with a free
   initial value, never written), same fetched word (free input each cycle). bad = any output or
   fetch argument differs. PASS = the mutant is sequentially equivalent to the shipped lane for
   every package and every input sequence from reset, i.e. an equivalent mutant. *)
(* [group]: which outputs are compared: "all" (every output and the fetch arguments), "fire"
   (fire, unit, role, code), "overrun", "busy", "pcs" (act, pc6, pc7, pcs, fetch arguments) *)
let eq_mon ?debug ?(group = "all") ?(spacing = 0) ~index ~name () =
  let open Signal in
  let module S = Pemu_monitor_v1.Mon_spec in
  let module L = Pemu_monitor_v1.Mon_lane in
  let module M = Pemu_monitor_v1.Mprog in
  let clock = input "clock" 1 in
  let gs = Reg_spec.create ~clock () in
  let started = reg gs vdd -- "env_started" in
  let i =
    S.I.map2 S.I.port_names S.I.port_widths ~f:(fun n w ->
      if String.equal n "clock" then clock else input ("in_" ^ n) w)
  in
  let i = { i with S.I.rst_sync_n = i.rst_sync_n &: started } in
  let k = ref 0 in
  let const w =
    incr k;
    let d = wire w in
    let q = reg gs d -- Printf.sprintf "free_tab_%d" !k in
    d <== q;
    q
  in
  let tables : S.tables =
    { remap = Array.init 16 ~f:(fun _ -> const 6)
    ; preds = Array.init 16 ~f:(fun _ -> const M.pred_width)
    ; windows = Array.init 8 ~f:(fun _ -> const 12)
    ; code_role = Array.init 16 ~f:(fun _ -> const 1)
    ; code_val = Array.init 16 ~f:(fun _ -> const 8)
    ; starts = Array.init S.n_units ~f:(fun _ -> const 7)
    ; guards = Array.init S.n_units ~f:(fun _ -> const 1, const 4, const 7, const 7, const 7)
    ; present = Array.init S.n_units ~f:(fun _ -> true)
    }
  in
  let present = Array.init S.n_units ~f:(fun _ -> const 1) in
  let w = input "free_word" M.instr_width in
  let args = ref [] in
  let fetch cur pc =
    args := cur :: pc :: !args;
    w
  in
  let a = L.create ~slots:5 ~pipe:true ~tables ~present ~fetch i in
  let b = Mutate_v2.mon_lane ~index ~slots:5 ~pipe:true ~tables ~present ~fetch i in
  let pick (o : _ L.O.t) =
    match group with
    | "fire" -> [ o.fire; o.unit_; o.role; o.code ]
    | "overrun" -> [ o.overrun ]
    | "busy" -> [ o.busy ]
    | "pcs" -> [ o.act; o.pc6; o.pc7 ] @ o.pcs
    | _ -> L.O.to_list o
  in
  let diffs = List.map2_exn (pick a) (pick b) ~f:( <>: ) in
  let fa = List.rev !args in
  let arg_diff =
    match fa with [ c1; p1; c2; p2 ] -> [ c1 <>: c2; p1 <>: p2 ] | _ -> failwith "eq_mon: fetch calls"
  in
  let arg_diff = if String.equal group "all" || String.equal group "pcs" then arg_diff else [] in
  (* [spacing] > 0: the monitor's environment assumption (shipped: P >= 5 admission, so running
     steps at least 6 cycles apart; the R1 harnesses' T6). A difference counts only while the
     assumption has held in every cycle so far (sticky). *)
  let env_ok =
    if spacing <= 0
    then vdd
    else (
      let step = i.rst_sync_n &: i.running &: i.tick in
      let since_d = wire 4 in
      let since = reg gs since_d -- "h_eq_since" in
      since_d <== mux2 step (of_int ~width:4 1) (mux2 (since ==:. 15) since (since +:. 1));
      let seen_d = wire 1 in
      let seen = reg gs seen_d -- "h_eq_seen" in
      seen_d <== (seen |: step);
      let viol = step &: seen &: (since <:. spacing) in
      let bad_q_d = wire 1 in
      let bad_q = reg gs bad_q_d -- "h_eq_env_broken" in
      bad_q_d <== (bad_q |: viol);
      ~:(bad_q |: viol))
  in
  Harness.bad_circuit ?debug ~dbg:[] ~name (env_ok &: reduce ~f:( |: ) (diffs @ arg_diff))
;;

let oracles (u : Mutate_v2.unit_) =
  match u with
  | Lane_rtl -> [ a1 "a1_lane_fetch" (A1_lane.fetch ?bug:None); a1 "a1_lane_dp" (A1_lane.datapath ?bug:None) ]
  | Lane_spec ->
    [ a1 "a1_lane_dp" (A1_lane.datapath ?bug:None)
    ; a1 "a1_lane_spec_indep" (fun ?debug ~name () -> A1_lane.spec_indep ?debug ~name ())
    ; a2_uart_tx
    ; a2_spi_ctl
    ]
  | Mon_lane -> List.init 5 ~f:r1
;;

let index_string i = if i < 0 then "id" else Int.to_string i
let name u i base = sprintf "m2_%s_%s__%s" (Mutate_v2.unit_to_string u) (index_string i) base

let build ?debug u i (o : t) =
  Mutate_v2.with_active (Some (u, i)) ~f:(fun () -> o.build ?debug ~name:(name u i o.base) ())
;;

let parse name =
  match String.chop_prefix name ~prefix:"m2_" with
  | None -> None
  | Some rest ->
    (match String.substr_index rest ~pattern:"__" with
     | None -> None
     | Some k ->
       let ui = String.prefix rest k
       and base = String.drop_prefix rest (k + 2) in
       (match String.rsplit2 ui ~on:'_' with
        | Some (u, i) ->
          Some (Mutate_v2.unit_of_string u, (if String.equal i "id" then -1 else Int.of_string i), base)
        | None -> None))
;;

let find ?debug name =
  match parse name with
  | None -> failwithf "bad v2 mutant harness name %s" name ()
  | Some (_, i, "eq_mon") -> eq_mon ?debug ~index:i ~name ()
  | Some (_, i, base) when String.is_prefix base ~prefix:"eq_mon_t6_" ->
    eq_mon ?debug ~spacing:6 ~group:(String.chop_prefix_exn base ~prefix:"eq_mon_t6_") ~index:i ~name ()
  | Some (_, i, base) when String.is_prefix base ~prefix:"eq_mon_" ->
    eq_mon ?debug ~group:(String.chop_prefix_exn base ~prefix:"eq_mon_") ~index:i ~name ()
  | Some (u, i, base) ->
    let o = List.find_exn (oracles u) ~f:(fun o -> String.equal o.base base) in
    build ?debug u i o
;;
