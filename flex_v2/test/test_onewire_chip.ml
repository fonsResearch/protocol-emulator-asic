(* 1-Wire firmware on the v2 top RTL (shipped configuration: lane pipe, verdict pipe,
   param_windows, ROM library v2inc5), unmonitored: no package is selected, because the shipped chip
   has no slot for a loadable contract.  The chip is compared cycle by cycle with Psim (lane spec
   model + the same device peer): monitor inputs, pads and pins must agree, and the RX bytes too.
   Psim's verdict columns are the contract's verdicts on the same run; the chip's are "-". *)
open! Core
open Pemu_monitor_v1
open Pemu_rtl_v1
module D = Pemu_rtl_v1_test.Test_c3_diff
module Psim = Pemu_protocols_v1.Psim
module Asm = Pemu_toolchain.Asm
module Peer = Pemu_flex_v2.Ow_peer

let source = In_channel.read_all "../firmware/onewire_ctl.s"
let cpu = 30
let lib = List.map (Rom_lib.v2_inc5 ()) ~f:Compile.compile_exn

let setup src : Psim.setup =
  match Asm.assemble src with
  | Error e -> failwithf "asm line %d: %s" e.line e.msg ()
  | Ok o ->
    { prog = Array.to_list o.prog |> List.filter_opt; own = o.meta.own; od = o.meta.od; cfg = o.meta.cfg
    ; cfg2 = o.meta.cfg2; p = cpu - 1; contract = Pemu_flex_v2.Flex_lib.onewire_ctl (); open_drain_wired_and = 0x04 }
;;

let reset = [ 0 ]
let write b = [ 1; b ]
let read n = List.concat (List.init n ~f:(fun _ -> [ 2 ]))

let%expect_test "1-Wire on the v2 top RTL, unmonitored, against Psim" =
  let k = List.hd_exn (D.calibrate ()) in
  let run ?(src = source) ?(timing = Peer.nominal) ?stream ~name ~tx_bytes ~us () =
    D.compare_one_cfg ~lane_pipe:true ~verdict_pipe:true ~param_windows:true ~monitor:false ?stream ~lib ~k ~name
      ~setup:(setup src) ~pkg:0 ~tx_bytes ~peer:(fun () -> snd (Peer.create ~timing ~cpu ())) ~cycles:(us * cpu) ()
  in
  let n = Peer.nominal in
  run ~name:"READ ROM (7 bytes)" ~stream:true ~tx_bytes:(reset @ write 0x33 @ read 7) ~us:6000 ();
  run ~name:"scratchpad round trip" ~stream:true
    ~tx_bytes:(reset @ write 0xCC @ write 0x4E @ write 0x55 @ write 0x0A @ write 0x3F @ reset @ write 0xCC @ write 0xBE @ read 6)
    ~us:13500 ();
  let fault name timing = run ~name ~timing ~tx_bytes:(reset @ write 0x33 @ read 2) ~us:3200 () in
  fault "presence after 5 us" { n with presence_wait_us = 5 };
  fault "no presence" { n with presence_us = 0 };
  fault "read-0 held 80 us" { n with read0_us = 80 };
  fault "spontaneous low at 800 us" { n with spontaneous = Some (800, 10) };
  let mutant name a b =
    run ~name ~src:(String.substr_replace_first source ~pattern:a ~with_:b) ~tx_bytes:(reset @ write 0x33 @ read 2) ~us:3200 ()
  in
  mutant "mutant reset low 401" "WAIT 499" "WAIT 399";
  mutant "mutant read slot 46" "WAIT 52 " "WAIT 30 ";
  [%expect {|
    READ ROM (7 bytes)             mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    scratchpad round trip          mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    presence after 5 us            mon-in = pads = pins = | fail psim - chip - | blame psim 22@15361 chip - | rx = (3)
    no presence                    mon-in = pads = pins = | fail psim - chip - | blame psim 23@17101 chip - | rx = (3)
    read-0 held 80 us              mon-in = pads = pins = | fail psim - chip - | blame psim 25@63571 chip - | rx = (3)
    spontaneous low at 800 us      mon-in = pads = pins = | fail psim - chip - | blame psim 21@24031 chip - | rx = (3)
    mutant reset low 401           mon-in = pads = pins = | fail psim 12@12211 chip - | blame psim 23@14101 chip - | rx = (3)
    mutant read slot 46            mon-in = pads = pins = | fail psim 14@62731 chip - | blame psim - chip - | rx = (3)
    |}]
;;
