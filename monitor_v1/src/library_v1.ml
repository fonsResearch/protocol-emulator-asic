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

(* SPI, doc/protocols/spi_v1.md. Pins: CS uio4, SCLK uio5, MOSI uio6, MISO uio7. One byte per
   CS assertion, MSB first. Written from the protocol document before the firmware. *)
let spi_cs = 4
let spi_sclk = 5
let spi_mosi = 6
let spi_miso = 7

(* Controller (section 3): half period h steps. Watchers:
   [shape] G1-G3 (fail 1: CS/SCLK not idle between frames, including step c + 17h;
   2: CS not selected in 1..4 steps with SCLK idle; 3: idle-level segment wrong or a pop
   inside the frame; 4: active-level segment wrong or a pop);
   [mosi] G4 (fail 1, all 8 bits); [miso] G5 (fail 1: push between frames; 5: push during
   the byte; 2: push early; 3: no push; 4: data); [drive] G6 (fail 1); [target] A1 (blame 1).
   Codes label check families (WF3 v1.1). *)
let spi_ctl ~cpol ~cpha ~h =
  if h < 2 then raise_s [%message "spi_ctl: need h >= 2" (h : int)];
  let cs = v "cs" and sclk = v "sclk" and pop = v "pop" and push = v "push" in
  let sclk_at lvl = if lvl then sclk else !!sclk in
  let idle = sclk_at cpol in
  let sel = !!cs in
  let shape =
    watcher
      "shape"
      ~base:0x50
      [ take_idle Tx_pop
      ; loop
          (List.concat
             [ [ await (sel &&& idle) (win 1 4 ~else_:(fail 2))
               ; hold (sel &&& idle &&& !!pop) ~for_:(h - 1) ~else_:(fail 3)
               ]
             ; List.init 16 ~f:(fun i ->
                 let j = i + 1 in
                 if j % 2 = 1
                 then hold (sel &&& sclk_at (not cpol) &&& !!pop) ~for_:h ~else_:(fail 4)
                 else hold (sel &&& idle &&& !!pop) ~for_:h ~else_:(fail 3))
             ; [ guard (sel ||| !!idle) [ take_idle Tx_pop ] ~on:[ hold False ~for_:1 ~else_:(fail 1) ]
               ]
             ])
      ]
  in
  let mosi_w =
    let first = if cpha then [ skip h ] else [] in
    watcher
      "mosi"
      ~base:0x60
      [ loop
          (List.concat
             [ [ take_idle ~byte:1 Tx_pop; await_idle sel ]
             ; first
             ; List.init 8 ~f:(fun k -> hold (eq_reg (v "mosi") (8 + 7 - k)) ~for_:(2 * h) ~else_:(fail 1))
             ])
      ]
  in
  let s0 = if cpha then 2 * h else h in
  let miso_w =
    watcher
      "miso"
      ~base:0x70
      [ loop
          (List.concat
             [ [ guard push [ take_idle ~byte:1 Tx_pop; await_idle sel ] ~on:[ hold False ~for_:1 ~else_:(fail 1) ]
               ; hold !!push ~for_:s0 ~else_:(fail 5)
               ; sample 7 (v "miso")
               ]
             ; List.concat
                 (List.init 7 ~f:(fun i ->
                    [ hold !!push ~for_:(2 * h) ~else_:(fail 5); sample (6 - i) (v "miso") ]))
             ; [ await push (win ~early:(fail 2) (17 * h - (s0 + 14 * h)) (17 * h - (s0 + 14 * h) + 3) ~else_:(fail 3))
               ; match_rx ~else_:(fail 4)
               ]
             ])
      ]
  in
  let drive =
    watcher
      "drive"
      ~base:0x80
      [ take_idle Tx_pop
      ; loop [ hold (v "oe_cs" &&& v "oe_sclk" &&& v "oe_mosi") ~for_:4095 ~else_:(fail 1) ]
      ]
  in
  let target =
    watcher
      "target"
      ~base:0x90
      [ loop
          (List.concat
             [ [ take_idle Tx_pop; await_idle sel; skip s0; expect (stable "miso") ~else_:(blame 1) ]
             ; List.concat (List.init 7 ~f:(fun _ -> [ skip (2 * h); expect (stable "miso") ~else_:(blame 1) ]))
             ])
      ]
  in
  { name = sprintf "spi_ctl_v1_m%d_h%d" ((if cpol then 2 else 0) + if cpha then 1 else 0) h
  ; observables =
      [ "cs", Uio_out spi_cs
      ; "sclk", Uio_out spi_sclk
      ; "mosi", Uio_out spi_mosi
      ; "oe_cs", Uio_oe spi_cs
      ; "oe_sclk", Uio_oe spi_sclk
      ; "oe_mosi", Uio_oe spi_mosi
      ; "miso", Uio_in spi_miso
      ; "pop", Tx_pop_ev
      ; "push", Rx_push_ev
      ]
  ; watchers = [ shape; mosi_w; miso_w; drive; target ]
  }
