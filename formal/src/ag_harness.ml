(* Assume-guarantee harnesses for the feasibility spike (doc/concept/assume_guarantee.md).
   Same conventions as harness.ml: one output [bad], all registers start at 0 (= reset
   state), the SRAM output register (RTL harnesses) is free.

   U     spec core running uart_tx(d) || hardwired monitor of the contract, environment
         completely free (rst_sync_n, ui_in, uio_in arbitrary every cycle):
         bad = fail_flag && !blame_flag   (no fail without an earlier or same-cycle blame)
   N1    as U, environment constrained to the reference behaviour R_P (RUN rises once and
         stays high; other pins and reset free): bad = fail_flag || blame_flag
   A1MON hardwired monitor == ROM engine on the same compiled program, all monitor inputs
         free: bad = any verdict output differs
   URTL  RTL core (synchronous SRAM fetch) || ROM engine, environment free: U end to end on
         the implementation side, as a cross-check of the composition A1 + A1MON + U.

   Negative controls (expected FAIL): no assumption; known-bad program; blame delayed past
   the earliest possible fail; over-strong assumption (N1); planted engine bugs (A1MON). *)
open! Core
open Hardcaml
open Signal
open Pemu_spec
module C = Pemu_contracts
module MC = C.Mon_circuit

let mon_inputs ~clock ~rst_sync_n ~ui_in ~uio_in (o : _ Spec_circuit.O.t) =
  { MC.I.clock; rst_sync_n; ui_in; uio_in; uo_out = o.uo_out; uio_out = o.uio_out; uio_oe = o.uio_oe }
;;

let dbg (o : _ Spec_circuit.O.t) (m : _ MC.O.t) =
  [ "uo_out", o.uo_out; "fail", m.fail_flag; "blame", m.blame_flag; "ff", m.first_fail
  ; "fb", m.first_blame ]
;;

