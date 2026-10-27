(* C3 differential check (log/proofs_v2.md section 7, plan item 3): the v2 top RTL (Top_v1, ROM
   monitor, 5 slots, library Rom_lib.minimum_v2, behavioural SRAMs), driven through its pins by a
   bit-banged host and a protocol peer, against the A2 harness composition as implemented by
   Psim (lane model + monitor interpreter, wired as in formal/src/ag_pkg.ml), on the same
   firmware, peer and divisor. Compared per scenario, with the chip trace aligned to Psim time:
   owned uio_out/uio_oe in every cycle, first fail and first blame (code; step stamp mapped to
   Psim time), the lane-0 monitor-input stream (running, tick, pads, owned outputs, FIFO events)
   in every cycle, and the received bytes. The chip's RUN-to-start latency is calibrated once on
   UART TX (no peer input) and reused for all scenarios.
   Environment convention (must match Psim): Lane_model.step returns the outputs of the cycle
   (pre-update), and Psim resolves the pad of cycle t from the outputs of cycle t - 1, i.e. one
   cycle of output-to-pad delay. The chip harness does the same, and keys chip outputs by the
   cycle in which they are valid. A first version used zero delay; the calibration then aligned
   the pins but left the lane tick one cycle late relative to the pads, which showed up as a
   constant +1 on all stamps and, with the time-based SPI controller peer, a blame two steps
   early (see log/proofs_v2.md section 7). *)
