(* Core v1 with the monitor engine (ROM library), through its pins. Lane 0 runs UART TX with
   the UART TX v1 guarantee package; lane 1 runs a loop with a blame package on ui_in[3].
   Checks: T8 admission (P = 6 refused, FLAGS bit 4), no firing for the correct program,
   first fail (code, unit, time) for a faulty program, fail pin, verdict clear, blame
   release faulting lane 1 with cause BLAME, and per-lane observation masking (OWN). *)
open! Core
open Pemu_spec_v1
open Pemu_monitor_v1
open Test_top

let blame_pkg =
  let open Lang in
  { name = "blame_ui3"
  ; observables = [ "x", Ui 3 ]
  ; watchers = [ watcher "w" ~base:0x40 [ loop [ hold (v "x") ~for_:4 ~else_:(blame 1) ] ] ]
  }
;;

let lib () =
  [ Compile.compile_exn (Library_v1.uart_tx ~d:3 ~pin:0); Compile.compile_exn blame_pkg ]
;;

let set_pkg h ~lane ~idx (p : Mprog.t) =
  write h (0x50 + (8 * lane)) [ 0x80 lor idx ];
  write h (0x60 + (16 * lane)) (Array.to_list p.remap)
;;

let verdict h =
  let v = read h 0x40 12 in
  let b k = List.nth_exn v k in
  let t k = b k lor (b (k + 1) lsl 8) lor (b (k + 2) lsl 16) lor (b (k + 3) lsl 24) in
  sprintf "VERDICT 0x%02X FIRST_FAIL 0x%02X FIRST_BLAME 0x%02X UNITS 0x%02X FAIL_TIME %d BLAME_TIME %d"
    (b 0) (b 1) (b 2) (b 3) (t 4) (t 8)
;;

let%expect_test "core v1 + monitor engine over SPI" =
  let lib = lib () in
  let h = create ~lib ~ui_hi:1 () in
  (* lane 0: UART TX d = 3 on uio[0], guarantee package 0 *)
  write h 0x10 [ 0x01 ];
  write h 0x12 [ 6; 0 ];
  load h ~lane:0 (Programs_v1.uart_tx ~d:3);
  set_pkg h ~lane:0 ~idx:0 (List.nth_exn lib 0);
  write h 0x01 [ 0x01 ];
  printf "P=6: STATUS 0x%02X L0 FLAGS 0x%02X (bit4 run refused)\n" (List.hd_exn (read h 0x02 1))
    (List.hd_exn (read h 0x1D 1));
  write h 0x01 [ 0x00 ];
  write h 0x12 [ 9; 0 ];
  write h 0x19 [ 0xA5 ];
  write h 0x19 [ 0x3C ];
  h.trace <- [];
  write h 0x01 [ 0x01 ];
  wait h 1200;
  printf "P=9 correct program: STATUS 0x%02X L0 FLAGS 0x%02X\n  %s\n" (List.hd_exn (read h 0x02 1))
    (List.hd_exn (read h 0x1D 1)) (verdict h);
  (* faulty program: start bit one step long *)
  write h 0x01 [ 0x00 ];
  load h ~lane:0 (Programs_v1.uart_tx_bad_start ~d:3);
  write h 0x01 [ 0x10 ];
  write h 0x19 [ 0xA5 ];
  h.trace <- [];
  write h 0x01 [ 0x01 ];
  wait h 600;
  let uo, _, _ = List.hd_exn h.trace in
  printf "start d+1: fail pin uo[1] %d blame pin uo[2] %d STATUS 0x%02X\n  %s\n" ((uo lsr 1) land 1)
    ((uo lsr 2) land 1) (List.hd_exn (read h 0x02 1)) (verdict h);
  write h 0x01 [ 0x11 ];
  printf "after CLR_VERDICT: %s\n" (verdict h);
  (* lane 1: loop, blame package on ui_in[3], release on blame *)
  write h 0x01 [ 0x00 ];
  write h 0x20 [ 0x02 ];
  write h 0x22 [ 7; 0 ];
  write h 0x25 [ 0x01 ];
  load h ~lane:1 Isa1.[ Wait 2; Jmp 0 ];
  set_pkg h ~lane:1 ~idx:1 (List.nth_exn lib 1);
  write h 0x01 [ 0x12 ];
  wait h 300;
  printf "lane 1 running, ui3 high: STATUS 0x%02X FAULT 0x%02X\n" (List.hd_exn (read h 0x02 1))
    (List.hd_exn (read h 0x03 1));
  h.ui_hi <- 0;
  wait h 300;
  printf "ui3 low: STATUS 0x%02X FAULT 0x%02X (L1 cause in [7:4], 2 = BLAME)\n  %s\n"
    (List.hd_exn (read h 0x02 1)) (List.hd_exn (read h 0x03 1)) (verdict h);
  [%expect {|
    P=6: STATUS 0x04 L0 FLAGS 0x14 (bit4 run refused)
    P=9 correct program: STATUS 0x05 L0 FLAGS 0x04
      VERDICT 0x00 FIRST_FAIL 0x00 FIRST_BLAME 0x00 UNITS 0x00 FAIL_TIME 0 BLAME_TIME 0
    start d+1: fail pin uo[1] 1 blame pin uo[2] 0 STATUS 0x45
      VERDICT 0x01 FIRST_FAIL 0x13 FIRST_BLAME 0x00 UNITS 0x00 FAIL_TIME 13680 BLAME_TIME 0
    after CLR_VERDICT: VERDICT 0x00 FIRST_FAIL 0x00 FIRST_BLAME 0x00 UNITS 0x00 FAIL_TIME 0 BLAME_TIME 0
    lane 1 running, ui3 high: STATUS 0x0E FAULT 0x00
    ui3 low: STATUS 0xAC FAULT 0x20 (L1 cause in [7:4], 2 = BLAME)
      VERDICT 0x06 FIRST_FAIL 0x00 FIRST_BLAME 0x41 UNITS 0x00 FAIL_TIME 0 BLAME_TIME 21838
    |}]
