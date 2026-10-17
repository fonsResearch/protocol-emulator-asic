(* Assume-guarantee harnesses on the ISA v1 lane spec (spec_v1/Lane_circuit) running
   Programs_v1.uart_tx, with the tick, host FIFO traffic, pins, blame_in and clear_fault all
   free. Contract: uart_tx_v01 without the progress watcher (progress needs a host stream
   assumption, contract language v1). The line seen by the monitor is the pad value with the
   pull-up (physical assumption): tx = !uio_oe[0] | uio_out[0]. RUN = ui_in[7] and uio_in go
   through 2-flop synchronisers into the lane, as in the v0 core.

   U_V1      bad = fail && !blame, environment free
   N1_V1     RUN rises once and stays high (reference peer), bad = fail || blame
   negatives no assumption (U must fail); start bit d+1 steps (U must fail) *)
open! Core
open Hardcaml
open Signal
module C = Pemu_contracts
module MC = C.Mon_circuit
module L = Pemu_spec_v1.Lane_circuit
module P1 = Pemu_spec_v1.Programs_v1
module Isa1 = Pemu_spec_v1.Isa1

let lane_harness ?debug ?(n1 = false) ?(prog = `Good) ~contract ~name ~d () =
  let clock = input "clock" 1
  and rst_sync_n = input "rst_sync_n" 1
  and tick = input "tick" 1
  and uio_in = input "uio_in" 8 in
  let ui_in =
    if n1
    then (
      let go = input "go" 1
      and ui_low = input "ui_low" 7 in
      let run_r = wire 1 in
      let run = run_r |: go in
      run_r <== reg (Reg_spec.create ~clock ()) run -- "env_run";
      run @: ui_low)
    else input "ui_in" 8
  in
  let spec = Reg_spec.create ~clock ~clear:~:rst_sync_n () in
  let sync2 x = reg spec (reg spec x) in
  let program =
    match prog with
    | `Good -> P1.uart_tx ~d
    | `Bad_start -> P1.uart_tx_bad_start ~d
  in
  let words = Isa1.assemble program in
  let o =
    L.create
      ~imem:(L.imem_rom words)
      { L.I.clock
      ; rst_sync_n
      ; tick
      ; run = sync2 (bit ui_in 7)
      ; loaded = vdd
      ; len = of_int ~width:8 (List.length program)
      ; own = of_int ~width:8 1
      ; od = zero 8
      ; cfg = zero 8
      ; cfg2 = zero 8
      ; pins = sync2 uio_in
      ; tx_push = input "tx_push" 1
      ; tx_wdata = input "tx_wdata" 8
      ; rx_pop = input "rx_pop" 1
      ; blame_in = input "blame_in" 1
      ; clear_fault = input "clear_fault" 1
      }
  in
  let line = ~:(bit o.uio_oe 0) |: bit o.uio_out 0 in
  let m =
    MC.Hardwired.create
      ~tick
      (C.Program.compile contract)
      { MC.I.clock
      ; rst_sync_n
      ; ui_in
      ; uio_in
      ; uo_out = zero 7 @: line
      ; uio_out = o.uio_out
      ; uio_oe = o.uio_oe
      }
  in
  let bad = if n1 then m.fail_flag |: m.blame_flag else m.fail_flag &: ~:(m.blame_flag) in
  Harness.bad_circuit
    ?debug
    ~dbg:
      [ "tick", tick; "line", line; "pc", o.pc; "fail", m.fail_flag; "blame", m.blame_flag
      ; "ff", m.first_fail; "fb", m.first_blame ]
    ~name
    bad
;;

let all ?debug () =
  let lib = C.Library.uart_tx_v01 ~with_progress:false in
  [ lane_harness ?debug ~contract:(lib ~d:4 ()) ~name:"u_v1_uart_tick_d4" ~d:4 ()
  ; lane_harness ?debug ~n1:true ~contract:(lib ~d:4 ()) ~name:"n1_v1_uart_tick_d4" ~d:4 ()
  ; lane_harness
      ?debug
      ~contract:(lib ~with_assumption:false ~d:4 ())
      ~name:"u_v1_uart_noassume_neg_d4"
      ~d:4
      ()
  ; lane_harness
      ?debug
      ~prog:`Bad_start
      ~contract:(lib ~d:4 ())
      ~name:"u_v1_uart_badprog_neg_d4"
      ~d:4
      ()
  ]
;;
