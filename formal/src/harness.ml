(* Formal observer harnesses. Each circuit has exactly one output, [bad]; the proof
   obligation is that [bad] is never 1 from the initial state (AIGER miter output, proven by
   PDR / k-induction after Yosys conversion).

   Initial state convention (applied by formal/run_proofs.sh in Yosys):
   - every register starts at 0, which equals its reset value in spec, RTL and monitor
     (all clears are to 0), i.e. proofs start from reset;
   - except the SRAM output registers (*rtl_imem_dout*), which are left unconstrained (X at
     power-up in silicon).

   A2  program-level: spec running the UART TX program never violates the UART monitor, never
       times out, and completes a frame at least every 10D+5 cycles. Environment: RUN held
       high from reset, reset not re-asserted, uio_in arbitrary every cycle.
   A1  RTL refines spec: pin outputs of RTL (synchronous SRAM fetch) and spec (combinational
       imem) are equal in every cycle, for arbitrary rst_sync_n / ui_in / uio_in sequences
       (so arbitrary programs loaded over the pins, arbitrary RUN toggling and resets).
       Initial imem contents: equal (zero) in both.
   B1  timed QED on the RTL alone: P = uart_tx and T(P) = uart_tx_unrolled produce identical
       uo_out traces, for arbitrary uio_in, RUN held high. No spec involved. *)
open! Core
open Hardcaml
open Signal
open Pemu_spec

(* With [~debug:true] the circuit also exposes internal pins as extra outputs named dbg_<name>, for
   counterexample replay in cyclesim. Only the [~debug:false] circuit is given to the model
   checker (write_aiger -miter ORs all outputs). *)
let bad_circuit ?(debug = false) ?(dbg = []) ~name bad =
  let extra =
    if debug then List.map dbg ~f:(fun (n, s) -> output ("dbg_" ^ n) s) else []
  in
  Circuit.create_exn ~name (output "bad" bad :: extra)

let spec_instance ?rom ~clock ~rst_sync_n ~ui_in ~uio_in () =
  Spec_circuit.create ?rom { Spec_circuit.I.clock; rst_sync_n; ui_in; uio_in }
;;

let rtl_instance ~sram ~clock ~rst_sync_n ~ui_in ~uio_in () =
  Pemu_rtl.Engine.create ~sram { Pemu_rtl.Engine.I.clock; rst_sync_n; ui_in; uio_in }
;;

let a2_uart ?debug ~d () =
  let clock = input "clock" 1
  and uio_in = input "uio_in" 8 in
  let rom = Isa.assemble (Programs.uart_tx ~d) in
  let o =
    spec_instance ~rom ~clock ~rst_sync_n:vdd ~ui_in:(of_int ~width:8 0x80) ~uio_in ()
  in
  let line = bit o.uo_out 0 in
  let m =
    Pemu_monitors.Uart_tx_monitor.create
      ~b:d
      { Pemu_monitors.Uart_tx_monitor.I.clock; clear = gnd; line }
  in
  (* bounded liveness: cycles since reset or since the last frame_done *)
  let bound = (10 * d) + 5 in
  let w = Int.ceil_log2 (bound + 2) in
  let spec_r = Reg_spec.create ~clock () in
  let since =
    reg_fb spec_r ~width:w ~f:(fun c ->
      mux2 m.frame_done (zero w) (mux2 (c ==:. bound + 1) c (c +:. 1)))
  in
  let live_bad = since >:. bound in
  bad_circuit ?debug
    ~dbg:[ "uo_out", o.uo_out; "mon_bad", m.bad; "mon_timeout", m.timeout; "since", since ]
    ~name:(sprintf "a2_uart_d%d" d)
    (m.bad |: m.timeout |: live_bad)
;;

let a1_miter ?debug () =
  let clock = input "clock" 1
  and rst_sync_n = input "rst_sync_n" 1
  and ui_in = input "ui_in" 8
  and uio_in = input "uio_in" 8 in
  let s = spec_instance ~clock ~rst_sync_n ~ui_in ~uio_in () in
  let r =
    rtl_instance
      ~sram:(Pemu_rtl.Sram.behavioural ?name_prefix:None)
      ~clock
      ~rst_sync_n
      ~ui_in
      ~uio_in
      ()
  in
  let differ =
    (s.uo_out <>: r.uo_out) |: (s.uio_out <>: r.uio_out) |: (s.uio_oe <>: r.uio_oe)
  in
  bad_circuit ?debug ~dbg:[ "spec_uo", s.uo_out; "rtl_uo", r.uo_out ] ~name:"a1_miter" differ
;;

(* Bounded variant of A1 restricted to a fixed program in both (ROM spec vs ROM RTL):
   same claim as A1 but for one program, used to measure proof cost. *)
let a1_rom_miter ?debug ~d () =
  let clock = input "clock" 1
  and rst_sync_n = input "rst_sync_n" 1
  and ui_in = input "ui_in" 8
  and uio_in = input "uio_in" 8 in
  let rom = Isa.assemble (Programs.uart_tx ~d) in
  let s = spec_instance ~rom ~clock ~rst_sync_n ~ui_in ~uio_in () in
  let r =
    rtl_instance
      ~sram:(Pemu_rtl.Sram.behavioural_rom ~contents:rom)
      ~clock
      ~rst_sync_n
      ~ui_in
      ~uio_in
      ()
  in
  bad_circuit ?debug ~dbg:[ "spec_uo", s.uo_out; "rtl_uo", r.uo_out ] ~name:(sprintf "a1_rom_d%d" d) (s.uo_out <>: r.uo_out)