;;

(* Target (section 4): minimum half period h_min, CS-high minimum g. Watchers:
   [ctl] B1-B5 (blame 1: SCLK not idle at CS fall; 2: edge too soon or CS rose mid-byte;
   3: edge or CS rise not within 4095 steps; 4: edge after the 16th; 5: CS high too short);
   [mosi_ok] B6 (blame 1); [ready] H1 (fail 1: CS fell or push before the pop);
   [frame] H2-H3 (fail 2: MISO data, all bits; 3: pop or push inside the frame; 4: no push
   in the window; 6: push early (CPHA 0); 5: data); [drive] H4 (fail 1).
   Codes label check families (WF3 v1.1). *)
let spi_tgt ~cpol ~cpha ~h_min ~g =
  if h_min < 3 || g < 2 then raise_s [%message "spi_tgt: need h_min >= 3, g >= 2" (h_min : int) (g : int)];
  let cs = v "cs" and sclk = v "sclk" in
  let sel = !!cs in
  let edge = changed "sclk" in
  let idle = if cpol then sclk else !!sclk in
  let ctl =
    watcher
      "ctl"
      ~base:0x50
      [ hold cs ~for_:g ~else_:(blame 5)
      ; loop
          (List.concat
             [ [ await_idle (fall "cs"); expect idle ~else_:(blame 1) ]
             ; List.concat
                 (List.init 16 ~f:(fun _ ->
                    [ hold (stable "sclk" &&& sel) ~for_:(h_min - 1) ~else_:(blame 2)
                    ; hold_until sel edge (win 1 4095 ~else_:(blame 3))
                    ]))
             ; [ hold_until (stable "sclk") cs (win 1 4095 ~else_:(blame 4))
               ; hold cs ~for_:(g - 1) ~else_:(blame 5)
               ]
             ])
      ]
  in
  let per_bit_edges body =
    (* sampling edge per CPHA; [body] runs at the sampling edge *)
    List.concat
      (List.init 8 ~f:(fun k ->
         List.concat
           [ (if cpha then [ await_idle edge ] else [])
           ; [ await_idle edge ]
           ; body k
           ; (if cpha then [] else [ await_idle edge ])
           ]))
  in
  let mosi_ok =
    watcher
      "mosi_ok"
      ~base:0x60
      [ loop
          ([ await_idle (fall "cs") ]
           @ per_bit_edges (fun _ ->
             [ expect (stable "mosi") ~else_:(blame 1); skip 1; expect (stable "mosi") ~else_:(blame 1) ]))
      ]
  in
  let ready =
    watcher
      "ready"
      ~base:0x90
      [ loop
          [ guard (fall "cs" ||| v "push") [ take_idle Tx_pop ] ~on:[ hold False ~for_:1 ~else_:(fail 1) ]
          ; await_idle (v "push")
          ]
      ]
  in
  let frame =
    watcher
      "frame"
      ~base:0x70
      [ loop
          [ take_idle ~byte:1 Tx_pop
          ; guard
              (v "pop" ||| v "push")
              ([ await_idle (fall "cs") ]
               @ per_bit_edges (fun k ->
                 (* MISO in S_k - 1 (checked at S_k) and in S_k (checked at S_k + 1) *)
                 [ expect (eq_reg (at ~delay:1 "miso") (8 + 7 - k)) ~else_:(fail 2)
                 ; skip 1
                 ; sample (7 - k) (v "mosi")
                 ; expect (eq_reg (at ~delay:1 "miso") (8 + 7 - k)) ~else_:(fail 2)
                 ]))
              ~on:[ hold False ~for_:1 ~else_:(fail 3) ]
          ; (* push in e_16 + 2 .. e_16 + 4; anchor is e_16 (CPHA 0) or e_16 + 1 (CPHA 1) *)
            (if cpha
             then await (v "push") (win 1 3 ~else_:(fail 4))
             else await (v "push") (win ~early:(fail 6) 2 4 ~else_:(fail 4)))
          ; match_rx ~else_:(fail 5)
          ]
      ]
  in
  let drive =
    watcher
      "drive"
      ~base:0x80
      [ take_idle Tx_pop; loop [ hold (v "oe_miso") ~for_:4095 ~else_:(fail 1) ] ]
  in
  { name = sprintf "spi_tgt_v1_m%d_h%d_g%d" ((if cpol then 2 else 0) + if cpha then 1 else 0) h_min g
  ; observables =
      [ "cs", Uio_in spi_cs
      ; "sclk", Uio_in spi_sclk
      ; "mosi", Uio_in spi_mosi
      ; "miso", Uio_out spi_miso
      ; "oe_miso", Uio_oe spi_miso
      ; "pop", Tx_pop_ev
      ; "push", Rx_push_ev
      ]
  ; watchers = [ ctl; mosi_ok; frame; drive; ready ]
  }
;;
