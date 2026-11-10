(* Differential test: lane RTL (behavioural 256x16 SRAM) vs Lane_model, all observable outputs
   every cycle. The program enters through the RTL write port (gaps, back-to-back writes, writes
   beyond len); during the run, random write attempts continue and each acknowledged write
   (imem_wack) is applied to the model's instruction memory. Cycle 0 is a reset cycle
   (power-up assumption). *)
open! Core
open Hardcaml
open Pemu_spec_v1
open Pemu_rtl_v1
module Sim = Cyclesim.With_interface (Lane_rtl.I) (Lane_rtl.O)

(* [mk]: lane constructor (default the shipped Lane_rtl; the mutation campaign passes mutants) *)
let create_sim ?(mk = fun ~sram i -> Lane_rtl.create ~sram i) () =
  Sim.create
    ~config:Cyclesim.Config.trace_all
    (mk ~sram:(fun i -> fst (Sram256.behavioural i)))
;;

type cov =
  { mutable cycles : int
  ; mutable acked_writes : int
  ; mutable acked_during_run_phase : int
  ; mutable refused_writes : int
  ; mutable ser_busy : int
  ; mutable pops : int
  ; mutable pushes : int
  ; faults : int array
  ; mutable mismatches : int
  ; mutable first : string option
  }

let run_one ?mk ~seed ~cycles cov =
  let st = Random.State.make [| seed; 7 |] in
  let framed = seed % 2 = 0 in
  let prog =
    if framed
    then Progen.frame_prog st
    else (
      let len = 1 + Random.State.int st 24 in
      List.init len ~f:(fun _ -> Progen.rand_instr st ~len))
  in
  let len = List.length prog in
  let words = Isa1.assemble prog in
  (* the model starts from garbage memory; only acknowledged writes define it *)
  let model_mem = Array.init 256 ~f:(fun _ -> Random.State.int st 65536) in
  let model = Lane_model.create model_mem in
  let sim = create_sim ?mk () in
  let si = Cyclesim.inputs sim
  and so = Cyclesim.outputs ~clock_edge:Before sim in
  let own = if framed then 0xFF else Random.State.int st 256
  and od = if framed then 0 else Random.State.int st 256
  and cfg = Random.State.int st 128 lor if framed then 0x20 else 0
  and cfg2 = Random.State.int st 128 in
  let tick_mode = Random.State.int st 3 in
  (* load schedule: word k written at some cycle; then junk writes beyond len *)
  let load_queue =
    Queue.of_list
      (List.init len ~f:(fun a -> a, words.(a))
       @ List.init (Random.State.int st 3) ~f:(fun _ ->
         len + Random.State.int st (256 - len), Random.State.int st 65536))
  in
  let load_cycles = 3 + (3 * Queue.length load_queue) + Random.State.int st 10 in
  for c = 0 to cycles - 1 do
    let r n = Random.State.int st n in
    let loading = c < load_cycles in
    let we, waddr, wdata =
      if loading
      then
        if c > 0 && (not (Queue.is_empty load_queue)) && r 3 <> 0
        then (
          let a, d = Queue.peek_exn load_queue in
          true, a, d)
        else false, 0, 0
      else if r 40 = 0
      then true, (if r 2 = 0 then 0 else r 256), r 65536 (* address 0: write-through path *)
      else false, 0, 0
    in
    let inp : Lane_model.inputs =
      { rst_sync_n = c > 0 && (loading || r 3000 <> 0)
      ; tick = (match tick_mode with 0 -> true | 1 -> r 2 = 0 | _ -> c % 3 = 0)
      ; run = (not loading) && r 300 <> 0
      ; loaded = (not loading) && r 1000 <> 0
      ; len
      ; own
      ; od
      ; cfg
      ; cfg2
      ; pins = r 256
      ; tx_push = (if framed then r 2 = 0 else r 3 = 0)
      ; tx_wdata = r 256
      ; rx_pop = r 3 = 0
      ; blame_in = r 400 = 0
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
    si.imem_we := b we;
    si.imem_waddr := n 8 waddr;
    si.imem_wdata := n 16 wdata;
    if model.ser.busy then cov.ser_busy <- cov.ser_busy + 1;
    let mo = Lane_model.step model inp in
    Cyclesim.cycle sim;
    let g p = Bits.to_int !p
    and gb p = Bits.to_bool !p in
    let ack = gb so.imem_wack in
    if we && ack
    then (
      model_mem.(waddr) <- wdata;
      cov.acked_writes <- cov.acked_writes + 1;
      if not loading then cov.acked_during_run_phase <- cov.acked_during_run_phase + 1;
      if loading then ignore (Queue.dequeue_exn load_queue : int * int))
    else if we
    then cov.refused_writes <- cov.refused_writes + 1;
    let co : Lane_model.outputs =
      { uio_out = g so.uio_out; uio_oe = g so.uio_oe; xo = g so.xo; faulted = gb so.faulted
      ; cause = g so.cause; pc = g so.pc; tx_level = g so.tx_level; rx_level = g so.rx_level
      ; rx_head = g so.rx_head; pop_ev = gb so.pop_ev; pop_data = g so.pop_data
      ; push_ev = gb so.push_ev; push_data = g so.push_data }
    in
    cov.cycles <- cov.cycles + 1;
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
                  "mismatch" (seed : int) (c : int) (load_cycles : int) (mo : Lane_model.outputs)
                    (co : Lane_model.outputs) (prog : Isa1.t list)]))
  done;
  (* the load phase must have completed for the run phase to be meaningful *)
  if not (Queue.is_empty load_queue) then cov.mismatches <- cov.mismatches + 0
