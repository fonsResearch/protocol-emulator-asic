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

(* SPI: channels in the RLE file are SCLK, MOSI, MISO, CS (indices 0..3). Files per scenario:
   <name>.mosi.bytes and <name>.miso.bytes, the bytes each side intended to send. *)
let spi_pins = [ Peers.spi_sclk; Peers.spi_mosi; Peers.spi_miso; Peers.spi_cs ]
let spi_modes = [ false, false; false, true; true, false; true, true ]
let mode_id (cpol, cpha) = (if cpol then 2 else 0) + if cpha then 1 else 0

let spi_ctl dir =
  List.iter spi_modes ~f:(fun (cpol, cpha) ->
    let rng = Random.State.make [| 13 + mode_id (cpol, cpha) |] in
    let host = List.init 64 ~f:(fun _ -> Random.State.int rng 256) in
    let tbytes = List.init 64 ~f:(fun _ -> Random.State.int rng 256) in
    let tgt = Peers.spi_target ~cpol ~cpha ~tco:3 ~send:tbytes () in
    let setup =
      { Psim.prog = P1.spi_ctl ~cpol ~cpha; own = P1.spi_own_ctl; od = 0; cfg = P1.spi_cfg_ctl
      ; cfg2 = P1.spi_cfg2_ctl; p = 7; contract = Lib.spi_ctl ~cpol ~cpha ~h:2; open_drain_wired_and = 0 }
    in
    let r = Psim.run ~tx_bytes:host ~setup ~cycles:(64 * 400) ~peer:tgt.drive () in
    let name = sprintf "spi_ctl_m%d" (mode_id (cpol, cpha)) in
    Psim.write_rle ~file:(dir ^/ name ^ ".rle") ~pins:spi_pins r.pads;
    write_bytes (dir ^/ name ^ ".mosi.bytes") (Psim.pops r);
    write_bytes (dir ^/ name ^ ".miso.bytes") (Psim.pushes r);
    printf "%s: %d pops, %d pushes, pushes = target bytes %b, firings [%s]\n" name
      (List.length (Psim.pops r)) (List.length (Psim.pushes r))
      ([%equal: int list] (Psim.pushes r) tbytes) (Psim.show_firings r))
;;

let spi_tgt dir =
  List.iter spi_modes ~f:(fun (cpol, cpha) ->
    let rng = Random.State.make [| 29 + mode_id (cpol, cpha) |] in
    let host = List.init 64 ~f:(fun _ -> Random.State.int rng 256) in
    let cbytes = List.init 64 ~f:(fun _ -> Random.State.int rng 256) in
    let c =
      Peers.spi_controller ~cpol ~cpha ~hp:28 ~setup:30 ~hold:30 ~gap:120 ~mdly:2 ~t0:300 ~bytes:cbytes ()
    in
    let setup =
      { Psim.prog = P1.spi_tgt ~cpol ~cpha; own = P1.spi_own_tgt; od = 0; cfg = 0; cfg2 = 0; p = 7
      ; contract = Lib.spi_tgt ~cpol ~cpha ~h_min:3 ~g:6; open_drain_wired_and = 0 }
    in
    let r = Psim.run ~tx_bytes:host ~setup ~cycles:(c.frames_end + 200) ~peer:c.cdrive () in
    let name = sprintf "spi_tgt_m%d" (mode_id (cpol, cpha)) in
    Psim.write_rle ~file:(dir ^/ name ^ ".rle") ~pins:spi_pins r.pads;
    write_bytes (dir ^/ name ^ ".mosi.bytes") (Psim.pushes r);
    write_bytes (dir ^/ name ^ ".miso.bytes") (Psim.pops r);
    printf "%s: %d pops, %d pushes, pushes = controller bytes %b, firings [%s]\n" name
      (List.length (Psim.pops r)) (List.length (Psim.pushes r))
      ([%equal: int list] (Psim.pushes r) cbytes) (Psim.show_firings r))
;;

let () =
  match Sys.get_argv () with
  | [| _; "spi_ctl"; dir |] -> spi_ctl dir
  | [| _; "spi_tgt"; dir |] -> spi_tgt dir
  | [| _; "uart_rx"; dir |] -> uart_rx dir
  | [| _; "uart_tx"; dir |] -> uart_tx dir
  | _ -> eprintf "usage: xcheck uart_rx <dir>\n"
;;
