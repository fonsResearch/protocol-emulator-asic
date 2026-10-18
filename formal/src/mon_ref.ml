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

let harness ?debug ?bug ?(spacing = 8) ~j ~name () =
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
  (* spec: unit j only, free instruction word, its fetch address captured *)
  let w_spec = inp "free_w" M.instr_width in
  let spec_pc = wire 7 in
  let so =
    S.create ~tables
      ~fetch:(fun u pc ->
        assert (u = j);
        spec_pc <== pc;
        w_spec)
      i
  in
  let step = rst_sync_n &: i.running &: i.tick in
  (* ghosts of step t: word, fetch address, firing of unit j *)
  let ghost x n = reg gs ~enable:step x -- ("ghost_" ^ n) in
  let g_w = ghost w_spec "w"
  and g_pc = ghost spec_pc "pc"
  and s_fire = bit so.fire j
  and s_role = bit so.role j
  and s_code = List.nth_exn so.codes j in
  let g_fire = ghost s_fire "fire"
  and g_role = ghost s_role "role"
  and g_code = ghost s_code "code" in
  (* lane: word = spec word of this step (slot 0) or the ghost (slots 1-7) *)
  let lane_pc = wire 7 in
  let present = Array.init S.n_units ~f:(fun u -> if u = j then vdd else inp (sprintf "free_in_present%d" u) 1) in
  let lo =
    L.create ~only_unit:j ?bug ~tables ~present
      ~fetch:(fun _cur pc ->
        lane_pc <== pc;
        mux2 step w_spec g_w)
      i
  in
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
  let clean = if j = 0 then vdd else ~:(rst_win |: ~:rst_sync_n) in
  (* environment assumption T8 (sticky) *)
  let env_ok_d = wire 1 in
  let env_ok = reg gs env_ok_d -- "h_env_ok_n" in
  (* stored inverted so that init 0 = assumption holds so far *)
  env_ok_d <== (env_ok |: (step &: seen &: (since <:. spacing)));
  let ok_so_far = ~:env_ok_d in
  let lane_fj = lo.fire &: (lo.unit_ ==:. j) in
  let at_slot = if j = 0 then step else seen &: (since ==:. j) in
  let exp_fire, exp_role, exp_code, exp_pc =
    if j = 0 then s_fire, s_role, s_code, spec_pc else g_fire, g_role, g_code, g_pc
  in
  let mism =
    (lane_fj ^: exp_fire) |: (exp_fire &: ((lo.role ^: exp_role) |: (lo.code <>: exp_code)))
  in
  let lane_at_j = lo.unit_ ==:. j in
  let bad_slot = at_slot &: clean &: (mism |: (lane_at_j &: (lane_pc <>: exp_pc)))
  and bad_extra = lane_fj &: ~:at_slot in
  let bad = ok_so_far &: (bad_slot |: bad_extra) in
  Harness.bad_circuit ?debug
    ~dbg:
      [ "step", step; "since", since; "lane_fire", lo.fire; "lane_unit", lo.unit_; "exp_fire", exp_fire
      ; "lane_pc", lane_pc; "exp_pc", exp_pc ]
    ~name bad
;;

let all ?debug () =
  List.init 8 ~f:(fun j -> harness ?debug ~j ~name:(sprintf "r1_mon_lane_u%d" j) ())
  @ [ harness ?debug ~j:3 ~bug:`Smask_unlatched ~name:"r1_mon_lane_u3_smask_neg" ()
    ; harness ?debug ~j:7 ~spacing:7 ~name:"r1_mon_lane_u7_t7_neg" ()
    ]
;;
