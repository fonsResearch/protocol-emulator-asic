(* Reference interpreter of one ISA v1 lane (doc/isa/isa_v1.md, clarifications v1.0.1 in
   doc/CHANGES.md), including its host FIFOs. Decodes instruction words itself (independent of
   [Lane_circuit]). One call to [step] = one clock cycle: returns this cycle's outputs (from the
   current state), then applies the end-of-cycle update.

   Precise points fixed here (all also in the ISA clarifications):
   - Blocking instructions: first step evaluates the condition; if it fails, later steps
     re-evaluate; with to <> 0 the instruction times out at step to+1 (T <- 1, no action).
   - Serializer "ready" includes the step in which the last bit (and any pending stuff bit) ends,
     so consecutive SENDs are contiguous on the line.
   - FIFOs run every cycle (host side) and are popped/pushed by the lane only in steps; a pop
     never sees a byte the host pushes in the same cycle. Depth 8.
   - A lane that is not live (did not run in its last step) drives no pin: uio_oe = 0. *)
open! Core

type inputs =
  { rst_sync_n : bool
  ; tick : bool
  ; run : bool
  ; loaded : bool
  ; len : int
  ; own : int
  ; od : int
  ; cfg : int (* bit0 release_on_blame, 1 pair, 2 msb_first, 3 nrzi, 4 stuff, 5 crc_en, 6 crc16 *)
  ; cfg2 : int (* ser_pin [2:0], pair_base [6:4] *)
  ; pins : int (* synchronised uio_in *)
  ; tx_push : bool
  ; tx_wdata : int
  ; rx_pop : bool
  ; blame_in : bool
  ; clear_fault : bool
  }

type outputs =
  { uio_out : int
  ; uio_oe : int
  ; xo : int
  ; faulted : bool
  ; cause : int (* 0 none, 1 FETCH_BOUND, 2 BLAME, 3 HALT *)
  ; pc : int
  ; tx_level : int
  ; rx_level : int
  ; rx_head : int
  ; pop_ev : bool
  ; pop_data : int
  ; push_ev : bool
  ; push_data : int
  }
[@@deriving sexp_of, equal]

type wait_kind =
  | No_wait
  | Wait_n of int (* steps remaining including the completing one *)
  | Block of int (* timeout steps remaining; 0 = none *)

type ser =
  { mutable busy : bool
  ; mutable shift : int
  ; mutable nbits : int (* data bits still to start after the current one *)
  ; mutable msb : bool
  ; mutable width : int
  ; mutable crc_upd : bool
  ; mutable timer : int
  ; mutable level : bool (* true = J / high *)
  ; mutable se0 : bool
  ; mutable eop_left : int (* EOP bits still to start after the current one; -1 = not in EOP *)
  ; mutable ones : int
  ; mutable stuff_pending : bool
  ; mutable crc : int
  ; mutable period : int
  }

type t =
  { imem : int array
  ; mutable pc : int
  ; mutable out : int
  ; mutable oe : int
  ; mutable xo : int
  ; regs : int array (* r0..r3, sr, lc *)
  ; mutable to_ : int
  ; mutable z : bool
  ; mutable t_flag : bool
  ; mutable wait : wait_kind
  ; mutable prev_pins : int
  ; mutable live : bool
  ; mutable faulted : bool
  ; mutable cause : int
  ; mutable blame_pending : bool
  ; ser : ser
  ; tx : int Queue.t
  ; rx : int Queue.t
  }

let fresh_ser () =
  { busy = false; shift = 0; nbits = 0; msb = false; width = 8; crc_upd = false; timer = 0
  ; level = true; se0 = false; eop_left = -1; ones = 0; stuff_pending = false; crc = 0
  ; period = 0 }
;;

