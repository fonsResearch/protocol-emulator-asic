(* v2 mutation driver (plan step 9).
     mutants_v2.exe list <unit>                CSV: index,op,desc
     mutants_v2.exe sim <unit> <index> [n]     oracle SIM: the unit's differential cyclesim test
                                               with the mutant; KILLED <where> | SURVIVED <budget>
   units: lane_rtl (vs Lane_model, rtl_v1/test/test_rtl_diff.ml), lane_spec (vs Lane_model,
   spec_v1/test/test_lane_diff.ml), mon_lane (vs Mon_spec, shipped 5 slots + pipelined schedule,
   monitor_v1/test/test_mon_lane.ml diff_pipe). index "id" = identity copy (copier check). *)
open! Core
open Pemu_formal
module Trd = Pemu_rtl_v1_test.Test_rtl_diff
module Tld = Pemu_spec_v1_test.Test_lane_diff
module Tml = Pemu_monitor_v1_test.Test_mon_lane

let sim u index n =
  let t0 = Time_ns.now () in
  let res =
    match (u : Mutate_v2.unit_) with
    | Lane_rtl ->
      let n = Option.value n ~default:300 in
      let cov : Trd.cov =
        { cycles = 0; acked_writes = 0; acked_during_run_phase = 0; refused_writes = 0; ser_busy = 0
        ; pops = 0; pushes = 0; faults = Array.create ~len:4 0; mismatches = 0; first = None }
      in
      let rec go seed =
        if seed > n
        then sprintf "SURVIVED programs=%d cycles=%d" n cov.cycles
        else (
          Trd.run_one ~mk:(fun ~sram i -> Mutate_v2.lane_rtl ~index ~sram i) ~seed ~cycles:2000 cov;
          if cov.mismatches > 0 then sprintf "KILLED program=%d cycles=%d" seed cov.cycles else go (seed + 1))
      in
      go 1
    | Lane_spec ->
      let n = Option.value n ~default:300 in
      let cov : Tld.cov =
        { cycles = 0; steps = 0; ser_busy = 0; se0 = 0; stuff = 0; timeouts = 0; pops = 0; pushes = 0
        ; faults = Array.create ~len:4 0; mismatches = 0; first = None }
      in
      let rec go seed =
        if seed > n
        then sprintf "SURVIVED programs=%d cycles=%d" n cov.cycles
        else (
          Tld.run_one ~mk:(fun ~imem i -> Mutate_v2.lane_spec ~index ~imem i) ~seed ~cycles:2000 cov;
          if cov.mismatches > 0 then sprintf "KILLED program=%d cycles=%d" seed cov.cycles else go (seed + 1))
      in
      go 1
    | Mon_lane ->
      let n = Option.value n ~default:200 in
      let mk ~tables ~present ~fetch i =
        Mutate_v2.mon_lane ~index ~slots:5 ~pipe:true ~tables ~present ~fetch i
      in
      (* tick spacing 5 (the admission minimum) for most packages, 9 for the rest *)
      let pk1, st1, _, m1, _ = Tml.diff_pipe ~mk ~stop_first:true ~spacing:5 ~packages:(n * 3 / 4) ~cycles:3000 ~seed0:9000 () in
      if m1 > 0
      then sprintf "KILLED spacing=5 package=%d steps=%d" pk1 st1
      else (
        let pk2, st2, _, m2, _ = Tml.diff_pipe ~mk ~stop_first:true ~spacing:9 ~packages:(n / 4) ~cycles:3000 ~seed0:9500 () in
        if m2 > 0
        then sprintf "KILLED spacing=9 package=%d steps=%d" pk2 (st1 + st2)
        else sprintf "SURVIVED packages=%d steps=%d" (pk1 + pk2) (st1 + st2))
  in
  printf "%s wall=%.1f\n" res (Time_ns.Span.to_sec (Time_ns.diff (Time_ns.now ()) t0))
;;

(* ---- chip-level oracles (C3 and the sigrok inputs) ----
   The v2 top (shipped library v2inc5, lane pipe, verdict pipe, parameter windows) with the mutant
   installed in both lanes (lane_rtl) or both monitor lanes (mon_lane), against Psim, on the C3
   directed scenarios plus USB and the I2C controller. C3 kills when the monitor-input stream,
   owned pins, verdict or pushes differ from Psim (Test_c3_env.diverged). For the clean scenarios
   the pad trace (<dir>/<scenario>.rle) and the intended traffic (bytes the host or peer meant to
   send, not Psim output) are written for formal/mutation/v2/sigrok_check.sh. *)
module D = Pemu_rtl_v1_test.Test_c3_diff
module E = Pemu_rtl_v1_test.Test_c3_env
module Psim = Pemu_protocols_v1.Psim
module Peers = Pemu_protocols_v1.Peers
module P1 = Pemu_spec_v1.Programs_v1
module Lib = Pemu_monitor_v1.Library_v1

let hex l = String.concat (List.map l ~f:(fun b -> sprintf "%02X\n" b))

type scen =
  { sname : string
  ; setup : Psim.setup
  ; pkg : int
  ; tx_bytes : int list
  ; peer : unit -> Psim.chip_view -> Psim.peer_drive
  ; cycles : int
  ; trace : (int list * (string * string) list) option (* pins; (suffix, intended content) *)
  }

