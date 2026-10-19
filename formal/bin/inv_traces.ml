(* Input traces for invariant mining and bounded checks on the I2C and USB A2 harnesses (plan step 7, user decision
   2026-10-19: invariant mining + k-induction). Drives the debug build of a harness in
   cyclesim with the Psim I2C peers under randomised timing, tick pattern, host traffic,
   reset/run drops and pad glitches, and records the harness inputs of every cycle plus the
   harness output [bad]. The traces are replayed on the AIGER model by formal/inv/aigsim, so
   the mined candidates refer to exactly the model that is proved; [bad] cross-checks the AIG
   simulator against the Hardcaml semantics. Nothing here is trusted by the final proof.

   usage: inv_traces.exe <harness> <out file> <traces> <cycles per trace> <seed>
   Output (binary): per trace, a 4-byte little-endian cycle count, then 3 bytes per cycle:
   flags (bit 0 rst_sync_n, 1 run, 2 tick, 3 tx_push, 4 rx_pop, 5 clear_fault, 6 bad),
   uio_in, tx_wdata. *)
open! Core
open Hardcaml
open Pemu_formal
module Peers = Pemu_protocols_v1.Peers
module Psim = Pemu_protocols_v1.Psim

let () =
  let argv = Sys.get_argv () in
  let name = argv.(1)
  and file = argv.(2)
  and ntr = Int.of_string argv.(3)
  and ncy = Int.of_string argv.(4)
  and seed = Int.of_string argv.(5) in
  let is_ctl = String.is_substring name ~substring:"_ctl_" in
  (* USB-LS TX harnesses (names containing _usb_): no peer; the host pushes random packets (PID, N, N bytes) *)
  let is_usb = String.is_substring name ~substring:"_usb_" in
  (* INV_CLEAN=1: legal traffic only (peer at or above the UM10204 minima, prescaler ticks, no
     glitches, no pad noise, no reset/run drops); used to check that environment assumptions
     do not exclude legal behaviour *)
  let clean = Option.is_some (Sys.getenv "INV_CLEAN") in
  let circuit = Registry.find ~debug:true name in
  let oc = Out_channel.create file in
  let rng = Random.State.make [| seed |] in
  let r n = Random.State.int rng n in
  let chance n = r n = 0 in
  let w32 v = Out_channel.output_string oc (String.init 4 ~f:(fun i -> Char.of_int_exn ((v lsr (8 * i)) land 0xFF))) in
  let bad_total = ref 0 in
  let status_hist = Array.create ~len:256 0 (* USB: values pushed to the host (status bytes) *) in
  for _tr = 1 to ntr do
    let sim = Cyclesim.create circuit in
    let ip n = Cyclesim.in_port sim n in
    let op n = Cyclesim.out_port ~clock_edge:Before sim n in
    let set n v = let p = ip n in p := Bits.of_int ~width:(Bits.width !p) v in
    (* tick pattern: prescaler period, with optional random jitter or fully random ticks *)
    let p = if is_ctl then 1 + r 15 else if chance 3 then 1 + r 7 else 3 in
    let tick_mode = if clean then 0 else r 4 (* 0,1: prescaler; 2: prescaler with jitter; 3: random *) in
    let tick_q = 1 + r 4 in
    let scale = p + 1 in
    (* peer *)
    let drive =
      if is_usb
      then None
      else if is_ctl
      then Some (
        let dd = 1 + r (Int.max 1 (scale * 5)) in
        let stretch = if chance 2 then 0 else r (scale * 30) in
        let nack_write = if chance 3 then r 4 else -1 in
        let read_data = List.init 4 ~f:(fun _ -> r 256) in
        (Peers.i2c_target ~addr:0x50 ~read_data ~dd ~nack_write ~stretch ()).drive)
      else Some (
        (* controller peer: UM10204 Fm/Sm minima scaled to the step length, sometimes faster
           than the contract allows (assumption violations end the useful part of a trace) *)
        let base = if String.is_substring name ~substring:"_sm_" then Peers.i2c_sm else Peers.i2c_fm in
        let num = if chance 6 && not clean then 2 + r 2 else 4 + r 8 and den = 4 in
        let sc x = Int.max 2 (x * num * scale / (den * 4)) in
        let t =
          { Peers.tlow = sc base.tlow; thigh = sc base.thigh; thd_sta = sc base.thd_sta
          ; tsu_sta = sc base.tsu_sta; tsu_sto = sc base.tsu_sto; tbuf = sc base.tbuf
          ; dh = 1 + r 3; su = sc base.su }
        in
        let addr () = if chance 3 then 0x50 + 1 + r 3 else 0x50 in
        let txs =
          List.init (2 + r 5) ~f:(fun _ ->
            (if chance 2 then `W (addr (), List.init (1 + r 3) ~f:(fun _ -> r 256)) else `R (addr (), 1 + r 3)),
            chance 3)
        in
        (Peers.i2c_controller ~t0:(r 600) ~t txs).cdrive)
    in
    (* host TX bytes *)
    let host =
      if is_usb
      then
        List.concat
          (List.init (2 + r 6) ~f:(fun _ ->
             let n = if (not clean) && chance 15 then 9 + r 247 else r 9 in
             r 256 :: n :: List.init (Int.min n 8) ~f:(fun _ -> r 256)))
      else if is_ctl
      then
        List.concat
          (List.init (2 + r 5) ~f:(fun _ ->
             let a = if chance 3 then 0x50 + 1 + r 3 else 0x50 in
             let rw = r 2 and n = 1 + r 3 in
             let sr = if chance 3 then 0x80 else 0 in
             let hdr = [ (a lsl 1) lor rw; n lor sr ] in
             if rw = 0 then hdr @ List.init n ~f:(fun _ -> r 256) else hdr))
      else (if chance 8 then 0x51 else 0x50) :: List.init 8 ~f:(fun _ -> r 256)
    in
    let host = Queue.of_list host in
    let gap = 2 + r 60 in
    let rst_at = r 3 and run_at = if chance 2 then 0 else r 12 in
    let glitch = if chance 4 then 2000 + r 50000 else 0 in
    let cnt = ref 0 and prev_out = ref 0 and prev_oe = ref 0 and prev_pad = ref 0xFF in
    w32 ncy;
    let buf = Bytes.create (3 * ncy) in
    let first_push = (not is_ctl) || r 3 = 0 in
    let verbose = Option.is_some (Sys.getenv "INV_VERBOSE") in
    let first_blame = ref None in
    for c = 0 to ncy - 1 do
      let rst = if c <= rst_at || ((not clean) && chance 40_000) then 0 else 1 in
      let run = if c < run_at || ((not clean) && chance 30_000) then 0 else 1 in
      let tick =
        match tick_mode with
        | 0 | 1 -> !cnt = p
        | 2 -> !cnt >= p && not (chance 3)
        | _ -> chance tick_q
      in
      cnt := if rst = 1 && run = 1 then (if tick then 0 else !cnt + 1) else 0;
      let env =
        match drive with
        | None -> 0xFF
        | Some drive ->
          let pd = drive { Psim.cycle = c; out = !prev_out; oe = !prev_oe; pad = !prev_pad } in
          0xFF land lnot (pd.drive_oe land lnot pd.drive_val)
      in
      let env = if glitch > 0 && (not clean) && chance glitch then env lxor (1 lsl (2 + r 2)) else env in
      let env = if chance 16 && not clean then env lxor (r 256 land 0xF3) else env in
      let push =
        (* the first push lands in the first cycle after reset release (a push under reset is
           lost and would violate the target's config-byte host assumption) *)
        (not (Queue.is_empty host))
        && ((c = rst_at + 1 && first_push) || (c > rst_at + 1 && c % gap = 0 && not (chance 20)))
      in
      let wdata = if push then Queue.dequeue_exn host else r 256 in
      let rx_pop = if chance 10 then 0 else 1 in
      let clear = if chance 20_000 then 1 else 0 in
      set "rst_sync_n" rst; set "run" run; set "tick" (Bool.to_int tick); set "uio_in" env;
      set "tx_push" (Bool.to_int push); set "tx_wdata" wdata; set "rx_pop" rx_pop; set "clear_fault" clear;
      Cyclesim.cycle sim;
      let v n = Bits.to_int !(op n) in
      let bad = v "bad" in
      bad_total := !bad_total + bad;
      if is_usb && rst = 1 && v "dbg_m_push" = 1
      then status_hist.(v "dbg_m_pushd") <- status_hist.(v "dbg_m_pushd") + 1;
      if verbose && Option.is_none !first_blame && v "dbg_fire" land v "dbg_role" <> 0 && rst = 1 then
        first_blame := Some (c, v "dbg_pc", v "dbg_fire" land v "dbg_role");
      prev_out := v "dbg_m_out"; prev_oe := v "dbg_m_oe"; prev_pad := v "dbg_uio_in";
      let flags =
        rst lor (run lsl 1) lor (Bool.to_int tick lsl 2) lor (Bool.to_int push lsl 3) lor (rx_pop lsl 4)
        lor (clear lsl 5) lor (bad lsl 6)
      in
      Bytes.set buf (3 * c) (Char.of_int_exn flags);
      Bytes.set buf ((3 * c) + 1) (Char.of_int_exn env);
      Bytes.set buf ((3 * c) + 2) (Char.of_int_exn wdata)
    done;
    if verbose then (
      match !first_blame with
      | None -> printf "trace P=%d mode=%d: no blame\n" p tick_mode
      | Some (c, pc, u) -> printf "trace P=%d mode=%d: first blame cycle %d lane pc %d units 0x%02x\n" p tick_mode c pc u);
    Out_channel.output_bytes oc buf
  done;
  Out_channel.close oc;
  printf "%s: %d traces x %d cycles, bad cycles %d\n" name ntr ncy !bad_total;
  if is_usb
  then
    Array.iteri status_hist ~f:(fun i n -> if n > 0 then printf "  pushed 0x%02x: %d\n" i n)
;;
