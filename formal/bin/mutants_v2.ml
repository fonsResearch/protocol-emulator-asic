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

let () =
  match Sys.get_argv () |> Array.to_list |> List.tl_exn with
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
