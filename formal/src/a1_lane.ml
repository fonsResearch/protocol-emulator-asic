(* A1 for one ISA v1 lane: lane RTL (rtl_v1/Lane_rtl) against the lane specification
   (spec_v1/Lane_circuit). Every lane input, including the instruction-memory write port, is
   free in every cycle. Environment assumption (power-up, PH6): rst_sync_n = 0 in frame 0.
   Observables (interface v1 section 8): pins, xo, fault state, pc, FIFO levels and head,
   stream events with data.

   a1_lane_full  monolithic: the RTL writes a 256x16 word array through the SRAM port; the
                 specification reads imem[pc] from the same array. Words and A_DOUT start free.
                 (4,760 latches; dprove TIMEOUT at 3,600 s, PDR stuck at frame 3. Kept as a
                 cross-check for longer runs.)

   Decomposition used instead (no memory array in either obligation):
   a1_lane_fetch (L1)  RTL only. Ghost registers follow the SRAM rules on the RTL's SRAM port:
                 dout_addr = address of the word in A_DOUT, fresh = no write to dout_addr since
                 it was read (write-through counts as a read). Property: in every cycle in which
                 the lane is running, fresh && dout_addr = pc. Hence A_DOUT = mem[pc] (current
                 contents) in every running cycle.
   a1_lane_dp (L2)  RTL with A_DOUT abstracted: on every read A_DOUT loads a free 16-bit value
                 (write-through loads A_DIN), except that re-reading the held address with no
                 write since returns the held word (a property of the real SRAM). The
                 specification executes that same A_DOUT word (imem = fun _ -> A_DOUT).
                 Property: all observables equal.
   a1_lane_spec_indep (L3)  the specification reads its instruction word only in step
                 cycles (two copies, words equal only in steps, outputs equal).
   Composition (paper argument; L3 machine-checks its first sentence): Lane_circuit's state and outputs depend on the instruction
   word only in executing cycles (all decode effects are gated by exec, which implies
   running). By L1, in those cycles A_DOUT = mem[pc]. L2 holds for every sequence of read
   values allowed by its constraint, and the real SRAM's read values satisfy it. So RTL = specification reading imem[pc] from the
   memory as the accepted writes leave it. *)
open! Core
open Hardcaml
open Signal
module L = Pemu_spec_v1.Lane_circuit
module R = Pemu_rtl_v1.Lane_rtl
module S = Pemu_rtl_v1.Sram256

type inputs =
  { clock : Signal.t
  ; ri : Signal.t R.I.t
  }

let lane_inputs () =
  let clock = input "clock" 1 in
  let started = reg (Reg_spec.create ~clock ()) vdd -- "env_started" in
  let rst_sync_n = input "rst_sync_n" 1 &: started in
  let inp n w = input n w in
  { clock
  ; ri =
      { R.I.clock; rst_sync_n; tick = inp "tick" 1; run = inp "run" 1; loaded = inp "loaded" 1
      ; len = inp "len" 8; own = inp "own" 8; od = inp "od" 8; cfg = inp "cfg" 8
      ; cfg2 = inp "cfg2" 8; pins = inp "pins" 8; tx_push = inp "tx_push" 1
      ; tx_wdata = inp "tx_wdata" 8; rx_pop = inp "rx_pop" 1; blame_in = inp "blame_in" 1
      ; clear_fault = inp "clear_fault" 1; imem_we = inp "imem_we" 1
      ; imem_waddr = inp "imem_waddr" 8; imem_wdata = inp "imem_wdata" 16 }
  }
;;

(* v2 mutation campaign hooks (formal/src/mutate_v2.ml): the active mutant replaces the unit *)
let rtl_create ?bug ~sram ri =
  match Mutate_v2.index_for Lane_rtl with
  | Some index ->
    assert (Option.is_none bug);
    Mutate_v2.lane_rtl ~index ~sram ri
  | None -> R.create ?bug ~sram ri
;;

