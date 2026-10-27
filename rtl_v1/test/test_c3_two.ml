(* C3 differential check, part 3 (log/proofs_v2.md section 7.3): both lanes running at once on
   disjoint pins, v2 top RTL against two independent Psim lanes (one per package, each with its
   own peer). Checks lane-1 wiring (lane view, blame index), non-interference between lanes, and
   the global first-fail / first-blame choice (monitor_isa_v1.md section 6: earliest stamp first,
   lane 0 on equal stamps). Per lane: the monitor-input stream (uio_in compared on the pins of the
   lane's interface only, since each Psim lane sees only its own peer), owned pins, pushes. *)
open! Core
open Pemu_spec_v1
open Pemu_monitor_v1
module D = Test_c3_diff
module Psim = Pemu_protocols_v1.Psim
module Peers = Pemu_protocols_v1.Peers
module P1 = Programs_v1

type lane_cfg =
  { lane : int
  ; name : string
  ; setup : Psim.setup
  ; pkg : int
  ; tx_bytes : int list
  ; peer : unit -> Psim.chip_view -> Psim.peer_drive
  ; pins : int (* uio pins of this lane's interface *)
  }

let compose peers (v : Psim.chip_view) =
  List.fold peers ~init:{ Psim.drive_oe = 0; drive_val = 0 } ~f:(fun (acc : Psim.peer_drive) p ->
    let (d : Psim.peer_drive) = p v in
    { Psim.drive_oe = acc.drive_oe lor d.drive_oe; drive_val = acc.drive_val lor (d.drive_val land d.drive_oe) })
;;

let chip_run2 ~k ~(lanes : lane_cfg list) ~cycles =
  let h = D.create () in
  List.iter lanes ~f:(fun c ->
    let b = 0x10 + (16 * c.lane) and s = c.setup in
    D.write h b [ s.own ];
    D.write h (b + 1) [ s.od ];
    D.write h (b + 2) [ s.p land 0xFF; s.p lsr 8 ];
    D.write h (b + 5) [ s.cfg ];
    D.write h (b + 6) [ s.cfg2 ];
    let words = Isa1.assemble s.prog in
    D.write h (b + 4) [ List.length s.prog ];
    D.write h (b + 7) [ 0 ];
    D.write h (b + 8)
      (List.concat_map (List.init (List.length s.prog) ~f:Fn.id) ~f:(fun a -> [ words.(a) land 0xFF; words.(a) lsr 8 ]));
    let p = List.nth_exn D.lib c.pkg in
    D.write h (0x50 + (8 * c.lane)) [ 0x80 lor c.pkg ];
    D.write h (0x60 + (16 * c.lane)) (Array.to_list p.remap);
    if not (List.is_empty c.tx_bytes) then D.write h (b + 9) c.tx_bytes);
  h.wired <- List.fold lanes ~init:0 ~f:(fun a c -> a lor c.setup.open_drain_wired_and);
  h.off <- h.n + D.ctrl_write_len - k;
  h.peer <- compose (List.map lanes ~f:(fun c -> c.peer ()));
  D.write h 0x01 [ List.fold lanes ~init:0 ~f:(fun a c -> a lor (1 lsl c.lane)) ];
  let stop = h.off + cycles in
  while h.n < stop do D.cycle h done;
  h.peer <- D.no_peer;
  let v = D.read h 0x40 12 in
  let rx =
    List.map lanes ~f:(fun c ->
      let b = 0x10 + (16 * c.lane) in
      let lvl = (List.hd_exn (D.read h (b + 11) 1) lsr 4) land 0xF in
      if lvl = 0 then [] else D.read h (b + 10) lvl)
  in
  h, v, rx
;;

let run ~k ~name (lanes : lane_cfg list) ~cycles =
  let h, v, chip_rx = chip_run2 ~k ~lanes ~cycles in
  printf "%s\n" name;
  let firsts =
    List.map2_exn lanes chip_rx ~f:(fun c crx ->
      let pmi = Array.create ~len:cycles None in
      let r =
        Psim.run ~on_cycle:(fun cy mi _ -> pmi.(cy) <- Some mi) ~tx_bytes:c.tx_bytes ~rx_pop_every:1_000_000_000
          ~setup:c.setup ~cycles ~peer:(c.peer ()) ()
      in
      let mon = if c.lane = 0 then h.mon else h.mon1 in
      let eq (a : Interp.inputs) (b : Interp.inputs) =
        Bool.equal a.running b.running && Bool.equal a.tick b.tick
        && a.uio_in land c.pins = b.uio_in land c.pins
        && a.uio_out = b.uio_out && a.uio_oe = b.uio_oe && Bool.equal a.pop_ev b.pop_ev
        && ((not a.pop_ev) || a.pop_data = b.pop_data) && Bool.equal a.push_ev b.push_ev
        && ((not a.push_ev) || a.push_data = b.push_data)
      in
      let mon_first =
        List.find (List.init cycles ~f:Fn.id) ~f:(fun cy ->
          match pmi.(cy), Hashtbl.find mon (cy + h.off) with
          | Some a, Some b -> not (eq a b)
          | _ -> true)
      in
      let own = c.setup.own in
      let pin_first =
        List.find (List.init cycles ~f:Fn.id) ~f:(fun cy ->
          let co, ce = Option.value (Hashtbl.find h.outs (cy + h.off)) ~default:(-1, -1)
          and po, pe = r.outs.(cy) in
          co land own <> po land own || ce land own <> pe land own)
      in
      let win =
        List.filter_map (List.init cycles ~f:Fn.id) ~f:(fun cy ->
          match Hashtbl.find mon (cy + h.off) with
          | Some b when b.push_ev -> Some b.push_data
          | _ -> None)
      in
      let rx_eq = [%equal: int list] (Psim.pushes r) win in
      let fifo_ok = List.is_prefix crx ~prefix:(List.take win 8) ~equal:Int.equal in
      let uo_nz =
        List.count (List.init cycles ~f:Fn.id) ~f:(fun cy ->
          match Hashtbl.find mon (cy + h.off) with Some b -> b.uo_out <> 0 | None -> false)
      in
      let o = function None -> "=" | Some x -> sprintf "@%d" x in
      let pf = D.psim_first r Fail and pb = D.psim_first r Blame in
      printf "  lane %d %-26s mon-in %-6s pins %-6s pushes %s (%d)%s%s | psim fail %s blame %s\n" c.lane c.name
        (o mon_first) (o pin_first) (if rx_eq then "=" else "DIFF") (List.length win)
        (if fifo_ok then "" else " FIFO-INCONSISTENT")
        (if uo_nz = 0 then "" else sprintf " uo_out nonzero %d" uo_nz)
        (D.show_opt pf) (D.show_opt pb);
      c.lane, pf, pb)
  in
  (* predicted global first per role: earliest Psim cycle (= stamp), lane 0 on ties *)
  let pick sel =
    List.filter_map firsts ~f:(fun (l, pf, pb) -> Option.map (sel (pf, pb)) ~f:(fun (code, t) -> t, l, code))
    |> List.min_elt ~compare:[%compare: int * int * int]
  in
  let pfail = pick fst and pblame = pick snd in
  let code i = List.nth_exn v i and time i = D.le32 (List.sub v ~pos:i ~len:4) in
  let to_psim s = h.c_rst + s - h.off in
  let cfail = if code 0 land 1 = 1 then Some (to_psim (time 4), (code 0 lsr 3) land 1, code 1) else None
  and cblame = if code 0 land 2 = 2 then Some (to_psim (time 8), (code 0 lsr 2) land 1, code 2) else None in
  let s = function None -> "-" | Some (t, l, c) -> sprintf "L%d %02X@%d" l c t in
  let ok = [%equal: (int * int * int) option] in
  printf "  first fail  predicted %-12s chip %-12s %s\n" (s pfail) (s cfail) (if ok pfail cfail then "=" else "DIFF");
  printf "  first blame predicted %-12s chip %-12s %s\n" (s pblame) (s cblame) (if ok pblame cblame then "=" else "DIFF")
;;

let%expect_test "C3: two lanes at once" =
  let k = List.hd_exn (D.calibrate ()) in
  let uart_tx ?(bad = false) () =
    { lane = 0; name = (if bad then "uart_tx bad start" else "uart_tx")
    ; setup = D.uart_tx_setup (if bad then P1.uart_tx_bad_start ~d:4 else P1.uart_tx ~d:4)
    ; pkg = 0; tx_bytes = [ 0xA5; 0x3C; 0x00 ]; peer = (fun () -> D.no_peer); pins = 0x01 }
  in
  let uart_rx ~rate () =
    let frames bp = Peers.frames_of ~bp ~st0:2000 [ 0x55; 0xA5; 0x00; 0xFF; 0x3C; 0x81; 0x7E; 0x01 ] ~gap:(fun b -> 3 + (b * 7 % 400)) in
    { lane = 0; name = sprintf "uart_rx rate x%.2f" rate; setup = D.rx_setup (); pkg = 1; tx_bytes = []
    ; peer = (fun () -> let bp = D.uart_bp /. rate in Peers.sender ~pin:1 ~bp ~frames:(frames bp) ~defect:No_defect)
    ; pins = 0x02 }
  in
  let spi_ctl ~tco () =
    { lane = 1; name = sprintf "spi_ctl tco %d" tco; setup = D.ctl_setup; pkg = 2; tx_bytes = D.host_bytes
    ; peer = (fun () -> (Peers.spi_target ~cpol:false ~cpha:false ~tco ~send:D.peer_bytes ()).drive); pins = 0xF0 }
  in
  let spi_tgt ?defect () =
    let mk () =
      Peers.spi_controller ~cpol:false ~cpha:false ~hp:40 ~setup:40 ~hold:40 ~gap:144 ~mdly:2 ~t0:300
        ~bytes:D.peer_bytes ?defect ()
    in
    { lane = 1; name = (if Option.is_some defect then "spi_tgt early CS" else "spi_tgt"); setup = D.tgt_setup; pkg = 3
    ; tx_bytes = D.host_bytes; peer = (fun () -> (mk ()).cdrive); pins = 0xF0 }
  in
  let ( @> ) a l = { a with lane = l } in
  run ~k ~name:"A: L0 uart_tx, L1 spi_ctl tco 3 (no firings)" [ uart_tx (); spi_ctl ~tco:3 () ] ~cycles:6000;
  run ~k ~name:"B: L0 uart_tx bad start (fail), L1 spi_ctl tco 14 (blame)" [ uart_tx ~bad:true (); spi_ctl ~tco:14 () ] ~cycles:6000;
  run ~k ~name:"C: L0 uart_rx 8% fast (blame 4421), L1 spi_tgt early CS (blame 2345)"
    [ uart_rx ~rate:1.08 (); spi_tgt ~defect:(Peers.Early_rise (2, 9)) () ] ~cycles:30_000;
  run ~k ~name:"D: swapped lanes: L0 spi_ctl tco 14 (blame), L1 uart_tx bad start (fail)"
    [ spi_ctl ~tco:14 () @> 0; uart_tx ~bad:true () @> 1 ] ~cycles:6000;
  run ~k ~name:"E: swapped lanes: L0 spi_tgt early CS, L1 uart_rx 8% fast"
    [ spi_tgt ~defect:(Peers.Early_rise (2, 9)) () @> 0; uart_rx ~rate:1.08 () @> 1 ] ~cycles:30_000;
  let rob c = { c with setup = { c.setup with cfg = c.setup.cfg lor 1 }; name = c.name ^ " rob" } in
  run ~k ~name:"F: release on blame on L1: L0 uart_tx, L1 spi_ctl tco 14 rob (L1 faults, L0 unaffected)"
    [ uart_tx (); rob (spi_ctl ~tco:14 ()) ] ~cycles:6000;
  run ~k ~name:"G: release on blame on L0: L0 spi_tgt early CS rob, L1 uart_tx (L0 faults, L1 unaffected)"
    [ rob (spi_tgt ~defect:(Peers.Early_rise (2, 9)) ()) @> 0; uart_tx () @> 1 ] ~cycles:6000;
  [%expect {|
    A: L0 uart_tx, L1 spi_ctl tco 3 (no firings)
      lane 0 uart_tx                    mon-in =      pins =      pushes = (0) | psim fail - blame -
      lane 1 spi_ctl tco 3              mon-in =      pins =      pushes = (8) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    B: L0 uart_tx bad start (fail), L1 spi_ctl tco 14 (blame)
      lane 0 uart_tx bad start          mon-in =      pins =      pushes = (0) | psim fail 13@81 blame -
      lane 1 spi_ctl tco 14             mon-in =      pins =      pushes = (8) | psim fail - blame 91@113
      first fail  predicted L0 13@81     chip L0 13@81     =
      first blame predicted L1 91@113    chip L1 91@113    =
    C: L0 uart_rx 8% fast (blame 4421), L1 spi_tgt early CS (blame 2345)
      lane 0 uart_rx rate x1.08         mon-in =      pins =      pushes = (4) | psim fail - blame 32@4421
      lane 1 spi_tgt early CS           mon-in =      pins =      pushes = (7) | psim fail - blame 52@2345
      first fail  predicted -            chip -            =
      first blame predicted L1 52@2345   chip L1 52@2345   =
    D: swapped lanes: L0 spi_ctl tco 14 (blame), L1 uart_tx bad start (fail)
      lane 0 spi_ctl tco 14             mon-in =      pins =      pushes = (8) | psim fail - blame 91@113
      lane 1 uart_tx bad start          mon-in =      pins =      pushes = (0) | psim fail 13@81 blame -
      first fail  predicted L1 13@81     chip L1 13@81     =
      first blame predicted L0 91@113    chip L0 91@113    =
    E: swapped lanes: L0 spi_tgt early CS, L1 uart_rx 8% fast
      lane 0 spi_tgt early CS           mon-in =      pins =      pushes = (7) | psim fail - blame 52@2345
      lane 1 uart_rx rate x1.08         mon-in =      pins =      pushes = (4) | psim fail - blame 32@4421
      first fail  predicted -            chip -            =
      first blame predicted L0 52@2345   chip L0 52@2345   =
    F: release on blame on L1: L0 uart_tx, L1 spi_ctl tco 14 rob (L1 faults, L0 unaffected)
      lane 0 uart_tx                    mon-in =      pins =      pushes = (0) | psim fail - blame -
      lane 1 spi_ctl tco 14 rob         mon-in =      pins =      pushes = (0) | psim fail - blame 91@113
      first fail  predicted -            chip -            =
      first blame predicted L1 91@113    chip L1 91@113    =
    G: release on blame on L0: L0 spi_tgt early CS rob, L1 uart_tx (L0 faults, L1 unaffected)
      lane 0 spi_tgt early CS rob       mon-in =      pins =      pushes = (2) | psim fail - blame 52@2345
      lane 1 uart_tx                    mon-in =      pins =      pushes = (0) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted L0 52@2345   chip L0 52@2345   =
    |}]
;;