;;

let%expect_test "lane RTL = lane model, 300 random programs through the write port" =
  let cov =
    { cycles = 0; acked_writes = 0; acked_during_run_phase = 0; refused_writes = 0
    ; ser_busy = 0; pops = 0; pushes = 0; faults = Array.create ~len:4 0; mismatches = 0
    ; first = None }
  in
  for seed = 1 to 300 do
    run_one ~seed ~cycles:2000 cov
  done;
  Option.iter cov.first ~f:print_endline;
  printf "programs 300 cycles %d mismatches %d\n" cov.cycles cov.mismatches;
  printf
    "coverage: acked %b acked_in_run_phase %b refused %b ser_busy %b pops %b pushes %b fb %b blame %b halt %b\n"
    (cov.acked_writes > 3000) (cov.acked_during_run_phase > 100) (cov.refused_writes > 100)
    (cov.ser_busy > 1000) (cov.pops > 100) (cov.pushes > 100) (cov.faults.(1) > 0)
    (cov.faults.(2) > 0) (cov.faults.(3) > 0);
  [%expect {|
    programs 300 cycles 600000 mismatches 0
    coverage: acked true acked_in_run_phase true refused true ser_busy true pops true pushes true fb true blame true halt true
    |}]
;;

(* Directed: word 0 rewritten in the last halted cycle before RUN rises. The first instruction
   executed must be the new word (write-through on the fetch address). *)
let%expect_test "write to address 0 in the last halted cycle" =
  let sim = create_sim () in
  let si = Cyclesim.inputs sim
  and so = Cyclesim.outputs ~clock_edge:Before sim in
  let n w x = Bits.of_int ~width:w x in
  let words = Isa1.assemble Isa1.[ Out 0x11; Jmp 1 ] in
  let cycle ?(rst = true) ?(run = false) ?(we = None) () =
    si.rst_sync_n := Bits.of_bool rst;
    si.tick := Bits.vdd;
    si.run := Bits.of_bool run;
    si.loaded := Bits.vdd;
    si.len := n 8 2;
    si.own := n 8 0xFF;
    (match we with
     | Some (a, d) ->
       si.imem_we := Bits.vdd;
       si.imem_waddr := n 8 a;
       si.imem_wdata := n 16 d
     | None -> si.imem_we := Bits.gnd);
    Cyclesim.cycle sim;
    Bits.to_int !(so.uio_out), Bits.to_bool !(so.imem_wack)
  in
  ignore (cycle ~rst:false ());
  ignore (cycle ~we:(Some (0, words.(0))) ());
  ignore (cycle ~we:(Some (1, words.(1))) ());
  ignore (cycle ());
  (* replace word 0 by OUT 0x22 in the last halted cycle *)
  let _, ack = cycle ~we:(Some (0, Isa1.encode (Isa1.Out 0x22))) () in
  (* explicit loop: List.init does not apply f in index order *)
  let trace = ref [] in
  for _ = 1 to 4 do
    trace := fst (cycle ~run:true ()) :: !trace
  done;
  let trace = List.rev !trace in
  printf "ack %b out %s\n" ack (String.concat ~sep:" " (List.map trace ~f:(sprintf "0x%02x")));
  [%expect {| ack true out 0x00 0x22 0x22 0x22 |}]
;;