let create imem =
  { imem; pc = 0; out = 0; oe = 0; xo = 0; regs = Array.create ~len:6 0; to_ = 0; z = false
  ; t_flag = false; wait = No_wait; prev_pins = 0; live = false; faulted = false; cause = 0
  ; blame_pending = false; ser = fresh_ser (); tx = Queue.create (); rx = Queue.create () }
;;

let reset_exec t =
  t.pc <- 0; t.out <- 0; t.oe <- 0; t.xo <- 0;
  Array.fill t.regs ~pos:0 ~len:6 0;
  t.to_ <- 0; t.z <- false; t.t_flag <- false; t.wait <- No_wait; t.prev_pins <- 0;
  let s = t.ser and f = fresh_ser () in
  s.busy <- f.busy; s.shift <- 0; s.nbits <- 0; s.msb <- false; s.width <- 8; s.crc_upd <- false;
  s.timer <- 0; s.level <- true; s.se0 <- false; s.eop_left <- -1; s.ones <- 0;
  s.stuff_pending <- false; s.crc <- 0; s.period <- 0
;;

let bit v k = (v lsr k) land 1 = 1
let b2i b = if b then 1 else 0

(* ---- serializer ---- *)
let eff_period s = Int.max 1 s.period

(* the step in which the current bit is the last one and ends: ready for a new load *)
let ser_ready s =
  (not s.busy) || (s.timer = 1 && s.nbits = 0 && (not s.stuff_pending) && s.eop_left <= 0)
;;

(* start emitting one data bit b (with coding) *)
let emit_data_bit (i : inputs) s b =
  let nrzi = bit i.cfg 3 and stuff = bit i.cfg 4 and crc16 = bit i.cfg 6 in
  s.se0 <- false;
  s.level <- (if nrzi then (if b then s.level else not s.level) else b);
  if s.crc_upd
  then
    if crc16
    then (
      let fb = Bool.( <> ) b (bit s.crc 15) in
      s.crc <- ((s.crc lsl 1) land 0xFFFF) lxor (if fb then 0x8005 else 0))
    else (
      let fb = Bool.( <> ) b (bit s.crc 4) in
      s.crc <- ((s.crc lsl 1) land 0x1F) lxor (if fb then 0x05 else 0));
  if stuff
  then
    if b
    then (
      s.ones <- s.ones + 1;
      if s.ones = 6 then (s.stuff_pending <- true; s.ones <- 0))
    else s.ones <- 0;
  s.timer <- eff_period s
;;

let emit_stuff_bit (i : inputs) s =
  let nrzi = bit i.cfg 3 in
  s.se0 <- false;
  s.level <- (if nrzi then not s.level else false);
  s.stuff_pending <- false;
  s.ones <- 0;
  s.timer <- eff_period s
;;

let next_data_bit s =
  (* take the next bit from the shift register, consuming it *)
  let b =
    if s.msb then bit s.shift (s.width - 1) else bit s.shift 0
  in
  if s.msb
  then s.shift <- (s.shift lsl 1) land ((1 lsl s.width) - 1)
  else s.shift <- s.shift lsr 1;
  b
;;

let start_byte (i : inputs) s ~value ~width ~msb ~crc_upd =
  s.busy <- true;
  s.shift <- value;
  s.width <- width;
  s.msb <- msb;
  s.crc_upd <- crc_upd;
  s.eop_left <- -1;
  s.nbits <- width - 1;
  emit_data_bit i s (next_data_bit s)
;;

let start_eop s =
  s.busy <- true;
  s.eop_left <- 2; (* SE0 now; then SE0, J *)
  s.nbits <- 0;
  s.se0 <- true;
  s.timer <- eff_period s
;;