let scenarios () =
  let bp = D.uart_bp in
  let frames bp =
    Peers.frames_of ~bp ~st0:2000 [ 0x55; 0xA5; 0x00; 0xFF; 0x3C; 0x81; 0x7E; 0x01 ] ~gap:(fun b -> 3 + (b * 7 % 400))
  in
  let rx_bytes = [ 0x55; 0xA5; 0x00; 0xFF; 0x3C; 0x81; 0x7E; 0x01 ] in
  let ctl ?defect () =
    Peers.spi_controller ~cpol:false ~cpha:false ~hp:40 ~setup:40 ~hold:40 ~gap:144 ~mdly:2 ~t0:300
      ~bytes:D.peer_bytes ?defect ()
  in
  let spi_pins = [ Peers.spi_sclk; Peers.spi_mosi; Peers.spi_miso; Peers.spi_cs ] in
  let usb_setup =
    { Psim.prog = P1.usb_ls_tx; own = P1.usb_own; od = 0; cfg = P1.usb_cfg; cfg2 = 0
    ; p = Pemu_rtl_v1.Rom_lib.usb_ls_p ~clock_hz:Pemu_rtl_v1.Rom_lib.v2_clock_hz
    ; contract = Lib.usb_ls_tx (); open_drain_wired_and = 0 }
  in
  let fm =
    { Psim.prog = P1.i2c_ctl ~l:6 ~h:4 ~tsu:3 ~thold:6; own = P1.i2c_own; od = P1.i2c_od; cfg = 0; cfg2 = 0; p = 7
    ; contract = Lib.i2c_ctl ~l:6 ~h:4 ~tsu:3 ~thold:6; open_drain_wired_and = P1.i2c_own }
  in
  let i2c_host = [ 0xA0; 0x03; 0x11; 0x22; 0x33; 0xA1; 0x02 ] in
  let tgt ?dd () () = (Peers.i2c_target ~addr:0x50 ~read_data:[ 0xC3; 0x5A ] ?dd ()).drive in
  let no () = D.no_peer in
  [ { sname = "uart_tx_ok"; setup = D.uart_tx_setup (P1.uart_tx ~d:4); pkg = 0; tx_bytes = [ 0xA5; 0x3C; 0x00 ]
    ; peer = no; cycles = 4000; trace = Some ([ 0 ], [ "bytes", hex [ 0xA5; 0x3C; 0x00 ] ]) }
  ; { sname = "uart_tx_badstart"; setup = D.uart_tx_setup (P1.uart_tx_bad_start ~d:4); pkg = 0
    ; tx_bytes = [ 0xA5; 0x3C; 0x00 ]; peer = no; cycles = 4000; trace = None }
  ; { sname = "uart_rx_ok"; setup = D.rx_setup (); pkg = 1; tx_bytes = []
    ; peer = (fun () -> Peers.sender ~pin:1 ~bp ~frames:(frames bp) ~defect:No_defect); cycles = 60_000
    ; trace = Some ([], [ "pushes", hex rx_bytes ]) }
  ; { sname = "uart_rx_fast"; setup = D.rx_setup (); pkg = 1; tx_bytes = []
    ; peer = (fun () -> let bp = bp /. 1.08 in Peers.sender ~pin:1 ~bp ~frames:(frames bp) ~defect:No_defect)
    ; cycles = 60_000; trace = None }
  ; { sname = "spi_ctl_ok"; setup = D.ctl_setup; pkg = 2; tx_bytes = D.host_bytes
    ; peer = (fun () -> (Peers.spi_target ~cpol:false ~cpha:false ~tco:3 ~send:D.peer_bytes ()).drive); cycles = 6000
    ; trace = Some (spi_pins, [ "mosi", hex D.host_bytes; "miso", hex D.peer_bytes; "pushes", hex D.peer_bytes ]) }
  ; { sname = "spi_ctl_tco14"; setup = D.ctl_setup; pkg = 2; tx_bytes = D.host_bytes
    ; peer = (fun () -> (Peers.spi_target ~cpol:false ~cpha:false ~tco:14 ~send:D.peer_bytes ()).drive)
    ; cycles = 6000; trace = None }
  ; { sname = "spi_tgt_ok"; setup = D.tgt_setup; pkg = 3; tx_bytes = D.host_bytes; peer = (fun () -> (ctl ()).cdrive)
    ; cycles = (ctl ()).frames_end + 200
    ; trace = Some (spi_pins, [ "mosi", hex D.peer_bytes; "miso", hex D.host_bytes; "pushes", hex D.peer_bytes ]) }
  ; { sname = "spi_tgt_earlycs"; setup = D.tgt_setup; pkg = 3; tx_bytes = D.host_bytes
    ; peer = (fun () -> (ctl ~defect:(Peers.Early_rise (2, 9)) ()).cdrive); cycles = (ctl ()).frames_end + 200
    ; trace = None }
  ; { sname = "usb_two"; setup = usb_setup; pkg = 7; tx_bytes = [ 0xC3; 0; 0x4B; 3; 0x01; 0x02; 0x03 ]; peer = no
    ; cycles = 5000; trace = Some ([ 0; 1 ], [ "packets", "C3\n4B 01 02 03\n"; "pushes", hex [ 0; 0 ] ]) }
  ; { sname = "i2c_ctl_ok"; setup = fm; pkg = 4; tx_bytes = i2c_host; peer = tgt (); cycles = 12_000
    ; trace =
        Some
          ( [ Peers.i2c_scl; Peers.i2c_sda ]
          , [ "bus", "S\nA50W+\nW11+\nW22+\nW33+\nP\nS\nA50R+\nRC3+\nR5A-\nP\n"; "pushes", hex [ 0; 0xC3; 0x5A; 0 ] ] ) }
  ; { sname = "i2c_ctl_dd70"; setup = fm; pkg = 4; tx_bytes = i2c_host; peer = tgt ~dd:70 (); cycles = 12_000
    ; trace = None }
  ]
;;

