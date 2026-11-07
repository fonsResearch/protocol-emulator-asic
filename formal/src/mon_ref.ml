(* R1(j): refinement of the time-multiplexed monitor lane (monitor_v1/Mon_lane) by the
   parallel ISA spec circuit (Mon_spec), for unit j (8 harnesses, j = 0..7).

   Claim: if unit j of Mon_spec fires in step t (role r, code c), then Mon_lane fires unit j
   in cycle t + j with role r and code c; Mon_lane fires unit j in no other cycle. Checked on
   every slot window t..t+j that contains no reset cycle.

   Model:
   - every input free in every cycle: rst_sync_n (low in frame 0), running, tick, pins and
     stream events;
   - tables (remap, predicates, windows, code table, start and guard of unit j): free
     constants (registers free_tab_*, free initial value, never written). In the engine they
     are constant over every slot window because context writes need the sequencer idle;
   - Mon_spec has unit j only. Its instruction word is a free input in every cycle;
   - Mon_lane has the state entries of the other units as free inputs (only_unit hook; slot j
     reads only entry j). In slot j it receives the word the spec read at step t (ghost),
     and the harness requires its fetch address to equal the spec's pc at t: a real ROM,
     being a function of the address, would then return that same word;
   - environment assumption T8: running steps at least 8 cycles apart.
   Negative controls: Mon_lane with the step mask unlatched (`Smask_unlatched); T8 relaxed
   to 7 cycles.

   Results 2026-10-18 (dprove, 1,114-1,131 latches): u0 PASS 99 s; u1-u7 TIMEOUT at 3,600 s
   (8 run in parallel on 11 cores); smask_neg FAIL depth 4, replay ok; t7_neg FAIL depth 8,
   replay ok. That t7_neg counterexample used reset cycles inside the window: the earlier
   [clean] condition ORed in [step]. It is per slot now; t7_neg must be re-run. Open: u1-u7
   need a strengthened decomposition (e.g. a per-slot state-equality lemma with the ghost
   pre-step state, then the firing comparison). *)
open! Core
open Hardcaml
open Signal
module S = Pemu_monitor_v1.Mon_spec
module L = Pemu_monitor_v1.Mon_lane
module M = Pemu_monitor_v1.Mprog

(* [pipe] (Mon_lane ~pipe, log/increments_v2.md section 3.4): the claim is shifted by one cycle,
   unit j fires in cycle t + j + 1, and every slot receives the ghost word of step t. *)
let harness ?debug ?bug ?(slots = S.n_units) ?(pipe = false) ?(spacing = 8) ~j ~name () =
  let clock = input "clock" 1 in
  let gs = Reg_spec.create ~clock () in
  let started = reg gs vdd -- "env_started" in
  let rst_sync_n = input "rst_sync_n" 1 &: started in
  let inp n w = input n w in
  let i =
    { S.I.clock; rst_sync_n; running = inp "running" 1; tick = inp "tick" 1; ui_in = inp "ui_in" 8
    ; uio_in = inp "uio_in" 8; uo_out = inp "uo_out" 8; uio_out = inp "uio_out" 8
    ; uio_oe = inp "uio_oe" 8; pop_ev = inp "pop_ev" 1; pop_data = inp "pop_data" 8
    ; push_ev = inp "push_ev" 1; push_data = inp "push_data" 8 }
  in
  let const name w =
    let d = wire w in
    let q = reg gs d -- ("free_tab_" ^ name) in
    d <== q;
    q
  in
  let tables : S.tables =
    { remap = Array.init 16 ~f:(fun k -> const (sprintf "remap%d" k) 6)
    ; preds =
        Array.init 16 ~f:(fun k ->
          if k = 0 || k = 15 then zero M.pred_width else const (sprintf "pred%d" k) M.pred_width)
    ; windows = Array.init 8 ~f:(fun k -> if k = 0 then zero 12 else const (sprintf "win%d" k) 12)
    ; code_role = Array.init 16 ~f:(fun k -> if k = 0 then gnd else const (sprintf "crole%d" k) 1)
    ; code_val = Array.init 16 ~f:(fun k -> if k = 0 then zero 8 else const (sprintf "cval%d" k) 8)
    ; starts =
        Array.init S.n_units ~f:(fun u ->
          if u = j then const "start" 7 else inp (sprintf "free_in_start%d" u) 7)
    ; guards =
        Array.init S.n_units ~f:(fun u ->
          let c n w = if u = j then const n w else inp (sprintf "free_in_%s%d" n u) w in
          c "gen" 1, c "gp" 4, c "gs" 7, c "ge" 7, c "gh" 7)
    ; present = Array.init S.n_units ~f:(fun u -> u = j)
    }
  in
  (* one shared observation front end (both circuits instantiate the same deterministic
     [observe] on the same inputs from the same reset state) *)
  let front = S.observe ~tables i in
  let _, step, bank = front in
  let bankv = concat_lsb bank in
  (* spec: unit j only, free instruction word, its fetch address captured *)
  let w_spec = inp "free_w" M.instr_width in
  let spec_pc = wire 7 in
  let spec_st = ref None in
  let so =
    S.create ~front ~probe:(fun _ st -> spec_st := Some st) ~tables
      ~fetch:(fun u pc ->
        assert (u = j);
        spec_pc <== pc;
        w_spec)
      i
  in
  let spec_st = Option.value_exn !spec_st in
  (* ghosts of step t *)
  let ghost x n = reg gs ~enable:step x -- ("ghost_" ^ n) in
  let g_w = ghost w_spec "w"
  and g_pc = ghost spec_pc "pc"
  and s_fire = bit so.fire j
  and s_role = bit so.role j
  and s_code = List.nth_exn so.codes j in
  let g_fire = ghost s_fire "fire"
  and g_role = ghost s_role "role"
  and g_code = ghost s_code "code"
  and g_bank = ghost bankv "bank"
  and g_pre =
    S.ustate_of_list
      (List.mapi (S.ustate_to_list spec_st) ~f:(fun k x -> ghost x (sprintf "pre%d" k)))
  and g_ev : S.events =
    { pop_ev = ghost i.pop_ev "pop_ev"; pop_data = ghost i.pop_data "pop_data"
    ; push_ev = ghost i.push_ev "push_ev"; push_data = ghost i.push_data "push_data" }
  in
  (* lane: word = spec word of this step (slot 0) or the ghost (slots 1-7) *)
  let lane_pc = wire 7 in
  let lint = ref None in
  let present = Array.init S.n_units ~f:(fun u -> if u = j then vdd else inp (sprintf "free_in_present%d" u) 1) in
  let lo =
    L.create ~slots ~pipe ~front ~probe:(fun x -> lint := Some x) ~only_unit:j ?bug ~tables ~present
      ~fetch:(fun _cur pc ->
        lane_pc <== pc;
        if pipe then g_w else mux2 step w_spec g_w)
      i
  in
  let lint = Option.value_exn !lint in
  (* window bookkeeping *)
  let since_d = wire 4 in
  let since = reg gs since_d -- "h_since" in
  let seen_d = wire 1 in
  let seen = reg gs seen_d -- "h_seen_step" in
  since_d <== mux2 step (of_int ~width:4 1) (mux2 (since ==:. 15) since (since +:. 1));
  seen_d <== (seen |: step);
  let rst_win_d = wire 1 in
  let rst_win = reg gs rst_win_d -- "h_rst_in_window" in
  rst_win_d <== mux2 step gnd (rst_win |: ~:rst_sync_n);
  (* slot window without reset: for j = 0 the window is the step cycle itself (never a reset
     cycle); for j > 0, no reset cycle after the step up to and including this cycle *)
  let clean = if j = 0 && not pipe then vdd else ~:(rst_win |: ~:rst_sync_n) in
  (* environment assumption T8 (sticky; stored inverted so that init 0 = holds so far) *)
  let env_ok_d = wire 1 in
  let env_ok = reg gs env_ok_d -- "h_env_ok_n" in
  env_ok_d <== (env_ok |: (step &: seen &: (since <:. spacing)));
  let ok_so_far = ~:env_ok_d in
  (* ---- refinement property ---- *)
  let lane_fj = lo.fire &: (lo.unit_ ==:. j) in
  let at_slot =
    if pipe then seen &: (since ==:. j + 1) else if j = 0 then step else seen &: (since ==:. j)
  in
  let exp_fire, exp_role, exp_code, exp_pc =
    if j = 0 && not pipe then s_fire, s_role, s_code, spec_pc else g_fire, g_role, g_code, g_pc
  in
  let mism =
    (lane_fj ^: exp_fire) |: (exp_fire &: ((lo.role ^: exp_role) |: (lo.code <>: exp_code)))
  in
  let lane_at_j = lo.unit_ ==:. j in
  let bad_slot = at_slot &: clean &: (mism |: (lane_at_j &: (lane_pc <>: exp_pc)))
  and bad_extra = lane_fj &: ~:at_slot in
  (* ---- strengthening invariants (each implied by the claim; together inductive) ---- *)
  let st_eq a b =
    List.map2_exn (S.ustate_to_list a) (S.ustate_to_list b) ~f:( ==: ) |> reduce ~f:( &: )
  in
  let st_mux c a b =
    S.ustate_of_list (List.map2_exn (S.ustate_to_list a) (S.ustate_to_list b) ~f:(mux2 c))
  in
  let rst_st = S.ustate_reset ~start:tables.starts.(j) in
  let entry = lint.entries.(j) in
  let pending = lint.busy_q &: (lint.slot_q <=:. j) in
  (* what the spec computed at step t, recomputed from the ghosts *)
  let pb idx = mux idx (bits_lsb g_bank) in
  let win idx = mux idx (Array.to_list tables.windows) in
  let r_next, r_fire, r_idx =
    S.unit_step ~pb ~win ~guard:tables.guards.(j) ~w:g_w ~st:g_pre ~act:~:(g_pre.stopped) ~ev:g_ev
  in
  let r_role = r_fire &: mux r_idx (Array.to_list tables.code_role)
  and r_code = mux2 r_fire (mux r_idx (Array.to_list tables.code_val)) (zero 8) in
  let i_ghost =
    ~:seen
    |: ((g_fire ==: r_fire) &: (g_role ==: r_role) &: (g_code ==: r_code)
        &: (g_pc ==: g_pre.pc))
  in
  let m_pend = bit lint.smask j
  and m_now = bit lint.mask_q j in
  let i_pend =
    ~:pending
    |: (st_eq (st_mux m_pend rst_st entry) g_pre
        &: st_eq (st_mux m_now rst_st r_next) spec_st
        &: (lint.bank_l ==: g_bank)
        &: (lint.ev_l.pop_ev ==: g_ev.pop_ev) &: (lint.ev_l.pop_data ==: g_ev.pop_data)
        &: (lint.ev_l.push_ev ==: g_ev.push_ev) &: (lint.ev_l.push_data ==: g_ev.push_data))
  in
  let i_np = pending |: st_eq (st_mux m_now rst_st entry) spec_st in
  let i_seq =
    if pipe
    then
      (lint.busy_q ==: (seen &: (since >=:. 1) &: (since <=:. slots) &: ~:rst_win))
      &: (~:(lint.busy_q) |: (uresize lint.slot_q 4 +:. 1 ==: since))
    else
      (lint.busy_q ==: (seen &: (since >=:. 1) &: (since <=:. slots - 1) &: ~:rst_win))
      &: (~:(lint.busy_q) |: (uresize lint.slot_q 4 ==: since))
  in
  let inv_bad = ~:(i_ghost &: i_pend &: i_np &: i_seq) in
  let bad = ok_so_far &: (bad_slot |: bad_extra |: inv_bad) in
  Harness.bad_circuit ?debug
    ~dbg:
      [ "step", step; "since", since; "lane_fire", lo.fire; "lane_unit", lo.unit_; "exp_fire", exp_fire
      ; "lane_pc", lane_pc; "exp_pc", exp_pc; "i_ghost", i_ghost; "i_pend", i_pend; "i_np", i_np
      ; "i_seq", i_seq; "pending", pending ]
    ~name bad
;;

let all ?debug () =
  List.init 8 ~f:(fun j -> harness ?debug ~j ~name:(sprintf "r1_mon_lane_u%d" j) ())
  @ [ harness ?debug ~j:3 ~bug:`Smask_unlatched ~name:"r1_mon_lane_u3_smask_neg" ()
    ; harness ?debug ~j:7 ~spacing:7 ~name:"r1_mon_lane_u7_t7_neg" ()
    ]
  (* v2 (doc/decisions/arch_v2_options.md V2-2): 5 slots, assumption T5 *)
  @ List.init 5 ~f:(fun j -> harness ?debug ~slots:5 ~spacing:5 ~j ~name:(sprintf "r1v2_s5_u%d" j) ())
  @ List.init 5 ~f:(fun j ->
    harness ?debug ~slots:5 ~pipe:true ~spacing:6 ~j ~name:(sprintf "r1v2p_s5_u%d" j) ())
  @ [ harness ?debug ~slots:5 ~spacing:5 ~j:3 ~bug:`Smask_unlatched ~name:"r1v2_s5_u3_smask_neg" ()
    ; harness ?debug ~slots:5 ~spacing:4 ~j:4 ~name:"r1v2_s5_u4_t4_neg" ()
    ; harness ?debug ~slots:5 ~pipe:true ~spacing:4 ~j:4 ~name:"r1v2p_s5_u4_t4_neg" ()
    ; harness ?debug ~slots:5 ~pipe:true ~spacing:5 ~j:4 ~name:"r1v2p_s5_u4_t5" ()
    ; harness ?debug ~slots:5 ~pipe:true ~spacing:6 ~j:3 ~bug:`Smask_unlatched ~name:"r1v2p_s5_u3_smask_neg" ()
    ]
;;
