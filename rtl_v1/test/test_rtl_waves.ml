(* Waveform of the lane RTL running the UART TX reference program (spec_v1/Programs_v1,
   d = 3 steps per bit, tick every cycle): program load through the write port, then one byte
   0xA5 from the host TX FIFO. Pin 0 is TX (push-pull); the line idles high. *)
open! Core
open Hardcaml
open Hardcaml_waveterm
open Pemu_spec_v1
open Pemu_rtl_v1
module Sim = Cyclesim.With_interface (Lane_rtl.I) (Lane_rtl.O)

let%expect_test "UART TX 0xA5 on the lane RTL" =
  let sim =
    Sim.create ~config:Cyclesim.Config.trace_all
      (Lane_rtl.create ~sram:(fun i -> fst (Sram256.behavioural i)))
  in
  let waves, sim = Waveform.create sim in
  let si = Cyclesim.inputs sim in
  let prog = Programs_v1.uart_tx ~d:3 in
  let words = Isa1.assemble prog in
  let n w x = Bits.of_int ~width:w x in
  si.len := n 8 (List.length prog);
  si.own := n 8 0x01;
  si.tick := Bits.vdd;
  si.rst_sync_n := Bits.gnd;
  Cyclesim.cycle sim;
  si.rst_sync_n := Bits.vdd;
  List.iteri prog ~f:(fun a _ ->
    si.imem_we := Bits.vdd;
    si.imem_waddr := n 8 a;
    si.imem_wdata := n 16 words.(a);
    Cyclesim.cycle sim);
  si.imem_we := Bits.gnd;
  si.loaded := Bits.vdd;
  si.run := Bits.vdd;
  for c = 0 to 45 do
    si.tx_push := Bits.of_bool (c = 3);
    si.tx_wdata := n 8 0xA5;
    Cyclesim.cycle sim
  done;
  let display_rules =
    List.map [ "tx_push"; "pc"; "tx_level"; "pop_ev"; "uio_oe"; "uio_out" ] ~f:(fun n ->
      Display_rule.port_name_is n ~wave_format:(if String.equal n "pc" then Unsigned_int else Hex))
  in
  Waveform.print
    ~display_rules
    ~display_height:20
    ~display_width:130
    ~wave_width:0
    ~start_cycle:13
    waves;
  [%expect {|
    ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────────────────────────────────────────────┐
    │                  ││──────┬─┬───────────────────────────────────────────────────────────────────────────────────                │
    │tx_push           ││ 0    │1│0                                                                                                  │
    │                  ││──────┴─┴───────────────────────────────────────────────────────────────────────────────────                │
    │                  ││──┬─┬─────┬─┬─┬───┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬───┬─┬─────────────────                │
    │pc                ││ 0│1│2    │3│4│5  │6│7│8│6│7│8│6│7│8│6│7│8│6│7│8│6│7│8│6│7│8│6│7│8│9│10 │.│2                                │
    │                  ││──┴─┴─────┴─┴─┴───┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴───┴─┴─────────────────                │
    │                  ││────────┬─┬─────────────────────────────────────────────────────────────────────────────────                │
    │tx_level          ││ 0      │1│0                                                                                                │
    │                  ││────────┴─┴─────────────────────────────────────────────────────────────────────────────────                │
    │                  ││────────┬─┬─────────────────────────────────────────────────────────────────────────────────                │
    │pop_ev            ││ 0      │1│0                                                                                                │
    │                  ││────────┴─┴─────────────────────────────────────────────────────────────────────────────────                │
    │                  ││────┬───────────────────────────────────────────────────────────────────────────────────────                │
    │uio_oe            ││ 00 │01                                                                                                     │
    │                  ││────┴───────────────────────────────────────────────────────────────────────────────────────                │
    │                  ││──┬───────────┬─────┬─────┬─────┬─────┬───────────┬─────┬─────┬─────────────────────────────                │
    │uio_out           ││ .│01         │00   │01   │00   │01   │00         │01   │00   │01                                           │
    │                  ││──┴───────────┴─────┴─────┴─────┴─────┴───────────┴─────┴─────┴─────────────────────────────                │
    └──────────────────┘└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
    |}]
;;
