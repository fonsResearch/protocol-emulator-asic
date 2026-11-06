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

(* store writes: LSTORE_ADDR at each discontinuity, then LSTORE_DATA low, high (auto-increment) *)
let write_store h ~lane (img : (int * int) list) =
  let b = 0x50 + (8 * lane) in
  let sorted = List.sort img ~compare:(fun (a, _) (b, _) -> Int.compare a b) in
  ignore
    (List.fold sorted ~init:(-2) ~f:(fun prev (a, w) ->
       if a <> prev + 1 then D.write h (b + 4) [ a ];
       D.write h (b + 5) [ w land 0xFF; w lsr 8 ];
       a)
      : int)
;;

(* [load_l1]: lane 1 is a v2 serial loadable lane; its package (D.lib, index c.pkg) is written to
   the store as an image (65-word header at 0, programs after it) and loaded, instead of being
   selected from a ROM *)
let load_package h ~lane (p : Pemu_monitor_v1.Mprog.t) =
  let module Mp = Pemu_monitor_v1.Mprog in
  let _, bases = Mp.serial_layout p in
  write_store h ~lane (Mp.store_image ~slots:5 p ~ctx_base:0 ~bases);
  let b = 0x50 + (8 * lane) in
  D.write h (b + 2) [ 0 ];
  D.write h b [ 0x80 ];
  D.write h (0x60 + (16 * lane)) (Array.to_list p.remap);
  D.write h (b + 1) [ 0x80 lor ((1 lsl Array.length p.units) - 1) ];
  D.wait h 80
;;

let configure ?(load_l1 = false) h (lanes : lane_cfg list) =
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
    if load_l1 && c.lane = 1
    then load_package h ~lane:1 p
    else (
      D.write h (0x50 + (8 * c.lane)) [ 0x80 lor c.pkg ];
      D.write h (0x60 + (16 * c.lane)) (Array.to_list p.remap));
    if not (List.is_empty c.tx_bytes) then D.write h (b + 9) c.tx_bytes)
;;

(* [prefix]: lanes run for [run_for] cycles after RUN, then reset is asserted for [rst_len]
   cycles; the measured scenario is then configured from scratch on the same chip instance *)
let chip_run2 ?verdict_pipe ?prefix ?(loadable_l1 = false) ?(windows = []) ~k ~(lanes : lane_cfg list) ~cycles () =
  let h = D.create ?verdict_pipe ~param_windows:(not (List.is_empty windows)) ~loadable:[| false; loadable_l1 |] () in
  (match prefix with
   | None -> ()
   | Some (pl, run_for, rst_len) ->
     configure h pl;
     h.wired <- List.fold pl ~init:0 ~f:(fun a c -> a lor c.setup.open_drain_wired_and);
     h.peer <- compose (List.map pl ~f:(fun c -> c.peer ()));
     D.write h 0x01 [ List.fold pl ~init:0 ~f:(fun a c -> a lor (1 lsl c.lane)) ];
     D.wait h run_for;
     let uo = Hardcaml.Bits.to_int !((Hardcaml.Cyclesim.outputs h.sim : _ D.Ox.t).top.uo_out) in
     printf "  prefix at reset: verdict pins fail %d blame %d\n" ((uo lsr 1) land 1) ((uo lsr 2) land 1);
     h.peer <- D.no_peer;
     h.rst_n <- false;
     D.wait h rst_len;
     h.rst_n <- true;
     h.c_rst <- -1;
     D.wait h 6);
  configure ~load_l1:loadable_l1 h lanes;
  List.iter windows ~f:(fun (lane, w) -> D.write_windows h ~lane w);
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

