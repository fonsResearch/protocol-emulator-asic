(* Cycle-level reference interpreter of the whole observable machine at the core boundary
   (doc/isa/isa_v0.md v0.1 + doc/interface.md v0.1).

   Convention: [outputs st] are the pin values DURING the current cycle; they are a pure
   function of registers (Moore machine). [step st inputs] applies the edge that ends the
   current cycle, using the inputs sampled at that edge. *)
open! Core

type inputs =
  { rst_sync_n : bool
  ; ui_in : int
  ; uio_in : int
  }
[@@deriving sexp_of]

type outputs =
  { uo_out : int
  ; uio_out : int
  ; uio_oe : int
  }
[@@deriving sexp_of, equal]

type t =
  { (* input synchronisers (interface section 3) *)
    mutable s1_run : bool
  ; mutable s2_run : bool
  ; mutable s1_wstb : bool
  ; mutable s2_wstb : bool
  ; mutable s3_wstb : bool (* previous cycle's s2_wstb, for edge detection *)
  ; mutable s1_uio : int
  ; mutable s2_uio : int
  ; (* architectural state (ISA section 2) *)
    mutable pc : int
  ; mutable out : int
  ; mutable sr : int
  ; mutable lc : int
  ; (* WAIT in progress: [waiting] and cycles remaining after the current one *)
    mutable waiting : bool
  ; mutable wait_cnt : int
  ; (* program-load state (interface section 5) *)
    mutable load_addr : int
  ; mutable load_hi : bool
  ; mutable load_lo : int
  ; imem : int array
  }
[@@deriving sexp_of]

(* All registers at their reset values; imem is supplied by the caller because it is
   undefined after reset (ISA section 2). *)
let create ~imem =
  if Array.length imem <> Isa.imem_depth then raise_s [%message "imem must have 64 words"];
  { s1_run = false
  ; s2_run = false
  ; s1_wstb = false
  ; s2_wstb = false
  ; s3_wstb = false
  ; s1_uio = 0
  ; s2_uio = 0
  ; pc = 0
  ; out = 0
  ; sr = 0
  ; lc = 0
  ; waiting = false
  ; wait_cnt = 0
  ; load_addr = 0
  ; load_hi = false
  ; load_lo = 0
  ; imem = Array.copy imem
  }
;;

let outputs st = { uo_out = st.out; uio_out = 0; uio_oe = 0 }
let running st = st.s2_run

let reset_regs st =
  st.s1_run <- false;
  st.s2_run <- false;
  st.s1_wstb <- false;
  st.s2_wstb <- false;
  st.s3_wstb <- false;
  st.s1_uio <- 0;
  st.s2_uio <- 0;
  st.pc <- 0;
  st.out <- 0;
  st.sr <- 0;
  st.lc <- 0;
  st.waiting <- false;
  st.wait_cnt <- 0;
  st.load_addr <- 0;
  st.load_hi <- false;
  st.load_lo <- 0
;;

let pc_inc pc = (pc + 1) land 0x3f

(* Execute one cycle of a running machine; returns next (pc, out, sr, lc, waiting, wait_cnt).
   Reads current-cycle register values only. *)
let exec st =
  if st.waiting
  then
    if st.wait_cnt = 0
    then pc_inc st.pc, st.out, st.sr, st.lc, false, 0
    else st.pc, st.out, st.sr, st.lc, true, st.wait_cnt - 1
  else (
    let keep_wait = false, 0 in
    let w, c = keep_wait in
    match Isa.decode st.imem.(st.pc) with
    | Jmp t -> t, st.out, st.sr, st.lc, w, c
    | Out v -> pc_inc st.pc, v, st.sr, st.lc, w, c
    | Outb p ->
      let bit = st.sr land 1 in
      let out = st.out land lnot (1 lsl p) lor (bit lsl p) in
      pc_inc st.pc, out, st.sr lsr 1, st.lc, w, c
    | Ldi v -> pc_inc st.pc, st.out, v, st.lc, w, c
    | In -> pc_inc st.pc, st.out, st.s2_uio, st.lc, w, c
    | Wait k ->
      (* k+1 cycles total: this cycle plus k more *)
      if k = 0
      then pc_inc st.pc, st.out, st.sr, st.lc, false, 0
      else st.pc, st.out, st.sr, st.lc, true, k - 1
    | Ldc v -> pc_inc st.pc, st.out, st.sr, v, w, c
    | Djnz t ->
      let lc' = (st.lc - 1) land 0xff in
      (if lc' <> 0 then t else pc_inc st.pc), st.out, st.sr, lc', w, c
    | Reserved _ -> pc_inc st.pc, st.out, st.sr, st.lc, w, c)
;;

let step st (i : inputs) =
  if not i.rst_sync_n
  then reset_regs st
  else (
    (* Architectural/load updates are computed from THIS cycle's register values before
       anything is written (all registers update at the same edge). *)
    let running = st.s2_run in
    let write_event = st.s2_wstb && not st.s3_wstb in
    if not running
    then (
      (* halted cycle: ISA section 3 *)
      st.pc <- 0;
      st.out <- 0;
      st.sr <- 0;
      st.lc <- 0;
      st.waiting <- false;
      st.wait_cnt <- 0;
      (* program load: interface section 5 *)
      if write_event
      then
        if not st.load_hi
        then (
          st.load_lo <- st.s2_uio;
          st.load_hi <- true)
        else (
          st.imem.(st.load_addr) <- (st.s2_uio lsl 8) lor st.load_lo;
          st.load_addr <- (st.load_addr + 1) land 0x3f;
          st.load_hi <- false))
    else (
      let pc, out, sr, lc, waiting, wait_cnt = exec st in
      st.pc <- pc;
      st.out <- out;
      st.sr <- sr;
      st.lc <- lc;
      st.waiting <- waiting;
      st.wait_cnt <- wait_cnt;
      st.load_addr <- 0;
      st.load_hi <- false;
      st.load_lo <- 0);
    (* synchroniser shift (interface section 3) *)
    st.s3_wstb <- st.s2_wstb;
    st.s2_wstb <- st.s1_wstb;
    st.s1_wstb <- i.ui_in land 0x40 <> 0;
    st.s2_run <- st.s1_run;
    st.s1_run <- i.ui_in land 0x80 <> 0;
    st.s2_uio <- st.s1_uio;
    st.s1_uio <- i.uio_in land 0xff)
;;
