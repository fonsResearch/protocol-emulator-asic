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

(* UART 8N1 RX on input pin [pin] (doc/protocols/uart_v1.md section 4), d steps per bit,
   tolerance m steps (d >= 2m + 2). s0 = the falling-edge step that starts a frame.
   Watcher [sender] (assumption, blame): the line is constant in each bit's core
   s0 + k d + m .. s0 + (k+1) d - 1 - m; start core low, stop core high.
   Watcher [receiver] (guarantee, fail): one push per frame, in s0 + 9d .. s0 + 10d - 1 - m,
   whose bit i equals the line at s0 + (i+1) d + d/2; no push before that or between frames.
   Written from the protocol document before the firmware (user decision: procedural
   isolation). *)
let uart_rx ~d ~m ~pin =
  if d < (2 * m) + 2 || m < 1 then raise_s [%message "uart_rx: need m >= 1, d >= 2m + 2" (d : int) (m : int)];
  let rx = v "rx" in
  let push = v "push" in
  let skip_n n = if n > 0 then [ skip n ] else [] in
  let sender =
    watcher
      "sender"
      ~base:0x30
      [ loop
          (List.concat
             [ [ await_idle (fall "rx") ]
             ; skip_n (m - 1)
             ; [ hold !!rx ~for_:(d - (2 * m)) ~else_:(blame 1) ]
             ; [ repeat
                   8
                   [ skip ((2 * m) + 1); hold (stable "rx") ~for_:(d - (2 * m) - 1) ~else_:(blame 2) ]
               ]
             ; [ skip (2 * m); hold rx ~for_:(d - (2 * m)) ~else_:(blame 3) ]
             ])
      ]
  in
  let c = d / 2 in
  let receiver =
    watcher
      "receiver"
      ~base:0x40
      [ loop
          (List.concat
             [ [ guard push [ await_idle (fall "rx") ] ~on:[ hold False ~for_:1 ~else_:(fail 1) ] ]
             ; [ hold !!push ~for_:(d + c) ~else_:(fail 2); sample 0 rx ]
             ; List.concat
                 (List.init 7 ~f:(fun i ->
                    [ hold !!push ~for_:d ~else_:(fail (3 + i)); sample (i + 1) rx ]))
             ; [ await push
                   (win ~early:(fail 10) (d - c) ((2 * d) - 1 - m - c) ~else_:(fail 11))
               ; match_rx ~else_:(fail 12)
               ]
             ])
      ]
  in
  { name = sprintf "uart_rx_v1_d%d_m%d_p%d" d m pin
  ; observables = [ "rx", Uio_in pin; "push", Rx_push_ev ]
  ; watchers = [ sender; receiver ]
  }
;;
