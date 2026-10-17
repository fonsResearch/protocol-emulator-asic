(* Differential test: Lane_model (reference interpreter) vs Lane_circuit (spec-as-circuit),
   random legal programs and random host/pin stimulus, all outputs compared every cycle.
   Coverage counters guard against a vacuous pass. *)
open! Core
open Hardcaml
open Pemu_spec_v1
module Sim = Cyclesim.With_interface (Lane_circuit.I) (Lane_circuit.O)

let regs = Isa1.[ R0; R1; R2; R3; Sr; Lc ]
let regs5 = Isa1.[ R0; R1; R2; R3; Sr ]

let rand_instr st ~len : Isa1.t =
  let open Isa1 in
  let pick l = List.nth_exn l (Random.State.int st (List.length l)) in
  let tgt () = Random.State.int st (len + 1) in
  let v () = Random.State.int st 256 in
  let small () = pick [ 0; 1; 2; 3; 5; 255; v () ] in
  match Random.State.int st 20 with
  | 0 -> Jmp (tgt ())
  | 1 -> Br (Random.State.int st 16, tgt ())
  | 2 -> Out (v ())
  | 3 -> Oen (v ())
  | 4 -> Pin (Random.State.int st 8, pick [ Out_lsb; Out_msb; In_lsb; In_msb ])
  | 5 -> Wait (pick [ 0; 1; 2; 3; 7 ])
  | 6 -> Wtp (Random.State.int st 8, pick [ Low; High; Rising; Falling ])
  | 7 ->
    Ldi
      ( pick [ L (pick regs); To_lo; Xo ]
      , (match Random.State.int st 3 with 0 -> pick [ 0; 1; 2; 3 ] | _ -> small ()) )
  | 8 ->
    Mov
      ( pick [ M (pick regs); Out_reg; Oe_reg ]
      , pick [ S (pick regs); Pins; Ser_status ] )
  | 9 -> Cmp (pick [ C (pick regs); Cpins ], small ())
  | 10 -> Addi (pick regs, small ())
  | 11 -> Pop (pick regs5)
  | 12 -> Push (pick regs5)
  | 13 | 14 | 15 ->
    Ser (pick [ Send (pick regs5); Sendc (pick regs5); Crci; Crcs; Eop; Period (pick regs5); Idle ])
  | 16 -> Djnz (tgt ())
  | 17 -> Nop
  | 18 -> if Random.State.int st 4 = 0 then Halt else Nop
  | _ -> Clrt
;;

(* Structured family: CRC-protected frames (CRCI; n x POP/SENDC; CRCS; EOP; IDLE), so that
   coding paths (CRC5/16, stuffing, NRZI, EOP, contiguous SENDs) are visible on owned pins. *)
let frame_prog st : Isa1.t list =
  let open Isa1 in
  let n = 1 + Random.State.int st 4 and per = Random.State.int st 4 in
  [ Ldi (L Lc, n); Ldi (L R1, per); Ser (Period R1); Ser Crci; Pop R0; Ser (Sendc R0)
  ; Djnz 4; Ser Crcs; Ser Eop; Ser Idle; Wait (Random.State.int st 3); Jmp 0 ]
;;

type cov =
  { mutable cycles : int
  ; mutable steps : int
  ; mutable ser_busy : int
  ; mutable se0 : int
  ; mutable stuff : int
  ; mutable timeouts : int
  ; mutable pops : int
  ; mutable pushes : int
  ; mutable faults : int array
  ; mutable mismatches : int
  ; mutable first : string option
  }