;;

(* Structural non-interference with the engine present (same check as test_top.ml): the
   fan-in of every input of lane L reaches no signal built by the other lane's prescaler or
   Lane_rtl.create except through the other lane's OWN register. *)
let%expect_test "structural non-interference between lanes, engine present" =
  let open Hardcaml in
  let open Pemu_rtl_v1 in
  let i =
    { Top_v1.I.clock = Signal.input "clock" 1
    ; rst_sync_n = Signal.input "rst_sync_n" 1
    ; ui_in = Signal.input "ui_in" 8
    ; uio_in = Signal.input "uio_in" 8
    }
  in
  let _, d =
    Top_v1.create_with_debug ~lib:(lib ()) ~sram:(fun _ x -> fst (Sram256.behavioural x)) i
  in
  let in_ranges l u = List.exists d.lane_uids.(l) ~f:(fun (a, b) -> u > a && u < b) in
  let hits ~l ~boundary =
    let other = 1 - l in
    let roots =
      Lane_rtl.I.to_list d.lane_inputs.(l) |> List.filter ~f:(fun s -> not (Signal.is_empty s))
    in
    let g = Signal_graph.create ?upto:(if boundary then Some [ d.own.(other) ] else None) roots in
    Signal_graph.fold g ~init:0 ~f:(fun n s ->
      if in_ranges other (Signal.Type.Uid.to_int (Signal.uid s)) then n + 1 else n)
  in
  List.iter [ 0; 1 ] ~f:(fun l ->
    printf "lane %d inputs: other-lane signals reached with OWN boundary %d, without %d\n" l
      (hits ~l ~boundary:true) (hits ~l ~boundary:false));
  [%expect {|
    lane 0 inputs: other-lane signals reached with OWN boundary 0, without 4110
    lane 1 inputs: other-lane signals reached with OWN boundary 0, without 4110
    |}]
;;

(* UART program on uio[1] *)
let on_pin1 prog =
  List.map prog ~f:(function
    | Isa1.Out 1 -> Isa1.Out 2
    | Oen 1 -> Oen 2
    | Pin (0, a) -> Pin (1, a)
    | x -> x)
;;

let write_store h ~lane img =
  let b = 0x50 + (8 * lane) in
  (* consecutive image words from address a0 *)
  let img = List.sort img ~compare:(fun (a, _) (b, _) -> Int.compare a b) in
  let a0 = fst (List.hd_exn img) in
  List.iteri img ~f:(fun k (a, _) -> assert (a = a0 + k));
  write h (b + 4) [ a0 ];
  write h (b + 5) (List.concat_map img ~f:(fun (_, w) -> [ w land 0xFF; w lsr 8 ]))
;;

(* Lane 0 runs a program with the UART package from ROM (units 0, 1); lane 1 runs the same
   program on uio[1] with the same package loaded into its store (units 6, 7). Both start
   with one CTRL write and use the same P, so their steps coincide: verdict stamps must be
   equal. *)
let lockstep ?(debug = false) ?(quiet = false) ~bad0 ~bad1 () =
  let rom0 = Compile.compile_exn (Library_v1.uart_tx ~d:3 ~pin:0)
  and ld1 = Compile.compile_exn (Library_v1.uart_tx ~d:3 ~pin:1) in
  let h = create ~lib:[ rom0 ] () in
  let printf fmt = if quiet then Printf.ifprintf stdout fmt else printf fmt in
  let pr b = if b then Programs_v1.uart_tx_bad_start ~d:3 else Programs_v1.uart_tx ~d:3 in
  (* lane 0: ROM package *)
  write h 0x10 [ 0x01 ];
  write h 0x12 [ 13; 0 ];
  load h ~lane:0 (pr bad0);
  set_pkg h ~lane:0 ~idx:0 rom0;
  (* lane 1: loadable package: header at 0, unit 6 program at 56, unit 7 at 56 + 6 * 12 *)
  write h 0x20 [ 0x02 ];
  write h 0x22 [ 13; 0 ];
  load h ~lane:1 (on_pin1 (pr bad1));
  let n6 = Array.length ld1.units.(0).code in
  let img = Mprog.store_image ld1 ~ctx_base:0 ~bases:[ 56; 56 + (6 * n6) ] in
  write_store h ~lane:1 img;
  write h 0x5A [ 0 ];
  write h 0x58 [ 0x80 ];
  write h 0x70 (Array.to_list ld1.remap);
  write h 0x59 [ 0x03 ];
  printf "  loadable, context not loaded: L1 LOAD_UNITS 0x%02X\n" (List.hd_exn (read h 0x59 1));
  write h 0x01 [ 0x02 ];
  printf "  RUN L1 refused (ctx not loaded): STATUS 0x%02X L1 FLAGS 0x%02X\n" (List.hd_exn (read h 0x02 1))
    (List.hd_exn (read h 0x2D 1));
  write h 0x01 [ 0x00 ];
  write h 0x59 [ 0x83 ];
  printf "  after LOAD: L1 LOAD_UNITS 0x%02X (bit5 ctx_loaded)\n" (List.hd_exn (read h 0x59 1));
  write h 0x22 [ 12; 0 ];
  write h 0x01 [ 0x02 ];
  printf "  P=12, two loadable units: STATUS 0x%02X L1 FLAGS 0x%02X\n" (List.hd_exn (read h 0x02 1))
    (List.hd_exn (read h 0x2D 1));
  write h 0x01 [ 0x00 ];
  write h 0x22 [ 13; 0 ];
  write h 0x19 [ 0xA5 ];
  write h 0x29 [ 0xA5 ];
  write h 0x19 [ 0x5A ];
  write h 0x29 [ 0x5A ];
  if debug
  then (
    let g n = match Hardcaml.Cyclesim.lookup_node_or_reg_by_name h.sim n with
      | Some x -> Hardcaml.Cyclesim.Node.to_int x | None -> -1 in
    let c = ref 0 and on = ref false and shown = ref 0 in
    (Test_top.cycle_hook := fun () ->
      incr c;
      if g "lane_running" >= 0 then ();
      if (g "mon_dbg_issue1" = 1 || g "mon_dbg_tick1" = 1 || g "mon_dbg_act1" = 1) then on := true;
      if !on && !shown < 40 then (
        incr shown;
        printf "c%5d tick %d cur %d act %d pc6 %d pc7 %d irv6 %d irpc6 %d irv7 %d irpc7 %d issue %d u %d ipc %d late %d\n" !c
        (g "mon_dbg_tick1") (g "mon_dbg_cur1") (g "mon_dbg_act1") (g "mon_dbg_pc6_1") (g "mon_dbg_pc7_1")
        (g "mon_dbg_irv6_1") (g "mon_dbg_irpc6_1") (g "mon_dbg_irv7_1") (g "mon_dbg_irpc7_1")
        (g "mon_dbg_issue1") (g "mon_dbg_issu1") (g "mon_dbg_isspc1") (g "mon_dbg_late_now1")));
    write h 0x01 [ 0x03 ];
    wait h 1500;
    Test_top.cycle_hook := fun () -> ())
  else (write h 0x01 [ 0x03 ]; wait h 1500);
  let st = List.hd_exn (read h 0x02 1) in
  let v = verdict h in
  printf "  P=13 both lanes: STATUS 0x%02X\n  %s\n" st v;
  v
;;

let%expect_test "ROM package (lane 0) and the same package loaded (lane 1) in lockstep" =
  print_endline "correct program on both lanes:";
  ignore (lockstep ~bad0:false ~bad1:false () : string);
  print_endline "start bit d+1 on lane 0 only (ROM package):";
  print_endline (lockstep ~quiet:true ~bad0:true ~bad1:false ());
  print_endline "start bit d+1 on lane 1 only (loaded package):";
  print_endline (lockstep ~quiet:true ~bad0:false ~bad1:true ());
  [%expect {|
    correct program on both lanes:
      loadable, context not loaded: L1 LOAD_UNITS 0x03
      RUN L1 refused (ctx not loaded): STATUS 0x0C L1 FLAGS 0x14
      after LOAD: L1 LOAD_UNITS 0x23 (bit5 ctx_loaded)
      P=12, two loadable units: STATUS 0x0C L1 FLAGS 0x14
      P=13 both lanes: STATUS 0x0F
      VERDICT 0x00 FIRST_FAIL 0x00 FIRST_BLAME 0x00 UNITS 0x00 FAIL_TIME 0 BLAME_TIME 0
    start bit d+1 on lane 0 only (ROM package):
    VERDICT 0x01 FIRST_FAIL 0x13 FIRST_BLAME 0x00 UNITS 0x00 FAIL_TIME 42208 BLAME_TIME 0
    start bit d+1 on lane 1 only (loaded package):
    VERDICT 0x09 FIRST_FAIL 0x13 FIRST_BLAME 0x00 UNITS 0x06 FAIL_TIME 42208 BLAME_TIME 0
    |}]
;;