(* advance an active serializer by one step (called in running steps, before executing) *)
let ser_advance (i : inputs) s =
  if s.busy
  then
    if s.timer > 1
    then s.timer <- s.timer - 1
    else if s.stuff_pending
    then emit_stuff_bit i s
    else if s.nbits > 0
    then (
      s.nbits <- s.nbits - 1;
      emit_data_bit i s (next_data_bit s))
    else if s.eop_left > 0
    then (
      s.eop_left <- s.eop_left - 1;
      if s.eop_left = 0
      then (s.se0 <- false; s.level <- true) (* J *)
      else s.se0 <- true;
      s.timer <- eff_period s)
    else (
      (* finished *)
      if s.eop_left = 0 then (s.level <- true; s.ones <- 0);
      s.busy <- false;
      s.eop_left <- -1)
;;

(* ---- outputs ---- *)
let outputs t (i : inputs) ~pop ~push =
  let s = t.ser in
  let pair = bit i.cfg 1 in
  let ser_pin = i.cfg2 land 7 and pair_base = (i.cfg2 lsr 4) land 7 in
  let out_eff = ref t.out and oe_eff = ref t.oe in
  if s.busy
  then
    if pair
    then (
      let dp = (not s.se0) && not s.level and dm = (not s.se0) && s.level in
      let set k v =
        let k = k land 7 in
        out_eff := (!out_eff land lnot (1 lsl k)) lor (b2i v lsl k);
        oe_eff := !oe_eff lor (1 lsl k)
      in
      set pair_base dp;
      set (pair_base + 1) dm)
    else (
      let v = (not s.se0) && s.level in
      out_eff := (!out_eff land lnot (1 lsl ser_pin)) lor (b2i v lsl ser_pin);
      oe_eff := !oe_eff lor (1 lsl ser_pin));
  let live_mask = if t.live then i.own else 0 in
  (* push-pull pins: out/oe; open-drain pins: out = 0 pulls low, out = 1 releases (v1.0.2) *)
  let pp = live_mask land lnot i.od and odm = live_mask land i.od in
  { uio_out = !out_eff land pp
  ; uio_oe = (!oe_eff land pp) lor (lnot !out_eff land odm)
  ; xo = t.xo
  ; faulted = t.faulted
  ; cause = t.cause
  ; pc = t.pc
  ; tx_level = Queue.length t.tx
  ; rx_level = Queue.length t.rx
  ; rx_head = Option.value (Queue.peek t.rx) ~default:0
  ; pop_ev = Option.is_some pop
  ; pop_data = Option.value pop ~default:0
  ; push_ev = Option.is_some push
  ; push_data = Option.value push ~default:0
  }
;;

(* ---- one running step: returns (pop, push) data for stream events ---- *)
let reg_get t r = t.regs.(Isa1.reg_code r)
let reg_set t r v = t.regs.(Isa1.reg_code r) <- v land 0xFF

