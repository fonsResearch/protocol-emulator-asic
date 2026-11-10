(* Time-multiplexed lane (Mon_lane) against the ISA spec circuit (Mon_spec), cyclesim.
   Ticks are at least [spacing] cycles apart; non-running cycles are frequent, including
   inside slot windows. A Mon_spec firing of unit u at step c must appear in Mon_lane at
   cycle c + u (same role and code), and Mon_lane must fire nothing else; steps whose
   window c..c+7 contains a reset cycle are excluded. *)
open! Core
open Hardcaml
open Pemu_monitor_v1
module Sim_l = Cyclesim.With_interface (Mon_lane.I) (Mon_lane.O)

let set_inputs (si : Bits.t ref Mon_spec.I.t) (i : Interp.inputs) =
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
  si.push_data := n 8 i.push_data
;;

(* inputs with tick spacing >= spacing among ticks of running cycles *)
let spaced_inputs ~spacing st =
  let last = ref (-1000) in
  fun cy ->
    let i = Test_mmodel.random_inputs st cy in
    let i = { i with running = i.running && Random.State.int st 6 <> 0 } in
    let tick = i.tick && cy - !last >= spacing in
    let stepping = tick && i.running && i.rst_sync_n in
    if stepping then last := cy;
    { i with tick }
;;

(* fill all 8 units by repeating the compiled watchers (shared tables, so still valid) *)
let fill8 ?(n_to = Mon_spec.n_units) (p : Mprog.t) =
  let n = Array.length p.units in
  { p with units = Array.init n_to ~f:(fun k -> p.units.(k mod n)) }
;;

(* [slots] (v2): Mon_lane slot count; with [fill] every package gets exactly [slots] units *)
let run ?(slots = Mon_spec.n_units) ?(fill = false) ~spacing ~packages ~cycles ~seed0 () =
  let pk = ref 0 and steps = ref 0 and firings = ref 0 and mism = ref 0 and overruns = ref 0 in
  let excluded = ref 0 and first = ref None in
  let seed = ref seed0 in
  while !pk < packages do
    incr seed;
    let st = Random.State.make [| !seed; 23 |] in
    match Compile.compile (Test_mmodel.gen_contract st) with
    | Error _ -> ()
    | Ok p when Array.length p.units > slots && not fill -> ignore p
    | Ok p ->
      let p = if fill then fill8 ~n_to:slots p else p in
      incr pk;
      let ss = Test_mon_spec.sim_of p
      and sl = Sim_l.create (Mon_lane.of_package ~slots p) in
      let inp = spaced_inputs ~spacing st in
      let lo : _ Mon_lane.O.t = Cyclesim.outputs ~clock_edge:Before sl in
      let expected = Hashtbl.create (module Int) (* cycle -> (unit, role, code) *)
      and got = Hashtbl.create (module Int)
      and rst_cycles = Hash_set.create (module Int)
      and step_cycles = ref [] in
      for cy = 0 to cycles - 1 do
        let i = inp cy in
        if not i.rst_sync_n then Hash_set.add rst_cycles cy;
        if i.rst_sync_n && i.running && i.tick then step_cycles := cy :: !step_cycles;
        set_inputs (Cyclesim.inputs sl) i;
        let fs = Test_mon_spec.step_sim ss i in
        Cyclesim.cycle sl;
        if Bits.to_bool !(lo.overrun) then incr overruns;
        if Bits.to_bool !(lo.fire)
        then
          Hashtbl.set got ~key:cy
            ~data:
              ( Bits.to_int !(lo.unit_)
              , (if Bits.to_bool !(lo.role) then Lang.Blame else Lang.Fail)
              , Bits.to_int !(lo.code) );
        (* the spec reports per unit; recover the unit index from its fire vector *)
        let so : _ Mon_spec.O.t = Cyclesim.outputs ~clock_edge:Before ss in
        let fv = Bits.to_int !(so.fire) in
        ignore fs;
        for u = 0 to Mon_spec.n_units - 1 do
          if (fv lsr u) land 1 = 1
          then
            Hashtbl.set expected ~key:(cy + u)
              ~data:
                ( u
                , (if (Bits.to_int !(so.role) lsr u) land 1 = 1 then Lang.Blame else Lang.Fail)
                , Bits.to_int !(List.nth_exn so.codes u) )
        done
      done;
      (* compare over windows of steps with no reset cycle *)
      List.iter !step_cycles ~f:(fun c ->
        if List.exists (List.init slots ~f:(fun d -> c + d)) ~f:(Hash_set.mem rst_cycles)
           || c + slots - 1 >= cycles
        then incr excluded
        else (
          incr steps;
          for d = 0 to slots - 1 do
            let e = Hashtbl.find expected (c + d)
            and g = Hashtbl.find got (c + d) in
            Option.iter e ~f:(fun _ -> incr firings);
            if not ([%equal: (int * Lang.role * int) option] e g)
            then (
              incr mism;
              if Option.is_none !first
              then
                first
                := Some
                     (sprintf "seed %d step %d slot %d: spec %s lane %s" !seed c d
                        (Sexp.to_string ([%sexp_of: (int * Lang.role * int) option] e))
                        (Sexp.to_string ([%sexp_of: (int * Lang.role * int) option] g))))
          done))
  done;
  Option.iter !first ~f:print_endline;
  printf "%s%sspacing %d: packages %d steps %d (excluded %d) firings %d mismatches %d overruns %d\n"
    (if slots = Mon_spec.n_units then "" else sprintf "%d slots, " slots)
    (if fill then sprintf "%d units, " slots else "") spacing !pk !steps !excluded !firings !mism !overruns
