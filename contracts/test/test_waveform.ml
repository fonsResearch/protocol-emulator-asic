open! Core
open Hardcaml
open Hardcaml_waveterm
open Pemu_contracts

(* Spec core running uart_tx(4) with the hardwired monitor of its contract, for waveforms. *)
module I = struct
  type 'a t =
    { clock : 'a
    ; rst_sync_n : 'a
    ; ui_in : 'a [@bits 8]
    ; uio_in : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { tx : 'a
    ; run_pin : 'a
    ; blame : 'a
    ; fail : 'a
    ; first_blame : 'a [@bits 8]
    ; first_fail : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

let create (i : _ I.t) =
  let s =
    Pemu_spec.Spec_circuit.create
      ~rom:(Pemu_spec.Isa.assemble (Pemu_spec.Programs.uart_tx ~d:4))
      { clock = i.clock; rst_sync_n = i.rst_sync_n; ui_in = i.ui_in; uio_in = i.uio_in }
  in
  let m =
    Mon_circuit.Hardwired.create
      (Program.compile (Library.uart_tx_v01 ~d:4 ()))
      { clock = i.clock
      ; rst_sync_n = i.rst_sync_n
      ; ui_in = i.ui_in
      ; uio_in = i.uio_in
      ; uo_out = s.uo_out
      ; uio_out = s.uio_out
      ; uio_oe = s.uio_oe
      }
  in
  { O.tx = Signal.bit s.uo_out 0
  ; run_pin = Signal.bit i.ui_in 7
  ; blame = m.blame_flag
  ; fail = m.fail_flag
  ; first_blame = m.first_blame
  ; first_fail = m.first_fail
  }
;;

module Sim = Cyclesim.With_interface (I) (O)

let%expect_test "waveform: RUN dropped at cycle 103; blame (0x81) at 105 precedes fail (0x13) at 106" =
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Waveform.create sim in
  let i = Cyclesim.inputs sim in
  let cyc ~rst ~ui =
    i.rst_sync_n := Bits.of_bool (not rst);
    i.ui_in := Bits.of_int ~width:8 ui;
    i.uio_in := Bits.of_int ~width:8 0x5a;
    Cyclesim.cycle sim
  in
  for _ = 1 to 3 do cyc ~rst:true ~ui:0 done;
  for _ = 1 to 100 do cyc ~rst:false ~ui:0x80 done;
  for _ = 1 to 12 do cyc ~rst:false ~ui:0x00 done;
  Waveform.print ~display_height:30 ~display_width:110 ~wave_width:0 ~start_cycle:98 waves;
  [%expect {|
    ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────────────────────────┐
    │clock             ││┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐│
    │                  ││ └┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└│
    │rst_sync_n        ││──────────────────────────────────                                                      │
    │                  ││                                                                                        │
    │                  ││──────────┬───────────────────────                                                      │
    │ui_in             ││ 80       │00                                                                           │
    │                  ││──────────┴───────────────────────                                                      │
    │                  ││──────────────────────────────────                                                      │
    │uio_in            ││ 5A                                                                                     │
    │                  ││──────────────────────────────────                                                      │
    │blame             ││              ┌───────────────────                                                      │
    │                  ││──────────────┘                                                                         │
    │fail              ││                ┌─────────────────                                                      │
    │                  ││────────────────┘                                                                       │
    │                  ││──────────────┬───────────────────                                                      │
    │first_blame       ││ 00           │81                                                                       │
    │                  ││──────────────┴───────────────────                                                      │
    │                  ││────────────────┬─────────────────                                                      │
    │first_fail        ││ 00             │13                                                                     │
    │                  ││────────────────┴─────────────────                                                      │
    │run_pin           ││──────────┐                                                                             │
    │                  ││          └───────────────────────                                                      │
    │tx                ││          ┌─────┐                                                                       │
    │                  ││──────────┘     └─────────────────                                                      │
    │gnd               ││                                                                                        │
    │                  ││──────────────────────────────────                                                      │
    │                  ││────────────┬───┬─┬───────────────                                                      │
    │mon_prev          ││ 5A80000000 │5A.│.│5A00000000                                                           │
    └──────────────────┘└────────────────────────────────────────────────────────────────────────────────────────┘
    |}]
;;
