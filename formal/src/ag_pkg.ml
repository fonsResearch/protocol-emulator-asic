(* A2 for protocol packages (plan step 7): the ISA v1 lane spec circuit (spec_v1/Lane_circuit)
   running a package's firmware, composed with the package's monitor as the parallel ISA
   spec circuit (monitor_v1/Mon_spec; the engine refines it, R1), wired as in the chip
   (rtl_v1/Top_v1 with the engine): the lane reads the pads through a 2-flop synchroniser,
   the monitor synchronises them itself; the monitor observes the lane's outputs masked by
   OWN and its stream events; a blame reaches the lane one cycle later (registered).

   Inputs, all free in every cycle: rst_sync_n (low in frame 0), tick, run, uio_in pads,
   host TX pushes and data, host RX pops, clear_fault. Ticks are free, so the claims hold
   for every prescaler setting (contracts are in steps).

   Modes:
   `U   bad = a fail fires while no blame has fired up to and including this cycle
   `N1  cover: [goal] happens with no fail and no blame so far (expected FAIL = reachable,
        with a replayed witness): the assumption is satisfiable while the guarantee is
        exercised.
   Host-stream assumptions (outside the monitor, package-specific) restrict the free host
   side: [rx_never_full] = the RX FIFO is never full; [pop_pcs] = the lane never executes a
   POP at one of these program addresses while the TX FIFO is empty (the host keeps a byte
   ready for every frame, SPI target). *)
open! Core
open Hardcaml
open Signal
module L = Pemu_spec_v1.Lane_circuit
module Isa1 = Pemu_spec_v1.Isa1
module S = Pemu_monitor_v1.Mon_spec
module Compile = Pemu_monitor_v1.Compile

type goal =
  | Push_ok (* a push event *)
  | Pop_ok (* a pop event *)

let harness ?debug ?(rx_never_full = false) ?(pop_pcs = []) ~mode ~prog ~contract ~own ~od ~cfg ~cfg2 ~name () =
  let clock = input "clock" 1 in
  let gs = Reg_spec.create ~clock () in
  let started = reg gs vdd -- "env_started" in
  let rst_sync_n = input "rst_sync_n" 1 &: started in
  let spec = Reg_spec.create ~clock ~clear:~:rst_sync_n () in
  let sync2 x = reg spec (reg spec x) in
  let tick = input "tick" 1
  and run = input "run" 1
  and uio_in = input "uio_in" 8 in
  let words = Isa1.assemble prog in
  let blame_in = wire 1 in
  let o =
    L.create ~imem:(L.imem_rom words)
      { L.I.clock; rst_sync_n; tick; run; loaded = vdd; len = of_int ~width:8 (List.length prog)
      ; own = of_int ~width:8 own; od = of_int ~width:8 od; cfg = of_int ~width:8 cfg
      ; cfg2 = of_int ~width:8 cfg2; pins = sync2 uio_in; tx_push = input "tx_push" 1
      ; tx_wdata = input "tx_wdata" 8; rx_pop = input "rx_pop" 1; blame_in
      ; clear_fault = input "clear_fault" 1 }
  in
  let running = rst_sync_n &: run &: ~:(o.faulted) in
  let ownv = of_int ~width:8 own in
  let pkg = Compile.compile_exn contract in
  let mo =
    S.of_package pkg
      { S.I.clock; rst_sync_n; running; tick; ui_in = zero 8; uio_in; uo_out = zero 8
      ; uio_out = o.uio_out &: ownv; uio_oe = o.uio_oe &: ownv; pop_ev = o.pop_ev
      ; pop_data = o.pop_data; push_ev = o.push_ev; push_data = o.push_data }
  in
  let fail_now = mo.fire &: ~:(mo.role) |> fun v -> v <>:. 0
  and blame_now = mo.fire &: mo.role |> fun v -> v <>:. 0 in
  blame_in <== reg spec blame_now -- "h_blame_to_lane";
  let sticky x n =
    let d = wire 1 in
    let q = reg gs d -- n in
    d <== (q |: x);
    q
  in
  let blame_seen = sticky blame_now "h_blame_seen"
  and fail_seen = sticky fail_now "h_fail_seen" in
  let env_bad = if rx_never_full then o.rx_level ==:. 8 else gnd in
  let env_bad =
    List.fold pop_pcs ~init:env_bad ~f:(fun acc a ->
      acc |: (running &: tick &: (o.pc ==:. a) &: (o.tx_level ==:. 0)))
  in
  let env_bad_seen = sticky env_bad "h_env_bad" in
  let ok = ~:(env_bad_seen |: env_bad) in
  let bad =
    match mode with
    | `U -> ok &: fail_now &: ~:(blame_seen |: blame_now)
    | `N1 goal ->
      let g = match goal with Push_ok -> o.push_ev | Pop_ok -> o.pop_ev in
      ok &: g &: ~:(fail_seen |: fail_now |: blame_seen |: blame_now)
  in
  Harness.bad_circuit ?debug
    ~dbg:[ "tick", tick; "pc", o.pc; "fire", mo.fire; "role", mo.role; "uio_in", uio_in ]
    ~name bad
;;

module P1 = Pemu_spec_v1.Programs_v1
module Lib = Pemu_monitor_v1.Library_v1

let uart_rx_late_mutant =
  List.mapi (P1.uart_rx ~d:8 ~pin:1) ~f:(fun i x -> if i = 2 then Isa1.Wait (8 + 4 - 3 + 8) else x)