let exec_step t (i : inputs) =
  let s = t.ser in
  let pop = ref None and push = ref None in
  let ready = ser_ready s in
  ser_advance i s;
  let pc1 = (t.pc + 1) land 0xFF in
  let complete () = t.wait <- No_wait; t.pc <- pc1 in
  (* blocking helper: [cond] evaluated this step; [act] on success *)
  let block ~cond ~act =
    let finish ok = if ok then (act (); t.t_flag <- false) else t.t_flag <- true; complete () in
    match t.wait with
    | No_wait ->
      if cond then finish true else t.wait <- Block t.to_
    | Block n ->
      if cond then finish true
      else if n = 1 then finish false
      else if n > 1 then t.wait <- Block (n - 1)
    | Wait_n _ -> assert false
  in
  (match t.wait with
   | Wait_n n -> if n <= 1 then complete () else t.wait <- Wait_n (n - 1)
   | No_wait | Block _ ->
     if (match t.wait with No_wait -> true | _ -> false) && t.pc >= i.len
     then (t.faulted <- true; t.cause <- 1)
     else (
       let w = t.imem.(t.pc) in
       let op = (w lsr 12) land 0xF and arg = w land 0xFFF in
       let a8 = arg land 0xFF in
       let reg_of c = Isa1.reg_of_code c in
       match op with
       | 0x0 -> t.pc <- a8
       | 0x1 ->
         let c = (arg lsr 8) land 0xF in
         let taken =
           match c with
           | 0 -> true
           | 1 -> t.z
           | 2 -> not t.z
           | 3 -> t.t_flag
           | 4 -> not t.t_flag
           | 5 -> Queue.is_empty t.tx
           | 6 -> not (Queue.is_empty t.tx)
           | 7 -> Queue.length t.rx >= 8
           | 8 -> ready
           | 9 -> s.busy
           | 10 -> reg_get t Lc <> 0
           | _ -> false
         in
         t.pc <- (if taken then a8 else pc1)
       | 0x2 -> t.out <- a8; complete ()
       | 0x3 -> t.oe <- a8; complete ()
       | 0x4 ->
         let p = arg land 7 and a = (arg lsr 4) land 3 in
         let sr = reg_get t Sr in
         (match a with
          | 0 ->
            t.out <- (t.out land lnot (1 lsl p)) lor ((sr land 1) lsl p);
            reg_set t Sr (sr lsr 1)
          | 1 ->
            t.out <- (t.out land lnot (1 lsl p)) lor (((sr lsr 7) land 1) lsl p);
            reg_set t Sr (sr lsl 1)
          | 2 -> reg_set t Sr ((b2i (bit i.pins p) lsl 7) lor (sr lsr 1))
          | _ -> reg_set t Sr ((sr lsl 1) lor b2i (bit i.pins p)));
         complete ()
       | 0x5 ->
         (match t.wait with
          | No_wait -> if arg = 0 then complete () else t.wait <- Wait_n arg
          | _ -> ())
       | 0x6 ->
         let p = arg land 7 and c = (arg lsr 4) land 3 in
         let now = bit i.pins p and before = bit t.prev_pins p in
         let cond =
           match c with
           | 0 -> not now
           | 1 -> now
           | 2 -> now && not before
           | _ -> (not now) && before
         in
         block ~cond ~act:(fun () -> ())
       | 0x7 ->
         let d = (arg lsr 8) land 7 in
         (match d with
          | 6 -> t.to_ <- a8
          | 7 -> t.xo <- a8 land 3
          | _ -> reg_set t (Option.value_exn (reg_of d)) a8);
         complete ()
       | 0x8 ->
         let d = (arg lsr 8) land 7 and sc = (arg lsr 4) land 7 in
         let v =
           match sc with
           | 6 -> i.pins
           | 7 -> b2i s.busy
           | x -> (match reg_of x with Some r -> reg_get t r | None -> 0)
         in
         (match d with
          | 6 -> t.out <- v
          | 7 -> t.oe <- v
          | x -> (match reg_of x with Some r -> reg_set t r v | None -> ()));
         complete ()
       | 0x9 ->
         let sc = (arg lsr 8) land 7 in
         let v =
           match sc with
           | 6 -> i.pins
           | x -> (match reg_of x with Some r -> reg_get t r | None -> 0)
         in
         t.z <- v = a8;
         complete ()
       | 0xA ->
         (match reg_of ((arg lsr 8) land 7) with
          | Some r ->
            let v = (reg_get t r + a8) land 0xFF in
            reg_set t r v;
            t.z <- v = 0
          | None -> ());
         complete ()
       | 0xB ->
         let a = (arg lsr 10) land 3 and x = arg land 7 in
         let r = Option.value (reg_of x) ~default:Isa1.R0 in
         if a = 0
         then
           block ~cond:(not (Queue.is_empty t.tx)) ~act:(fun () ->
             let v = Queue.dequeue_exn t.tx in
             reg_set t r v;
             pop := Some v)
         else if a = 1
         then
           block ~cond:(Queue.length t.rx < 8) ~act:(fun () ->
             let v = reg_get t r in
             Queue.enqueue t.rx v;
             push := Some v)
         else complete ()
       | 0xC ->
         let a = (arg lsr 9) land 7 and x = arg land 7 in
         let r = Option.value (reg_of x) ~default:Isa1.R0 in
         let crc16 = bit i.cfg 6 and msb = bit i.cfg 2 and crc_en = bit i.cfg 5 in
         (match a with
          | 0 | 6 ->
            let v = reg_get t r in
            block ~cond:ready ~act:(fun () ->
              start_byte i s ~value:v ~width:8 ~msb ~crc_upd:(a = 6 && crc_en))
          | 1 -> s.crc <- (if crc16 then 0xFFFF else 0x1F); complete ()
          | 2 ->
            let w = if crc16 then 16 else 5 in
            let v = lnot s.crc land ((1 lsl w) - 1) in
            block ~cond:ready ~act:(fun () ->
              start_byte i s ~value:v ~width:w ~msb:true ~crc_upd:false)
          | 3 -> block ~cond:ready ~act:(fun () -> start_eop s)
          | 4 -> s.period <- reg_get t r; complete ()
          | 5 -> block ~cond:ready ~act:(fun () -> ())
          | _ -> complete ())
       | 0xD ->
         let lc = (reg_get t Lc - 1) land 0xFF in
         reg_set t Lc lc;
         t.pc <- (if lc <> 0 then a8 else pc1)
       | 0xE ->
         (match arg land 0xF with
          | 1 -> t.faulted <- true; t.cause <- 3
          | 2 -> t.t_flag <- false; complete ()
          | _ -> complete ())
       | _ -> complete ()));
  t.prev_pins <- i.pins;
  !pop, !push