let spec_create ~imem i =
  match Mutate_v2.index_for Lane_spec with
  | Some index -> Mutate_v2.lane_spec ~index ~imem i
  | None -> L.create ~imem i
;;

let spec_of (i : _ R.I.t) ~imem =
  spec_create
    ~imem
    { L.I.clock = i.clock; rst_sync_n = i.rst_sync_n; tick = i.tick; run = i.run
    ; loaded = i.loaded; len = i.len; own = i.own; od = i.od; cfg = i.cfg; cfg2 = i.cfg2
    ; pins = i.pins; tx_push = i.tx_push; tx_wdata = i.tx_wdata; rx_pop = i.rx_pop
    ; blame_in = i.blame_in; clear_fault = i.clear_fault }
;;

let compare_outputs (s : _ L.O.t) (r : _ R.O.t) =
  [ "uio_out", s.uio_out, r.uio_out; "uio_oe", s.uio_oe, r.uio_oe; "xo", s.xo, r.xo
  ; "faulted", s.faulted, r.faulted; "cause", s.cause, r.cause; "pc", s.pc, r.pc
  ; "tx_level", s.tx_level, r.tx_level; "rx_level", s.rx_level, r.rx_level
  ; "rx_head", s.rx_head, r.rx_head; "pop_ev", s.pop_ev, r.pop_ev
  ; "pop_data", s.pop_data, r.pop_data; "push_ev", s.push_ev, r.push_ev
  ; "push_data", s.push_data, r.push_data ]
;;

let differ pairs = List.map pairs ~f:(fun (_, a, b) -> a <>: b) |> reduce ~f:( |: )
let dbg pairs = List.concat_map pairs ~f:(fun (n, a, b) -> [ "spec_" ^ n, a; "rtl_" ^ n, b ])

let full ?debug ?bug ~name () =
  let { ri; _ } = lane_inputs () in
  let words = ref [] in
  let sram i =
    let o, mem = S.behavioural ~mem_name:"free_imem_word" ~dout_name:"rtl_imem_dout" i in
    words := mem;
    o
  in
  let r = rtl_create ?bug ~sram ri in
  let s = spec_of ri ~imem:(fun pc -> mux pc !words) in
  let pairs = compare_outputs s r in
  Harness.bad_circuit ?debug ~dbg:(dbg pairs) ~name (differ pairs)
;;

(* A_DOUT abstracted: free read data on every read (A_MEN & A_REN & !A_WEN); write-through
   loads A_DIN merged with the bit mask (all ones here); otherwise hold. *)
let free_read_sram ~rdata (i : _ S.I.t) =
  let spec = Reg_spec.create ~clock:i.a_clk () in
  let write = i.a_men &: i.a_wen
  and read = i.a_men &: i.a_ren in
  let dout_en = (write &: i.a_ren) |: (~:write &: read) in
  let d = mux2 write i.a_din rdata in
  (* explicit hold multiplexer (see Sram256.behavioural) *)
  let q = wire 16 in
  let r = reg spec (mux2 dout_en d q) -- "rtl_imem_dout" in
  q <== r;
  { S.O.a_dout = r }
;;

(* Ghost tracking of the word held in A_DOUT, from the SRAM port signals. *)
let ghost ~clock (p : _ S.I.t) =
  let gs = Reg_spec.create ~clock () in
  let write = p.a_men &: p.a_wen
  and read = p.a_men &: p.a_ren in
  let addr_d = wire 8
  and fresh_d = wire 1 in
  let dout_addr = reg gs addr_d -- "ghost_dout_addr"
  and fresh = reg gs fresh_d -- "ghost_fresh" in
  addr_d <== mux2 read p.a_addr dout_addr;
  fresh_d <== mux2 read vdd (mux2 (write &: (p.a_addr ==: dout_addr)) gnd fresh);
  dout_addr, fresh
;;