;;

let uart_rx_noassume =
  let c = Lib.uart_rx ~d:8 ~m:2 ~pin:1 in
  { c with watchers = List.filter c.watchers ~f:(fun w -> String.equal w.wname "receiver") }
;;

(* SPI (doc/protocols/spi_v1.md) *)
let spi_modes = [ false, false; false, true; true, false; true, true ]
let spi_mid (cpol, cpha) = (if cpol then 2 else 0) + if cpha then 1 else 0

let spi_tgt_nomov ~cpol ~cpha =
  (* mutant: MISO is never updated after the first bit (per-bit MOV removed: replaced by NOP) *)
  let p = P1.spi_tgt ~cpol ~cpha in
  let k = if cpha then 7 else 9 in
  List.mapi p ~f:(fun i x -> if i = k then Isa1.Nop else x)
;;

let spi_ctl_lsbin ~cpol ~cpha =
  List.map (P1.spi_ctl ~cpol ~cpha) ~f:(function Isa1.Pin (7, In_msb) -> Isa1.Pin (7, In_lsb) | x -> x)
;;

let spi_tgt_noassume ~cpol ~cpha =
  let c = Lib.spi_tgt ~cpol ~cpha ~h_min:3 ~g:6 in
  { c with watchers = List.filter c.watchers ~f:(fun w -> not (String.equal w.wname "ctl")) }
;;

let spi_all ?debug () =
  let ctl ?prog ?(cfg = P1.spi_cfg_ctl) ~mode (cpol, cpha) name =
    let prog = Option.value prog ~default:(P1.spi_ctl ~cpol ~cpha) in
    harness ?debug ~rx_never_full:true ~mode ~prog ~contract:(Lib.spi_ctl ~cpol ~cpha ~h:2)
      ~own:P1.spi_own_ctl ~od:0 ~cfg ~cfg2:P1.spi_cfg2_ctl ~name ()
  in
  let tgt ?prog ?contract ~mode (cpol, cpha) name =
    let prog = Option.value prog ~default:(P1.spi_tgt ~cpol ~cpha) in
    let contract = Option.value contract ~default:(Lib.spi_tgt ~cpol ~cpha ~h_min:3 ~g:6) in
    harness ?debug ~rx_never_full:true ~pop_pcs:[ 2 ] ~mode ~prog ~contract ~own:P1.spi_own_tgt ~od:0
      ~cfg:0 ~cfg2:0 ~name ()
  in
  List.concat_map spi_modes ~f:(fun m ->
    let i = spi_mid m in
    [ ctl ~mode:`U m (sprintf "a2_spi_ctl_m%d_u" i)
    ; ctl ~mode:(`N1 Push_ok) m (sprintf "a2_spi_ctl_m%d_n1_cover_neg" i)
    ; tgt ~mode:`U m (sprintf "a2_spi_tgt_m%d_u" i)
    ; tgt ~mode:(`N1 Push_ok) m (sprintf "a2_spi_tgt_m%d_n1_cover_neg" i)
    ])
  @ [ ctl ~prog:(spi_ctl_lsbin ~cpol:false ~cpha:false) ~mode:`U (false, false) "a2_spi_ctl_m0_lsbin_neg"
    ; ctl ~cfg:0 ~mode:`U (false, true) "a2_spi_ctl_m1_lsbmosi_neg"
    ; tgt ~prog:(spi_tgt_nomov ~cpol:false ~cpha:false) ~mode:`U (false, false) "a2_spi_tgt_m0_nomov_neg"
    ; tgt ~prog:(spi_tgt_nomov ~cpol:true ~cpha:true) ~mode:`U (true, true) "a2_spi_tgt_m3_nomov_neg"
    ; tgt ~contract:(spi_tgt_noassume ~cpol:false ~cpha:false) ~mode:`U (false, false) "a2_spi_tgt_m0_noassume_neg"
    ]
;;

let all ?debug () =
  let rx ?(prog = P1.uart_rx ~d:8 ~pin:1) ?(contract = Lib.uart_rx ~d:8 ~m:2 ~pin:1) ~mode name =
    harness ?debug ~rx_never_full:true ~mode ~prog ~contract ~own:0 ~od:0 ~cfg:0 ~cfg2:0 ~name ()
  in
  let tx ?(prog = P1.uart_tx ~d:4) ~mode name =
    harness ?debug ~mode ~prog ~contract:(Lib.uart_tx ~d:4 ~pin:0) ~own:1 ~od:0 ~cfg:0 ~cfg2:0 ~name ()
  in
  [ rx ~mode:`U "a2_uart_rx_d8_u"
  ; rx ~mode:(`N1 Push_ok) "a2_uart_rx_d8_n1_cover_neg"
  ; rx ~prog:uart_rx_late_mutant ~mode:`U "a2_uart_rx_d8_late_neg"
  ; rx ~contract:uart_rx_noassume ~mode:`U "a2_uart_rx_d8_noassume_neg"
  ; tx ~mode:`U "a2_uart_tx_d4_u"
  ; tx ~mode:(`N1 Pop_ok) "a2_uart_tx_d4_n1_cover_neg"
  ; tx ~prog:(P1.uart_tx_bad_start ~d:4) ~mode:`U "a2_uart_tx_d4_badstart_neg"
  ]
  @ spi_all ?debug ()
;;
