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
   the byte; 2: push early; 3: no push; 4: data); [drive] G6 (fail 1); [target] A1 (blame 1:
   MISO changes in S_k; 2: MISO changes in S_k + 1 .. S_k + h - 1, D2 in log/disagreements.md).
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
             [ [ take_idle Tx_pop; await_idle sel; skip s0 ]
             ; List.concat
                 (List.init 8 ~f:(fun k ->
                    (if k = 0 then [] else [ skip (h + 1) ])
                    @ [ expect (stable "miso") ~else_:(blame 1)
                      ; hold (stable "miso") ~for_:(h - 1) ~else_:(blame 2)
                      ]))
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
   [mosi_ok] B6 (blame 1: MOSI changes in S_k; 2/3: MOSI changes after S_k before the next
   shifting edge / CS high, D2 in log/disagreements.md); [ready] H1 (fail 1: CS fell or push before the pop);
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
  (* B6 (D2): MOSI is constant from S_k - 1 until the next shifting edge (CPHA 0: e_{2k+2};
     CPHA 1: e_{2k+3}, or CS high after the last bit). The hold-until consumes that edge. *)
  let mosi_ok =
    let bit k =
      List.concat
        [ (if cpha && k = 0 then [ await_idle edge ] else [])
        ; [ await_idle edge (* S_k *); expect (stable "mosi") ~else_:(blame 1) ]
        ; (if cpha && k = 7
           then [ hold_until (stable "mosi") cs (win 1 4095 ~else_:(blame 3)) ]
           else [ hold_until (stable "mosi") edge (win 1 4095 ~else_:(blame 2)) ])
        ]
    in
    watcher "mosi_ok" ~base:0x60 [ loop ([ await_idle (fall "cs") ] @ List.concat (List.init 8 ~f:bit)) ]
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

(* I2C (doc/protocols/i2c_v1.md). SCL uio2, SDA uio3, open-drain. Observables: dscl/dsda = the
   chip pulls the line low (uio_oe), scl/sda = synchronised line values. A cell is a low phase
   followed by a high phase; cells are tracked with level waits (release: dscl = 0; first
   high step: scl = 1; end: dscl = 1). Written from the protocol document before firmware. *)
let i2c_scl = 2
let i2c_sda = 3

(* Controller (section 2). Timing in steps: l (low), h (high), tsu (Tsu_sta = Tsu_sto,
   tsu <= h), thold (Tsta = Tbuf). Branches test live observables (the compiler accepts no
   register terms in branch conditions). Watchers:
   [clock] G1, G2 (fail 1: dSDA changes in a pull or release step; 2: low phase < l;
   3: high phase < h);
   [cond] G4 (fail 1: condition (or pull) less than tsu steps after the high phase began;
   2: SCL pulled, or a START, within thold steps of a START/Sr/STOP);
   [frame] G3, G5, G6, G7 and A1, A2 (fail 1: address / write bit value; 2: dSDA changes in
   a high phase; 3: SDA not released in a read or ACK-receive cell; 4: push missing (read
   byte or status); 5: pushed byte differs (read data or status); blame 6: SDA low while
   released in a controller-transmit cell; blame 7: SDA changes in a read high phase).
   Register: byte1 = address byte a, then the current write data byte; byte0 = read data, or
   status (bit0 address NACK, bit1 data NACK; bits cleared one per address cell and after
   a read NACK). *)
let i2c_ctl ~l ~h ~tsu ~thold =
  (* h >= 3 (D4): the read-cell stability window must end before the pull step of a high
     phase of exactly h steps *)
  if l < 2 || h < 3 || tsu < 1 || tsu > h || thold < 2 then raise_s [%message "i2c_ctl: bad timing"];
  let dscl = v "dscl" and dsda = v "dsda" and scl = v "scl" and sda = v "sda" and push = v "push" in
  let ndscl = !!dscl in
  let cond_ev = changed "dsda" &&& ndscl in
  let clock =
    watcher
      "clock"
      ~base:0x50
      [ loop
          [ await_idle dscl
          ; expect (stable "dsda") ~else_:(fail 1)
          ; hold dscl ~for_:(l - 1) ~else_:(fail 2)
          ; await_idle ndscl
          ; expect (stable "dsda") ~else_:(fail 1)
            (* G1 (D4): the high phase starts at the first step with SCL = 1, which is the
               release step itself when SCL is already high there *)
          ; if_ scl [ hold ndscl ~for_:(h - 1) ~else_:(fail 3) ]
              [ await_idle scl; hold ndscl ~for_:(h - 1) ~else_:(fail 3) ]
          ]
      ]
  in
  (* after a START/Sr (sampled dsda = 1): dSCL stays 0 and dSDA stays 1; after a STOP
     (sampled 0): no START, i.e. (dsda and not dscl) stays 0 *)
  let cond_hold = hold (eq_reg (dsda &&& ndscl) 0) ~for_:(thold - 1) ~else_:(fail 2) in
  let cond_rest =
    [ await_idle (cond_ev ||| dscl)
    ; sample 0 dsda
    ; expect (Elapsed_ge { mark = 0; t = tsu }) ~else_:(fail 1)
    ; if_ dscl
        [ skip 1 ]
        [ cond_hold
        ; if_ dsda [ skip 1 ] [ await_idle cond_ev; sample 0 dsda; cond_hold ]
        ]
    ]
  in
  let cond =
    watcher
      "cond"
      ~base:0x60
      [ loop
          ([ await_idle ndscl
             (* G4 (D4): SCL observed high counts from the first step with SCL = 1, which is
                the release step itself when SCL is already high there *)
           ; mark 0
           ; if_ scl cond_rest ([ await_idle scl; mark 0 ] @ cond_rest)
           ])
      ]
  in
  (* A1 is checked in the first high step (D5): in the step where the monitor sees dSCL = 1
     the line has already been low for up to one step, and a target may drive its ACK right
     after the SCL fall (tHD;DAT min 0). The bit value (dSDA, held stable by fail 2 and by
     the clock watcher) is checked in the pull step. *)
  let tx_head ?clr _bit =
    [ await_idle ndscl; await_idle scl ]
    @ (match clr with Some b -> [ sample b False ] | None -> [])
    @ [ expect ~when_:!!dsda sda ~else_:(blame 6) ]
  in
  let tx_rest bit =
    [ hold_until (stable "dsda") dscl (win 1 4095 ~else_:(fail 2)); expect (eq_reg !!dsda bit) ~else_:(fail 1) ]
  in
  let tx_cell ?clr bit = tx_head ?clr bit @ tx_rest bit in
  (* read and ACK bits are taken in the second step of the high phase (D3: the lane's WTP
     completes in the first high step s, so its earliest read is in s+1). The await below
     completes in s+1 when SCL is already high in the release step s, else in s (D4); with
     SDA stable for h-2 steps after it (blame 7), the sampled value is SDA(s+1) in both cases,
     and the window ends before the pull step of a high phase of exactly h steps (a target
     may change SDA right after the SCL fall). *)
  let rx_cell k =
    [ await_idle ndscl
    ; await_idle scl
    ; expect !!dsda ~else_:(fail 3)
    ; hold (stable "sda") ~for_:(h - 2) ~else_:(blame 7)
    ; sample (7 - k) sda
    ; await_idle dscl
    ]
  in
  (* ACK cell received by the controller: SDA stable into the second high step, sampled into
     [b] there, branch on it (1 = NACK) *)
  let ack_rx b ~nack ~ack =
    [ await_idle ndscl
    ; await_idle scl
    ; expect !!dsda ~else_:(fail 3)
    ; hold (stable "sda") ~for_:1 ~else_:(blame 7)
    ; sample b sda
    ; if_ sda nack ack
    ]
  in
  let stuck = [ await_idle False ] in
  let write_loop =
    loop
      ([ take_idle ~byte:1 Tx_pop ]
       @ List.concat (List.init 8 ~f:(fun k -> tx_cell (15 - k)))
       @ ack_rx 1 ~nack:stuck ~ack:[ await_idle dscl ])
  in
  let clear_byte0 = List.concat (List.init 8 ~f:(fun i -> [ skip 1; sample i False ])) in
  let s_hold = hold_until (stable "dsda") dscl (win 1 4095 ~else_:(fail 2)) in
  let read_loop =
    loop
      (List.concat (List.init 8 ~f:rx_cell)
       @ [ await push (win 1 64 ~else_:(fail 4)); match_rx ~else_:(fail 5) ]
       @ [ await_idle ndscl; await_idle scl; if_ dsda [ s_hold ] ([ s_hold ] @ clear_byte0 @ stuck) ])
  in
  let after_addr ~loop_ = tx_rest 8 @ ack_rx 0 ~nack:stuck ~ack:[ await_idle dscl; loop_ ] in
  let transaction =
    [ await_idle dscl ]
    @ List.concat (List.init 7 ~f:(fun k -> tx_cell ~clr:k (15 - k)))
    @ tx_head ~clr:7 8
    @ [ if_ sda (after_addr ~loop_:read_loop) (after_addr ~loop_:write_loop) ]
  in
  let header = [ take_idle ~byte:1 Tx_pop; await_idle (v "pop") ] in
  let status = [ await push (win 1 7 ~else_:(fail 4)); match_rx ~else_:(fail 5) ] in
  let frame =
    watcher
      "frame"
      ~base:0x70
      (header
       @ [ await_idle cond_ev
         ; loop
             [ guard
                 cond_ev
                 transaction
                 ~on:[ skip 1; if_ dsda (status @ header) (status @ header @ [ await_idle cond_ev ]) ]
             ]
         ])
  in
  { name = sprintf "i2c_ctl_v1_l%d_h%d" l h
  ; observables =
      [ "dscl", Uio_oe i2c_scl; "dsda", Uio_oe i2c_sda; "scl", Uio_in i2c_scl; "sda", Uio_in i2c_sda
      ; "pop", Tx_pop_ev; "push", Rx_push_ev ]
  ; watchers = [ clock; cond; frame ]
  }
;;

(* Target (section 3). h_min, l_min, hd in steps (controller timing assumption). Cells are
   keyed on the SCL line. Watchers:
   [frame] H2-H4, B4 (fail 1: target drives a line in a cell it must not (address cells,
   write data cells, read ACK cell); 2: target drives while not addressed; 3: dSDA changes
   in a high phase; 4: written byte not ACKed; 5: read bit value; 6: push missing;
   7: pushed byte differs; blame 8: SDA low while the target releases it in a read cell);
   [stretch] H5 part (fail 1: the target starts pulling SCL while SCL is high);
   [timing] B1 (blame 1: low phase < l_min; 2: high phase < h_min);
   [bytes] B2/B3 and hd (blame 1: SDA changes in a high phase other than the first cell of
   a byte; 2: SCL falls within hd steps of a START/Sr; 3 (D6): SDA changes in the step SCL
   is first seen high, or in the next step of a byte's first cell);
   [idle] B5 (blame 1: SCL low in the first 4 steps).
   Not checked on chip [O]: ACK iff the address matches the config byte (the language has no
   register-to-register comparison and branch conditions cannot read the register), that
   stretching happens only while a read byte is pending, the 2-step stretch response.
   Register: byte1 = config byte (unused by the checks), byte0 = write data / read data. *)
let i2c_tgt ~h_min ~l_min ~hd =
  if h_min < 2 || l_min < 2 || hd < 2 then raise_s [%message "i2c_tgt: bad timing"];
  let dsda = v "dsda" and dscl = v "dscl" and scl = v "scl" and sda = v "sda" and push = v "push" in
  let nscl = !!scl in
  let passive = !!dsda &&& !!dscl in
  let start = fall "sda" &&& scl in
  let cond_env = changed "sda" &&& scl in
  let stuck = [ loop [ hold passive ~for_:4095 ~else_:(fail 2) ] ] in
  let pcell = [ await_idle nscl; await_idle scl; expect passive ~else_:(fail 1) ] in
  let rx_cell k = [ await_idle nscl; await_idle scl; sample (7 - k) sda; expect passive ~else_:(fail 1) ] in
  let write_bytes =
    loop
      (List.concat (List.init 8 ~f:rx_cell)
       @ [ await push (win 1 4095 ~else_:(fail 6)); match_rx ~else_:(fail 7) ]
       @ [ await_idle nscl; await_idle scl; expect dsda ~else_:(fail 4) ])
  in
  let tx_cell k =
    [ await_idle nscl
    ; await_idle scl
    ; expect (eq_reg !!dsda (7 - k)) ~else_:(fail 5)
    ; skip 1
    ; expect ~when_:!!dsda sda ~else_:(blame 8)
    ]
  in
  let read_bytes =
    loop
      ([ take_idle Tx_pop ]
       @ List.concat (List.init 8 ~f:tx_cell)
       @ [ await_idle nscl; await_idle scl; expect passive ~else_:(fail 1); if_ sda stuck [ await_idle nscl ] ])
  in
  let ack_then body = [ await_idle nscl; await_idle scl; if_ dsda [ body ] stuck ] in
  let transaction =
    List.concat (List.init 7 ~f:(fun _ -> pcell))
    @ pcell
    @ [ if_ sda (ack_then read_bytes) (ack_then write_bytes) ]
  in
  let frame =
    watcher
      "frame"
      ~base:0x50
      [ take_idle ~byte:1 Tx_pop
      ; await_idle start
      ; loop [ guard cond_env transaction ~on:[ skip 1; if_ sda [ await_idle start ] [ skip 1 ] ] ]
      ]
  in
  (* while SCL is high the target neither changes dSDA nor starts pulling SCL (it never
     generates START/STOP); replaces per-cell stability checks *)
  let stretch =
    watcher
      "high"
      ~base:0x60
      (* D7: "SCL high" includes the step SCL falls (high in the previous step): at small P the
         pad and synchroniser latency fits in one step, so a pull started while SCL was high
         is seen together with the fall it causes *)
      [ loop [ hold ~when_:(scl ||| fall "scl") (stable "dsda" &&& !!(rise "dscl")) ~for_:4095 ~else_:(fail 1) ] ]
  in
  let timing =
    watcher
      "timing"
      ~base:0x70
      [ loop
          [ await_idle nscl
          ; hold nscl ~for_:(l_min - 1) ~else_:(blame 1)
          ; await_idle scl
            (* D7/D11: SCL low is blamed except in the step where a target pull of SCL (or a
               target SDA change) becomes visible; that step is failed by the high watcher, and
               a persisting pull is blamed only from the next step, so the target's fail is
               never excused. An environment glitch is blamed in its first low step: the
               target changes dSDA only two or more steps after it sees a fall. Same bank
               entry as the high watcher's requirement (WF2: the chip observables are in the
               condition only). D7's one-step-delayed form let a one-step low glitch pass. *)
          ; hold ~when_:(stable "dsda" &&& !!(rise "dscl")) scl ~for_:(h_min - 1) ~else_:(blame 2)
          ]
      ]
  in
  let bytes =
    watcher
      "bytes"
      ~base:0x80
      [ await_idle start
      ; hold scl ~for_:(hd - 1) ~else_:(blame 2)
      ; loop
          [ (* first cell of a byte: a condition may occur in its high phase *)
            await_idle nscl
          ; await_idle scl
            (* D6: no SDA change in the step SCL is first seen high (setup violation), and a
               condition needs SCL high for 2 steps first (the target samples b in the second) *)
          ; expect (stable "sda") ~else_:(blame 3)
          ; skip 1
          ; expect (stable "sda") ~else_:(blame 3)
          ; await_idle (changed "sda" ||| nscl)
          ; if_ nscl
              (List.concat
                 (List.init 8 ~f:(fun _ ->
                    [ await_idle scl
                    ; expect (stable "sda") ~else_:(blame 3)
                    ; hold_until (stable "sda") nscl (win 1 4095 ~else_:(blame 1))
                    ])))
              [ skip 1
              ; if_ sda [ await_idle start; hold scl ~for_:(hd - 1) ~else_:(blame 2) ] [ hold scl ~for_:(hd - 2) ~else_:(blame 2) ]
              ]
          ]
      ]
  in
  let idle = watcher "idle" ~base:0x90 [ hold scl ~for_:4 ~else_:(blame 1) ] in
  { name = sprintf "i2c_tgt_v1_h%d_l%d" h_min l_min
  ; observables =
      [ "dscl", Uio_oe i2c_scl; "dsda", Uio_oe i2c_sda; "scl", Uio_in i2c_scl; "sda", Uio_in i2c_sda
      ; "pop", Tx_pop_ev; "push", Rx_push_ev ]
  ; watchers = [ frame; stretch; timing; bytes; idle ]
  }
;;

(* USB low-speed TX, one DATA packet (doc/protocols/usb_ls_v1.md, guarantees G1-G6, G8, G9 [C];
   G7 contents is proved in the A2 harness, not here). Written from the protocol document
   before the firmware (procedural isolation). One step = one bit (P = 39, bit_period = 1).
   D+ = uio0, D- = uio1, observed as the chip's own outputs. Line states: J = (dp, dm) = (0,1),
   K = (1,0), SE0 = (0,0), SE1 = (1,1) illegal. There is no environment input, so the contract
   has no blame checks: U for this package is "no fail". Predicates have at most 3 literals, so
   driven-ness and SE1 are separate watchers and J/K/SE0 are tested on dp/dm only.
   [drive] (G1): both pins driven in every step after the first one after a restart (first-step
   convention).  [legal] (G2): never SE1.
   [frame]: idle = J (G3); K starts a packet (guard); SYNC tail J K J K J K K (G4); SE0 within
   [1, data_max + 1] steps (G8; data_max = PID 8 + payload 64 + CRC 16 + 14 stuffed bits); then
   SE0 for exactly 2 steps and J for 1 (G6). Between SYNC and SE0 the line is J or K (no SE0 by
   the await, no SE1 by [legal]).
   [runs] (G5) and [status] (G9): see below. The language has only lower-bound elapsed tests,
   so the underrun abort is made observable: the firmware pushes status 2 when it starts the
   abort (doc 2.3). *)
let usb_ls_tx () =
  let dp = v "dp" and dm = v "dm" in
  let j = !!dp &&& dm
  and k = dp &&& !!dm
  and se0 = !!dp &&& !!dm in
  let chg = changed "dp" ||| changed "dm" in
  let data_max = 8 + 64 + 16 + 14 in
  let drive =
    watcher "drive" ~base:0x90 [ skip 1; loop [ hold (v "oe0" &&& v "oe1") ~for_:4095 ~else_:(fail 1) ] ]
  in
  let legal = watcher "legal" ~base:0xD0 [ loop [ hold !!(dp &&& dm) ~for_:4095 ~else_:(fail 1) ] ] in
  let hj = hold j ~for_:1 ~else_:(fail 2)
  and hk = hold k ~for_:1 ~else_:(fail 3) in
  let frame =
    watcher
      "frame"
      ~base:0xA0
      [ loop
          [ guard k
              [ loop [ hold j ~for_:4095 ~else_:(fail 1) ] ]
              ~on:
                [ hj; hk; hj; hk; hj; hk; hk
                ; await se0 (win 1 (data_max + 1) ~else_:(fail 4))
                ; hold se0 ~for_:1 ~else_:(fail 5)
                ; hj
                ]
          ]
      ]
  in
  let push = v "push" in
  (* [runs] (G5): inside a packet a J/K run lasts at most 7 steps. An underrun abort is marked
     by the status push (doc 2.3): after it the line is J until SE0, which comes 7..15 steps
     after the step following the push (J run of at least 8 steps including the push step). *)
  let runs =
    watcher
      "runs"
      ~base:0xB0
      [ loop
          [ await_idle k
          ; guard (se0 ||| push)
              [ loop [ await chg (win 1 7 ~else_:(fail 1)) ] ]
              ~on:
                [ skip 1
                ; if_ (at ~delay:1 "push")
                    [ hold_until j se0 (win 7 15 ~else_:(fail 2)); skip 2 ]
                    [ skip 1 ]
                ]
          ]
      ]
  in
  (* [status] (G9): exactly one push per packet: either the abort push before the EOP, or one
     push within 8 steps after the EOP's J step; none elsewhere inside the packet. *)
  let status =
    watcher
      "status"
      ~base:0xC0
      [ loop
          [ await_idle k
          ; await_idle (push ||| se0)
          ; if_ push
              [ hold_until !!push se0 (win 1 4095 ~else_:(fail 1)); skip 2 ]
              [ skip 2; await push (win 1 8 ~else_:(fail 2)) ]
          ]
      ]
  in
  { name = "usb_ls_tx_v1"
  ; observables =
      [ "dp", Uio_out 0; "dm", Uio_out 1; "oe0", Uio_oe 0; "oe1", Uio_oe 1; "push", Rx_push_ev ]
  ; watchers = [ drive; legal; frame; runs; status ]
  }
;;