open! Core
open Hardcaml
open Pemu_spec_v1
open Pemu_monitor_v1
open Pemu_rtl_v1
module Psim = Pemu_protocols_v1.Psim
module Peers = Pemu_protocols_v1.Peers
module P1 = Programs_v1
module Lib = Library_v1
(* top outputs plus lane 0's monitor inputs (test visibility via Top_v1.create_with_debug) *)
module Ox = struct
  type 'a t =
    { top : 'a Top_v1.O.t [@rtlprefix "t_"]
    ; m_run : 'a
    ; m_tick : 'a
    ; m_out : 'a [@bits 8]
    ; m_oe : 'a [@bits 8]
    ; m_xo : 'a [@bits 2]
    ; m_pop : 'a
    ; m_pop_d : 'a [@bits 8]
    ; m_push : 'a
    ; m_push_d : 'a [@bits 8]
    ; m_clr : 'a
    ; m1_run : 'a
    ; m1_tick : 'a
    ; m1_out : 'a [@bits 8]
    ; m1_oe : 'a [@bits 8]
    ; m1_xo : 'a [@bits 2]
    ; m1_pop : 'a
    ; m1_pop_d : 'a [@bits 8]
    ; m1_push : 'a
    ; m1_push_d : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module Sim = Cyclesim.With_interface (Top_v1.I) (Ox)

let lib = List.map (Rom_lib.minimum_v2 ()) ~f:Compile.compile_exn

type h =
  { sim : (Bits.t ref Top_v1.I.t, Bits.t ref Ox.t) Cyclesim.t
  ; mutable rst_n : bool
  ; mutable s0 : bool
  ; mutable s1 : bool
  ; mutable cs_n : bool
  ; mutable sck : bool
  ; mutable mosi : bool
  ; mutable miso : int
  ; mutable n : int
  ; mutable c_rst : int (* first cycle with rst_sync_n = 1 *)
  ; mutable off : int (* Psim cycle = chip cycle - off *)
  ; mutable peer : Psim.chip_view -> Psim.peer_drive
  ; mutable wired : int
  ; mutable prev_out : int (* outputs after the previous edge *)
  ; mutable prev_oe : int
  ; mutable prev2_out : int (* one edge earlier: Psim's pad model (pad at t from outputs of t - 1) *)
  ; mutable prev2_oe : int
  ; mutable prev_pad : int
  ; outs : (int, int * int) Hashtbl.t (* chip cycle -> uio_out, uio_oe during that cycle *)
  ; pads : (int, int) Hashtbl.t (* chip cycle -> resolved uio pad *)
  ; mon : (int, Interp.inputs) Hashtbl.t (* chip cycle -> lane 0 monitor inputs *)
  ; mutable clears : int list (* chip cycles with lane 0 clear_fault high *)
  ; mon1 : (int, Interp.inputs) Hashtbl.t (* chip cycle -> lane 1 monitor inputs *)
  }

let no_peer (_ : Psim.chip_view) = { Psim.drive_oe = 0; drive_val = 0 }

let resolve ~wired ~out ~oe (pd : Psim.peer_drive) =
  List.init 8 ~f:(fun i ->
    let b x = (x lsr i) land 1 = 1 in
    let chip_low = b oe && not (b out) and chip_high = b oe && b out in
    let peer_low = b pd.drive_oe && not (b pd.drive_val) and peer_high = b pd.drive_oe && b pd.drive_val in
    let v =
      if b wired then not (chip_low || peer_low)
      else if chip_low || chip_high then chip_high
      else if peer_low || peer_high then peer_high
      else true
    in
    if v then 1 lsl i else 0)
  |> List.fold ~init:0 ~f:( lor )
;;

let cycle h =
  let i = Cyclesim.inputs h.sim and o = Cyclesim.outputs h.sim in
  h.miso <- Bits.to_int !(o.top.uo_out) land 1;
  (* environment as in Psim: Lane_model.step returns the outputs of the cycle (pre-update), and
     the pad of cycle t resolves the outputs of cycle t - 1, i.e. one cycle of output-to-pad
     delay; here the outputs of cycle t - 1 are those after edge t - 2 *)
  let pd = h.peer { cycle = h.n - h.off; out = h.prev2_out; oe = h.prev2_oe; pad = h.prev_pad } in
  let pad = resolve ~wired:h.wired ~out:h.prev2_out ~oe:h.prev2_oe pd in
  if not h.rst_n then (h.s0 <- false; h.s1 <- false);
  if h.s1 && h.c_rst < 0 then h.c_rst <- h.n;
  i.rst_sync_n := Bits.of_bool h.s1;
  i.ui_in := Bits.of_int ~width:8 (Bool.to_int h.cs_n lor (Bool.to_int h.sck lsl 1) lor (Bool.to_int h.mosi lsl 2));
  i.uio_in := Bits.of_int ~width:8 pad;
  Cyclesim.cycle h.sim;
  if h.rst_n then (h.s1 <- h.s0; h.s0 <- true);
  let ob : _ Ox.t = Cyclesim.outputs ~clock_edge:Before h.sim in
  let gi x = Bits.to_int !x and gb x = Bits.to_bool !x in
  Hashtbl.set h.mon ~key:h.n
    ~data:
      { Interp.rst_sync_n = h.s1; running = gb ob.m_run; tick = gb ob.m_tick
      ; ui_in = Bits.to_int !(i.ui_in); uio_in = pad; uo_out = gi ob.m_xo lsl 3
      ; uio_out = gi ob.m_out; uio_oe = gi ob.m_oe; pop_ev = gb ob.m_pop; pop_data = gi ob.m_pop_d
      ; push_ev = gb ob.m_push; push_data = gi ob.m_push_d };
  Hashtbl.set h.mon1 ~key:h.n
    ~data:
      { Interp.rst_sync_n = h.s1; running = gb ob.m1_run; tick = gb ob.m1_tick
      ; ui_in = Bits.to_int !(i.ui_in); uio_in = pad; uo_out = gi ob.m1_xo lsl 5
      ; uio_out = gi ob.m1_out; uio_oe = gi ob.m1_oe; pop_ev = gb ob.m1_pop; pop_data = gi ob.m1_pop_d
      ; push_ev = gb ob.m1_push; push_data = gi ob.m1_push_d };
  if gb ob.m_clr then h.clears <- h.n :: h.clears;
  let out = Bits.to_int !(o.top.uio_out) and oe = Bits.to_int !(o.top.uio_oe) in
  Hashtbl.set h.outs ~key:(h.n + 1) ~data:(out, oe) (* valid during cycle n + 1 *);
  Hashtbl.set h.pads ~key:h.n ~data:pad;
  h.prev2_out <- h.prev_out; h.prev2_oe <- h.prev_oe;
  h.prev_out <- out; h.prev_oe <- oe; h.prev_pad <- pad;
  h.n <- h.n + 1
;;

let wait h k = for _ = 1 to k do cycle h done

let xfer_byte h b =
  let r = ref 0 in
  for k = 7 downto 0 do
    h.mosi <- (b lsr k) land 1 = 1; wait h 6; r := (!r lsl 1) lor h.miso; h.sck <- true; wait h 6; h.sck <- false
  done;
  !r
;;

let transaction h bytes =
  h.cs_n <- false; wait h 6;
  let out = List.map bytes ~f:(xfer_byte h) in
  wait h 6; h.cs_n <- true; wait h 8; out
;;

let write h a d = ignore (transaction h ((a land 0x7F) :: d) : int list)
let read h a k = List.tl_exn (transaction h ((0x80 lor a) :: List.init k ~f:(fun _ -> 0)))
let le32 l = List.foldi l ~init:0 ~f:(fun i acc b -> acc lor (b lsl (8 * i)))

let create () =
  let sim =
    Sim.create
      (fun i ->
        let o, (d : Top_v1.debug) =
          Top_v1.create_with_debug ~loadable:[| false; false |] ~mon_slots:5 ~lib
            ~sram:(fun _ i -> fst (Sram256.behavioural i)) i
        in
        let lo = d.lane_outputs.(0) and l1 = d.lane_outputs.(1) in
        { Ox.top = o; m_run = d.mon_running.(0); m_tick = d.lane_inputs.(0).tick
        ; m_out = Signal.(lo.uio_out &: d.own.(0)); m_oe = Signal.(lo.uio_oe &: d.own.(0)); m_xo = lo.xo
        ; m_pop = lo.pop_ev; m_pop_d = lo.pop_data; m_push = lo.push_ev; m_push_d = lo.push_data
        ; m_clr = d.lane_inputs.(0).clear_fault
        ; m1_run = d.mon_running.(1); m1_tick = d.lane_inputs.(1).tick
        ; m1_out = Signal.(l1.uio_out &: d.own.(1)); m1_oe = Signal.(l1.uio_oe &: d.own.(1)); m1_xo = l1.xo
        ; m1_pop = l1.pop_ev; m1_pop_d = l1.pop_data; m1_push = l1.push_ev; m1_push_d = l1.push_data })
  in
  let h =
    { sim; rst_n = false; s0 = false; s1 = false; cs_n = true; sck = false; mosi = false; miso = 0; n = 0
    ; c_rst = -1; off = 0; peer = no_peer; wired = 0; prev_out = 0; prev_oe = 0; prev2_out = 0; prev2_oe = 0; prev_pad = 0xFF
    ; outs = Hashtbl.create (module Int); pads = Hashtbl.create (module Int); mon = Hashtbl.create (module Int); clears = []
    ; mon1 = Hashtbl.create (module Int) }
  in
  wait h 3; h.rst_n <- true; wait h 6; h
;;

(* length of a 2-byte write transaction in cycles: 6 + 2 * 8 * 12 + 6 + 8 *)
let ctrl_write_len = 6 + (2 * 8 * 12) + 6 + 8

type chip_result =
  { outs : (int, int * int) Hashtbl.t
  ; pads : (int, int) Hashtbl.t
  ; mon : (int, Interp.inputs) Hashtbl.t
  ; clears : int list (* Psim time *)
  ; first_units : int (* FIRST_UNITS: fail unit [2:0], blame unit [6:4] *)
  ; off : int
  ; first_fail : (int * int) option (* code, Psim-time cycle of the step stamp *)
  ; first_blame : (int * int) option
  ; rx : int list
  }

(* [ctrl_writes]: (Psim time at which the CTRL write transaction starts, value) *)
let chip_run ?(ctrl_writes = []) ~k ~(setup : Psim.setup) ~pkg ~tx_bytes ~peer ~cycles () =
  let h = create () in
  let b = 0x10 in
  write h b [ setup.own ]; write h (b + 1) [ setup.od ];
  write h (b + 2) [ setup.p land 0xFF; setup.p lsr 8 ];
  write h (b + 5) [ setup.cfg ]; write h (b + 6) [ setup.cfg2 ];
  let words = Isa1.assemble setup.prog in
  write h (b + 4) [ List.length setup.prog ]; write h (b + 7) [ 0 ];
  write h (b + 8) (List.concat_map (List.init (List.length setup.prog) ~f:Fn.id) ~f:(fun a -> [ words.(a) land 0xFF; words.(a) lsr 8 ]));
  let p = List.nth_exn lib pkg in
  write h 0x50 [ 0x80 lor pkg ]; write h 0x60 (Array.to_list p.remap);
  if not (List.is_empty tx_bytes) then write h (b + 9) tx_bytes;
  h.wired <- setup.open_drain_wired_and;
  h.off <- h.n + ctrl_write_len - k;
  h.peer <- peer;
  write h 0x01 [ 0x01 ];
  let stop = h.off + cycles in
  List.iter (List.sort ctrl_writes ~compare:(fun (a, _) (b, _) -> Int.compare a b)) ~f:(fun (t, v) ->
    while h.n < h.off + t do cycle h done;
    write h 0x01 [ v ]);
  while h.n < stop do cycle h done;
  h.peer <- no_peer;
  let v = read h 0x40 12 in
  let code i = List.nth_exn v i and time i = le32 (List.sub v ~pos:i ~len:4) in
  let to_psim s = h.c_rst + s - h.off in
  let first_fail = if code 0 land 1 = 1 then Some (code 1, to_psim (time 4)) else None
  and first_blame = if code 0 land 2 = 2 then Some (code 2, to_psim (time 8)) else None in
  let lvl = (List.hd_exn (read h (b + 11) 1) lsr 4) land 0xF in
  let rx = if lvl = 0 then [] else read h (b + 10) lvl in
  { outs = h.outs; pads = h.pads; mon = h.mon; off = h.off
  ; clears = List.rev_map h.clears ~f:(fun n -> n - h.off); first_units = code 3; first_fail; first_blame; rx }
;;

let psim_first r role =
  List.find_map (Psim.firings r) ~f:(fun (c, ro, k) -> if Lang.equal_role ro role then Some (k, c) else None)
;;

let pin_mismatches ~own (c : chip_result) (r : Psim.result) ~from ~upto =
  let m = ref 0 and first = ref None in
  for cy = from to upto - 1 do
    let co, ce = Option.value (Hashtbl.find c.outs (cy + c.off)) ~default:(-1, -1)
    and po, pe = r.outs.(cy) in
    if co land own <> po land own || ce land own <> pe land own
    then (incr m; if Option.is_none !first then first := Some cy)
  done;
  !m, !first
;;

let show_opt = function None -> "-" | Some (code, cy) -> sprintf "%02X@%d" code cy

let compare_one ~k ~name ~setup ~pkg ~tx_bytes ~peer ~cycles =
  let pmi = Array.create ~len:cycles None in
  let on_cycle cy mi _ = pmi.(cy) <- Some mi in
  let r = Psim.run ~on_cycle ~tx_bytes ~rx_pop_every:1_000_000_000 ~setup ~cycles ~peer:(peer ()) () in
  let c = chip_run ~k ~setup ~pkg ~tx_bytes ~peer:(peer ()) ~cycles () in
  let pm, pf = pin_mismatches ~own:setup.own c r ~from:0 ~upto:cycles in
  let sf = psim_first r Fail and sb = psim_first r Blame in
  let px = Psim.pushes r in
  let pad_first =
    List.find (List.init cycles ~f:Fn.id) ~f:(fun cy ->
      Option.value (Hashtbl.find c.pads (cy + c.off)) ~default:(-1) <> r.pads.(cy))
  in
  (* monitor-input stream: first cycle and fields where chip and psim differ (ui_in and uo_out
     are excluded: psim drives them as 0; reported separately when nonzero on the chip) *)
  let fields (a : Interp.inputs) (b : Interp.inputs) =
    List.filter_map
      [ "running", Bool.equal a.running b.running; "tick", Bool.equal a.tick b.tick
      ; "uio_in", a.uio_in = b.uio_in; "uio_out", a.uio_out = b.uio_out; "uio_oe", a.uio_oe = b.uio_oe
      ; "pop", Bool.equal a.pop_ev b.pop_ev && ((not a.pop_ev) || a.pop_data = b.pop_data)
      ; "push", Bool.equal a.push_ev b.push_ev && ((not a.push_ev) || a.push_data = b.push_data) ]
      ~f:(fun (n, ok) -> if ok then None else Some n)
  in
  let mon_first =
    List.find_map (List.init cycles ~f:Fn.id) ~f:(fun cy ->
      match pmi.(cy), Hashtbl.find c.mon (cy + c.off) with
      | Some a, Some b -> (match fields a b with [] -> None | l -> Some (cy, l))
      | _ -> None)
  in
  let uo_nz = List.count (List.init cycles ~f:Fn.id) ~f:(fun cy ->
    match Hashtbl.find c.mon (cy + c.off) with Some b -> b.uo_out <> 0 | None -> false) in
  printf "%-30s mon-in %s%s pads %s pins %s | fail psim %s chip %s | blame psim %s chip %s | rx %s\n" name
    (match mon_first with None -> "=" | Some (cy, l) -> sprintf "first-diff@%d [%s]" cy (String.concat ~sep:"," l))
    (if uo_nz = 0 then "" else sprintf " (uo_out nonzero in %d cycles)" uo_nz)
    (match pad_first with None -> "=" | Some cy -> sprintf "first-diff@%d" cy)
    (if pm = 0 then "=" else sprintf "%d mism (first @%d)" pm (Option.value pf ~default:(-1)))
    (show_opt sf) (show_opt c.first_fail) (show_opt sb) (show_opt c.first_blame)
    (if [%equal: int list] (List.take px 8) c.rx then sprintf "= (%d)" (List.length c.rx)
     else sprintf "psim %d chip %d DIFFER" (List.length px) (List.length c.rx))
;;

let uart_tx_setup prog = { Psim.prog; own = 0x01; od = 0; cfg = 0; cfg2 = 0; p = 7; contract = Lib.uart_tx ~d:4 ~pin:0; open_drain_wired_and = 0 }
let rx_setup ?(prog = P1.uart_rx ~d:8 ~pin:1) () = { Psim.prog; own = 0; od = 0; cfg = 0; cfg2 = 0; p = 64; contract = Lib.uart_rx ~d:8 ~m:2 ~pin:1; open_drain_wired_and = 0 }
let ctl_setup = { Psim.prog = P1.spi_ctl ~cpol:false ~cpha:false; own = P1.spi_own_ctl; od = 0; cfg = P1.spi_cfg_ctl; cfg2 = P1.spi_cfg2_ctl; p = 7; contract = Lib.spi_ctl ~cpol:false ~cpha:false ~h:2; open_drain_wired_and = 0 }
let tgt_setup = { Psim.prog = P1.spi_tgt ~cpol:false ~cpha:false; own = P1.spi_own_tgt; od = 0; cfg = 0; cfg2 = 0; p = 7; contract = Lib.spi_tgt ~cpol:false ~cpha:false ~h_min:3 ~g:6; open_drain_wired_and = 0 }
let host_bytes = [ 0xA5; 0x3C; 0x00; 0xFF; 0x81; 0x7E; 0x55; 0x0F ]
let peer_bytes = [ 0x96; 0x01; 0x80; 0xC3; 0x5A; 0xF0; 0x33; 0xE7 ]

(* calibration: the k for which the UART TX pin traces agree. With no peer input the chip trace
   does not depend on k, so one chip run is re-aligned for every candidate. *)
let calibrate () =
  let setup = uart_tx_setup (P1.uart_tx ~d:4) and cycles = 3000 in
  let r = Psim.run ~tx_bytes:[ 0xA5; 0x3C ] ~rx_pop_every:1_000_000_000 ~setup ~cycles ~peer:no_peer () in
  let c = chip_run ~k:0 ~setup ~pkg:0 ~tx_bytes:[ 0xA5; 0x3C ] ~peer:no_peer ~cycles () in
  List.filter (List.init 400 ~f:Fn.id) ~f:(fun k ->
    fst (pin_mismatches ~own:setup.own { c with off = c.off - k } r ~from:0 ~upto:cycles) = 0)
;;

let uart_bp = 60e6 /. 115200.

let%expect_test "C3 differential: v2 top RTL vs A2 harness composition (Psim)" =
  let ks = calibrate () in
  printf "calibration: k in [%s]\n" (String.concat ~sep:" " (List.map ks ~f:Int.to_string));
  let k = List.hd_exn ks in
  let frames bp = Peers.frames_of ~bp ~st0:2000 [ 0x55; 0xA5; 0x00; 0xFF; 0x3C; 0x81; 0x7E; 0x01 ] ~gap:(fun b -> 3 + (b * 7 % 400)) in
  let run = compare_one ~k in
  run ~name:"uart_tx correct" ~setup:(uart_tx_setup (P1.uart_tx ~d:4)) ~pkg:0 ~tx_bytes:[ 0xA5; 0x3C; 0x00 ] ~peer:(fun () -> no_peer) ~cycles:4000;
  run ~name:"uart_tx bad start (fail)" ~setup:(uart_tx_setup (P1.uart_tx_bad_start ~d:4)) ~pkg:0 ~tx_bytes:[ 0xA5; 0x3C; 0x00 ] ~peer:(fun () -> no_peer) ~cycles:4000;
  run ~name:"uart_rx nominal" ~setup:(rx_setup ()) ~pkg:1 ~tx_bytes:[] ~peer:(fun () -> Peers.sender ~pin:1 ~bp:uart_bp ~frames:(frames uart_bp) ~defect:No_defect) ~cycles:60_000;
  run ~name:"uart_rx 8% fast (blame)" ~setup:(rx_setup ()) ~pkg:1 ~tx_bytes:[] ~peer:(fun () -> let bp = uart_bp /. 1.08 in Peers.sender ~pin:1 ~bp ~frames:(frames bp) ~defect:No_defect) ~cycles:60_000;
  let late = List.mapi (P1.uart_rx ~d:8 ~pin:1) ~f:(fun i x -> if i = 2 then Isa1.Wait (8 + 4 - 3 + 8) else x) in
  run ~name:"uart_rx late sampling (fail)" ~setup:(rx_setup ~prog:late ()) ~pkg:1 ~tx_bytes:[] ~peer:(fun () -> Peers.sender ~pin:1 ~bp:uart_bp ~frames:(frames uart_bp) ~defect:No_defect) ~cycles:60_000;
  run ~name:"spi_ctl m0 tco 3" ~setup:ctl_setup ~pkg:2 ~tx_bytes:host_bytes ~peer:(fun () -> (Peers.spi_target ~cpol:false ~cpha:false ~tco:3 ~send:peer_bytes ()).drive) ~cycles:6000;
  run ~name:"spi_ctl m0 tco 14 (blame)" ~setup:ctl_setup ~pkg:2 ~tx_bytes:host_bytes ~peer:(fun () -> (Peers.spi_target ~cpol:false ~cpha:false ~tco:14 ~send:peer_bytes ()).drive) ~cycles:6000;
  let ctl ?defect () = Peers.spi_controller ~cpol:false ~cpha:false ~hp:40 ~setup:40 ~hold:40 ~gap:144 ~mdly:2 ~t0:300 ~bytes:peer_bytes ?defect () in
  let cycles = (ctl ()).frames_end + 200 in
  run ~name:"spi_tgt m0 hp 40" ~setup:tgt_setup ~pkg:3 ~tx_bytes:host_bytes ~peer:(fun () -> (ctl ()).cdrive) ~cycles;
  run ~name:"spi_tgt m0 early CS (blame)" ~setup:tgt_setup ~pkg:3 ~tx_bytes:host_bytes ~peer:(fun () -> (ctl ~defect:(Peers.Early_rise (2, 9)) ()).cdrive) ~cycles;
  [%expect {|
    calibration: k in [19]
    uart_tx correct                mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (0)
    uart_tx bad start (fail)       mon-in = pads = pins = | fail psim 13@81 chip 13@81 | blame psim - chip - | rx = (0)
    uart_rx nominal                mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    uart_rx 8% fast (blame)        mon-in = pads = pins = | fail psim - chip - | blame psim 32@4421 chip 32@4421 | rx = (6)
    uart_rx late sampling (fail)   mon-in = pads = pins = | fail psim 4B@7021 chip 4B@7021 | blame psim - chip - | rx = (6)
    spi_ctl m0 tco 3               mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    spi_ctl m0 tco 14 (blame)      mon-in = pads = pins = | fail psim - chip - | blame psim 91@113 chip 91@113 | rx = (8)
    spi_tgt m0 hp 40               mon-in = pads = pins = | fail psim - chip - | blame psim - chip - | rx = (8)
    spi_tgt m0 early CS (blame)    mon-in = pads = pins = | fail psim - chip - | blame psim 52@2345 chip 52@2345 | rx = (7)
    |}]
;;
