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
   ready for every frame, SPI target).
   [i2c_env (gap, scl, sda)] (I2C target, user decision 2026-10-19 on D12: an environment
   assumption that the chip does NOT monitor, listed with the physical assumptions in
   doc/protocols/i2c_v1.md). Both parts constrain only what the environment drives (its own
   input bits; 1 = released), never the wired-AND bus level, so a chip pull can never raise
   them (D7 pattern). A-gap: changes of the environment's SDA drive (synchronised as the pads,
   sampled at lane steps) while the bus SCL is high in this step and the previous step are at
   least [gap] steps apart. A-idle: the environment releases SCL and SDA in every cycle in which
   the lane is running and has not yet popped since its last restart (the pop cycle included);
   a halted or disabled lane puts no constraint on the bus.
   [od_wired] (I2C): for these pins the pad is the wired-AND of the free environment input and
   the lane's own pull (uio_oe and not uio_out, owned pins) in the same cycle, as on an
   open-drain bus in silicon (the pad follows the output flop within the cycle; the
   synchronisers sample it at the next edge). Without it the environment could show a line
   high while the lane pulls it. *)
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
  | Push_data of int (* a push event carrying this byte *)

type io =
  { clock : Signal.t
  ; rst_in : Signal.t
  ; tick : Signal.t
  ; run : Signal.t
  ; uio_in : Signal.t
  ; tx_push : Signal.t
  ; tx_wdata : Signal.t
  ; rx_pop : Signal.t
  ; clear_fault : Signal.t
  }

let free_io () =
  { clock = input "clock" 1; rst_in = input "rst_sync_n" 1; tick = input "tick" 1; run = input "run" 1
  ; uio_in = input "uio_in" 8; tx_push = input "tx_push" 1; tx_wdata = input "tx_wdata" 8
  ; rx_pop = input "rx_pop" 1; clear_fault = input "clear_fault" 1 }
;;

type core_out =
  { bad : Signal.t
  ; dbg : (string * Signal.t) list
  ; obs : Signal.t
  ; blame_seen : Signal.t
  ; ok : Signal.t
  ; running : Signal.t
  ; rst_sync_n : Signal.t
  ; tick : Signal.t
  ; pc : Signal.t
  ; lane_taps : (string * Signal.t) list
  }