let u_spec ?debug ?(prog = `Good) ~contract ~name ~d () =
  let clock = input "clock" 1
  and rst_sync_n = input "rst_sync_n" 1
  and ui_in = input "ui_in" 8
  and uio_in = input "uio_in" 8 in
  let program =
    match prog with
    | `Good -> Programs.uart_tx ~d
    | `Bad_start -> Programs.uart_tx_bad_start ~d
  in
  let s =
    Harness.spec_instance ~rom:(Isa.assemble program) ~clock ~rst_sync_n ~ui_in ~uio_in ()
  in
  let m = MC.Hardwired.create (C.Program.compile contract) (mon_inputs ~clock ~rst_sync_n ~ui_in ~uio_in s) in
  Harness.bad_circuit ?debug ~dbg:(dbg s m) ~name (m.fail_flag &: ~:(m.blame_flag))
;;

let n1_spec ?debug ~contract ~name ~d () =
  let clock = input "clock" 1
  and rst_sync_n = input "rst_sync_n" 1
  and go = input "go" 1
  and ui_low = input "ui_low" 7
  and uio_in = input "uio_in" 8 in
  (* R_P: the RUN pin rises once (when [go]) and stays high; not affected by reset *)
  let run_r = wire 1 in
  let run = run_r |: go in
  run_r <== reg (Reg_spec.create ~clock ()) run -- "env_run";
  let ui_in = run @: ui_low in
  let s =
    Harness.spec_instance
      ~rom:(Isa.assemble (Programs.uart_tx ~d))
      ~clock
      ~rst_sync_n
      ~ui_in
      ~uio_in
      ()
  in
  let m = MC.Hardwired.create (C.Program.compile contract) (mon_inputs ~clock ~rst_sync_n ~ui_in ~uio_in s) in
  Harness.bad_circuit ?debug ~dbg:(dbg s m) ~name (m.fail_flag |: m.blame_flag)
;;

let a1mon ?debug ?bug ~contract ~name () =
  let i =
    { MC.I.clock = input "clock" 1
    ; rst_sync_n = input "rst_sync_n" 1
    ; ui_in = input "ui_in" 8
    ; uio_in = input "uio_in" 8
    ; uo_out = input "uo_out" 8
    ; uio_out = input "uio_out" 8
    ; uio_oe = input "uio_oe" 8
    }
  in
  let p = C.Program.compile contract in
  let h = MC.Hardwired.create p i
  and e = C.Engine.create_rom ?bug p i in
  let differ =
    MC.O.to_list (MC.O.map2 h e ~f:(fun a b -> a <>: b)) |> List.reduce_exn ~f:( |: )
  in
  Harness.bad_circuit
    ?debug
    ~dbg:[ "h_fail", h.fail_flag; "e_fail", e.fail_flag; "h_ff", h.first_fail; "e_ff", e.first_fail ]
    ~name
    differ
;;

let u_rtl ?debug ~contract ~name ~d () =
  let clock = input "clock" 1
  and rst_sync_n = input "rst_sync_n" 1
  and ui_in = input "ui_in" 8
  and uio_in = input "uio_in" 8 in
  let rom = Isa.assemble (Programs.uart_tx ~d) in
  let r =
    Harness.rtl_instance
      ~sram:(Pemu_rtl.Sram.behavioural_rom ~contents:rom)
      ~clock
      ~rst_sync_n
      ~ui_in
      ~uio_in
      ()
  in
  let o = { Spec_circuit.O.uo_out = r.uo_out; uio_out = r.uio_out; uio_oe = r.uio_oe } in
  let m = C.Engine.create_rom (C.Program.compile contract) (mon_inputs ~clock ~rst_sync_n ~ui_in ~uio_in o) in
  Harness.bad_circuit ?debug ~dbg:(dbg o m) ~name (m.fail_flag &: ~:(m.blame_flag))
;;

let all ?debug () =
  let lib = C.Library.uart_tx_v01 in
  List.concat_map [ 3; 4 ] ~f:(fun d ->
    [ u_spec ?debug ~contract:(lib ~d ()) ~name:(sprintf "u_spec_uart_d%d" d) ~d ()
    ; n1_spec ?debug ~contract:(lib ~d ()) ~name:(sprintf "n1_spec_uart_d%d" d) ~d ()
    ; a1mon ?debug ~contract:(lib ~d ()) ~name:(sprintf "a1mon_uart_d%d" d) ()
    ; u_rtl ?debug ~contract:(lib ~d ()) ~name:(sprintf "u_rtl_uart_d%d" d) ~d ()
    ])
  @ [ u_spec ?debug ~contract:(lib ~blame_delay:1 ~d:4 ()) ~name:"u_spec_uart_delay1_d4" ~d:4 ()
    ; u_spec
        ?debug
        ~contract:(lib ~blame_delay:2 ~d:4 ())
        ~name:"u_spec_uart_delay2_neg_d4"
        ~d:4
        ()
    ; u_spec
        ?debug
        ~contract:(lib ~with_assumption:false ~d:4 ())
        ~name:"u_spec_uart_noassume_neg_d4"
        ~d:4
        ()
    ; u_spec
        ?debug
        ~prog:`Bad_start
        ~contract:(lib ~d:4 ())
        ~name:"u_spec_uart_badprog_neg_d4"
        ~d:4
        ()
    ; n1_spec
        ?debug
        ~contract:(lib ~overstrong:true ~d:4 ())
        ~name:"n1_spec_uart_overstrong_neg_d4"
        ~d:4
        ()
    ; a1mon
        ?debug
        ~contract:(lib ~blame_delay:2 ~overstrong:true ~d:4 ())
        ~name:"a1mon_uart_variant_d4"
        ()
    ; a1mon
        ?debug
        ~bug:`Window_off_by_one
        ~contract:(lib ~d:4 ())
        ~name:"a1mon_window_neg_d4"
        ()
    ; a1mon ?debug ~bug:`Code_off_by_one ~contract:(lib ~d:4 ()) ~name:"a1mon_code_neg_d4" ()
    ]
  (* scaling: proof cost of U against the bit period (window lengths) *)
  @ List.concat_map [ 6; 8 ] ~f:(fun d ->
    [ u_spec ?debug ~contract:(lib ~d ()) ~name:(sprintf "u_spec_uart_d%d" d) ~d ()
    ; u_rtl ?debug ~contract:(lib ~d ()) ~name:(sprintf "u_rtl_uart_d%d" d) ~d ()
    ])
  @ List.map [ 12; 16 ] ~f:(fun d ->
    u_spec ?debug ~contract:(lib ~d ()) ~name:(sprintf "u_spec_uart_d%d" d) ~d ())
;;