;;

let b1_qed ?debug ~d () =
  let clock = input "clock" 1
  and uio_in = input "uio_in" 8 in
  let run ~prog =
    rtl_instance
      ~sram:(Pemu_rtl.Sram.behavioural_rom ~contents:(Isa.assemble prog))
      ~clock
      ~rst_sync_n:vdd
      ~ui_in:(of_int ~width:8 0x80)
      ~uio_in
      ()
  in
  let p = run ~prog:(Programs.uart_tx ~d)
  and t = run ~prog:(Programs.uart_tx_unrolled ~d) in
  bad_circuit ?debug ~dbg:[ "p_uo", p.uo_out; "t_uo", t.uo_out ] ~name:(sprintf "b1_qed_d%d" d) (p.uo_out <>: t.uo_out)
;;

(* Negative control for B1: T'(P) with a deliberate timing error (one unrolled WAIT one
   cycle short). The QED miter must FAIL; otherwise the check is vacuous. *)
let b1_qed_negative ?debug ~d () =
  let clock = input "clock" 1
  and uio_in = input "uio_in" 8 in
  let run ~prog =
    rtl_instance
      ~sram:(Pemu_rtl.Sram.behavioural_rom ~contents:(Isa.assemble prog))
      ~clock
      ~rst_sync_n:vdd
      ~ui_in:(of_int ~width:8 0x80)
      ~uio_in
      ()
  in
  let broken =
    List.mapi (Programs.uart_tx_unrolled ~d) ~f:(fun i ins ->
      if i = 8 then Isa.Wait (d - 3) else ins)
  in
  let p = run ~prog:(Programs.uart_tx ~d)
  and t = run ~prog:broken in
  bad_circuit ?debug ~dbg:[ "p_uo", p.uo_out; "t_uo", t.uo_out ] ~name:(sprintf "b1_qed_neg_d%d" d) (p.uo_out <>: t.uo_out)
;;

(* Negative control for A2: the known-bad program must violate the monitor. *)
let a2_uart_negative ?debug ~d () =
  let clock = input "clock" 1
  and uio_in = input "uio_in" 8 in
  let rom = Isa.assemble (Programs.uart_tx_bad_start ~d) in
  let o =
    spec_instance ~rom ~clock ~rst_sync_n:vdd ~ui_in:(of_int ~width:8 0x80) ~uio_in ()
  in
  let m =
    Pemu_monitors.Uart_tx_monitor.create
      ~b:d
      { Pemu_monitors.Uart_tx_monitor.I.clock; clear = gnd; line = bit o.uo_out 0 }
  in
  bad_circuit ?debug ~dbg:[ "uo_out", o.uo_out ] ~name:(sprintf "a2_uart_neg_d%d" d) m.bad
;;

(* Negative control for A1: RTL whose SRAM model lacks write-through (on MEN & WEN & REN the
   DOUT register holds instead of taking DIN). The RTL load path relies on write-through for
   writes to address 0 while halted, so the miter must FAIL. *)
let sram_no_write_through (i : _ Pemu_rtl.Sram.I.t) =
  let module S = Pemu_rtl.Sram in
  let spec = Reg_spec.create ~clock:i.a_clk () in
  let write = i.a_men &: i.a_wen in
  let read = i.a_men &: i.a_ren in
  let mem =
    List.init S.depth ~f:(fun a ->
      reg spec ~enable:(write &: (i.a_addr ==:. a)) i.a_din -- sprintf "rtl_imem_%d" a)
  in
  let rd = mux i.a_addr mem in
  let dout = reg spec ~enable:(~:write &: read) rd -- "rtl_imem_dout" in
  { S.O.a_dout = dout }
;;

let a1_miter_negative ?debug () =
  let clock = input "clock" 1
  and rst_sync_n = input "rst_sync_n" 1
  and ui_in = input "ui_in" 8
  and uio_in = input "uio_in" 8 in
  let s = spec_instance ~clock ~rst_sync_n ~ui_in ~uio_in () in
  let r = rtl_instance ~sram:sram_no_write_through ~clock ~rst_sync_n ~ui_in ~uio_in () in
  let differ =
    (s.uo_out <>: r.uo_out) |: (s.uio_out <>: r.uio_out) |: (s.uio_oe <>: r.uio_oe)
  in
  bad_circuit ?debug ~dbg:[ "spec_uo", s.uo_out; "rtl_uo", r.uo_out ] ~name:"a1_miter_neg" differ
;;

(* Registry: every harness by name, for the emitter and the counterexample replayer. *)
let all ?debug () =
  List.concat_map [ 3; 4 ] ~f:(fun d ->
    [ a2_uart ?debug ~d ()
    ; a2_uart_negative ?debug ~d ()
    ; a1_rom_miter ?debug ~d ()
    ; b1_qed ?debug ~d ()
    ; b1_qed_negative ?debug ~d ()
    ])
  @ [ a1_miter ?debug (); a1_miter_negative ?debug () ]
;;

let find ?debug name =
  List.find_exn (all ?debug ()) ~f:(fun c -> String.equal (Circuit.name c) name)
;;