(* The harness logic on given inputs. *)
let core ?(rx_never_full = false) ?(pop_pcs = []) ?(od_wired = 0) ?i2c_env ~io ~mode ~prog ~contract ~own ~od ~cfg ~cfg2 () =
  let clock = io.clock in
  let gs = Reg_spec.create ~clock () in
  let started = reg gs vdd -- "env_started" in
  let rst_sync_n = io.rst_in &: started in
  let spec = Reg_spec.create ~clock ~clear:~:rst_sync_n () in
  let sync2 x = reg spec (reg spec x) in
  let tick = io.tick
  and run = io.run
  and uio_in = wire 8 -- "h_pad" in
  let words = Isa1.assemble prog in
  let blame_in = wire 1 in
  L.taps := [];
  let lane_create ~imem i =
    match Mutate_v2.index_for Lane_spec with
    | Some index -> Mutate_v2.lane_spec ~index ~imem i
    | None -> L.create ~imem i
  in
  let o =
    lane_create ~imem:(L.imem_rom words)
      { L.I.clock; rst_sync_n; tick; run; loaded = vdd; len = of_int ~width:8 (List.length prog)
      ; own = of_int ~width:8 own; od = of_int ~width:8 od; cfg = of_int ~width:8 cfg
      ; cfg2 = of_int ~width:8 cfg2; pins = sync2 uio_in; tx_push = io.tx_push
      ; tx_wdata = io.tx_wdata; rx_pop = io.rx_pop; blame_in
      ; clear_fault = io.clear_fault }
  in
  let running = rst_sync_n &: run &: ~:(o.faulted) in
  let ownv = of_int ~width:8 own in
  uio_in <== (io.uio_in &: ~:(o.uio_oe &: ~:(o.uio_out) &: ownv &: of_int ~width:8 od_wired));
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
  let env_bad =
    match i2c_env with
    | None -> env_bad
    | Some (gap, scl_pin, sda_pin) ->
      let rs = Reg_spec.create ~clock () in
      let fb n w f =
        let d = wire w in
        let q = reg rs d -- n in
        d <== f q;
        q
      in
      let scl = bit (sync2 uio_in) scl_pin (* bus SCL as the lane and monitor see it *)
      and sda = bit (sync2 io.uio_in) sda_pin (* the environment's own SDA drive *) in
      let step = running &: tick in
      let valid = fb "h_i2c_valid" 1 (fun q -> mux2 ~:running gnd (q |: step)) in
      let scl_p = fb "h_i2c_scl_p" 1 (fun q -> mux2 step scl q) in
      let sda_p = fb "h_i2c_sda_p" 1 (fun q -> mux2 step sda q) in
      let cond = step &: valid &: scl &: scl_p &: (sda ^: sda_p) in
      let w = Int.ceil_log2 (gap + 1) in
      let since =
        fb "h_i2c_since" w (fun q ->
          mux2 ~:running (of_int ~width:w gap)
            (mux2 cond (zero w) (mux2 (step &: (q <:. gap)) (q +:. 1) q)))
      in
      let gap_bad = cond &: (since <:. gap - 1) in
      let popped = fb "h_i2c_popped" 1 (fun q -> mux2 ~:running gnd (q |: o.pop_ev)) in
      let idle_bad = running &: ~:popped &: ~:(bit io.uio_in scl_pin &: bit io.uio_in sda_pin) in
      env_bad |: gap_bad |: idle_bad
  in
  let env_bad_seen = sticky env_bad "h_env_bad" in
  let ok = ~:(env_bad_seen |: env_bad) in
  (* USB-LS TX contents (G7, G9 values): proof-side receiver, D+ = uio0, D- = uio1 *)
  let usb_mm =
    match mode with
    | `G7 ->
      fst
        (Usb_check.create ~clock ~running ~step:(running &: tick) ~dp:(bit o.uio_out 0) ~dm:(bit o.uio_out 1)
           ~pop_ev:o.pop_ev ~pop_data:o.pop_data ~push_ev:o.push_ev ~push_data:o.push_data)
    | _ -> gnd
  in
  let bad =
    match mode with
    | `G7 -> ok &: usb_mm
    | `U -> ok &: fail_now &: ~:(blame_seen |: blame_now)
    | `N1 goal ->
      let g =
        match goal with
        | Push_ok -> o.push_ev
        | Pop_ok -> o.pop_ev
        | Push_data v -> o.push_ev &: (o.push_data ==:. v)
      in
      ok &: g &: ~:(fail_seen |: fail_now |: blame_seen |: blame_now)
  in
  (* observable behaviour per cycle, for the symmetry lemma *)
  let obs =
    concat_lsb
      [ bad; mo.fire; mo.role; o.uio_out &: ownv; o.uio_oe &: ownv; o.push_ev; o.push_data; o.pop_ev
      ; o.pop_data; o.faulted ]
  in
  { bad
  ; dbg =
      [ "tick", tick; "pc", o.pc; "fire", mo.fire; "role", mo.role; "uio_in", uio_in
        (* monitor inputs, for the reference-interpreter decode in replay_cex *)
      ; "m_rst", rst_sync_n; "m_running", running; "m_out", o.uio_out &: ownv; "m_oe", o.uio_oe &: ownv
      ; "m_pop", o.pop_ev; "m_popd", o.pop_data; "m_push", o.push_ev; "m_pushd", o.push_data ]
  ; obs
  ; blame_seen; ok; running; rst_sync_n; tick; pc = o.pc; lane_taps = !L.taps }
;;

(* harness name -> contract, for the reference-interpreter decode of counterexamples *)
let contracts : Pemu_monitor_v1.Lang.t String.Table.t = String.Table.create ()

let harness ?debug ?rx_never_full ?pop_pcs ?od_wired ?i2c_env ~mode ~prog ~contract ~own ~od ~cfg ~cfg2 ~name () =
  Hashtbl.set contracts ~key:name ~data:contract;
  let c = core ?rx_never_full ?pop_pcs ?od_wired ?i2c_env ~io:(free_io ()) ~mode ~prog ~contract ~own ~od ~cfg ~cfg2 () in
  Harness.bad_circuit ?debug ~dbg:c.dbg ~name c.bad
;;

(* Symmetry lemma (user decision 2026-10-18): two copies of a harness on shared free inputs,
   copy B seeing uio_in xor [flip]. bad = the copies' observation vectors differ (U verdict,
   monitor fire and role vectors, owned pin outputs, stream events and data, fault). If this
   never fires, then for every input sequence the B copy behaves exactly as the A copy on the
   flipped inputs; in particular bad_B(in) = bad_A(in xor flip), and since xor is a bijection
   on input sequences, U for A implies U for B. Comparing only the U verdicts would be weaker:
   both are constant 0 when both packages satisfy U, so the no-flip control could not fail. *)