let chip u index dir =
  let lib = List.map (Pemu_rtl_v1.Rom_lib.v2_inc5 ()) ~f:Pemu_monitor_v1.Compile.compile_exn in
  let k = List.hd_exn (D.calibrate ()) (* with the shipped units: the harness's time offset *) in
  (match (u : Mutate_v2.unit_) with
   | Lane_rtl -> Pemu_rtl_v1.Lane_rtl.hook := Some (fun ~sram i -> Mutate_v2.lane_rtl ~index ~sram i)
   | Mon_lane ->
     Pemu_monitor_v1.Mon_lane.hook
     := Some (fun ~slots ~pipe ~tables ~present ~fetch i -> Mutate_v2.mon_lane ~index ~slots ~pipe ~tables ~present ~fetch i)
   | Lane_spec -> failwith "chip: lane_spec mutants are not in the chip (Top_v1 instantiates Lane_rtl)");
  let first = ref None in
  List.iter (scenarios ()) ~f:(fun s ->
    let t0 = Time_ns.now () in
    let c =
      D.chip_run ~lib ~lane_pipe:true ~verdict_pipe:true ~param_windows:true ~k ~setup:s.setup ~pkg:s.pkg
        ~tx_bytes:s.tx_bytes ~peer:(s.peer ()) ~cycles:s.cycles ()
    in
    let r, pmi = E.psim_run ~clear_at:[] ~setup:s.setup ~tx_bytes:s.tx_bytes ~peer:s.peer ~cycles:s.cycles in
    let x = E.compare_runs ~setup:s.setup ~cycles:s.cycles c r pmi in
    let div = E.diverged x in
    if div && Option.is_none !first then first := Some s.sname;
    Option.iter s.trace ~f:(fun (pins, files) ->
      if not (List.is_empty pins)
      then (
        let pads = Array.init s.cycles ~f:(fun cy -> Option.value (Hashtbl.find c.pads (cy + c.off)) ~default:0xFF) in
        Psim.write_rle ~file:(dir ^/ s.sname ^ ".rle") ~pins pads);
      List.iter files ~f:(fun (suf, data) -> Out_channel.write_all (dir ^/ s.sname ^ ".exp_" ^ suf) ~data);
      Out_channel.write_all (dir ^/ s.sname ^ ".got_pushes") ~data:(hex c.rx));
    printf "%s %s wall=%.1f\n" s.sname
      (if div
       then
         sprintf "DIFF mon=%s pins=%s verdict=%b rx=%b"
           (Option.value_map x.mon_first ~default:"-" ~f:Int.to_string)
           (Option.value_map x.pins_first ~default:"-" ~f:Int.to_string)
           x.verdict_eq x.rx_eq
       else "same")
      (Time_ns.Span.to_sec (Time_ns.diff (Time_ns.now ()) t0)));
  printf "C3 %s\n" (match !first with Some n -> "KILLED " ^ n | None -> "SURVIVED")
;;

(* ---- contract mutants: oracle SV (Psim directed scenarios, golden = shipped contract) ---- *)
let sv_scenarios (p : Pemu_formal.Cmut.pkg) =
  let bp = D.uart_bp in
  let frames bp = Peers.frames_of ~bp ~st0:2000 [ 0x55; 0xA5; 0x00; 0xFF; 0x3C; 0x81; 0x7E; 0x01 ] ~gap:(fun b -> 3 + (b * 7 % 400)) in
  let sender ?(f = 1.0) defect () = let bp = bp /. f in Peers.sender ~pin:1 ~bp ~frames:(frames bp) ~defect in
  let ctl ?defect () =
    (Peers.spi_controller ~cpol:false ~cpha:false ~hp:40 ~setup:40 ~hold:40 ~gap:144 ~mdly:2 ~t0:300 ~bytes:D.peer_bytes ?defect ()).cdrive
  in
  let tgt ?miso_glitch ?glitch_len tco () =
    (Peers.spi_target ~cpol:false ~cpha:false ~tco ~send:D.peer_bytes ?miso_glitch ?glitch_len ()).drive
  in
  let usb_mut ~from ~to_ = List.map P1.usb_ls_tx ~f:(fun x -> if Pemu_spec_v1.Isa1.equal x from then to_ else x) in
  let no () = D.no_peer in
  (* (name, prog option, tx_bytes, peer, cycles) *)
  match p.pname with
  | "uart_tx" ->
    let s = D.uart_tx_setup (P1.uart_tx ~d:4) in
    [ "ok", s, [ 0xA5; 0x3C; 0x00 ], no, 4000
    ; "badstart", D.uart_tx_setup (P1.uart_tx_bad_start ~d:4), [ 0xA5; 0x3C; 0x00 ], no, 4000 ]
  | "uart_rx" ->
    let s = D.rx_setup () in
    [ "nominal", s, [], sender No_defect, 60_000; "fast8", s, [], sender ~f:1.08 No_defect, 60_000
    ; "slow8", s, [], sender ~f:0.92 No_defect, 60_000; "shortstop", s, [], sender (Short_stop 2), 60_000
    ; "glitch", s, [], sender (Glitch (3, 900, 60)), 60_000 ]
  | "spi_ctl" ->
    let s = D.ctl_setup in
    [ "tco3", s, D.host_bytes, tgt 3, 6000; "tco14", s, D.host_bytes, tgt 14, 6000
    ; "misoglitch", s, D.host_bytes, tgt ~miso_glitch:(3, 4) ~glitch_len:10 3, 6000 ]
  | "spi_tgt" ->
    let s = D.tgt_setup in
    let cy = (Peers.spi_controller ~cpol:false ~cpha:false ~hp:40 ~setup:40 ~hold:40 ~gap:144 ~mdly:2 ~t0:300 ~bytes:D.peer_bytes ()).frames_end + 200 in
    [ "ok", s, D.host_bytes, (fun () -> ctl ()), cy; "earlycs", s, D.host_bytes, (fun () -> ctl ~defect:(Early_rise (2, 9)) ()), cy
    ; "mosiatsample", s, D.host_bytes, (fun () -> ctl ~defect:(Mosi_at_sample (1, 3)) ()), cy
    ; "badidle", s, D.host_bytes, (fun () -> ctl ~defect:(Bad_idle 2) ()), cy; "fastpair", s, D.host_bytes, (fun () -> ctl ~defect:(Fast_pair (1, 5)) ()), cy ]
  | "usb" ->
    let s prog =
      { Psim.prog; own = P1.usb_own; od = 0; cfg = P1.usb_cfg; cfg2 = 0
      ; p = Pemu_rtl_v1.Rom_lib.usb_ls_p ~clock_hz:Pemu_rtl_v1.Rom_lib.v2_clock_hz; contract = p.contract
      ; open_drain_wired_and = 0 }
    in
    let two = [ 0xC3; 0; 0x4B; 3; 0x01; 0x02; 0x03 ] in
    [ "two", s P1.usb_ls_tx, two, no, 5000; "n9halt", s P1.usb_ls_tx, [ 0xC3; 9; 0x01 ], no, 3000
    ; "sync", s (usb_mut ~from:(Ldi (L Sr, 0x80)) ~to_:(Ldi (L Sr, 0x81))), two, no, 5000
    ; "nopush", s (usb_mut ~from:(Push R3) ~to_:Nop), two, no, 5000
    ; "status", s (usb_mut ~from:(Ldi (L R1, 0)) ~to_:(Ldi (L R1, 3))), two, no, 5000
    ; "sendc", s (usb_mut ~from:(Ser (Sendc R2)) ~to_:(Ser (Send R2))), two, no, 5000 ]
  | n -> failwithf "sv: no scenarios for %s" n ()
;;

let csv pname i =
  let module C = Pemu_formal.Cmut in
  let p = C.pkg_by pname in
  let m = C.mutant p.contract i in
  match C.invalid m with
  | Some why -> printf "SV INVALID %s\n" why
  | None ->
    let run contract (s : Psim.setup) tx peer cycles =
      Psim.firings (Psim.run ~tx_bytes:tx ~rx_pop_every:1_000_000_000 ~setup:{ s with contract } ~cycles ~peer:(peer ()) ())
    in
    let first = ref None in
    List.iter (sv_scenarios p) ~f:(fun (n, s, tx, peer, cycles) ->
      let g = run p.contract s tx peer cycles and x = run m s tx peer cycles in
      let same = [%equal: (int * Pemu_monitor_v1.Lang.role * int) list] g x in
      if (not same) && Option.is_none !first then first := Some n;
      let show l = String.concat ~sep:"," (List.map (List.take l 3) ~f:(fun (c, r, k) -> sprintf "%s%02X@%d" (match (r : Pemu_monitor_v1.Lang.role) with Fail -> "F" | Blame -> "B") k c)) in
      printf "%s golden [%s] mutant [%s] %s\n" n (show g) (show x) (if same then "same" else "DIFF"));
    printf "SV %s\n" (match !first with Some n -> "KILLED " ^ n | None -> "SURVIVED")
;;

(* ---- directed witness search (checks the formal cover did not decide, log/witness_v2.md) ----
   A witness only has to exist: a concrete run in which the target check is the monitor's first
   verdict. Blame checks: the shipped firmware with peer parameter sweeps. Fail checks: single-
   instruction firmware mutants with the nominal peer. A hit is confirmed on the v2 chip RTL
   (shipped library v2inc5, D.chip_run): the chip's first verdict has the target role and code. *)
module Isa1 = Pemu_spec_v1.Isa1

let fw_mutants prog =
  let a = Array.of_list prog in
  let rep i x = List.mapi prog ~f:(fun k y -> if k = i then x else y) in
  List.concat_mapi prog ~f:(fun i ins ->
    let alts : (string * Isa1.t) list =
      ("nop", Isa1.Nop)
      ::
      (match (ins : Isa1.t) with
       | Wait n -> [ "wait-1", Isa1.Wait (n - 1); "wait+1", Isa1.Wait (n + 1) ]
       | Out v -> List.init 8 ~f:(fun b -> sprintf "out^%d" b, Isa1.Out (v lxor (1 lsl b)))
       | Oen v -> List.init 8 ~f:(fun b -> sprintf "oen^%d" b, Isa1.Oen (v lxor (1 lsl b)))
       | Ldi (d, v) -> [ "ldi-1", Isa1.Ldi (d, v - 1); "ldi+1", Isa1.Ldi (d, v + 1) ]
       | Cmp (s, v) -> [ "cmp-1", Isa1.Cmp (s, v - 1); "cmp+1", Isa1.Cmp (s, v + 1) ]
       | Addi (r, v) -> [ "addi-1", Isa1.Addi (r, v - 1); "addi+1", Isa1.Addi (r, v + 1) ]
       | Br (c, t) -> [ "br^1", Isa1.Br (c lxor 1, t); "br-1", Isa1.Br (c, t - 1); "br+1", Isa1.Br (c, t + 1) ]
       | Jmp t -> [ "jmp-1", Isa1.Jmp (t - 1); "jmp+1", Isa1.Jmp (t + 1) ]
       | Djnz t -> [ "djnz-1", Isa1.Djnz (t - 1); "djnz+1", Isa1.Djnz (t + 1) ]
       | _ -> [])
    in
    ignore a;
    List.filter_map alts ~f:(fun (d, x) ->
      if Isa1.equal x ins then None
      else (
        let m = rep i x in
        match Isa1.assemble m with
        | _ -> Some (sprintf "%d:%s" i d, m)
        | exception _ -> None)))
;;

type wscen =
  { wname : string
  ; wsetup : Psim.setup
  ; wpkg : int
  ; wtx : int list
  ; wpeer : unit -> Psim.chip_view -> Psim.peer_drive
  ; wcycles : int
  ; wpop : int (* Psim host RX pop interval; < 1_000_000_000 = draining host (chip: rx_drain) *)
  }

let i2c_ctl_setup (l, h, tsu, thold) p =
  { Psim.prog = P1.i2c_ctl ~l ~h ~tsu ~thold; own = P1.i2c_own; od = P1.i2c_od; cfg = 0; cfg2 = 0; p
  ; contract = Lib.i2c_ctl ~l ~h ~tsu ~thold; open_drain_wired_and = P1.i2c_own }
;;

let i2c_tgt_setup =
  { Psim.prog = P1.i2c_tgt ~addr:0x50; own = P1.i2c_own; od = P1.i2c_od; cfg = 0; cfg2 = 0; p = 5
  ; contract = Lib.i2c_tgt ~h_min:19 ~l_min:22 ~hd:19; open_drain_wired_and = P1.i2c_own }
;;

let sm30 = { Peers.tlow = 141; thigh = 120; thd_sta = 120; tsu_sta = 141; tsu_sto = 120; tbuf = 141; dh = 1; su = 8 }
let tgt_txs = [ `W (0x50, [ 0x11; 0x22 ]), true; `R (0x50, 2), false; `W (0x52, [ 0xAA ]), false ]

let usb_setup prog =
  { Psim.prog; own = P1.usb_own; od = 0; cfg = P1.usb_cfg; cfg2 = 0
  ; p = Pemu_rtl_v1.Rom_lib.usb_ls_p ~clock_hz:Pemu_rtl_v1.Rom_lib.v2_clock_hz
  ; contract = Lib.usb_ls_tx (); open_drain_wired_and = 0 }
;;

(* peer-parameter scenario families per package (blame witnesses) and the nominal scenario
   (fail witnesses, with firmware mutants) *)
let wfamilies pkg =
  let i2c_host = [ 0xA0; 0x03; 0x11; 0x22; 0x33; 0xA1; 0x02 ] in
  let ictl name lhts p cycles =
    let s = i2c_ctl_setup lhts p in
    let mk n ?(dd = 8) ?(stretch = 0) ?(nack_write = -1) () =
      { wname = n; wsetup = s; wpkg = (if p = 7 then 4 else 5); wtx = i2c_host
      ; wpeer = (fun () -> (Peers.i2c_target ~addr:0x50 ~read_data:[ 0xC3; 0x5A ] ~dd ~stretch ~nack_write ()).drive)
      ; wcycles = cycles; wpop = 1_000_000_000 }
    in
    ignore name;
    mk "nominal" ()
    :: (List.init 60 ~f:(fun k -> let dd = 4 * k in mk (sprintf "dd%d" dd) ~dd ())
        @ List.init 20 ~f:(fun k -> let st = 50 * k in mk (sprintf "stretch%d" st) ~stretch:st ())
        @ [ mk "nackw1" ~nack_write:1 () ])
  in
  let itgt =
    let mk n t txs =
      { wname = n; wsetup = i2c_tgt_setup; wpkg = 6; wtx = [ 0x50; 0xA1; 0x36 ]
      ; wpeer = (fun () -> (Peers.i2c_controller ~t txs).cdrive); wcycles = 60_000; wpop = 1_000_000_000 }
    in
    let scale f v = Int.max 1 (Float.iround_nearest_exn (Float.of_int v *. f)) in
    let fields =
      [ "tlow", (fun t v -> { t with Peers.tlow = v }), sm30.tlow; "thigh", (fun t v -> { t with Peers.thigh = v }), sm30.thigh
      ; "thd_sta", (fun t v -> { t with Peers.thd_sta = v }), sm30.thd_sta; "tsu_sta", (fun t v -> { t with Peers.tsu_sta = v }), sm30.tsu_sta
      ; "tsu_sto", (fun t v -> { t with Peers.tsu_sto = v }), sm30.tsu_sto; "tbuf", (fun t v -> { t with Peers.tbuf = v }), sm30.tbuf
      ; "dh", (fun t v -> { t with Peers.dh = v }), 1; "su", (fun t v -> { t with Peers.su = v }), sm30.su ]
    in
    mk "nominal" sm30 tgt_txs
    :: List.concat_map fields ~f:(fun (fn, set, v0) ->
      List.map [ 0.1; 0.25; 0.4; 0.5; 0.6; 0.75; 0.9; 1.5; 2.0; 4.0; 10.0; 40.0; 100.0 ] ~f:(fun f ->
        let v = if v0 <= 1 then scale f 20 else scale f v0 in
        mk (sprintf "%s=%d" fn v) (set sm30 v) tgt_txs))
    @ [ mk "read1" sm30 [ `R (0x50, 1), false ]; mk "read3" sm30 [ `R (0x50, 3), false ]
      ; mk "write3" sm30 [ `W (0x50, [ 1; 2; 3 ]), false ]; mk "sr_write" sm30 [ `W (0x50, [ 1 ]), true; `W (0x50, [ 2 ]), false ]
      ; mk "other_addr" sm30 [ `W (0x51, [ 1 ]), false; `R (0x50, 1), false ] ]
    (* SDA pull overlays on the nominal controller: the environment pulls SDA low for [len]
       cycles from cycle [from] (B58: a whole read cell, low to low; B81: a short glitch in a
       high phase). The overlay counts peer calls, one per cycle. *)
    @ List.concat_map [ "pull", 261; "glitch", 30 ] ~f:(fun (nm, len) ->
      List.init 500 ~f:(fun i ->
        let from = 400 + (50 * i) in
        { (mk (sprintf "%s%d+%d" nm from len) sm30 tgt_txs) with
          wcycles = 30_000
        ; wpeer =
            (fun () ->
              let d = (Peers.i2c_controller ~t:sm30 tgt_txs).cdrive in
              let n = ref 0 in
              fun v ->
                let x : Psim.peer_drive = d v in
                incr n;
                if !n > from && !n <= from + len then { x with drive_oe = x.drive_oe lor (1 lsl Peers.i2c_sda) } else x)
        }))
    (* fail base: a write long enough that the push window (4095 steps) can expire without a
       START/STOP resetting the frame guard *)
    @ [ { (mk "long16" sm30 [ `W (0x50, List.init 16 ~f:(fun k -> 0x10 + k)), false ]) with wpop = 50 } ]
  in
  match pkg with
  | "i2c_ctl_fm" -> ictl "fm" (6, 4, 3, 6) 7 14_000
  | "i2c_ctl_sm" -> ictl "sm" (5, 5, 5, 5) 29 50_000
  | "i2c_tgt" -> itgt
  | "usb" ->
    let two = [ 0xC3; 0; 0x4B; 3; 0x01; 0x02; 0x03 ] in
    [ { wname = "nominal"; wsetup = usb_setup P1.usb_ls_tx; wpkg = 7; wtx = two; wpeer = (fun () -> D.no_peer); wcycles = 5000; wpop = 1_000_000_000 }
    ; { wname = "n9"; wsetup = usb_setup P1.usb_ls_tx; wpkg = 7; wtx = [ 0xC3; 9; 0x01 ]; wpeer = (fun () -> D.no_peer); wcycles = 3000; wpop = 1_000_000_000 } ]
    (* fail bases with long all-ones payloads (bit stuffing lengthens the body past data_max) *)
    @ List.map [ 9; 10; 12; 15 ] ~f:(fun n ->
      { wname = sprintf "long%dff" n; wsetup = usb_setup P1.usb_ls_tx; wpkg = 7; wtx = 0xC3 :: n :: List.init n ~f:(fun _ -> 0xFF)
      ; wpeer = (fun () -> D.no_peer); wcycles = 6000; wpop = 1_000_000_000 })
  | p -> failwithf "wsearch: no families for %s" p ()
;;

let first_verdict r = List.hd (Psim.firings r)

let wsearch pkg role code =
  let target (r, c) = Pemu_monitor_v1.Lang.equal_role r role && c = code in
  let fams = wfamilies pkg in
  let runs =
    match (role : Pemu_monitor_v1.Lang.role) with
    | Blame -> List.map fams ~f:(fun s -> s.wname, s)
    | Fail ->
      let base = List.filter fams ~f:(fun s ->
        String.equal s.wname "nominal" || String.equal s.wname "n9" || String.is_prefix s.wname ~prefix:"long") in
      List.concat_map base ~f:(fun s ->
        List.map (fw_mutants s.wsetup.prog) ~f:(fun (d, prog) -> s.wname ^ "/fw " ^ d, { s with wsetup = { s.wsetup with prog } }))
  in
  let hit =
    List.find_map runs ~f:(fun (d, s) ->
      let r = Psim.run ~tx_bytes:s.wtx ~rx_pop_every:s.wpop ~setup:s.wsetup ~cycles:s.wcycles ~peer:(s.wpeer ()) () in
      match first_verdict r with
      | Some (cy, ro, c) when target (ro, c) -> Some (d, s, cy)
      | _ -> None)
  in
  match hit with
  | None -> printf "WSEARCH %s %s%02X NONE (%d runs)\n" pkg (match role with Fail -> "F" | Blame -> "B") code (List.length runs)
  | Some (d, s, cy) ->
    (* confirm on the v2 chip RTL *)
    let lib = List.map (Pemu_rtl_v1.Rom_lib.v2_inc5 ()) ~f:Pemu_monitor_v1.Compile.compile_exn in
    let k = List.hd_exn (D.calibrate ()) in
    let c =
      D.chip_run ~lib ~lane_pipe:true ~verdict_pipe:true ~param_windows:true ~stream:true ~rx_drain:(s.wpop < 1_000_000_000) ~k ~setup:s.wsetup ~pkg:s.wpkg ~tx_bytes:s.wtx
        ~peer:(s.wpeer ()) ~cycles:s.wcycles ()
    in
    let mine, other = match role with Fail -> c.first_fail, c.first_blame | Blame -> c.first_blame, c.first_fail in
    let ok =
      match mine, other with
      | Some (cc, t), None -> cc = code && true && t >= 0
      | Some (cc, t), Some (_, t2) -> cc = code && t <= t2
      | None, _ -> false
    in
    printf "WSEARCH %s %s%02X FOUND [%s] psim first verdict at %d; chip %s (first fail %s, first blame %s)\n" pkg
      (match role with Fail -> "F" | Blame -> "B") code d cy (if ok then "CONFIRMED" else "NOT CONFIRMED")
      (Option.value_map c.first_fail ~default:"-" ~f:(fun (cc, t) -> sprintf "%02X@%d" cc t))
      (Option.value_map c.first_blame ~default:"-" ~f:(fun (cc, t) -> sprintf "%02X@%d" cc t))
;;

(* ---- witness oracle W for contract mutants (log/witness_v2.md section 5) ----
   Every witness of a package is a monitor-input trace in which the shipped contract's first
   verdict is the witnessed check. A contract mutant is killed when the reference interpreter
   (Interp) gives a different firing list (frame, role, code) on some witness trace. Formal
   witnesses: the traces are parsed from the replay files of the cover run (dbg_ ports; the
   replay has already checked that Interp agrees with the harness). Directed witnesses: the
   wsearch scenario re-run in Psim under both contracts. *)
let witness_dir = "formal/work/mut_v2/witness3"
let wsearch_dir = "formal/work/mut_v2/wsearch"

let parse_replay file : Pemu_monitor_v1.Interp.inputs list =
  let lines = In_channel.read_lines file in
  let words l = String.split l ~on:' ' |> List.filter ~f:(fun x -> not (String.is_empty x)) in
  let hdr = List.find_exn lines ~f:(String.is_prefix ~prefix:"# frame ") in
  let cols = words (String.drop_prefix hdr 2) in
  let idx n = fst (List.findi_exn cols ~f:(fun _ c -> String.equal c n)) in
  let iv x = if String.equal x "-" then 0 else Int.of_string x in
  List.filter_map lines ~f:(fun l ->
    let t = words l in
    if String.is_prefix l ~prefix:"#" || List.length t <> List.length cols
    then None
    else (
      let g n = iv (List.nth_exn t (idx n)) in
      let b n = g n = 1 in
      Some
        { Pemu_monitor_v1.Interp.rst_sync_n = b "dbg_m_rst"; running = b "dbg_m_running"; tick = b "dbg_tick"; ui_in = 0
        ; uio_in = g "dbg_uio_in"; uo_out = 0; uio_out = g "dbg_m_out"; uio_oe = g "dbg_m_oe"; pop_ev = b "dbg_m_pop"
        ; pop_data = g "dbg_m_popd"; push_ev = b "dbg_m_push"; push_data = g "dbg_m_pushd" }))
;;

let trace_firings contract mis =
  let module I = Pemu_monitor_v1.Interp in
  let t = I.create contract in
  List.concat_mapi mis ~f:(fun k mi -> List.map (I.step t mi) ~f:(fun (r, c) -> k, r, c))
;;

(* directed witnesses of a package: (check name, scenario) from the wsearch records *)
let directed_witnesses pkg =
  match Stdlib.Sys.readdir wsearch_dir with
  | exception _ -> []
  | files ->
    Array.to_list files
    |> List.sort ~compare:String.compare
    |> List.filter_map ~f:(fun f ->
      if not (String.is_prefix f ~prefix:(pkg ^ "_") && String.is_suffix f ~suffix:".txt")
      then None
      else (
        let last = List.last (In_channel.read_lines (wsearch_dir ^/ f)) in
        match last with
        | Some l when String.is_substring l ~substring:"chip CONFIRMED" ->
          let desc = List.nth_exn (String.split_on_chars l ~on:[ '['; ']' ]) 1 in
          let base, fw = match String.lsplit2 desc ~on:'/' with Some (b, m) -> b, Some (String.chop_prefix_exn m ~prefix:"fw ") | None -> desc, None in
          let s = List.find_exn (wfamilies pkg) ~f:(fun s -> String.equal s.wname base) in
          let s =
            match fw with
            | None -> s
            | Some d -> { s with wsetup = { s.wsetup with prog = List.Assoc.find_exn (fw_mutants s.wsetup.prog) ~equal:String.equal d } }
          in
          Some (String.chop_suffix_exn f ~suffix:".txt", s)
        | _ -> None))
;;

(* check code(s) of the statement holding contract-mutation site i (same pre-order numbering as
   Cmut.traverse), and how many statements of the contract carry each code *)
let site_checks (c : Pemu_monitor_v1.Lang.t) i =
  let module C = Pemu_formal.Cmut in
  let module Lang = Pemu_monitor_v1.Lang in
  let n = ref 0 and found = ref None in
  let own base (st : Lang.stmt) =
    let w (x : Lang.window) = x.timeout :: Option.to_list x.early in
    (match st with
     | Await { w = x; _ } | Hold_until { w = x; _ } | Take { w = Some x; _ } -> w x
     | Hold_for { check; _ } | Expect { check; _ } | Match { check } -> [ check ]
     | Raise ch -> [ ch ]
     | _ -> [])
    |> List.map ~f:(fun ((r, k) : Lang.check) -> r, base + k)
  in
  let rec go wn base (l : Lang.stmt list) =
    List.iter l ~f:(fun (st : Lang.stmt) ->
      let k = List.length (C.ops_of st) in
      if i >= !n && i < !n + k then found := Some (wn, C.stmt_kind st, own base st);
      n := !n + k;
      match st with
      | If (_, a, b) -> go wn base a; go wn base b
      | Loop b | Repeat (_, b) -> go wn base b
      | Guard { body; handler; _ } -> go wn base body; go wn base handler
      | _ -> ())
  in
  List.iter c.watchers ~f:(fun wt -> go wt.wname wt.base wt.body);
  let all = Pemu_formal.Witness_v2.checks c in
  match !found with
  | None -> "SITE none"
  | Some (wn, sk, chs) ->
    sprintf "SITE %s.%s %s" wn sk
      (String.concat ~sep:" "
         (List.map chs ~f:(fun ((r, k) as ch) ->
            sprintf "%s%02X(shared by %d)" (match (r : Lang.role) with Fail -> "F" | Blame -> "B") k
              (List.count all ~f:(fun (_, _, x) -> [%equal: Lang.role * int] x ch)))))
;;

let wsv pname i =
  let module C = Pemu_formal.Cmut in
  let p = C.pkg_by pname in
  let m = C.mutant p.contract i in
  match C.invalid m with
  | Some why -> printf "W INVALID %s\n" why
  | None ->
    let show l =
      String.concat ~sep:","
        (List.map (List.take l 3) ~f:(fun (c, r, k) ->
           sprintf "%s%02X@%d" (match (r : Pemu_monitor_v1.Lang.role) with Fail -> "F" | Blame -> "B") k c))
    in
    let killed = ref [] in
    let report name g x =
      let same = [%equal: (int * Pemu_monitor_v1.Lang.role * int) list] g x in
      if not same then killed := name :: !killed;
      printf "%s golden [%s] mutant [%s] %s\n" name (show g) (show x) (if same then "same" else "DIFF")
    in
    let files =
      Stdlib.Sys.readdir witness_dir |> Array.to_list |> List.sort ~compare:String.compare
      |> List.filter ~f:(fun f -> String.is_prefix f ~prefix:(sprintf "w2_%s_" pname) && String.is_suffix f ~suffix:".replay.txt")
    in
    List.iter files ~f:(fun f ->
      let mis = parse_replay (witness_dir ^/ f) in
      report (String.chop_suffix_exn f ~suffix:".replay.txt") (trace_firings p.contract mis) (trace_firings m mis));
    let dws = directed_witnesses pname in
    List.iter dws ~f:(fun (n, s) ->
      let run contract =
        Psim.firings (Psim.run ~tx_bytes:s.wtx ~rx_pop_every:s.wpop ~setup:{ s.wsetup with contract } ~cycles:s.wcycles ~peer:(s.wpeer ()) ())
      in
      report ("directed " ^ n) (run p.contract) (run m));
    printf "W traces %d directed %d\n" (List.length files) (List.length dws);
    printf "W %s\n" (match List.rev !killed with [] -> "SURVIVED" | n :: _ -> "KILLED " ^ n)
;;

let () =
  match Sys.get_argv () |> Array.to_list |> List.tl_exn with
  | [ "wsv"; pkg; i ] -> wsv pkg (Int.of_string i)
  | [ "wsite"; pkg; i ] -> print_endline (site_checks (Pemu_formal.Cmut.pkg_by pkg).contract (Int.of_string i))
  | [ "wins"; pkg; i ] ->
    (* firmware instruction i (and neighbours) of the package's nominal scenario *)
    let s = List.hd_exn (wfamilies pkg) in
    let i = Int.of_string i in
    List.iteri s.wsetup.prog ~f:(fun k x ->
      if abs (k - i) <= 2 then printf "%s %d %s%s\n" pkg k (Sexp.to_string (Isa1.sexp_of_t x)) (if k = i then "  <--" else ""))
  | [ "wbase"; pkg ] ->
    (* shipped firmware on every family scenario: first verdicts (Psim; chip for the long bases) *)
    List.iter (wfamilies pkg) ~f:(fun s ->
      if not (String.is_prefix s.wname ~prefix:"pull" || String.is_prefix s.wname ~prefix:"glitch")
      then (
        let r = Psim.run ~tx_bytes:s.wtx ~rx_pop_every:s.wpop ~setup:s.wsetup ~cycles:s.wcycles ~peer:(s.wpeer ()) () in
        let chip =
          if String.is_prefix s.wname ~prefix:"long" || String.equal s.wname "nominal"
          then (
            let lib = List.map (Pemu_rtl_v1.Rom_lib.v2_inc5 ()) ~f:Pemu_monitor_v1.Compile.compile_exn in
            let k = List.hd_exn (D.calibrate ()) in
            let c = D.chip_run ~lib ~lane_pipe:true ~verdict_pipe:true ~param_windows:true ~stream:true ~rx_drain:(s.wpop < 1_000_000_000) ~k ~setup:s.wsetup
                ~pkg:s.wpkg ~tx_bytes:s.wtx ~peer:(s.wpeer ()) ~cycles:s.wcycles () in
            let f = Option.value_map ~default:"-" ~f:(fun (cc, t) -> sprintf "%02X@%d" cc t) in
            sprintf " chip fail %s blame %s rx %d" (f c.first_fail) (f c.first_blame) (List.length c.rx))
          else ""
        in
        let fs = Psim.firings r in
        printf "WBASE %s %s psim [%s] pushes %d%s\n" pkg s.wname
          (String.concat ~sep:"," (List.map (List.take fs 3) ~f:(fun (c, r, k) ->
             sprintf "%s%02X@%d" (match (r : Pemu_monitor_v1.Lang.role) with Fail -> "F" | Blame -> "B") k c)))
          (List.length (Psim.pushes r)) chip))
  | [ "wsearch"; pkg; rc ] ->
    let role : Pemu_monitor_v1.Lang.role = if Char.equal rc.[0] 'F' then Fail else Blame in
    wsearch pkg role (Int.of_string ("0x" ^ String.drop_prefix rc 1))
  | [ "wlist" ] ->
    (* check-witness harnesses (Pemu_formal.Witness_v2): name, package, role, code, statements *)
    let module W = Pemu_formal.Witness_v2 in
    W.check_against_rom ();
    List.iter (W.packages ()) ~f:(fun p ->
      let cs = W.checks p.contract in
      List.iter (W.distinct p.contract) ~f:(fun ch ->
        let sites = List.filter cs ~f:(fun (_, _, c) -> Poly.equal c ch) in
        printf "%s %s %s %02X %s\n" (W.name p ch) p.pname (W.role_char (fst ch)) (snd ch)
          (String.concat ~sep:"," (List.map sites ~f:(fun (w, s, _) -> w ^ "." ^ s)))))
  | [ "wemit"; nm; dir ] ->
    let c = Pemu_formal.Witness_v2.find nm in
    Hardcaml.Rtl.output ~output_mode:(To_file (dir ^/ nm ^ ".v")) Verilog c;
    printf "W dprove %s\n" nm
  | [ "ccov"; pname ] ->
    (* contract check coverage: every check (role, code) of the shipped contract, and whether a
       directed SV scenario (Psim, shipped contract) fires it *)
    let module C = Pemu_formal.Cmut in
    let module Lang = Pemu_monitor_v1.Lang in
    let p = C.pkg_by pname in
    let checks = ref [] in
    let base = ref 0 in
    (* firings report watcher base + local code *)
    let add w s ((r, k) : Lang.check) = checks := (w, s, (r, !base + k)) :: !checks in
    let win w s (x : Lang.window) = add w s x.timeout; Option.iter x.early ~f:(add w (s ^ ".early")) in
    let rec go w (l : Lang.stmt list) =
      List.iter l ~f:(fun (st : Lang.stmt) ->
        let k = C.stmt_kind st in
        match st with
        | Await { w = x; _ } | Hold_until { w = x; _ } | Take { w = Some x; _ } -> win w k x
        | Hold_for { check; _ } | Expect { check; _ } | Match { check } -> add w k check
        | Raise c -> add w k c
        | If (_, a, b) -> go w a; go w b
        | Loop b | Repeat (_, b) -> go w b
        | Guard { body; handler; _ } -> go w body; go w handler
        | _ -> ())
    in
    List.iter p.contract.watchers ~f:(fun wt -> base := wt.base; go wt.wname wt.body);
    let fired = Hash_set.Poly.create () in
    List.iter (sv_scenarios p) ~f:(fun (n, s, tx, peer, cycles) ->
      let f =
        Psim.firings (Psim.run ~tx_bytes:tx ~rx_pop_every:1_000_000_000 ~setup:{ s with contract = p.contract } ~cycles ~peer:(peer ()) ())
      in
      List.iter f ~f:(fun (_, r, k) -> Hash_set.add fired (r, k));
      printf "scenario %s: %s\n" n
        (String.concat ~sep:"," (List.map f ~f:(fun (_, r, k) -> sprintf "%s%02X" (match (r : Lang.role) with Fail -> "F" | Blame -> "B") k))));
    let all = List.rev !checks in
    let distinct = List.dedup_and_sort (List.map all ~f:(fun (_, _, c) -> c)) ~compare:[%compare: Lang.role * int] in
    List.iter distinct ~f:(fun ((r, k) as c) ->
      let sites = List.filter all ~f:(fun (_, _, c') -> [%equal: Lang.role * int] c c') in
      printf "check %s%02X (%d statements: %s) %s\n" (match r with Fail -> "F" | Blame -> "B") k (List.length sites)
        (String.concat ~sep:"," (List.map sites ~f:(fun (w, s, _) -> w ^ "." ^ s)))
        (if Hash_set.mem fired c then "FIRED" else "never fired"));
    printf "coverage %s: %d/%d distinct checks fired by the directed scenarios\n" pname
      (List.count distinct ~f:(Hash_set.mem fired)) (List.length distinct)
  | "eqemit" :: i :: dir :: rest ->
    (* survivor triage: monitor-lane mutant vs the shipped lane (Mut_v2_harness.eq_mon);
       optional output group (fire | overrun | busy | pcs) *)
    let index = Int.of_string i in
    let group = Option.value (List.hd rest) ~default:"all" in
    (* optional 4th argument t6: with the tick-spacing assumption (running steps >= 6 apart) *)
    let t6 = match rest with [ _; "t6" ] -> true | _ -> false in
    let base = (if String.equal group "all" && not t6 then "eq_mon" else "eq_mon_") ^ (if t6 then "t6_" else "") ^ (if String.equal group "all" && not t6 then "" else group) in
    let name = Mut_v2_harness.name Mon_lane index base in
    let c = Mut_v2_harness.eq_mon ~group ~spacing:(if t6 then 6 else 0) ~index ~name () in
    Hardcaml.Rtl.output ~output_mode:(To_file (dir ^/ name ^ ".v")) Verilog c;
    printf "EQ dprove %s\n" name
  | [ "clist"; p ] ->
    let module C = Pemu_formal.Cmut in
    let pk = C.pkg_by p in
    List.iter (C.sites pk.contract) ~f:(fun s ->
      let valid = Option.is_none (C.invalid (C.mutant pk.contract s.index)) in
      printf "%d,%s,%s,%s,%s\n" s.index (C.op_to_string s.op) s.watcher s.stmt (if valid then "valid" else "invalid"))
  | [ "csv"; p; i ] -> csv p (Int.of_string i)
  | [ "cemit"; p; i; dir ] ->
    let module C = Pemu_formal.Cmut in
    let pk = C.pkg_by p and i = Int.of_string i in
    (match C.invalid (C.mutant pk.contract i) with
     | Some why -> printf "INVALID %s\n" why
     | None ->
       List.iter (C.harnesses pk i) ~f:(fun (o, name, build) ->
         let c = build () in
         Hardcaml.Rtl.output ~output_mode:(To_file (dir ^/ name ^ ".v")) Verilog c;
         printf "%s dprove %s\n" o name))
  | [ "chip"; u; i; dir ] ->
    let index = if String.equal i "id" then -1 else Int.of_string i in
    (try chip (Mutate_v2.unit_of_string u) index dir with
     | e -> printf "C3 ERROR %s\n" (String.prefix (Exn.to_string e) 300))
  | [ "list"; u ] ->
    List.iter (Mutate_v2.sites (Mutate_v2.unit_of_string u)) ~f:(fun (s : Mutate.site) ->
      printf "%d,%s,%s\n" s.index (Mutate.op_to_string s.op) s.desc)
  | [ "emit"; u; i; dir ] ->
    (* formal oracle harnesses of one mutant: <dir>/<name>.v; prints "<oracle> <engine> <name>" *)
    let u = Mutate_v2.unit_of_string u
    and index = if String.equal i "id" then -1 else Int.of_string i in
    List.iter (Mut_v2_harness.oracles u) ~f:(fun o ->
      let c = Mut_v2_harness.build u index o in
      Hardcaml.Rtl.output ~output_mode:(To_file (dir ^/ Hardcaml.Circuit.name c ^ ".v")) Verilog c;
      printf "%s %s %s\n" o.oracle o.engine (Hardcaml.Circuit.name c))
  | "sim" :: u :: i :: rest ->
    let index = if String.equal i "id" then -1 else Int.of_string i in
    (try sim (Mutate_v2.unit_of_string u) index (Option.map (List.hd rest) ~f:Int.of_string) with
     | e -> printf "ERROR %s\n" (String.prefix (Exn.to_string e) 300))
  | _ -> failwith "usage: mutants_v2.exe (list UNIT | sim UNIT INDEX [N])"
;;