;;

(* Fault handling (clarified): a fault raised in a step (FETCH_BOUND, HALT, BLAME) releases the
   lane immediately: execution state is reset and the lane is not live from the next cycle.
   Blame release: blame_in with cfg.release_on_blame is latched; the lane faults (cause BLAME)
   at its next step, instead of executing that step. *)
let step t (i : inputs) =
  if not i.rst_sync_n
  then (
    let o = outputs t i ~pop:None ~push:None in
    reset_exec t;
    t.live <- false;
    t.faulted <- false;
    t.cause <- 0;
    t.blame_pending <- false;
    Queue.clear t.tx;
    Queue.clear t.rx;
    o)
  else (
    let o0 = outputs t i ~pop:None ~push:None in
    let tx_level0 = Queue.length t.tx and rx_level0 = Queue.length t.rx in
    let release_on_blame = bit i.cfg 0 in
    let blame_now = t.blame_pending || (i.blame_in && release_on_blame) in
    let running = i.run && i.loaded && not t.faulted in
    let pop, push =
      if i.tick
      then
        if running && blame_now && not t.faulted
        then (
          t.faulted <- true;
          t.cause <- 2;
          t.blame_pending <- false;
          None, None)
        else if running
        then exec_step t i
        else None, None
      else None, None
    in
    (* v1.0.2: every non-running cycle (and a step that faults) resets the execution state *)
    if running && not t.faulted
    then (if i.tick then t.live <- true)
    else (
      reset_exec t;
      t.live <- false);
    (* blame latch: pending until consumed by a step *)
    if i.blame_in && release_on_blame && not (i.tick && running) then t.blame_pending <- true;
    (* host side of the FIFOs, using levels at the start of the cycle *)
    if i.tx_push && tx_level0 < 8 then Queue.enqueue t.tx (i.tx_wdata land 0xFF);
    if i.rx_pop && rx_level0 > 0 then ignore (Queue.dequeue_exn t.rx : int);
    if i.clear_fault && not (i.tick && running && t.faulted)
    then (
      t.faulted <- false;
      t.cause <- 0;
      t.blame_pending <- false);
    { o0 with
      pop_ev = Option.is_some pop
    ; pop_data = Option.value pop ~default:0
    ; push_ev = Option.is_some push
    ; push_data = Option.value push ~default:0
    })
;;