let sym_harness ?debug ?rx_never_full ?pop_pcs ~mode ~flip ~a:(prog_a, contract_a) ~b:(prog_b, contract_b)
      ~own ~od ~cfg ~cfg2 ~name () =
  let io = free_io () in
  let ca = core ?rx_never_full ?pop_pcs ~io ~mode ~prog:prog_a ~contract:contract_a ~own ~od ~cfg ~cfg2 () in
  let io_b = { io with uio_in = io.uio_in ^: of_int ~width:8 flip } in
  let cb = core ?rx_never_full ?pop_pcs ~io:io_b ~mode ~prog:prog_b ~contract:contract_b ~own ~od ~cfg ~cfg2 () in
  Harness.bad_circuit ?debug ~dbg:[ "bad_a", ca.bad; "bad_b", cb.bad ] ~name (ca.obs <>: cb.obs)
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

(* Register correspondence for the symmetry lemma: the registers of each copy in creation
   (uid) order. Both copies are built by the same code, so the k-th register of A corresponds
   to the k-th register of B when the programs and contracts have the same shape. *)
let regs_of outs =
  Signal_graph.create outs
  |> Signal_graph.fold ~init:[] ~f:(fun acc s -> if Signal.Type.is_reg s then s :: acc else acc)
  |> List.sort ~compare:(fun a b -> Signal.Type.Uid.compare (Signal.uid a) (Signal.uid b))
;;

let mems_of outs =
  Signal_graph.create outs
  |> Signal_graph.fold ~init:0 ~f:(fun acc s ->
    match s with Signal.Type.Multiport_mem _ -> acc + 1 | _ -> acc)
;;

(* Discovery circuit: both copies on shared inputs (B flipped), outputs the concatenated
   register vectors of each copy (for simulation-based classification of bit pairs). *)
let sym_regs_circuit ?rx_never_full ?pop_pcs ~mode ~flip ~a:(prog_a, contract_a) ~b:(prog_b, contract_b)
      ~own ~od ~cfg ~cfg2 () =
  let io = free_io () in
  let obs_a = (core ?rx_never_full ?pop_pcs ~io ~mode ~prog:prog_a ~contract:contract_a ~own ~od ~cfg ~cfg2 ()).obs in
  let io_b = { io with uio_in = io.uio_in ^: of_int ~width:8 flip } in
  let obs_b = (core ?rx_never_full ?pop_pcs ~io:io_b ~mode ~prog:prog_b ~contract:contract_b ~own ~od ~cfg ~cfg2 ()).obs in
  let ra = regs_of [ obs_a ] and rb = regs_of [ obs_b ] in
  let ra = List.filter ra ~f:(fun r -> not (List.mem rb r ~equal:phys_equal)) in
  let shared = List.length (regs_of [ obs_a ]) - List.length ra in
  let widths l = List.map l ~f:Signal.width in
  let circ =
    Circuit.create_exn ~name:"sym_regs"
      [ output "regs_a" (concat_lsb ra); output "regs_b" (concat_lsb rb); output "obs_diff" (obs_a <>: obs_b) ]
  in
  circ, widths ra, widths rb, shared, mems_of [ obs_a; obs_b ], List.map ra ~f:(fun r -> String.concat ~sep:"/" (Signal.names r))
