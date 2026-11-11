(* 1-Wire firmware on the lane spec model with a DS18B20-subset device (Psim): the contract runs in
   the reference interpreter and, compiled, in the monitor model (fit check).  P = 29: 30 cycles per
   step, one step = 1 us. *)
open! Core
module Psim = Pemu_protocols_v1.Psim
module Asm = Pemu_toolchain.Asm
module Peer = Pemu_flex_v2.Ow_peer

let source = In_channel.read_all "../firmware/onewire_ctl.s"
let cpu = 30

let assemble src =
  match Asm.assemble src with
  | Ok o -> o
  | Error e -> failwithf "asm line %d: %s" e.line e.msg ()
;;

let run ?(src = source) ?timing ~tx ~us () =
  let o = assemble src in
  let setup : Psim.setup =
    { prog = Array.to_list o.prog |> List.filter_opt; own = o.meta.own; od = o.meta.od; cfg = o.meta.cfg
    ; cfg2 = o.meta.cfg2; p = cpu - 1; contract = Pemu_flex_v2.Flex_lib.onewire_ctl (); open_drain_wired_and = 0x04 }
  in
  let dev, peer = Peer.create ?timing ~cpu () in
  let r = Psim.run ~setup ~cycles:(us * cpu) ~tx_bytes:tx ~peer () in
  let fires =
    List.map (Psim.firings r) ~f:(fun (c, ro, k) ->
      sprintf "%s%02X@%dus" (match ro with Fail -> "F" | Blame -> "B") k (c / cpu))
  in
  printf "verdict  %s\n" (if List.is_empty fires then "clean" else String.concat ~sep:"," (List.take fires 4));
  printf "pushed   %s\n" (String.concat ~sep:" " (List.map (Psim.pushes r) ~f:(sprintf "%02X")));
  printf "device   %s\n" (String.concat ~sep:"; " (Queue.to_list dev.log));
  printf "mmodel   %s\n" (if r.model_mismatch = 0 then "agrees" else sprintf "differs in %d cycles" r.model_mismatch);
  r
;;

let reset = [ 0 ]
let write b = [ 1; b ]
let read n = List.concat (List.init n ~f:(fun _ -> [ 2 ]))

let%expect_test "firmware size" =
  let o = assemble source in
  printf "%d words\n" (Array.length o.words);
  [%expect {| 34 words |}]
;;

let%expect_test "READ ROM" =
  ignore (run ~tx:(reset @ write 0x33 @ read 8) ~us:7000 () : Psim.result);
  printf "expected %s\n" (String.concat ~sep:" " (List.map Peer.default_rom ~f:(sprintf "%02X")));
  [%expect {|
    verdict  clean
    pushed   00 28 5A 3C 11 07 00 00 97
    device   reset; rom 33
    mmodel   agrees
    expected 28 5A 3C 11 07 00 00 97
    |}]
;;

let%expect_test "SKIP ROM, WRITE SCRATCHPAD, reset, SKIP ROM, READ SCRATCHPAD" =
  ignore
    (run
       ~tx:(reset @ write 0xCC @ write 0x4E @ write 0x55 @ write 0x0A @ write 0x3F @ reset @ write 0xCC @ write 0xBE @ read 9)
       ~us:15000 ()
     : Psim.result);
  let sp = [ 0x91; 0x01; 0x55; 0x0A; 0x3F; 0xFF; 0x0F; 0x10 ] in
  printf "expected %s\n" (String.concat ~sep:" " (List.map (Peer.with_crc sp) ~f:(sprintf "%02X")));
  [%expect {|
    verdict  clean
    pushed   00 00 91 01 55 0A 3F FF 0F 10 45
    device   reset; rom CC; fn 4E; data 55; data 0A; data 3F; scratch written; reset; rom CC; fn BE
    mmodel   agrees
    expected 91 01 55 0A 3F FF 0F 10 45
    |}]
;;

let%expect_test "device faults (blame)" =
  let t name timing =
    printf "-- %s\n" name;
    ignore (run ~timing ~tx:(reset @ write 0x33 @ read 2) ~us:3000 () : Psim.result)
  in
  let n = Peer.nominal in
  t "presence after 5 us" { n with presence_wait_us = 5 };
  t "no presence" { n with presence_us = 0 };
  t "presence 30 us" { n with presence_us = 30 };
  t "read-0 held 80 us" { n with read0_us = 80 };
  t "spontaneous low at 800 us" { n with spontaneous = Some (800, 10) };
  [%expect {|
    -- presence after 5 us
    verdict  B22@512us
    pushed   00 28
    device   reset; rom 33
    mmodel   agrees
    -- no presence
    verdict  B23@570us
    pushed   80 28
    device   reset; rom 33
    mmodel   agrees
    -- presence 30 us
    verdict  B24@567us
    pushed   80 28
    device   reset; rom 33
    mmodel   agrees
    -- read-0 held 80 us
    verdict  B25@2119us
    pushed   00 6A
    device   reset; rom 33
    mmodel   agrees
    -- spontaneous low at 800 us
    verdict  B21@801us
    pushed   00 28
    device   reset; rom 33
    mmodel   agrees
    |}]
;;

let%expect_test "firmware mutants (fail)" =
  let t name a b =
    printf "-- %s\n" name;
    let src = String.substr_replace_first source ~pattern:a ~with_:b in
    assert (not (String.equal src source));
    ignore (run ~src ~tx:(reset @ write 0x33 @ read 2) ~us:3000 () : Psim.result)
  in
  t "reset low 401" "WAIT 499" "WAIT 399";
  t "write-0 low 28" "WAIT 58 " "WAIT 20 ";
  t "write recovery 53" "WAIT 61 " "WAIT 50 ";
  t "read slot 46" "WAIT 52 " "WAIT 30 ";
  t "reset recovery 378" "WAIT 409" "WAIT 300";
  [%expect {|
    -- reset low 401
    verdict  F12@407us,B23@470us
    pushed   80 FF
    device
    mmodel   agrees
    -- write-0 low 28
    verdict  F11@1210us,B23@1365us
    pushed   00 FF FF
    device   reset; rom FF
    mmodel   agrees
    -- write recovery 53
    verdict  F14@1355us,B25@1415us
    pushed   00 28
    device   reset; rom 33
    mmodel   agrees
    -- read slot 46
    verdict  F14@2091us
    pushed   00 28 5A
    device   reset; rom 33
    mmodel   agrees
    -- reset recovery 378
    verdict  F13@889us
    pushed   00 28
    device   reset; rom 33
    mmodel   agrees
    |}]
;;