let fetch ?debug ?bug ~name () =
  let { clock; ri } = lane_inputs () in
  let rdata = input "free_rdata" 16 in
  let port = ref None in
  let sram i =
    port := Some i;
    free_read_sram ~rdata i
  in
  let r = rtl_create ?bug ~sram ri in
  let p = Option.value_exn !port in
  let dout_addr, fresh = ghost ~clock p in
  let running = ri.rst_sync_n &: ri.run &: ri.loaded &: ~:(r.faulted) in
  let bad = running &: ~:(fresh &: (dout_addr ==: r.pc)) in
  Harness.bad_circuit
    ?debug
    ~dbg:[ "running", running; "fresh", fresh; "dout_addr", dout_addr; "pc", r.pc ]
    ~name
    bad
;;

(* L2. Read data are free except that a read of the address whose word A_DOUT holds, with no
   write to it since, returns that word (true of the real SRAM). Without this constraint L2 is
   false for unreachable reasons: a lane waiting in a blocking instruction would see a
   different instruction at the same pc (counterexample found 2026-10-17, depth 3). *)
let datapath ?debug ?bug ~name () =
  let { clock; ri } = lane_inputs () in
  let rdata = input "free_rdata" 16 in
  let dout = ref None in
  let sram (i : _ S.I.t) =
    let held = wire 16 in
    let dout_addr, fresh = ghost ~clock i in
    let same = fresh &: (i.a_addr ==: dout_addr) in
    let o = free_read_sram ~rdata:(mux2 same held rdata) i in
    held <== o.a_dout;
    dout := Some o.a_dout;
    o
  in
  let r = rtl_create ?bug ~sram ri in
  let ir = Option.value_exn !dout in
  let s = spec_of ri ~imem:(fun _ -> ir) in
  let pairs = compare_outputs s r in
  Harness.bad_circuit ?debug ~dbg:(dbg pairs) ~name (differ pairs)
;;

(* L3 (spec only). Two copies of the specification with independent free instruction words,
   equal only in step cycles (tick && running, running computed from the inputs and the
   copy's fault flag): all outputs equal. So the specification reads its instruction word only
   in steps, which is where L1 gives A_DOUT = mem[pc]. Negative control: the words are also
   allowed to differ in step cycles. *)
let spec_indep ?debug ?(neg = false) ~name () =
  let { ri; _ } = lane_inputs () in
  let wa = input "free_word_a" 16
  and wb = input "free_word_b" 16 in
  let fa = wire 1 in
  let running = ri.rst_sync_n &: ri.run &: ri.loaded &: ~:fa in
  let step = ri.tick &: running in
  let wb' = if neg then wb else mux2 step wa wb in
  let sa = spec_of ri ~imem:(fun _ -> wa)
  and sb = spec_of ri ~imem:(fun _ -> wb') in
  fa <== sa.faulted;
  let pairs =
    List.map2_exn (L.O.to_list sa) (L.O.to_list sb) ~f:(fun a b -> "o", a, b)
  in
  Harness.bad_circuit ?debug ~dbg:[ "step", step ] ~name (differ pairs)
;;

let all ?debug () =
  [ full ?debug ~name:"a1_lane_full" ()
  ; full ?debug ~bug:`No_write_through ~name:"a1_lane_full_nowt_neg" ()
  ; full ?debug ~bug:`No_prev_running_gate ~name:"a1_lane_full_gate_neg" ()
  ; fetch ?debug ~name:"a1_lane_fetch" ()
  ; fetch ?debug ~bug:`No_write_through ~name:"a1_lane_fetch_nowt_neg" ()
  ; fetch ?debug ~bug:`No_prev_running_gate ~name:"a1_lane_fetch_gate_neg" ()
  ; datapath ?debug ~name:"a1_lane_dp" ()
  ; datapath ?debug ~bug:`Timeout_early ~name:"a1_lane_dp_timeout_neg" ()
  ; spec_indep ?debug ~name:"a1_lane_spec_indep" ()
  ; spec_indep ?debug ~neg:true ~name:"a1_lane_spec_indep_neg" ()
  ]
;;