;;

(* Warm-up symmetry lemma (user decision 2026-10-18). As [sym_harness] with flip on one pin,
   strengthened by an explicit correspondence invariant so that it is inductive:
   - shadow flags tell whether a register currently holds a warm (post-synchroniser) sample of
     the flipped pin: s1w/s2w for the two synchroniser stages (cleared by reset like them),
     pw for the lane's prev_pins (cleared by step_reset, set to s2w on exec), hw for the
     monitor history of that pin (shifts like mon_hist), stc = steps since monitor restart;
   - bit pairs of the flipped pin are complementary where the shadow is warm and equal where
     it is cold; all other register bits are equal;
   - early-state facts: a cold prev_pins means lane pc <= 2; while a cold history entry exists
     and no blame has fired, the listed units are at one of the listed pcs ([early_units] = []:
     no cold history entry exists without an earlier blame. For the SPI target this holds
     because a monitor step during the synchroniser warm-up sees CS = 0 and B5 blames).
   Observations are compared only until the first blame (after a blame bad = 0 in both
   copies). bad = env ok and no earlier blame and (observations differ or invariant false). *)
let sym_inv_harness ?debug ?(expose = false) ?rx_never_full ?pop_pcs ~mode ~pin ~hist_slot ~early_units
      ~a:(prog_a, contract_a) ~b:(prog_b, contract_b) ~own ~od ~cfg ~cfg2 ~name () =
  let flip = 1 lsl pin in
  let io = free_io () in
  let ca = core ?rx_never_full ?pop_pcs ~io ~mode ~prog:prog_a ~contract:contract_a ~own ~od ~cfg ~cfg2 () in
  let io_b = { io with uio_in = io.uio_in ^: of_int ~width:8 flip } in
  let cb = core ?rx_never_full ?pop_pcs ~io:io_b ~mode ~prog:prog_b ~contract:contract_b ~own ~od ~cfg ~cfg2 () in
  let ra = regs_of [ ca.obs ] and rb = regs_of [ cb.obs ] in
  if List.length ra <> List.length rb then raise_s [%message "sym_inv: register count differs"];
  let spec = Reg_spec.create ~clock:io.clock ~clear:~:(ca.rst_sync_n) () in
  let s1w = reg spec vdd -- "sh_s1w" in
  let s2w = reg spec s1w -- "sh_s2w" in
  let tap n = List.Assoc.find_exn ca.lane_taps ~equal:String.equal n in
  let pw =
    let d = wire 1 in
    let q = reg spec d -- "sh_pw" in
    d <== mux2 (tap "step_reset") gnd (mux2 (tap "exec") s2w q);
    q
  in
  let running_m = ca.rst_sync_n &: ca.running in
  let step = running_m &: ca.tick in
  let stc =
    let d = wire 4 in
    let q = reg spec d -- "sh_stc" in
    d <== mux2 (~:running_m) (zero 4) (mux2 (step &: (q <:. 8)) (q +:. 1) q);
    q
  in
  let hw =
    let d = wire 4 in
    let q = reg spec d -- "sh_hw" in
    d <== mux2 (~:running_m) (zero 4) (mux2 step (select (q @: s2w) 3 0) q);
    q
  in
  let has_name r n = List.mem (Signal.names r) n ~equal:String.equal in
  let d_of r = match r with Signal.Type.Reg { d; _ } -> Some d | _ -> None in
  let is_stage1 r uin = match d_of r with Some d -> phys_equal d uin | None -> false in
  let stage1_a = List.filter ra ~f:(fun r -> is_stage1 r io.uio_in) in
  let is_stage2 r st1 = match d_of r with Some d -> List.exists st1 ~f:(fun s -> phys_equal d s) | None -> false in
  let rel w x y = mux2 w (x ==: ~:y) (x ==: y) in
  let inv_terms =
    List.map2_exn ra rb ~f:(fun a b ->
      let w = Signal.width a in
      let bit_rel i =
        let x = bit a i and y = bit b i in
        if i = pin && is_stage1 a io.uio_in then rel s1w x y
        else if i = pin && is_stage2 a stage1_a then rel s2w x y
        else if i = pin && has_name a "lane_prev_pins" then rel pw x y
        else if has_name a (sprintf "mon_hist%d" hist_slot) then rel (bit hw i) x y
        else x ==: y
      in
      reduce ~f:( &: ) (List.init w ~f:bit_rel))
  in
  let corr = reduce ~f:( &: ) inv_terms in
  let cold_hist = reduce ~f:( |: ) (List.init 4 ~f:(fun d -> (stc >=:. d + 1) &: ~:(bit hw d))) in
  let find_reg n = List.find_exn ra ~f:(fun r -> has_name r n) in
  let early_ok =
    List.map early_units ~f:(fun (u, pcs) ->
      let pc = find_reg (sprintf "mon_u%d_pc" u) in
      reduce ~f:( |: ) (List.map pcs ~f:(fun v -> pc ==:. v)))
    |> List.fold ~init:(if List.is_empty early_units then gnd else vdd) ~f:( &: )
  in
  let nb = ~:(ca.blame_seen) in
  (* monitor bookkeeping: seen = min(stc, 4); stc = 0 means no monitor step since restart, so
     every present unit is in its reset state (start pc, everything else 0) *)
  let seen = find_reg "mon_seen" in
  let seen_ok = mux2 (stc >=:. 4) (seen ==:. 4) (seen ==: uresize stc (Signal.width seen)) in
  let starts =
    (S.tables_of_package (Compile.compile_exn contract_a)).starts
  in
  let unit_reset =
    List.filter_map (List.init 8 ~f:Fn.id) ~f:(fun u ->
      match List.find ra ~f:(fun r -> has_name r (sprintf "mon_u%d_pc" u)) with
      | None -> None
      | Some pc ->
        let z n = find_reg (sprintf "mon_u%d_%s" u n) ==:. 0 in
        Some (pc ==: starts.(u) &: z "k" &: z "m0" &: z "m1" &: z "reg" &: z "stopped"))
    |> List.fold ~init:vdd ~f:( &: )
  in
  let inv =
    corr
    &: (pw |: (ca.pc <=:. 2))
    &: (~:(nb &: cold_hist) |: early_ok)
    &: seen_ok
    &: (s2w |: (ca.pc <=:. 1))
    &: (~:(nb &: ~:s2w) |: (stc ==:. 0))
    &: ((stc <>:. 0) |: unit_reset)
  in
  let bad = ca.ok &: nb &: ((ca.obs <>: cb.obs) |: ~:inv) in
  if expose
  then (
    let ustate u = find_reg (sprintf "mon_u%d_pc" u) in
    Circuit.create_exn ~name
      ([ output "bad" bad; output "corr" corr; output "inv" inv; output "nb" nb; output "cold_hist" cold_hist
       ; output "stc" stc; output "pw" pw; output "lane_pc" ca.pc; output "obs_diff" (ca.obs <>: cb.obs) ]
       @ List.map early_units ~f:(fun (u, _) -> output (sprintf "u%d_pc" u) (ustate u))))
  else Harness.bad_circuit ?debug ~dbg:[ "bad_a", ca.bad; "bad_b", cb.bad; "inv", inv ] ~name bad
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
  @ (let pkg (cpol, cpha) = P1.spi_tgt ~cpol ~cpha, Lib.spi_tgt ~cpol ~cpha ~h_min:3 ~g:6 in
     let symi ~pin a b name =
       sym_inv_harness ?debug ~rx_never_full:true ~pop_pcs:[ 2 ] ~mode:`U ~pin ~hist_slot:1 ~early_units:[]
         ~a:(pkg a) ~b:(pkg b) ~own:P1.spi_own_tgt ~od:0 ~cfg:0 ~cfg2:0 ~name ()
     in
     [ (* warm-up symmetry lemmas with explicit correspondence (inductive) *)
       symi ~pin:5 (true, true) (false, true) "a2_spi_tgt_symi_m3_m1"
     ; symi ~pin:5 (true, false) (false, false) "a2_spi_tgt_symi_m2_m0"
     ; (* negative control: flipping CS instead of SCLK is not a symmetry *)
       symi ~pin:4 (true, true) (false, true) "a2_spi_tgt_symi_m3_m1_cs_neg"
     ; (* negative control: B = mode-1 firmware with the per-bit MOV removed *)
       sym_inv_harness ?debug ~rx_never_full:true ~pop_pcs:[ 2 ] ~mode:`U ~pin:5 ~hist_slot:1 ~early_units:[]
         ~a:(pkg (true, true))
         ~b:(spi_tgt_nomov ~cpol:false ~cpha:true, Lib.spi_tgt ~cpol:false ~cpha:true ~h_min:3 ~g:6)
         ~own:P1.spi_own_tgt ~od:0 ~cfg:0 ~cfg2:0 ~name:"a2_spi_tgt_symi_m3_m1nomov_neg" ()
     ])
