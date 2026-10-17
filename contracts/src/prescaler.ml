(* Timebase prescaler (spike for decision G1). [p] is sampled while rst_sync_n = 0 and held
   afterwards; [tick] is 1 every (p + 1) cycles, first at cycle p after reset release.
   Lemma (formal/src/ag_harness.ml, presc_lemma): consecutive ticks are exactly p + 1 cycles
   apart, for every p. *)
open! Core
open Hardcaml
open Signal

let create ~clock ~rst_sync_n ~p =
  let w = width p in
  let p_r = reg (Reg_spec.create ~clock ()) ~enable:~:rst_sync_n p -- "presc_p" in
  let spec = Reg_spec.create ~clock ~clear:~:rst_sync_n () in
  let cnt_d = wire w in
  let cnt = reg spec cnt_d -- "presc_cnt" in
  let tick = rst_sync_n &: (cnt ==: p_r) in
  cnt_d <== mux2 tick (zero w) (cnt +:. 1);
  tick, p_r
;;
