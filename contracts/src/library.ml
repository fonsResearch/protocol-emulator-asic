(* Contracts used by the feasibility spike (doc/contracts/contracts_v0.md section 0).

   uart_tx_v01: UART 8N1 TX by the v0.1 core running doc/isa/isa_v0.md section 6, bit period
   d. TX = uo_out[0], RUN = ui_in[7]. Guarantee in exact form (doc/protocols/uart.md: within
   a frame the line changes only on the d-grid, start low, stop high) plus a progress bound;
   one assumption: RUN, once high, never drops (v0.1 drives 0 while halted, so any halt
   breaks the line; known v0 issue, decision 6).

   Variants (negative controls and margin experiments):
   - [~blame_delay k]: the assumption fires k cycles after RUN is seen low (k = 0 normal);
   - [~with_assumption:false]: no assumption watcher (U must fail: the assumption is needed);
   - [~overstrong:true]: adds a blame on any change of uio_in[0] (N1 must fail). *)
open! Core
open Contract

let uart_tx_v01 ?(blame_delay = 0) ?(with_assumption = true) ?(overstrong = false) ~d () =
  let host_run =
    watcher
      "host_run"
      ~base:0x80
      ([ await_idle (v "run"); await_idle (!!(v "run")) ]
       @ (if blame_delay > 0 then [ skip blame_delay ] else [])
       @ [ raise_ (blame 1) ])
  in
  let frame =
    watcher
      "frame"
      ~base:0x10
      [ await_idle (v "run") (* c0: first running cycle; OUT 0x01 executes here *)
      ; hold (v "tx") ~for_:1 ~else_:(fail 1) (* line high from c0+1 *)
      ; loop
          [ await_idle (!!(v "tx")) (* start bit, first low cycle a *)
          ; hold (!!(v "tx")) ~for_:(d - 1) ~else_:(fail 2) (* start bit exactly d *)
          ; repeat
              8
              [ skip 1 (* a change is allowed on the grid *)
              ; hold (stable "tx") ~for_:(d - 1) ~else_:(fail 3)
              ]
          ; hold (v "tx") ~for_:d ~else_:(fail 4) (* stop bit *)
          ]
      ]
  in
  let progress =
    watcher
      "progress"
      ~base:0x20
      [ await_idle (v "run")
      ; await (fall "tx") ~within:(1, 5) ~else_:(fail 1) (* first start bit *)
      ; loop
          [ skip ((10 * d) - 1)
          ; await (fall "tx") ~within:(1, 5) ~else_:(fail 2) (* next start bit *)
          ]
      ]
  in
  let nosy =
    watcher "nosy" ~base:0x90 [ await_idle (changed "d0"); raise_ (blame 1) ]
  in
  { name = sprintf "uart_tx_v01_d%d" d
  ; clock_hz = 50_000_000
  ; observables = [ "tx", Uo 0; "run", Ui 7; "d0", Uio_in 0 ]
  ; watchers =
      (if with_assumption then [ host_run ] else [])
      @ [ frame; progress ]
      @ if overstrong then [ nosy ] else []
  }
;;