;;

let%expect_test "time-multiplexed lane = spec circuit" =
  run ~spacing:8 ~packages:200 ~cycles:3000 ~seed0:0 ();
  run ~fill:true ~spacing:8 ~packages:200 ~cycles:3000 ~seed0:500 ();
  run ~spacing:13 ~packages:50 ~cycles:3000 ~seed0:1000 ();
  (* assumption broken: shows it is needed *)
  run ~fill:true ~spacing:7 ~packages:50 ~cycles:3000 ~seed0:2000 ();
  [%expect {|
    spacing 8: packages 200 steps 66623 (excluded 1323) firings 24673 mismatches 0 overruns 0
    8 units, spacing 8: packages 200 steps 66656 (excluded 1319) firings 109065 mismatches 0 overruns 0
    spacing 13: packages 50 steps 10636 (excluded 224) firings 4188 mismatches 0 overruns 0
    seed 2006 step 2990 slot 7: spec ((7 Blame 6)) lane ()
    8 units, spacing 7: packages 50 steps 18780 (excluded 362) firings 30921 mismatches 3310 overruns 10237
    |}]
;;

(* Shipped v2 configuration: 5 slots, pipelined slot schedule (Mon_lane ~pipe:true, firing of
   unit u in step c at cycle c + u + 1). [mk] builds the lane under test from the package tables
   (default the shipped Mon_lane; the mutation campaign passes mutants). Stops at the first
   package with a mismatch when [stop_first]. Returns (packages, steps, firings, mismatches,
   first mismatch). *)
