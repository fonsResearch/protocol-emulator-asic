(* C3 diagnosis: the monitor-input stream of a Psim run replayed into the Mon_spec circuit and
   into Mon_lane (5 slots), firings compared with the interpreter. Isolates monitor semantics
   from chip-level wiring. *)
open! Core
open Hardcaml
open Pemu_spec_v1
open Pemu_monitor_v1
open Pemu_protocols_v1
module Lib = Library_v1
module P1 = Programs_v1
module Ss = Cyclesim.With_interface (Mon_spec.I) (Mon_spec.O)
module Sl = Cyclesim.With_interface (Mon_lane.I) (Mon_lane.O)

let drive (si : _ Mon_spec.I.t) (i : Interp.inputs) =
  let b x = Bits.of_bool x
  and n w x = Bits.of_int ~width:w x in
  si.rst_sync_n := b i.rst_sync_n; si.running := b i.running; si.tick := b i.tick;
  si.ui_in := n 8 i.ui_in; si.uio_in := n 8 i.uio_in; si.uo_out := n 8 i.uo_out;
  si.uio_out := n 8 i.uio_out; si.uio_oe := n 8 i.uio_oe; si.pop_ev := b i.pop_ev;
  si.pop_data := n 8 i.pop_data; si.push_ev := b i.push_ev; si.push_data := n 8 i.push_data
;;

let replay ~name ~(setup : Psim.setup) ~tx_bytes ~peer ~cycles =
  let pkg = Compile.compile_exn setup.contract in
  let ss = Ss.create (Mon_spec.of_package pkg)
  and sl = Sl.create (Mon_lane.of_package ~slots:5 pkg) in
  let fi = ref [] and fs = ref [] and fl = ref [] in
  let tick_cycles = ref [] in
  let on_cycle cy (mi : Interp.inputs) fa =
    if mi.tick then tick_cycles := cy :: !tick_cycles;
    List.iter fa ~f:(fun (r, c) -> fi := (cy, r, c) :: !fi);
    drive (Cyclesim.inputs ss) mi; drive (Cyclesim.inputs sl) mi;
    Cyclesim.cycle ss; Cyclesim.cycle sl;
    let so : _ Mon_spec.O.t = Cyclesim.outputs ~clock_edge:Before ss in
    let fire = Bits.to_int !(so.fire) and role = Bits.to_int !(so.role) in
    List.iteri so.codes ~f:(fun u c ->
      if (fire lsr u) land 1 = 1
      then fs := (cy, (if (role lsr u) land 1 = 1 then Lang.Blame else Fail), Bits.to_int !c) :: !fs);
    let lo : _ Mon_lane.O.t = Cyclesim.outputs ~clock_edge:Before sl in
    if Bits.to_bool !(lo.fire)
    then fl := (cy, (if Bits.to_bool !(lo.role) then Lang.Blame else Fail), Bits.to_int !(lo.code)) :: !fl
  in
  ignore (Psim.run ~on_cycle ~tx_bytes ~rx_pop_every:1_000_000_000 ~setup ~cycles ~peer () : Psim.result);
  let show l =
    List.rev l |> List.map ~f:(fun (c, r, k) -> sprintf "%s%02X@%d" (match r with Lang.Fail -> "F" | Blame -> "B") k c)
    |> String.concat ~sep:","
  in
  printf "%s\n  interp %s\n  spec   %s\n  lane5  %s\n" name (show !fi) (show !fs) (show !fl)
;;

let%expect_test "c3 replay: spi_tgt m0 early CS" =
  let setup =
    { Psim.prog = P1.spi_tgt ~cpol:false ~cpha:false; own = P1.spi_own_tgt; od = 0; cfg = 0; cfg2 = 0; p = 7
    ; contract = Lib.spi_tgt ~cpol:false ~cpha:false ~h_min:3 ~g:6; open_drain_wired_and = 0 }
  in
  let peer_bytes = [ 0x96; 0x01; 0x80; 0xC3; 0x5A; 0xF0; 0x33; 0xE7 ] in
  let host_bytes = [ 0xA5; 0x3C; 0x00; 0xFF; 0x81; 0x7E; 0x55; 0x0F ] in
  let ctl ?defect () =
    Peers.spi_controller ~cpol:false ~cpha:false ~hp:40 ~setup:40 ~hold:40 ~gap:144 ~mdly:2 ~t0:300
      ~bytes:peer_bytes ?defect ()
  in
  replay ~name:"early CS" ~setup ~tx_bytes:host_bytes ~peer:(ctl ~defect:(Peers.Early_rise (2, 9)) ()).cdrive ~cycles:((ctl ()).frames_end + 200);
  [%expect {|
    early CS
      interp B52@2345
      spec   B52@2345
      lane5  B52@2345
    |}]
;;
