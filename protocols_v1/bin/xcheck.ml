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

(* I2C controller: random transactions (hit 0x50 / miss 0x51, read or write, N 1..6, random
   repeated-start flag) against the target peer, Sm and Fm, with and without stretching and
   a NACKed write byte. Writes the pad trace, the lane's pushes (.bytes) and the peer's bus
   transcript (.bus, one token per line). *)
let i2c_ctl dir =
  List.iter
    [ "sm", (59, 5, 5, 5, 5), 0, -1; "fm", (14, 6, 4, 3, 6), 0, -1; "fm_stretch", (14, 6, 4, 3, 6), 300, 3
    ; "sm_stretch", (59, 5, 5, 5, 5), 1000, 5 ]
    ~f:(fun (gname, (p, l, h, tsu, thold), stretch, nack_write) ->
      let rng = Random.State.make [| 41 + p + stretch |] in
      let ntx = 14 in
      let txs =
        List.init ntx ~f:(fun i ->
          let a = if Random.State.int rng 5 = 0 then 0x51 else 0x50 in
          let rw = Random.State.bool rng in
          let n = 1 + Random.State.int rng 6 in
          let r = i < ntx - 1 && Random.State.int rng 3 = 0 in
          [ (a lsl 1) lor Bool.to_int rw; n lor if r then 0x80 else 0 ]
          @ if rw then [] else List.init n ~f:(fun _ -> Random.State.int rng 256))
      in
      let read_data = List.init 128 ~f:(fun _ -> Random.State.int rng 256) in
      let tgt = Peers.i2c_target ~addr:0x50 ~read_data ~stretch ~nack_write () in
      let setup =
        { Psim.prog = P1.i2c_ctl ~l ~h ~tsu ~thold; own = P1.i2c_own; od = P1.i2c_od; cfg = 0; cfg2 = 0; p
        ; contract = Lib.i2c_ctl ~l ~h ~tsu ~thold; open_drain_wired_and = P1.i2c_own }
      in
      let r = Psim.run ~tx_bytes:(List.concat txs) ~setup ~cycles:(if p > 20 then 2_500_000 else 700_000) ~peer:tgt.drive () in
      let name = "i2c_ctl_" ^ gname in
      Psim.write_rle ~file:(dir ^/ name ^ ".rle") ~pins:[ Peers.i2c_scl; Peers.i2c_sda ] r.pads;
      write_bytes (dir ^/ name ^ ".bytes") (Psim.pushes r);
      Out_channel.write_all (dir ^/ name ^ ".bus")
        ~data:(String.concat (List.map (String.split (tgt.log ()) ~on:' ') ~f:(fun t -> t ^ "\n")));
      (* reference transcript from the host transactions (doc 2.1/2.2 and the peer's rules) *)
      let rd = Queue.of_list read_data and nw = ref 0 and prev_sr = ref false in
      let expected =
        List.concat_map txs ~f:(fun tx ->
          match tx with
          | a :: c :: data ->
            let addr = a lsr 1 and rw = a land 1 = 1 and n = c land 0x7F and rflag = c land 0x80 <> 0 in
            let start = if !prev_sr then "Sr" else "S" in
            let hit = addr = 0x50 in
            let body, nacked =
              if not hit
              then [ sprintf "A%02X%c-" addr (if rw then 'R' else 'W') ], true
              else if rw
              then
                ( sprintf "A%02XR+" addr
                  :: (* in order: Base's List.init does not evaluate f in index order *)
                   (let acc = ref [] in
                    for k = 0 to n - 1 do
                      acc := sprintf "R%02X%c" (Queue.dequeue_exn rd) (if k = n - 1 then '-' else '+') :: !acc
                    done;
                    List.rev !acc)
                , false )
              else (
                let rec go = function
                  | [] -> [], false
                  | d :: rest ->
                    let ack = !nw <> nack_write in
                    incr nw;
                    if ack then (let t, nk = go rest in (sprintf "W%02X+" d :: t), nk) else [ sprintf "W%02X-" d ], true
                in
                let t, nk = go data in
                sprintf "A%02XW+" addr :: t, nk)
            in
            prev_sr := rflag && not nacked;
            [ start ] @ body @ if rflag && not nacked then [] else [ "P" ]
          | _ -> [])
      in
      let got = String.split (tgt.log ()) ~on:' ' in
      Out_channel.write_all (dir ^/ name ^ ".ref") ~data:(String.concat (List.map expected ~f:(fun t -> t ^ "\n")));
      printf "%s: %d pops, %d pushes, firings [%s], model_mismatch %d, bus = host reference %b\n" name
        (List.length (Psim.pops r)) (List.length (Psim.pushes r)) (Psim.show_firings r) r.model_mismatch
        ([%equal: string list] got expected))
;;

(* I2C target at P = 3: random transactions from the controller peer (UM10204 minima), Sm and
   Fm, one Fm run with read data arriving late (stretching). Writes the pad trace, the
   controller transcript (.bus), the lane's pushes (.wbytes: expected = decoded writes to
   0x50) and pops (.rbytes: expected = decoded reads from 0x50). *)
let i2c_tgt dir =
  List.iter [ "sm", Peers.i2c_sm, 0; "fm", Peers.i2c_fm, 0; "fm_stretch", Peers.i2c_fm, 20_000 ] ~f:(fun (gname, t, late) ->
    let rng = Random.State.make [| 53 + t.tlow + late |] in
    let txs =
      List.init 14 ~f:(fun _ ->
        let a = if Random.State.int rng 5 = 0 then 0x51 else 0x50 in
        let n = 1 + Random.State.int rng 5 in
        let tx = if Random.State.bool rng then `R (a, n) else `W (a, List.init n ~f:(fun _ -> Random.State.int rng 256)) in
        tx, Random.State.int rng 3 = 0)
    in
    let rdata = List.init 64 ~f:(fun _ -> Random.State.int rng 256) in
    let c = Peers.i2c_controller ~t txs in
    let f x = Int.max 2 ((x / 4) - 1) in
    let setup =
      { Psim.prog = P1.i2c_tgt ~addr:0x50; own = P1.i2c_own; od = P1.i2c_od; cfg = 0; cfg2 = 0; p = 3
      ; contract = Lib.i2c_tgt ~h_min:(f t.thigh) ~l_min:(f t.tlow) ~hd:(f t.thd_sta); open_drain_wired_and = P1.i2c_own }
    in
    let tx_times = 0 :: List.map rdata ~f:(fun _ -> late) in
    let r = Psim.run ~tx_bytes:(0x50 :: rdata) ~tx_times ~setup ~cycles:(if t.tlow > 100 then 1_200_000 else 400_000) ~peer:c.cdrive () in
    let name = "i2c_tgt_" ^ gname in
    Psim.write_rle ~file:(dir ^/ name ^ ".rle") ~pins:[ Peers.i2c_scl; Peers.i2c_sda ] r.pads;
    write_bytes (dir ^/ name ^ ".wbytes") (Psim.pushes r);
    write_bytes (dir ^/ name ^ ".rbytes") (List.drop (Psim.pops r) 1);
    Out_channel.write_all (dir ^/ name ^ ".bus")
      ~data:(String.concat (List.map (String.split (c.clog ()) ~on:' ') ~f:(fun t -> t ^ "\n")));
    let stretched = Array.count r.outs ~f:(fun (_, oe) -> (oe lsr Peers.i2c_scl) land 1 = 1) in
    printf "%s: done %b, %d pushes, %d pops, lane SCL-pull cycles %d, firings [%s], model_mismatch %d\n" name
      (c.cdone ()) (List.length (Psim.pushes r)) (List.length (Psim.pops r)) stretched (Psim.show_firings r) r.model_mismatch)
;;

let () =
  match Sys.get_argv () with
  | [| _; "spi_ctl"; dir |] -> spi_ctl dir
  | [| _; "spi_tgt"; dir |] -> spi_tgt dir
  | [| _; "uart_rx"; dir |] -> uart_rx dir
  | [| _; "uart_tx"; dir |] -> uart_tx dir
  | [| _; "i2c_ctl"; dir |] -> i2c_ctl dir
  | [| _; "i2c_tgt"; dir |] -> i2c_tgt dir
  | _ -> eprintf "usage: xcheck uart_rx <dir>\n"
;;