let diff_pipe ?mk ?(stop_first = false) ?(slots = 5) ~spacing ~packages ~cycles ~seed0 () =
  let mk =
    match mk with
    | Some f -> f
    | None -> fun ~tables ~present ~fetch i -> Mon_lane.create ~slots ~pipe:true ~tables ~present ~fetch i
  in
  let pk = ref 0 and steps = ref 0 and firings = ref 0 and mism = ref 0 and first = ref None in
  let seed = ref seed0 in
  while !pk < packages && not (stop_first && !mism > 0) do
    incr seed;
    let st = Random.State.make [| !seed; 23 |] in
    match Compile.compile (Test_mmodel.gen_contract st) with
    | Error _ -> ()
    | Ok p when Array.length p.units > slots -> ignore p
    | Ok p ->
      let p = if !seed % 2 = 0 then fill8 ~n_to:slots p else p in
      incr pk;
      let ss = Test_mon_spec.sim_of p in
      let tables = Mon_spec.tables_of_package p in
      let present = Array.map tables.present ~f:(fun b -> if b then Signal.vdd else Signal.gnd) in
      let fetch u pc = Signal.mux u (List.init Mon_spec.n_units ~f:(fun k -> Mon_spec.rom_fetch p k pc)) in
      let sl = Sim_l.create (mk ~tables ~present ~fetch) in
      let inp = spaced_inputs ~spacing st in
      let lo : _ Mon_lane.O.t = Cyclesim.outputs ~clock_edge:Before sl in
      let expected = Hashtbl.create (module Int)
      and got = Hashtbl.create (module Int)
      and rst_cycles = Hash_set.create (module Int)
      and step_cycles = ref [] in
      for cy = 0 to cycles - 1 do
        let i = inp cy in
        if not i.rst_sync_n then Hash_set.add rst_cycles cy;
        if i.rst_sync_n && i.running && i.tick then step_cycles := cy :: !step_cycles;
        set_inputs (Cyclesim.inputs sl) i;
        ignore (Test_mon_spec.step_sim ss i);
        Cyclesim.cycle sl;
        if Bits.to_bool !(lo.fire)
        then
          Hashtbl.set got ~key:cy
            ~data:
              ( Bits.to_int !(lo.unit_)
              , (if Bits.to_bool !(lo.role) then Lang.Blame else Lang.Fail)
              , Bits.to_int !(lo.code) );
        let so : _ Mon_spec.O.t = Cyclesim.outputs ~clock_edge:Before ss in
        let fv = Bits.to_int !(so.fire) in
        for u = 0 to Mon_spec.n_units - 1 do
          if (fv lsr u) land 1 = 1
          then
            Hashtbl.set expected ~key:(cy + u + 1)
              ~data:
                ( u
                , (if (Bits.to_int !(so.role) lsr u) land 1 = 1 then Lang.Blame else Lang.Fail)
                , Bits.to_int !(List.nth_exn so.codes u) )
        done
      done;
      List.iter !step_cycles ~f:(fun c ->
        if List.exists (List.init (slots + 1) ~f:(fun d -> c + d)) ~f:(Hash_set.mem rst_cycles)
           || c + slots >= cycles
        then ()
        else (
          incr steps;
          for d = 1 to slots do
            let e = Hashtbl.find expected (c + d)
            and g = Hashtbl.find got (c + d) in
            Option.iter e ~f:(fun _ -> incr firings);
            if not ([%equal: (int * Lang.role * int) option] e g)
            then (
              incr mism;
              if Option.is_none !first
              then
                first
                := Some
                     (sprintf "seed %d step %d slot %d: spec %s lane %s" !seed c (d - 1)
                        (Sexp.to_string ([%sexp_of: (int * Lang.role * int) option] e))
                        (Sexp.to_string ([%sexp_of: (int * Lang.role * int) option] g))))
          done))
  done;
  !pk, !steps, !firings, !mism, !first
;;

let%expect_test "shipped v2 lane (5 slots, pipelined schedule) = spec circuit" =
  let show (pk, steps, firings, mism, first) =
    Option.iter first ~f:print_endline;
    printf "packages %d steps %d firings %d mismatches %d\n" pk steps firings mism
  in
  show (diff_pipe ~spacing:5 ~packages:200 ~cycles:3000 ~seed0:6000 ());
  show (diff_pipe ~spacing:9 ~packages:50 ~cycles:3000 ~seed0:6500 ());
  (* assumption broken (ticks 4 apart): shows the comparison is not vacuous *)
  show (diff_pipe ~spacing:4 ~packages:50 ~cycles:3000 ~seed0:7000 ());
  [%expect {|
    packages 200 steps 101313 firings 59876 mismatches 0
    packages 50 steps 15075 firings 10179 mismatches 0
    seed 7004 step 2683 slot 0: spec ((4 Blame 3)) lane ()
    packages 50 steps 30521 firings 14374 mismatches 1481
    |}]
;;

(* v2 (doc/decisions/arch_v2_options.md V2-2): 5 slots, assumption T5 *)
let%expect_test "time-multiplexed lane, 5 slots = spec circuit" =
  run ~slots:5 ~spacing:5 ~packages:200 ~cycles:3000 ~seed0:3000 ();
  run ~slots:5 ~fill:true ~spacing:5 ~packages:200 ~cycles:3000 ~seed0:3500 ();
  run ~slots:5 ~fill:true ~spacing:9 ~packages:50 ~cycles:3000 ~seed0:4000 ();
  (* assumption broken (T4): shows it is needed *)
  run ~slots:5 ~fill:true ~spacing:4 ~packages:50 ~cycles:3000 ~seed0:4500 ();
  [%expect {|
    5 slots, spacing 5: packages 200 steps 101632 (excluded 1197) firings 32435 mismatches 0 overruns 0
    5 slots, 5 units, spacing 5: packages 200 steps 101646 (excluded 1205) firings 112451 mismatches 0 overruns 0
    5 slots, 5 units, spacing 9: packages 50 steps 15080 (excluded 171) firings 17659 mismatches 0 overruns 0
    seed 4501 step 2890 slot 4: spec ((4 Fail 4)) lane ()
    5 slots, 5 units, spacing 4: packages 50 steps 30670 (excluded 387) firings 37539 mismatches 5613 overruns 16827
    |}]
;;
