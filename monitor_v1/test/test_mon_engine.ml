(* Mon_engine directly (cyclesim), directed: context writes are refused while the slots of a
   halted lane's last step are pending, and accepted once the sequencer is idle. *)
open! Core
open Hardcaml
open Signal
open Pemu_monitor_v1

let%expect_test "PKG write refused during pending slots" =
  let p = Compile.compile_exn (Library_v1.uart_tx ~d:3 ~pin:0) in
  let inp n w = input n w in
  let lanes =
    Array.init 2 ~f:(fun l ->
      { Mon_engine.running = inp (sprintf "running%d" l) 1; tick = inp (sprintf "tick%d" l) 1
      ; uo_out = zero 8; uio_out = zero 8; uio_oe = zero 8; pop_ev = gnd; pop_data = zero 8
      ; push_ev = gnd; push_data = zero 8 })
  in
  let e =
    Mon_engine.create ~clock:(inp "clock" 1) ~rst_sync_n:(inp "rst_sync_n" 1) ~lib:[ p; p ]
      ~host:{ wr = inp "wr" 1; addr = inp "addr" 7; wdata = inp "wdata" 8; clr_verdict = gnd }
      ~lanes ~ui_in:(zero 8) ~uio_in:(zero 8)
  in
  let circ = Circuit.create_exn ~name:"eng" [ output "pkg0" (e.read (of_int ~width:7 0x50)) ] in
  let sim = Cyclesim.create circ in
  let set n v = Cyclesim.in_port sim n := Bits.of_int ~width:(Bits.width !(Cyclesim.in_port sim n)) v in
  let cyc () = Cyclesim.cycle sim in
  (* one settle cycle, then the registered value *)
  let pkg0 () = cyc (); Bits.to_int !(Cyclesim.out_port ~clock_edge:Before sim "pkg0") in
  set "rst_sync_n" 0; cyc (); set "rst_sync_n" 1;
  let write v = set "wr" 1; set "addr" 0x50; set "wdata" v; cyc (); set "wr" 0 in
  write 0x80;
  printf "halted, idle: PKG <- 0x80 reads 0x%02X\n" (pkg0 ());
  (* one step, then halt; write in the cycle after the step *)
  set "running0" 1; set "tick0" 1; cyc (); set "tick0" 0; set "running0" 0;
  write 0x81;
  printf "halted, slots pending: PKG <- 0x81 reads 0x%02X\n" (pkg0 ());
  for _ = 1 to 6 do cyc () done;
  write 0x81;
  printf "halted, idle again: PKG <- 0x81 reads 0x%02X\n" (pkg0 ());
  [%expect {|
    halted, idle: PKG <- 0x80 reads 0x80
    halted, slots pending: PKG <- 0x81 reads 0x80
    halted, idle again: PKG <- 0x81 reads 0x81
    |}]
;;
