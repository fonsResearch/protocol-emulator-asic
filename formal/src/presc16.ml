(* Prescaler lemma (16 bits). Reference definition: while the lane runs, let gap be the number
   of earlier running cycles since the start of the running interval or since the last tick
   (16 bits; sound without saturation: if tick <=> gap = P holds in every cycle, gap restarts
   at every tick and never exceeds P, so it cannot wrap). ISA section 1 with v1.0.2 says: first tick at running-cycle index P,
   then ticks exactly P + 1 cycles apart, i.e. tick <=> gap = P. P is free but changes only in
   non-running cycles; running and reset are free. This is a definitional check of the counter
   (including hold-at-0 while halted and reset), not an independent oracle.
   Negative control: one divisor value (300) never ticks. *)
open! Core
open Hardcaml
open Signal

let lemma ?debug ?(bug = false) ~name () =
  let clock = input "clock" 1
  and rst_sync_n = input "rst_sync_n" 1
  and run_in = input "running" 1
  and p_in = input "p" 16 in
  let rs = Reg_spec.create ~clock () in
  let running = run_in &: rst_sync_n in
  let p_q = wire 16 in
  let p = mux2 running p_q p_in in
  p_q <== reg rs p -- "env_p";
  let tick = Pemu_rtl_v1.Prescaler16.create ~bug ~clock ~rst_sync_n ~running ~p () in
  let gap_d = wire 16 in
  let gap = reg rs gap_d -- "ref_gap" in
  gap_d <== mux2 (running &: ~:tick) (gap +:. 1) (zero 16);
  let bad = running &: (tick <>: (gap ==: p)) in
  Harness.bad_circuit ?debug ~dbg:[ "tick", tick; "gap", gap ] ~name bad
;;

let all ?debug () =
  [ lemma ?debug ~name:"presc16_lemma" (); lemma ?debug ~bug:true ~name:"presc16_lemma_neg" () ]
;;
