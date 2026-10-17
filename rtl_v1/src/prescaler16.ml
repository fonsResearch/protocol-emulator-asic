(* Per-lane prescaler (ISA v1 section 1 with v1.0.2 section 11 item 2): the counter is held at
   0 in every cycle in which the lane is not running; while running, tick = (counter = P) and
   the counter then returns to 0, else it increments. P is the host divisor (16 bits), written
   only while the lane is halted (interface section 5). *)
open! Core
open Hardcaml
open Signal

let create ?(bug = false) ~clock ~rst_sync_n ~running ~p () =
  let spec = Reg_spec.create ~clock ~clear:~:rst_sync_n () in
  let cnt_d = wire 16 in
  let cnt = reg spec cnt_d -- "presc_cnt" in
  let hit = if bug then cnt ==: p &: (p <>:. 300) else cnt ==: p in
  let tick = running &: hit in
  cnt_d <== mux2 (running &: ~:tick) (cnt +:. 1) (zero 16);
  tick -- "lane_tick"
;;