;;

(* ---- I2C (doc/protocols/i2c_v1.md) ---- *)
let mutate_first prog ~at ~f =
  let a = Array.of_list prog in
  let nth i = if i >= 0 && i < Array.length a then Some a.(i) else None in
  match Array.findi a ~f:(fun i _ -> at nth i) with
  | Some (i, x) ->
    a.(i) <- f x;
    Array.to_list a
  | None -> raise_s [%message "mutant site not found"]
;;

let is x = function Some y -> [%equal: Isa1.t] x y | None -> false

(* target mutants (as in protocols_v1/test/test_i2c.ml) *)
let i2c_tgt_noack =
  mutate_first (P1.i2c_tgt ~addr:0x50) ~at:(fun n i -> is (Out 0x04) (n i) && is (Push Sr) (n (i + 1))) ~f:(fun _ -> Nop)
;;

let i2c_tgt_stretchhigh =
  mutate_first (P1.i2c_tgt ~addr:0x50)
    ~at:(fun n i -> is (Wtp (2, Low)) (n i) && match n (i + 1) with Some (Br (5, _)) -> true | _ -> false)
    ~f:(fun _ -> Wtp (2, High))
;;

let i2c_tgt_noassume c =
  { c with
    Pemu_monitor_v1.Lang.watchers =
      List.filter c.Pemu_monitor_v1.Lang.watchers ~f:(fun w -> List.mem [ "frame"; "high" ] w.wname ~equal:String.equal)
  }
