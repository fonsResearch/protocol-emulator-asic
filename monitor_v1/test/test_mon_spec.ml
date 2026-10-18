(* ISA spec circuit (Mon_spec, cyclesim) against the ISA model (Mmodel), unit firings compared
   every cycle, on compiled random packages and the UART TX package. *)
open! Core
open Hardcaml
open Pemu_monitor_v1
module Sim = Cyclesim.With_interface (Mon_spec.I) (Mon_spec.O)

let sim_of p = Sim.create (Mon_spec.of_package p)

let step_sim sim (i : Interp.inputs) =
  let si : _ Mon_spec.I.t = Cyclesim.inputs sim
  and so : _ Mon_spec.O.t = Cyclesim.outputs ~clock_edge:Before sim in
  let b x = Bits.of_bool x
  and n w x = Bits.of_int ~width:w x in
  si.rst_sync_n := b i.rst_sync_n;
  si.running := b i.running;
  si.tick := b i.tick;
  si.ui_in := n 8 i.ui_in;
  si.uio_in := n 8 i.uio_in;
  si.uo_out := n 8 i.uo_out;
  si.uio_out := n 8 i.uio_out;
  si.uio_oe := n 8 i.uio_oe;
  si.pop_ev := b i.pop_ev;
  si.pop_data := n 8 i.pop_data;
  si.push_ev := b i.push_ev;
  si.push_data := n 8 i.push_data;
  Cyclesim.cycle sim;
  let fire = Bits.to_int !(so.fire)
  and role = Bits.to_int !(so.role) in
  List.filter_mapi so.codes ~f:(fun u c ->
    if (fire lsr u) land 1 = 1
    then Some ((if (role lsr u) land 1 = 1 then Lang.Blame else Lang.Fail), Bits.to_int !c)
    else None)
;;

let%expect_test "spec circuit = ISA model, random packages" =
  let pk = ref 0 and cycles = ref 0 and firings = ref 0 and mism = ref 0 and first = ref None in
  let seed = ref 0 and mexp = ref 0 and hazard = ref 0 in
  while !pk < 200 do
    incr seed;
    let st = Random.State.make [| !seed; 11 |] in
    let c = Test_mmodel.gen_contract st in
    match Compile.compile c with
    | Error _ -> ()
    | Ok p ->
      incr pk;
      Array.iter p.units ~f:(fun up ->
        Array.iter up.code ~f:(fun (ins : Mprog.instr) ->
          if ins.md_exp then incr mexp;
          if ins.md_exp && (ins.mark <> 0 || Option.is_some ins.smp) then incr hazard));
      let m = Mmodel.create p and sim = sim_of p in
      for cy = 0 to 400 do
        let i = Test_mmodel.random_inputs st cy in
        let fm = Mmodel.step m i and fs = step_sim sim i in
        incr cycles;
        firings := !firings + List.length fm;
        if not ([%equal: (Lang.role * int) list] fm fs)
        then (
          incr mism;
          if Option.is_none !first
          then first := Some (sprintf "seed %d cycle %d model [%s] circuit [%s]" !seed cy
                                (Test_mmodel.show fm) (Test_mmodel.show fs)))
      done
  done;
  Option.iter !first ~f:print_endline;
  printf "packages %d cycles %d firings %d mismatches %d\n" !pk !cycles !firings !mism;
  printf "instructions with md_exp %d, of which share a bundle with mark/sample %d\n" !mexp !hazard;
  [%expect {|
    packages 200 cycles 80200 firings 1984 mismatches 0
    instructions with md_exp 141, of which share a bundle with mark/sample 59
    |}]
;;

let%expect_test "UART TX package: spec circuit = ISA model on lane traces" =
  let open Pemu_spec_v1 in
  let d = 4 in
  let good = Programs_v1.uart_tx ~d in
  let replace k ins = List.mapi good ~f:(fun i x -> if i = k then ins else x) in
  let p = Compile.compile_exn (Library_v1.uart_tx ~d ~pin:0) in
  List.iter
    [ "correct", good; "start d+1", Programs_v1.uart_tx_bad_start ~d
    ; "MSB first", replace 6 (Isa1.Pin (0, Out_msb)); "stop d-1", replace 10 (Isa1.Wait (d - 3)) ]
    ~f:(fun (name, prog) ->
      let mism = ref 0 and fm_n = ref 0 in
      for seed = 1 to 5 do
        let st = Random.State.make [| seed |] in
        let pdiv = Random.State.int st 4 in
        let lane = Lane_model.create (Isa1.assemble prog) in
        let m = Mmodel.create p and sim = sim_of p in
        let cnt = ref 0 and prev = ref false in
        for cy = 0 to 5999 do
          let r n = Random.State.int st n in
          let rst = cy > 0 and run = r 5000 <> 0 in
          let running = rst && run in
          if not (running && !prev) then cnt := 0;
          let tick = running && !cnt = pdiv in
          let o =
            Lane_model.step lane
              { rst_sync_n = rst; tick; run; loaded = true; len = List.length prog; own = 1; od = 0
              ; cfg = 0; cfg2 = 0; pins = 0; tx_push = r 30 = 0; tx_wdata = r 256; rx_pop = false
              ; blame_in = false; clear_fault = false }
          in
          let i : Interp.inputs =
            { rst_sync_n = rst; running; tick; ui_in = 0; uio_in = 0; uo_out = 0; uio_out = o.uio_out
            ; uio_oe = o.uio_oe; pop_ev = o.pop_ev; pop_data = o.pop_data; push_ev = o.push_ev
            ; push_data = o.push_data }
          in
          let fm = Mmodel.step m i and fs = step_sim sim i in
          fm_n := !fm_n + List.length fm;
          if not ([%equal: (Lang.role * int) list] fm fs) then incr mism;
          cnt := if running then if tick then 0 else !cnt + 1 else 0;
          prev := running
        done
      done;
      printf "%-10s firings %3d mismatches %d\n" name !fm_n !mism);
  [%expect {|
    correct    firings   0 mismatches 0
    start d+1  firings  11 mismatches 0
    MSB first  firings  11 mismatches 0
    stop d-1   firings  11 mismatches 0
    |}]
;;
