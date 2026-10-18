(* Trace export for the spec-free cross-check (tools/sigrok/xcheck.sh): runs a scenario,
   writes the pad trace as run-length samples (<dir>/<name>.rle) and the bytes the lane
   pushed/popped (<dir>/<name>.bytes, hex, one per line). *)
open! Core
open Pemu_protocols_v1
module P1 = Pemu_spec_v1.Programs_v1
module Lib = Pemu_monitor_v1.Library_v1

let write_bytes file l =
  Out_channel.write_all file ~data:(String.concat (List.map l ~f:(sprintf "%02X\n")))
;;

let uart_rx dir =
  let nominal = 60e6 /. 115200. in
  let rng = Random.State.make [| 7 |] in
  let bytes = List.init 64 ~f:(fun _ -> Random.State.int rng 256) in
  List.iter [ "uart_rx_nominal", 1.0; "uart_rx_fast2p5", 1.0 /. 1.025; "uart_rx_slow2p5", 1.0 /. 0.975 ]
    ~f:(fun (name, f) ->
      let bp = nominal *. f in
      let frames = Peers.frames_of ~bp ~st0:2000 bytes ~gap:(fun b -> 3 + (b * 13 % 900)) in
      let setup =
        { Psim.prog = P1.uart_rx ~d:8 ~pin:1; own = 0; od = 0; cfg = 0; cfg2 = 0; p = 64
        ; contract = Lib.uart_rx ~d:8 ~m:2 ~pin:1; open_drain_wired_and = 0 }
      in
      let r =
        Psim.run ~setup ~cycles:(2000 + (64 * 6000)) ~peer:(Peers.sender ~pin:1 ~bp ~frames ~defect:No_defect) ()
      in
      Psim.write_rle ~file:(dir ^/ name ^ ".rle") ~pins:[ 1 ] r.pads;
      write_bytes (dir ^/ name ^ ".bytes") (Psim.pushes r);
      printf "%s: %d pushes, firings [%s]\n" name (List.length (Psim.pushes r)) (Psim.show_firings r))
;;

let uart_tx dir =
  let rng = Random.State.make [| 11 |] in
  let bytes = List.init 64 ~f:(fun _ -> Random.State.int rng 256) in
  let setup =
    { Psim.prog = P1.uart_tx ~d:4; own = 1; od = 0; cfg = 0; cfg2 = 0; p = 129
    ; contract = Lib.uart_tx ~d:4 ~pin:0; open_drain_wired_and = 0 }
  in
  let r =
    Psim.run ~tx_bytes:bytes ~setup ~cycles:((64 * 5600) + 20_000) ~peer:(fun _ -> { Psim.drive_oe = 0; drive_val = 0 }) ()
  in
  Psim.write_rle ~file:(dir ^/ "uart_tx_nominal.rle") ~pins:[ 0 ] r.pads;
  write_bytes (dir ^/ "uart_tx_nominal.bytes") (Psim.pops r);
  printf "uart_tx_nominal: %d pops, firings [%s]\n" (List.length (Psim.pops r)) (Psim.show_firings r)
;;

let () =
  match Sys.get_argv () with
  | [| _; "uart_rx"; dir |] -> uart_rx dir
  | [| _; "uart_tx"; dir |] -> uart_tx dir
  | _ -> eprintf "usage: xcheck uart_rx <dir>\n"
;;
