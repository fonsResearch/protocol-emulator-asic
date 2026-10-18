(* One ISA v1 lane as a Hardcaml circuit (spec-as-circuit, S1 v1). Same semantics as
   [Lane_model], written independently as explicit next-state functions. Registers clear to 0
   on rst_sync_n = 0; the line level is stored inverted (lvl_n = 0 means J / high) so that the
   all-zero reset state is the architectural reset state. *)
open! Core
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_sync_n : 'a
    ; tick : 'a
    ; run : 'a
    ; loaded : 'a
    ; len : 'a [@bits 8]
    ; own : 'a [@bits 8]
    ; od : 'a [@bits 8]
    ; cfg : 'a [@bits 8]
    ; cfg2 : 'a [@bits 8]
    ; pins : 'a [@bits 8]
    ; tx_push : 'a
    ; tx_wdata : 'a [@bits 8]
    ; rx_pop : 'a
    ; blame_in : 'a
    ; clear_fault : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uio_out : 'a [@bits 8]
    ; uio_oe : 'a [@bits 8]
    ; xo : 'a [@bits 2]
    ; faulted : 'a
    ; cause : 'a [@bits 2]
    ; pc : 'a [@bits 8]
    ; tx_level : 'a [@bits 4]
    ; rx_level : 'a [@bits 4]
    ; rx_head : 'a [@bits 8]
    ; pop_ev : 'a
    ; pop_data : 'a [@bits 8]
    ; push_ev : 'a
    ; push_data : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

(* serializer state *)
type ser =
  { busy : Signal.t
  ; shift : Signal.t (* 16 *)
  ; nbits : Signal.t (* 5 *)
  ; msb : Signal.t
  ; width : Signal.t (* 5 *)
  ; crc_upd : Signal.t
  ; timer : Signal.t (* 8 *)
  ; lvl_n : Signal.t (* 0 = J/high *)
  ; se0 : Signal.t
  ; eop_mode : Signal.t
  ; eop_cnt : Signal.t (* 2 *)
  ; ones : Signal.t (* 3 *)
  ; stuffp : Signal.t
  ; crc : Signal.t (* 16 *)
  ; period : Signal.t (* 8 *)
  }

let ser_widths =
  [ 1; 16; 5; 1; 5; 1; 8; 1; 1; 1; 2; 3; 1; 16; 8 ]

let ser_to_list s =
  [ s.busy; s.shift; s.nbits; s.msb; s.width; s.crc_upd; s.timer; s.lvl_n; s.se0; s.eop_mode
  ; s.eop_cnt; s.ones; s.stuffp; s.crc; s.period ]
;;

let ser_of_list = function
  | [ busy; shift; nbits; msb; width; crc_upd; timer; lvl_n; se0; eop_mode; eop_cnt; ones
    ; stuffp; crc; period ] ->
    { busy; shift; nbits; msb; width; crc_upd; timer; lvl_n; se0; eop_mode; eop_cnt; ones
    ; stuffp; crc; period }
  | _ -> assert false
;;

let ser_mux2 c a b = ser_of_list (List.map2_exn (ser_to_list a) (ser_to_list b) ~f:(mux2 c))

let imem_rom (words : int array) pc =
  mux pc (List.init 256 ~f:(fun a -> of_int ~width:16 words.(a)))
;;

(* Internal signals of the most recently built lane, for proof harnesses that need them
   (formal/src/ag_pkg.ml symmetry lemma). Adds no logic unless a harness reads them. *)
let taps : (string * Signal.t) list ref = ref []

