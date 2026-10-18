(* Package contracts for language v1. *)
open! Core
open Lang

(* UART 8N1 TX guarantee for spec_v1/Programs_v1.uart_tx ~d on owned push-pull pin [pin].
   Line = pad level through the pull-up: !oe || out. Anchor = the step in which the lane pops
   byte b (step s). The program executes LDI at s+1 and OUT 0 at s+2, so the line is high in
   steps s+1, s+2, low for d steps (start bit), then carries b LSB first, d steps per bit, then
   is high for d steps (stop bit). Waiting for the next byte never fires (idle take).
   Watcher [one_pop]: after a pop, no further pop until the frame has ended (2 + 10d steps).
   Without it, a pop during a hold of [frame] would go unseen and every second frame would be
   unchecked (found by test: stop bit shortened by one step was not detected). *)
let uart_tx ~d ~pin =
  let line = !!(v "oe") ||| v "out" in
  let frame =
    watcher
      "frame"
      ~base:0x10
      [ loop
          ([ take_idle Tx_pop
           ; hold line ~for_:2 ~else_:(fail 1)
           ; hold !!line ~for_:d ~else_:(fail 2)
           ]
           @ List.init 8 ~f:(fun i -> hold (eq_reg line i) ~for_:d ~else_:(fail (3 + i)))
           @ [ hold line ~for_:d ~else_:(fail 11) ])
      ]
  in
  let one_pop =
    watcher
      "one_pop"
      ~base:0x20
      [ loop [ take_idle Tx_pop; hold !!(v "pop") ~for_:(2 + (10 * d)) ~else_:(fail 1) ] ]
  in
  { name = sprintf "uart_tx_v1_d%d_p%d" d pin
  ; observables = [ "out", Uio_out pin; "oe", Uio_oe pin; "pop", Tx_pop_ev ]
  ; watchers = [ frame; one_pop ]
  }
;;