;;

let i2c_all ?debug () =
  let fm = 6, 4, 3, 6 and sm = 5, 5, 5, 5 in
  let ctl ?prog ?(wired = true) ~mode (l, h, tsu, thold) name =
    let prog = Option.value prog ~default:(P1.i2c_ctl ~l ~h ~tsu ~thold) in
    harness ?debug ~rx_never_full:true ~od_wired:(if wired then P1.i2c_own else 0) ~mode ~prog
      ~contract:(Lib.i2c_ctl ~l ~h ~tsu ~thold) ~own:P1.i2c_own ~od:P1.i2c_od ~cfg:0 ~cfg2:0 ~name ()
  in
  let tfm = 8, 18, 8 and tsm = 59, 69, 59 in
  (* increment 3: the v2 ROM package, Sm at 30 MHz and P = 5 (Rom_lib.i2c_tgt_sm_params; the
     P = 4 parameters 23/27/23 were checked the same way before the pipelined schedule) *)
  let tsm30 = 19, 22, 19 in
  let tgt ?(prog = P1.i2c_tgt ~addr:0x50) ?(contract = Fn.id) ~mode (h_min, l_min, hd) name =
    (* host-stream assumption (doc 3.1): the config byte is in the TX FIFO when the lane
       starts, i.e. the config POP (pc 2) never executes with an empty FIFO *)
    harness ?debug ~rx_never_full:true ~pop_pcs:[ 2 ] ~od_wired:P1.i2c_own
      ~i2c_env:(hd, 2, 3) (* SCL = uio2, SDA = uio3 (user decision 2026-10-18) *) ~mode ~prog
      ~contract:(contract (Lib.i2c_tgt ~h_min ~l_min ~hd)) ~own:P1.i2c_own ~od:P1.i2c_od ~cfg:0 ~cfg2:0 ~name ()
  in
  let l, h, tsu, thold = fm in
  [ ctl ~mode:`U fm "a2_i2c_ctl_fm_u"
  ; ctl ~mode:`U sm "a2_i2c_ctl_sm_u"
  ; ctl ~mode:(`N1 Push_ok) fm "a2_i2c_ctl_fm_n1_cover_neg"
  ; ctl ~prog:(P1.i2c_ctl ~l ~h:(h - 2) ~tsu ~thold) ~mode:`U fm "a2_i2c_ctl_fm_h2_neg"
  ; ctl ~wired:false ~mode:`U fm "a2_i2c_ctl_fm_nowired_neg"
  ; tgt ~mode:`U tfm "a2_i2c_tgt_fm_u"
  ; tgt ~mode:`U tsm "a2_i2c_tgt_sm_u"
  ; tgt ~mode:(`N1 Push_ok) tfm "a2_i2c_tgt_fm_n1_cover_neg"
  ; tgt ~prog:i2c_tgt_noack ~mode:`U tfm "a2_i2c_tgt_fm_noack_neg"
  ; tgt ~prog:i2c_tgt_stretchhigh ~mode:`U tfm "a2_i2c_tgt_fm_stretchhigh_neg"
  ; tgt ~contract:i2c_tgt_noassume ~mode:`U tfm "a2_i2c_tgt_fm_noassume_neg"
  ; tgt ~mode:`U tsm30 "a2_i2c_tgt_sm30_u"
  ; tgt ~mode:(`N1 Push_ok) tsm30 "a2_i2c_tgt_sm30_n1_cover_neg"
  ; tgt ~prog:i2c_tgt_noack ~mode:`U tsm30 "a2_i2c_tgt_sm30_noack_neg"
  ; tgt ~prog:i2c_tgt_stretchhigh ~mode:`U tsm30 "a2_i2c_tgt_sm30_stretchhigh_neg"
  ]
;;

(* ---- USB-LS TX (doc/protocols/usb_ls_v1.md) ---- *)
let usb_mut ~from ~to_ =
  let m = List.map P1.usb_ls_tx ~f:(fun x -> if Isa1.equal x from then to_ else x) in
  if List.equal Isa1.equal m P1.usb_ls_tx then raise_s [%message "usb mutant does not change the program"];
  m
;;

let usb_all ?debug () =
  let h ?(prog = P1.usb_ls_tx) ~mode name =
    harness ?debug ~rx_never_full:true ~mode ~prog ~contract:(Lib.usb_ls_tx ()) ~own:P1.usb_own ~od:0
      ~cfg:P1.usb_cfg ~cfg2:0 ~name ()
  in
  let sendc = usb_mut ~from:(Isa1.Ser (Sendc R2)) ~to_:(Isa1.Ser (Send R2))
  and sync = usb_mut ~from:(Isa1.Ldi (L Sr, 0x80)) ~to_:(Isa1.Ldi (L Sr, 0x81))
  and status = usb_mut ~from:(Isa1.Ldi (L R1, 0)) ~to_:(Isa1.Ldi (L R1, 3))
  and nopush = usb_mut ~from:(Isa1.Push R3) ~to_:Isa1.Nop in
  [ h ~mode:`U "a2_usb_u"
  ; h ~mode:`G7 "a2_usb_g7"
  ; h ~mode:(`N1 (Push_data 0)) "a2_usb_n1_cover_neg"
  ; h ~prog:sendc ~mode:`G7 "a2_usb_g7_sendc_neg"
  ; h ~prog:sendc ~mode:`U "a2_usb_u_sendc"
  ; h ~prog:sync ~mode:`U "a2_usb_u_sync_neg"
  ; h ~prog:status ~mode:`G7 "a2_usb_g7_status_neg"
  ; h ~prog:nopush ~mode:`U "a2_usb_u_nopush_neg"
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
  @ i2c_all ?debug ()
  @ usb_all ?debug ()
;;