let run_one ~seed ~cycles cov =
  let st = Random.State.make [| seed |] in
  let framed = seed % 2 = 0 in
  let prog =
    if framed
    then frame_prog st
    else (
      let len = 1 + Random.State.int st 24 in
      List.init len ~f:(fun _ -> rand_instr st ~len))
  in
  let len = List.length prog in
  let words = Isa1.assemble prog in
  let model = Lane_model.create words in
  let sim =
    Sim.create ~config:Cyclesim.Config.trace_all
      (Lane_circuit.create ~imem:(Lane_circuit.imem_rom words))
  in
  let si = Cyclesim.inputs sim
  and so = Cyclesim.outputs ~clock_edge:Before sim in
  let own = if framed then 0xFF else Random.State.int st 256
  and od = if framed then 0 else Random.State.int st 256
  and cfg = Random.State.int st 128 lor if framed then 0x20 else 0
  and cfg2 = Random.State.int st 128 in
  let tick_mode = Random.State.int st 3 in
  let prev_t = ref false in
  for c = 0 to cycles - 1 do
    let r n = Random.State.int st n in
    let inp : Lane_model.inputs =
      { rst_sync_n = c > 1 && r 2000 <> 0
      ; tick = (match tick_mode with 0 -> true | 1 -> r 2 = 0 | _ -> c % 3 = 0)
      ; run = (if framed then r 3000 <> 0 else r 300 <> 0)
      ; loaded = (if framed then r 10000 <> 0 else r 1000 <> 0)
      ; len
      ; own
      ; od
      ; cfg
      ; cfg2
      ; pins = r 256
      ; tx_push = (if framed then r 2 = 0 else r 3 = 0)
      ; tx_wdata = r 256
      ; rx_pop = r 3 = 0
      ; blame_in = (if framed then r 4000 = 0 else r 400 = 0)
      ; clear_fault = r 50 = 0
      }
    in
    let b x = if x then Bits.vdd else Bits.gnd in
    let n w x = Bits.of_int ~width:w x in
    si.rst_sync_n := b inp.rst_sync_n;
    si.tick := b inp.tick;
    si.run := b inp.run;
    si.loaded := b inp.loaded;
    si.len := n 8 inp.len;
    si.own := n 8 inp.own;
    si.od := n 8 inp.od;
    si.cfg := n 8 inp.cfg;
    si.cfg2 := n 8 inp.cfg2;
    si.pins := n 8 inp.pins;
    si.tx_push := b inp.tx_push;
    si.tx_wdata := n 8 inp.tx_wdata;
    si.rx_pop := b inp.rx_pop;
    si.blame_in := b inp.blame_in;
    si.clear_fault := b inp.clear_fault;
    let ser = model.ser in
    if ser.busy then cov.ser_busy <- cov.ser_busy + 1;
    if ser.busy && ser.se0 then cov.se0 <- cov.se0 + 1;
    if ser.stuff_pending then cov.stuff <- cov.stuff + 1;
    let mo = Lane_model.step model inp in
    Cyclesim.cycle sim;
    if model.t_flag && not !prev_t then cov.timeouts <- cov.timeouts + 1;
    prev_t := model.t_flag;
    let g p = Bits.to_int !p and gb p = Bits.to_bool !p in
    let co : Lane_model.outputs =
      { uio_out = g so.uio_out; uio_oe = g so.uio_oe; xo = g so.xo; faulted = gb so.faulted
      ; cause = g so.cause; pc = g so.pc; tx_level = g so.tx_level; rx_level = g so.rx_level
      ; rx_head = g so.rx_head; pop_ev = gb so.pop_ev; pop_data = g so.pop_data
      ; push_ev = gb so.push_ev; push_data = g so.push_data }
    in
    cov.cycles <- cov.cycles + 1;
    if inp.tick && inp.run && inp.loaded && inp.rst_sync_n then cov.steps <- cov.steps + 1;
    if mo.pop_ev then cov.pops <- cov.pops + 1;
    if mo.push_ev then cov.pushes <- cov.pushes + 1;
    if mo.faulted && mo.cause > 0 then cov.faults.(mo.cause) <- cov.faults.(mo.cause) + 1;
    if not (Lane_model.equal_outputs mo co)
    then (
      cov.mismatches <- cov.mismatches + 1;
      if Option.is_none cov.first
      then
        cov.first
        <- Some
             (Sexp.to_string_hum
                [%message
                  "mismatch" (seed : int) (c : int) (mo : Lane_model.outputs)
                    (co : Lane_model.outputs)
                    (prog : Isa1.t list)]))
  done
;;

let%expect_test "lane model = lane circuit, random programs" =
  let cov =
    { cycles = 0; steps = 0; ser_busy = 0; se0 = 0; stuff = 0; timeouts = 0; pops = 0
    ; pushes = 0; faults = Array.create ~len:4 0; mismatches = 0; first = None }
  in
  for seed = 1 to 300 do
    run_one ~seed ~cycles:2000 cov
  done;
  Option.iter cov.first ~f:print_endline;
  printf "programs 300 cycles %d mismatches %d\n" cov.cycles cov.mismatches;
  printf "coverage: ser_busy %b se0 %b stuff %b timeouts %b pops %b pushes %b fb %b blame %b halt %b\n"
    (cov.ser_busy > 1000) (cov.se0 > 100) (cov.stuff > 10) (cov.timeouts > 10) (cov.pops > 100)
    (cov.pushes > 100) (cov.faults.(1) > 0) (cov.faults.(2) > 0) (cov.faults.(3) > 0);
  [%expect {|
    programs 300 cycles 600000 mismatches 0
    coverage: ser_busy true se0 true stuff true timeouts true pops true pushes true fb true blame true halt true
    |}]
;;