let create ~imem (i : _ I.t) =
  let spec = Reg_spec.create ~clock:i.clock ~clear:~:(i.rst_sync_n) () in
  let regw name w =
    let d = wire w in
    let q = reg spec d -- ("lane_" ^ name) in
    q, d
  in
  let pc, pc_d = regw "pc" 8 in
  let out, out_d = regw "out" 8 in
  let oe, oe_d = regw "oe" 8 in
  let xo, xo_d = regw "xo" 2 in
  let rs = List.init 6 ~f:(fun k -> regw (sprintf "r%d" k) 8) in
  let r k = fst (List.nth_exn rs k) in
  let to_, to_d = regw "to" 8 in
  let z, z_d = regw "z" 1 in
  let tf, tf_d = regw "t" 1 in
  let wkind, wkind_d = regw "wkind" 2 in (* 0 none, 1 wait, 2 block *)
  let wcnt, wcnt_d = regw "wcnt" 12 in
  let prevp, prevp_d = regw "prev_pins" 8 in
  let live, live_d = regw "live" 1 in
  let faulted, faulted_d = regw "faulted" 1 in
  let cause, cause_d = regw "cause" 2 in
  let bpend, bpend_d = regw "blame_pending" 1 in
  let ser_regs = List.mapi ser_widths ~f:(fun k w -> regw (sprintf "ser%d" k) w) in
  let s = ser_of_list (List.map ser_regs ~f:fst) in
  (* FIFOs: 8 x 8, head pointer and count *)
  let fifo name =
    let mem = List.init 8 ~f:(fun k -> regw (sprintf "%s_m%d" name k) 8) in
    let head, head_d = regw (name ^ "_head") 3 in
    let cnt, cnt_d = regw (name ^ "_cnt") 4 in
    mem, head, head_d, cnt, cnt_d
  in
  let txm, txh, txh_d, txc, txc_d = fifo "tx" in
  let rxm, rxh, rxh_d, rxc, rxc_d = fifo "rx" in
  let txhead_v = mux txh (List.map txm ~f:fst)
  and rxhead_v = mux rxh (List.map rxm ~f:fst) in
  (* ---- control ---- *)
  let cfgb k = bit i.cfg k in
  let rob = cfgb 0
  and pair = cfgb 1
  and msb_cfg = cfgb 2
  and nrzi = cfgb 3
  and stuff = cfgb 4
  and crc_en = cfgb 5
  and crc16 = cfgb 6 in
  (* under reset nothing executes; registers clear via the synchronous clear *)
  let running = i.rst_sync_n &: i.run &: i.loaded &: ~:faulted in
  let blame_now = bpend |: (i.blame_in &: rob) in
  let step_blame = i.tick &: running &: blame_now in
  let exec = i.tick &: running &: ~:blame_now in
  (* ---- serializer helpers ---- *)
  let eff_period = mux2 (s.period ==:. 0) (of_int ~width:8 1) s.period in
  let ser_ready =
    ~:(s.busy)
    |: (s.timer ==:. 1 &: (s.nbits ==:. 0) &: ~:(s.stuffp) &: ~:(s.eop_mode &: (s.eop_cnt <>:. 0)))
  in
  let take_bit (x : ser) =
    let w = x.width in
    let top = mux (w -:. 1) (bits_lsb x.shift) in
    let b = mux2 x.msb top (lsb x.shift) in
    let mask = mux w (List.init 17 ~f:(fun k -> of_int ~width:16 ((1 lsl k) - 1))) in
    let shifted = mux2 x.msb (sll x.shift 1 &: mask) (srl x.shift 1) in
    b, { x with shift = shifted }
  in
  let emit_data (x : ser) b =
    let lvl = ~:(x.lvl_n) in
    let new_lvl = mux2 nrzi (mux2 b lvl ~:lvl) b in
    let crc16_n =
      let fb = b ^: bit x.crc 15 in
      sll x.crc 1 ^: mux2 fb (of_int ~width:16 0x8005) (zero 16)
    in
    let crc5_n =
      let fb = b ^: bit x.crc 4 in
      uresize (select (sll x.crc 1) 4 0 ^: mux2 fb (of_int ~width:5 0x05) (zero 5)) 16
    in
    let crc' = mux2 x.crc_upd (mux2 crc16 crc16_n crc5_n) x.crc in
    let ones_inc = x.ones +:. 1 in
    let six = ones_inc ==:. 6 in
    let ones' = mux2 stuff (mux2 b (mux2 six (zero 3) ones_inc) (zero 3)) x.ones in
    let stuffp' = mux2 (stuff &: b &: six) vdd x.stuffp in
    { x with se0 = gnd; lvl_n = ~:new_lvl; crc = crc'; ones = ones'; stuffp = stuffp'; timer = eff_period }
  in
  let emit_stuff (x : ser) =
    let lvl = ~:(x.lvl_n) in
    let new_lvl = mux2 nrzi ~:lvl gnd in
    { x with se0 = gnd; lvl_n = ~:new_lvl; stuffp = gnd; ones = zero 3; timer = eff_period }
  in
  let advance (x : ser) =
    let dec = { x with timer = x.timer -:. 1 } in
    let st = emit_stuff x in
    let b, x' = take_bit x in
    let nd = emit_data { x' with nbits = x.nbits -:. 1 } b in
    let eop_step =
      let cnt' = x.eop_cnt -:. 1 in
      let last = cnt' ==:. 0 in
      { x with eop_cnt = cnt'; se0 = ~:last; lvl_n = mux2 last gnd x.lvl_n; timer = eff_period }
    in
    let finish =
      let was_eop0 = x.eop_mode &: (x.eop_cnt ==:. 0) in
      { x with
        busy = gnd
      ; eop_mode = gnd
      ; lvl_n = mux2 was_eop0 gnd x.lvl_n
      ; ones = mux2 was_eop0 (zero 3) x.ones
      }
    in
    let at_end = x.timer <=:. 1 in
    let r =
      ser_mux2 (x.nbits <>:. 0) nd (ser_mux2 (x.eop_mode &: (x.eop_cnt <>:. 0)) eop_step finish)
    in
    let r = ser_mux2 x.stuffp st r in
    ser_mux2 x.busy (ser_mux2 at_end r dec) x
  in
  (* ---- instruction decode ---- *)
  let w = imem pc in
  let op = select w 15 12
  and arg = select w 11 0 in
  let a8 = select arg 7 0 in
  let pc1 = pc +:. 1 in
  let in_wait = wkind ==:. 1
  and in_block = wkind ==:. 2 in
  let fetch_bound = (wkind ==:. 0) &: (pc >=: i.len) in
  let is o = op ==:. o in
  let regsel c = mux c (List.init 8 ~f:(fun k -> if k < 6 then r k else zero 8)) in
  let tx_empty = txc ==:. 0
  and rx_full = rxc >=:. 8 in
  (* blocking condition per instruction *)
  let pin_p = select arg 2 0 in
  let pin_now = mux pin_p (bits_lsb i.pins)
  and pin_before = mux pin_p (bits_lsb prevp) in
  let wtp_c = select arg 5 4 in
  let wtp_cond = mux wtp_c [ ~:pin_now; pin_now; pin_now &: ~:pin_before; ~:pin_now &: pin_before ] in
  let fifo_a = select arg 11 10 in
  let ser_a = select arg 11 9 in
  (* POP/PUSH/SER register operand: codes 6, 7 select r0 (as Isa1.reg_of_code default) *)
  let xsel = select arg 2 0 in
  let xsel0 = mux2 (xsel >=:. 6) (zero 3) xsel in
  let x_reg = regsel xsel0 in
  let is_block_op =
    is 0x6
    |: (is 0xB &: (fifo_a <=:. 1))
    |: (is 0xC &: ((ser_a ==:. 0) |: (ser_a ==:. 2) |: (ser_a ==:. 3) |: (ser_a ==:. 5) |: (ser_a ==:. 6)))
  in
  let block_cond =
    mux2 (is 0x6) wtp_cond
    @@ mux2 (is 0xB) (mux2 (fifo_a ==:. 0) ~:tx_empty ~:rx_full)
    @@ ser_ready
  in
  (* outcome of a blocking op this step *)
  let blk_ok = block_cond
  and blk_timeout = ~:block_cond &: in_block &: (wcnt ==:. 1) in
  let blk_done = blk_ok |: blk_timeout in
  let wait_done = in_wait &: (wcnt <=:. 1) in
  (* ---- serializer next state in an exec step ---- *)
  let adv = advance s in
  let ser_send = is 0xC &: ((ser_a ==:. 0) |: (ser_a ==:. 6)) &: blk_ok
  and ser_crcs = is 0xC &: (ser_a ==:. 2) &: blk_ok
  and ser_eop = is 0xC &: (ser_a ==:. 3) &: blk_ok
  and ser_crci = is 0xC &: (ser_a ==:. 1)
  and ser_period = is 0xC &: (ser_a ==:. 4) in
  let normal = ~:in_wait &: ~:fetch_bound in
  let sent =
    let v8 = uresize x_reg 16 in
    let x =
      { adv with
        busy = vdd
      ; shift = v8
      ; width = of_int ~width:5 8
      ; msb = msb_cfg
      ; crc_upd = (ser_a ==:. 6) &: crc_en
      ; eop_mode = gnd
      ; nbits = of_int ~width:5 7
      }
    in
    let b, x' = take_bit x in
    emit_data x' b
  in
  let crcs =
    let wd = mux2 crc16 (of_int ~width:5 16) (of_int ~width:5 5) in
    let mask = mux2 crc16 (of_int ~width:16 0xFFFF) (of_int ~width:16 0x1F) in
    let x =
      { adv with
        busy = vdd
      ; shift = ~:(adv.crc) &: mask
      ; width = wd
      ; msb = vdd
      ; crc_upd = gnd
      ; eop_mode = gnd
      ; nbits = wd -:. 1
      }
    in
    let b, x' = take_bit x in
    emit_data x' b
  in
  let eop =
    { adv with busy = vdd; eop_mode = vdd; eop_cnt = of_int ~width:2 2; nbits = zero 5; se0 = vdd; timer = eff_period }
  in
  let ser_exec =
    let x = adv in
    let x = ser_mux2 (normal &: ser_send) sent x in
    let x = ser_mux2 (normal &: ser_crcs) crcs x in
    let x = ser_mux2 (normal &: ser_eop) eop x in
    let x = { x with crc = mux2 (normal &: ser_crci) (mux2 crc16 (of_int ~width:16 0xFFFF) (of_int ~width:16 0x1F)) x.crc } in
    { x with period = mux2 (normal &: ser_period) x_reg x.period }
  in
  let ser_reset = ser_of_list (List.map ser_widths ~f:zero) in
  (* ---- architectural effects of a normal (not waiting, not fetch-bound) instruction ---- *)
  let br_cond =
    mux (select arg 11 8)
      [ vdd; z; ~:z; tf; ~:tf; tx_empty; ~:tx_empty; rx_full; ser_ready; adv.busy; r 5 <>:. 0
      ; gnd; gnd; gnd; gnd; gnd ]
  in
  let sr = r 4 in
  let pin_a = select arg 5 4 in
  let pmask = binary_to_onehot pin_p in
  let out_pin v = (out &: ~:pmask) |: mux2 v pmask (zero 8) in
  let lc_dec = r 5 -:. 1 in
  let mov_src =
    mux (select arg 6 4)
      [ r 0; r 1; r 2; r 3; r 4; r 5; i.pins; uresize adv.busy 8 ]
  in
  let cmp_src = mux (select arg 10 8) [ r 0; r 1; r 2; r 3; r 4; r 5; i.pins; zero 8 ] in
  let addi_sum = regsel (select arg 10 8) +: a8 in
  let d3 = select arg 10 8 in
  (* next pc *)
  let block_next = mux2 blk_done pc1 pc in
  let pc_normal =
    mux op
      [ a8; mux2 br_cond a8 pc1; pc1; pc1; pc1
      ; mux2 (arg ==:. 0) pc1 pc (* WAIT: completes now only if k = 0 *)
      ; block_next; pc1; pc1; pc1; pc1
      ; mux2 is_block_op block_next pc1
      ; mux2 is_block_op block_next pc1
      ; mux2 (lc_dec <>:. 0) a8 pc1
      ; mux2 (select arg 3 0 ==:. 1) pc pc1
      ; pc1 ]
  in
  let pc_exec = mux2 in_wait (mux2 wait_done pc1 pc) pc_normal in
  (* wait state *)
  let enter_wait = normal &: is 0x5 &: (arg <>:. 0) in
  let enter_block = normal &: is_block_op &: ~:blk_ok &: (wkind ==:. 0) in
  let wkind_exec =
    mux2 in_wait (mux2 wait_done (zero 2) (of_int ~width:2 1))
    @@ mux2 enter_wait (of_int ~width:2 1)
    @@ mux2 enter_block (of_int ~width:2 2)
    @@ mux2 (in_block &: blk_done) (zero 2) wkind
  in
  let wcnt_exec =
    mux2 in_wait (wcnt -:. 1)
    @@ mux2 enter_wait arg
    @@ mux2 enter_block (uresize to_ 12)
    @@ mux2 (in_block &: ~:blk_done &: (wcnt >:. 1)) (wcnt -:. 1) wcnt
  in
  let t_exec =
    mux2 (normal &: is_block_op &: blk_done) blk_timeout
    @@ mux2 (normal &: is 0xE &: (select arg 3 0 ==:. 2)) gnd tf
  in
  let z_exec =
    mux2 (normal &: is 0x9) (cmp_src ==: a8)
    @@ mux2 (normal &: is 0xA &: (d3 <:. 6)) (addi_sum ==:. 0) z
  in
  let out_exec =
    mux2 (normal &: is 0x2) a8
    @@ mux2 (normal &: is 0x4 &: (pin_a ==:. 0)) (out_pin (lsb sr))
    @@ mux2 (normal &: is 0x4 &: (pin_a ==:. 1)) (out_pin (msb sr))
    @@ mux2 (normal &: is 0x8 &: (d3 ==:. 6)) mov_src out
  in
  let oe_exec =
    mux2 (normal &: is 0x3) a8 @@ mux2 (normal &: is 0x8 &: (d3 ==:. 7)) mov_src oe
  in
  let xo_exec = mux2 (normal &: is 0x7 &: (d3 ==:. 7)) (select a8 1 0) xo in
  let to_exec = mux2 (normal &: is 0x7 &: (d3 ==:. 6)) a8 to_ in
  let pop_now = normal &: is 0xB &: (fifo_a ==:. 0) &: blk_ok
  and push_now = normal &: is 0xB &: (fifo_a ==:. 1) &: blk_ok in
  let reg_exec k =
    let rk = r k in
    let kk = of_int ~width:3 k in
    let x = rk in
    let x = mux2 (normal &: is 0x7 &: (d3 ==: kk)) a8 x in
    let x = mux2 (normal &: is 0x8 &: (d3 ==: kk)) mov_src x in
    let x = mux2 (normal &: is 0xA &: (d3 ==: kk)) addi_sum x in
    let x = mux2 (pop_now &: (xsel0 ==: kk)) txhead_v x in
    let x =
      if k = 4
      then
        x
        |> mux2 (normal &: is 0x4 &: (pin_a ==:. 0)) (srl sr 1)
        |> mux2 (normal &: is 0x4 &: (pin_a ==:. 1)) (sll sr 1)
        |> mux2 (normal &: is 0x4 &: (pin_a ==:. 2)) (pin_now @: select sr 7 1)
        |> mux2 (normal &: is 0x4 &: (pin_a ==:. 3)) (select sr 6 0 @: pin_now)
      else x
    in
    let x = if k = 5 then mux2 (normal &: is 0xD) lc_dec x else x in
    x
  in
  let halt_now = normal &: is 0xE &: (select arg 3 0 ==:. 1) in
  let fault_now = exec &: (fetch_bound |: halt_now) in
  let cause_now = mux2 fetch_bound (of_int ~width:2 1) (of_int ~width:2 3) in
  (* ---- assemble next state ---- *)
  (* v1.0.2: reset in every non-running cycle, and at the end of a step that faults *)
  let step_reset = ~:running |: step_blame |: fault_now in
  taps := ("step_reset", step_reset) :: ("exec", exec) :: !taps;
  let hold_or v_exec v_reset v =
    mux2 step_reset v_reset (mux2 exec v_exec v)
  in
  pc_d <== hold_or pc_exec (zero 8) pc;
  out_d <== hold_or out_exec (zero 8) out;
  oe_d <== hold_or oe_exec (zero 8) oe;
  xo_d <== hold_or xo_exec (zero 2) xo;
  List.iteri rs ~f:(fun k (q, d) -> d <== hold_or (reg_exec k) (zero 8) q);
  to_d <== hold_or to_exec (zero 8) to_;
  z_d <== hold_or z_exec gnd z;
  tf_d <== hold_or t_exec gnd tf;
  wkind_d <== hold_or wkind_exec (zero 2) wkind;
  wcnt_d <== hold_or wcnt_exec (zero 12) wcnt;
  prevp_d <== hold_or i.pins (zero 8) prevp;
  List.iteri ser_regs ~f:(fun k (q, d) ->
    d <== hold_or (List.nth_exn (ser_to_list ser_exec) k) (List.nth_exn (ser_to_list ser_reset) k) q);
  live_d <== mux2 step_reset gnd (mux2 i.tick vdd live);
  let new_fault = step_blame |: fault_now in
  let new_cause = mux2 step_blame (of_int ~width:2 2) cause_now in
  let clear = i.clear_fault &: ~:new_fault in
  faulted_d <== mux2 new_fault vdd (mux2 clear gnd faulted);
  cause_d <== mux2 new_fault new_cause (mux2 clear (zero 2) cause);
  bpend_d
  <== mux2 (i.tick &: running) gnd
      @@ mux2 clear gnd
      @@ mux2 (i.blame_in &: rob) vdd bpend;
  (* ---- FIFOs (levels at the start of the cycle) ---- *)
  let pop_now = pop_now &: exec
  and push_now = push_now &: exec in
  let tx_do_push = i.tx_push &: (txc <:. 8) in
  let tx_tail = txh +: select txc 2 0 in
  List.iteri txm ~f:(fun k (q, d) ->
    d <== mux2 (tx_do_push &: (tx_tail ==:. k)) i.tx_wdata q);
  txh_d <== mux2 pop_now (txh +:. 1) txh;
  txc_d <== txc +: uresize tx_do_push 4 -: uresize pop_now 4;
  let rx_do_pop = i.rx_pop &: (rxc >:. 0) in
  let rx_tail = rxh +: select rxc 2 0 in
  let push_data = x_reg in
  List.iteri rxm ~f:(fun k (q, d) ->
    d <== mux2 (push_now &: (rx_tail ==:. k)) push_data q);
  rxh_d <== mux2 rx_do_pop (rxh +:. 1) rxh;
  rxc_d <== rxc +: uresize push_now 4 -: uresize rx_do_pop 4;
  (* ---- pin outputs from the current state ---- *)
  let ser_pin = select i.cfg2 2 0
  and pair_base = select i.cfg2 6 4 in
  let lvl = ~:(s.lvl_n) in
  let ser_v = ~:(s.se0) &: lvl in
  let dp = ~:(s.se0) &: ~:lvl
  and dm = ~:(s.se0) &: lvl in
  let oh p = binary_to_onehot p in
  let set_bit vec p v = (vec &: ~:(oh p)) |: mux2 v (oh p) (zero 8) in
  let out_np = set_bit out ser_pin ser_v
  and oe_np = oe |: oh ser_pin in
  let out_pr = set_bit (set_bit out pair_base dp) (pair_base +:. 1) dm
  and oe_pr = oe |: oh pair_base |: oh (pair_base +:. 1) in
  let out_eff = mux2 s.busy (mux2 pair out_pr out_np) out
  and oe_eff = mux2 s.busy (mux2 pair oe_pr oe_np) oe in
  let lm = mux2 live i.own (zero 8) in
  let pp = lm &: ~:(i.od)
  and odm = lm &: i.od in
  { O.uio_out = out_eff &: pp
  ; uio_oe = (oe_eff &: pp) |: (~:out_eff &: odm)
  ; xo
  ; faulted
  ; cause
  ; pc
  ; tx_level = txc
  ; rx_level = rxc
  ; rx_head = mux2 (rxc ==:. 0) (zero 8) rxhead_v
  ; pop_ev = pop_now
  ; pop_data = mux2 pop_now txhead_v (zero 8)
  ; push_ev = push_now
  ; push_data = mux2 push_now push_data (zero 8)
  }
;;