let run ?verdict_pipe ?prefix ?loadable_l1 ?windows ~k ~name (lanes : lane_cfg list) ~cycles =
  let h, v, chip_rx = chip_run2 ?verdict_pipe ?prefix ?loadable_l1 ?windows ~k ~lanes ~cycles () in
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
  printf "  first blame predicted %-12s chip %-12s %s\n" (s pblame) (s cblame) (if ok pblame cblame then "=" else "DIFF");
  if code 0 land 0xF0 <> 0 then printf "  VERDICT flags 0x%02X (overrun L0/L1 bits 4/5, fetch late bits 6/7)\n" (code 0 land 0xF0)
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
  (* timing increment (log/increments_v2.md): the cross-lane verdict scenarios again with the
     registered firing record (Mon_engine ~verdict_pipe:true); only the recording cycle moves *)
  run ~verdict_pipe:true ~k ~name:"B+vpipe" [ uart_tx ~bad:true (); spi_ctl ~tco:14 () ] ~cycles:6000;
  run ~verdict_pipe:true ~k ~name:"C+vpipe" [ uart_rx ~rate:1.08 (); spi_tgt ~defect:(Peers.Early_rise (2, 9)) () ] ~cycles:30_000;
  run ~verdict_pipe:true ~k ~name:"D+vpipe" [ spi_ctl ~tco:14 () @> 0; uart_tx ~bad:true () @> 1 ] ~cycles:6000;
  run ~verdict_pipe:true ~k ~name:"G+vpipe" [ rob (spi_tgt ~defect:(Peers.Early_rise (2, 9)) ()) @> 0; uart_tx () @> 1 ] ~cycles:6000;
  (* mid-run reset: the prefix records a fail (L0 13@81) and a blame (L1 91@113, L1 faulted by
     release on blame); reset lands 2,000 + x cycles after RUN, x chosen so that it falls inside a
     step's slot window on L1 (P = 7) and mid-bit on L0 *)
  let prefix = [ uart_tx ~bad:true (); rob (spi_ctl ~tco:14 ()) ] in
  run ~prefix:(prefix, 2003, 3) ~k ~name:"H: after mid-run reset (prefix B+rob): L0 uart_tx, L1 spi_ctl tco 3 (expect no firings)"
    [ uart_tx (); spi_ctl ~tco:3 () ] ~cycles:6000;
  run ~prefix:(prefix, 157, 1) ~k ~name:"I: after reset 1 cycle long, 157 cycles into the prefix: C"
    [ uart_rx ~rate:1.08 (); spi_tgt ~defect:(Peers.Early_rise (2, 9)) () ] ~cycles:30_000;
  (* D13 check at the documented 33 MHz divisors (Rom_lib.minimum_v2_with_p): UART TX P = 71,
     UART RX P = 35 with a 115200-baud sender (33e6 / 115200 = 286.46 cycles per bit), SPI P = 7 *)
  let p_of i = snd (List.nth_exn (Pemu_rtl_v1.Rom_lib.minimum_v2_with_p ()) i) in
  let bp33 = 33e6 /. 115200. in
  let rx33 ?(defect = Peers.No_defect) () =
    let frames bp = Peers.frames_of ~bp ~st0:400 [ 0x55; 0xC3; 0x0F; 0xA5; 0x00; 0xFF ] ~gap:(fun b -> 50 + b) in
    { (uart_rx ~rate:1.0 ()) with
      name = "uart_rx P35 115200@33MHz"; setup = { (D.rx_setup ()) with p = p_of 1 }
    ; peer = (fun () -> Peers.sender ~pin:1 ~bp:bp33 ~frames:(frames bp33) ~defect) }
  in
  let tx33 () = let c = uart_tx () in { c with name = "uart_tx P71"; setup = { c.setup with p = p_of 0 } } in
  run ~k ~name:"J: documented P: L0 uart_rx P=35, L1 spi_ctl P=7 tco 3" [ rx33 (); spi_ctl ~tco:3 () ] ~cycles:20_000;
  run ~k ~name:"K: documented P: L0 uart_tx P=71, L1 spi_tgt P=7" [ tx33 (); spi_tgt () ] ~cycles:12_000;
  run ~k ~name:"L: documented P: L0 uart_rx P=35 short stop (frame 2), L1 spi_ctl P=7 tco 14"
    [ rx33 ~defect:(Peers.Short_stop 2) (); spi_ctl ~tco:14 () ] ~cycles:20_000;
  (* the same at the 30 MHz divisors (variant v2-inc1-30mhz, Rom_lib.divisors_at): UART TX P = 64,
     UART RX P = 32 with a 115200-baud sender at 30 MHz (30e6 / 115200 = 260.42 cycles per bit;
     the RX bit is 8 * 33 = 264 cycles, -1.4 %), SPI P = 7 *)
  let p30 i = snd (List.nth_exn (Pemu_rtl_v1.Rom_lib.minimum_v2_with_p_at ~clock_hz:30_000_000) i) in
  let bp30 = 30e6 /. 115200. in
  let rx30 ?(defect = Peers.No_defect) () =
    let frames bp = Peers.frames_of ~bp ~st0:400 [ 0x55; 0xC3; 0x0F; 0xA5; 0x00; 0xFF ] ~gap:(fun b -> 50 + b) in
    { (uart_rx ~rate:1.0 ()) with
      name = sprintf "uart_rx P%d 115200@30MHz" (p30 1); setup = { (D.rx_setup ()) with p = p30 1 }
    ; peer = (fun () -> Peers.sender ~pin:1 ~bp:bp30 ~frames:(frames bp30) ~defect) }
  in
  let tx30 () = let c = uart_tx () in { c with name = sprintf "uart_tx P%d" (p30 0); setup = { c.setup with p = p30 0 } } in
  run ~k ~name:"J30: 30 MHz P: L0 uart_rx, L1 spi_ctl P=7 tco 3" [ rx30 (); spi_ctl ~tco:3 () ] ~cycles:20_000;
  run ~k ~name:"K30: 30 MHz P: L0 uart_tx, L1 spi_tgt P=7" [ tx30 (); spi_tgt () ] ~cycles:12_000;
  run ~k ~name:"L30: 30 MHz P: L0 uart_rx short stop (frame 2), L1 spi_ctl tco 14"
    [ rx30 ~defect:(Peers.Short_stop 2) (); spi_ctl ~tco:14 () ] ~cycles:20_000;
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
    B+vpipe
      lane 0 uart_tx bad start          mon-in =      pins =      pushes = (0) | psim fail 13@81 blame -
      lane 1 spi_ctl tco 14             mon-in =      pins =      pushes = (8) | psim fail - blame 91@113
      first fail  predicted L0 13@81     chip L0 13@81     =
      first blame predicted L1 91@113    chip L1 91@113    =
    C+vpipe
      lane 0 uart_rx rate x1.08         mon-in =      pins =      pushes = (4) | psim fail - blame 32@4421
      lane 1 spi_tgt early CS           mon-in =      pins =      pushes = (7) | psim fail - blame 52@2345
      first fail  predicted -            chip -            =
      first blame predicted L1 52@2345   chip L1 52@2345   =
    D+vpipe
      lane 0 spi_ctl tco 14             mon-in =      pins =      pushes = (8) | psim fail - blame 91@113
      lane 1 uart_tx bad start          mon-in =      pins =      pushes = (0) | psim fail 13@81 blame -
      first fail  predicted L1 13@81     chip L1 13@81     =
      first blame predicted L0 91@113    chip L0 91@113    =
    G+vpipe
      lane 0 spi_tgt early CS rob       mon-in =      pins =      pushes = (2) | psim fail - blame 52@2345
      lane 1 uart_tx                    mon-in =      pins =      pushes = (0) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted L0 52@2345   chip L0 52@2345   =
      prefix at reset: verdict pins fail 1 blame 1
    H: after mid-run reset (prefix B+rob): L0 uart_tx, L1 spi_ctl tco 3 (expect no firings)
      lane 0 uart_tx                    mon-in =      pins =      pushes = (0) | psim fail - blame -
      lane 1 spi_ctl tco 3              mon-in =      pins =      pushes = (8) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
      prefix at reset: verdict pins fail 1 blame 1
    I: after reset 1 cycle long, 157 cycles into the prefix: C
      lane 0 uart_rx rate x1.08         mon-in =      pins =      pushes = (4) | psim fail - blame 32@4421
      lane 1 spi_tgt early CS           mon-in =      pins =      pushes = (7) | psim fail - blame 52@2345
      first fail  predicted -            chip -            =
      first blame predicted L1 52@2345   chip L1 52@2345   =
    J: documented P: L0 uart_rx P=35, L1 spi_ctl P=7 tco 3
      lane 0 uart_rx P35 115200@33MHz   mon-in =      pins =      pushes = (6) | psim fail - blame -
      lane 1 spi_ctl tco 3              mon-in =      pins =      pushes = (8) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    K: documented P: L0 uart_tx P=71, L1 spi_tgt P=7
      lane 0 uart_tx P71                mon-in =      pins =      pushes = (0) | psim fail - blame -
      lane 1 spi_tgt                    mon-in =      pins =      pushes = (8) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    L: documented P: L0 uart_rx P=35 short stop (frame 2), L1 spi_ctl P=7 tco 14
      lane 0 uart_rx P35 115200@33MHz   mon-in =      pins =      pushes = (6) | psim fail - blame 33@9217
      lane 1 spi_ctl tco 14             mon-in =      pins =      pushes = (8) | psim fail - blame 91@113
      first fail  predicted -            chip -            =
      first blame predicted L1 91@113    chip L1 91@113    =
    J30: 30 MHz P: L0 uart_rx, L1 spi_ctl P=7 tco 3
      lane 0 uart_rx P32 115200@30MHz   mon-in =      pins =      pushes = (6) | psim fail - blame -
      lane 1 spi_ctl tco 3              mon-in =      pins =      pushes = (8) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    K30: 30 MHz P: L0 uart_tx, L1 spi_tgt P=7
      lane 0 uart_tx P64                mon-in =      pins =      pushes = (0) | psim fail - blame -
      lane 1 spi_tgt                    mon-in =      pins =      pushes = (8) | psim fail - blame -
      first fail  predicted -            chip -            =
      first blame predicted -            chip -            =
    L30: 30 MHz P: L0 uart_rx short stop (frame 2), L1 spi_ctl tco 14
      lane 0 uart_rx P32 115200@30MHz   mon-in =      pins =      pushes = (6) | psim fail - blame 33@8449
      lane 1 spi_ctl tco 14             mon-in =      pins =      pushes = (8) | psim fail - blame 91@113
      first fail  predicted -            chip -            =
      first blame predicted L1 91@113    chip L1 91@113    =
    |}]
;;
