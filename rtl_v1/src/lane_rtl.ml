(* Driver lane RTL, ISA v1 (doc/isa/isa_v1.md incl. sections 10, 11) and interface v1.

   Fetch: next-pc addressing of the 256x16 SRAM (user decision, v1.0.2). [next_pc] is the value
   [pc] takes at the end of the cycle; it is the SRAM address, so A_DOUT during the next cycle is
   imem[pc]. A_DOUT is the executing instruction.
   Instruction-memory writes (program load) are accepted only when the lane was not running in
   this cycle nor in the previous one ([imem_wack]); since a non-running lane has pc = 0
   (v1.0.2), every accepted write happens while A_DOUT holds imem[0], and the port does
   write-through exactly when the written address is the fetch address. Hence A_DOUT = imem[pc]
   in every cycle after the first reset cycle (proved by the lane A1, formal/src/a1_lane.ml).

   Reset: rst_sync_n is a synchronous clear of every register except the SRAM words and A_DOUT.
   No asynchronous set or reset; single clock domain; asynchronous pins enter through the
   interface synchronisers outside this module. *)
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
    ; imem_we : 'a
    ; imem_waddr : 'a [@bits 8]
    ; imem_wdata : 'a [@bits 16]
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
    ; imem_wack : 'a
    }
  [@@deriving hardcaml]
end

(* ---- byte FIFO, depth 8: push accepted iff level < 8, pop iff level > 0 (start of cycle) ---- *)
module Fifo = struct
  type t =
    { level : Signal.t
    ; head : Signal.t
    }

  let create ~spec ~name ~push ~push_data ~pop =
    let open Always in
    let wp = Variable.reg spec ~width:3
    and rp = Variable.reg spec ~width:3
    and lvl = Variable.reg spec ~width:4 in
    let mem = Array.init 8 ~f:(fun _ -> Variable.reg spec ~width:8) in
    let do_push = push &: (lvl.value <:. 8)
    and do_pop = pop &: (lvl.value <>:. 0) in
    compile
      [ when_
          do_push
          [ switch wp.value (List.init 8 ~f:(fun k -> of_int ~width:3 k, [ mem.(k) <-- push_data ]))
          ; wp <-- wp.value +:. 1
          ]
      ; when_ do_pop [ rp <-- rp.value +:. 1 ]
      ; lvl <-- lvl.value +: uresize do_push 4 -: uresize do_pop 4
      ];
    let head = mux rp.value (Array.to_list mem |> List.map ~f:(fun v -> v.value)) in
    { level = lvl.value -- (name ^ "_level"); head = head -- (name ^ "_head") }
  ;;
end

(* ---- serializer ---- *)
module Ser = struct
  type cmd =
    { adv : Signal.t (* executing step: advance the current bit *)
    ; clr : Signal.t (* lane reset (non-running cycle or faulting step) *)
    ; ld_byte : Signal.t
    ; ld_crc : Signal.t
    ; ld_eop : Signal.t
    ; crci : Signal.t
    ; set_period : Signal.t
    ; value : Signal.t (* 8 *)
    ; crc_upd : Signal.t
    }

  type t =
    { busy : Signal.t
    ; ready : Signal.t (* before this step's advance *)
    ; busy_after : Signal.t (* after this step's advance (ser_status, BR 9) *)
    ; se0 : Signal.t
    ; lvl : Signal.t (* 1 = J / high *)
    }

  let create ~spec ~cfg (c : cmd) =
    let open Always in
    let msb_cfg = bit cfg 2
    and nrzi = bit cfg 3
    and stuff = bit cfg 4
    and crc16 = bit cfg 6 in
    let r w = Variable.reg spec ~width:w in
    let busy = r 1
    and sh = r 16
    and cnt = r 5
    and msbf = r 1
    and crcu = r 1
    and tmr = r 8
    and lvl_n = r 1
    and se0 = r 1
    and ph = r 2 (* EOP phase: 0 none, 1 first SE0, 2 second SE0, 3 J *)
    and ones = r 3
    and stp = r 1
    and crc = r 16
    and per = r 8 in
    let eff_per = mux2 (per.value ==:. 0) (one 8) per.value in
    let ready =
      ~:(busy.value)
      |: (tmr.value ==:. 1
          &: (cnt.value ==:. 0)
          &: ~:(stp.value)
          &: ((ph.value ==:. 0) |: (ph.value ==:. 3)))
    in
    let crc_step crc_v b =
      let c16 = sll crc_v 1 ^: mux2 (b ^: bit crc_v 15) (of_int ~width:16 0x8005) (zero 16) in
      let c5 =
        uresize ((select crc_v 3 0 @: gnd) ^: mux2 (b ^: bit crc_v 4) (of_int ~width:5 0x05) (zero 5)) 16
      in
      mux2 crc16 c16 c5
    in
    (* start a data bit [b] from line level [lv] and ones count [on] *)
    let emit ~lv ~on ~upd b =
      let ones_inc = on +:. 1 in
      let six = stuff &: b &: (ones_inc ==:. 6) in
      [ lvl_n <-- ~:(mux2 nrzi (mux2 b lv ~:lv) b)
      ; se0 <-- gnd
      ; when_ upd [ crc <-- crc_step crc.value b ]
      ; when_ stuff [ ones <-- mux2 (b &: ~:six) ones_inc (zero 3) ]
      ; when_ six [ stp <-- vdd ]
      ; tmr <-- eff_per
      ]
    in
    let lvl = ~:(lvl_n.value) in
    (* state after this step's advance when the serializer is ready (finishing step) *)
    let fin_eop = busy.value &: (ph.value ==:. 3) in
    let base_lvl = lvl |: fin_eop
    and base_ones = mux2 fin_eop (zero 3) ones.value in
    let next_bit = mux2 msbf.value (msb sh.value) (lsb sh.value) in
    let shifted = mux2 msbf.value (sll sh.value 1) (srl sh.value 1) in
    let advance =
      [ when_
          busy.value
          [ if_
              (tmr.value >:. 1)
              [ tmr <-- tmr.value -:. 1 ]
            @@ elif
                 stp.value
                 [ lvl_n <-- ~:(mux2 nrzi ~:lvl gnd)
                 ; se0 <-- gnd
                 ; stp <-- gnd
                 ; ones <-- zero 3
                 ; tmr <-- eff_per
                 ]
            @@ elif
                 (cnt.value <>:. 0)
                 ([ sh <-- shifted; cnt <-- cnt.value -:. 1 ]
                  @ emit ~lv:lvl ~on:ones.value ~upd:crcu.value next_bit)
            @@ elif (ph.value ==:. 1) [ ph <-- of_int ~width:2 2; tmr <-- eff_per ]
            @@ elif
                 (ph.value ==:. 2)
                 [ ph <-- of_int ~width:2 3; se0 <-- gnd; lvl_n <-- gnd; tmr <-- eff_per ]
                 [ busy <-- gnd
                 ; ph <-- zero 2
                 ; when_ (ph.value ==:. 3) [ lvl_n <-- gnd; ones <-- zero 3 ]
                 ]
          ]
      ]
    in
    (* loading a new item (only when ready): first bit starts now *)
    let load ~sh0 ~cnt0 ~msb0 ~upd0 =
      let b = mux2 msb0 (msb sh0) (lsb sh0) in
      let sh1 = mux2 msb0 (sll sh0 1) (srl sh0 1) in
      [ busy <-- vdd
      ; ph <-- zero 2
      ; sh <-- sh1
      ; cnt <-- cnt0
      ; msbf <-- msb0
      ; crcu <-- upd0
      ]
      @ emit ~lv:base_lvl ~on:base_ones ~upd:upd0 b
    in
    let byte_sh = mux2 msb_cfg (c.value @: zero 8) (uresize c.value 16) in
    let crc_sh = mux2 crc16 ~:(crc.value) (~:(select crc.value 4 0) @: zero 11) in
    compile
      [ if_
          c.clr
          [ busy <-- gnd; sh <-- zero 16; cnt <-- zero 5; msbf <-- gnd; crcu <-- gnd
          ; tmr <-- zero 8; lvl_n <-- gnd; se0 <-- gnd; ph <-- zero 2; ones <-- zero 3
          ; stp <-- gnd; crc <-- zero 16; per <-- zero 8 ]
          [ when_ c.adv advance
          ; when_
              c.ld_byte
              (load ~sh0:byte_sh ~cnt0:(of_int ~width:5 7) ~msb0:msb_cfg ~upd0:c.crc_upd)
          ; when_
              c.ld_crc
              (load
                 ~sh0:crc_sh
                 ~cnt0:(mux2 crc16 (of_int ~width:5 15) (of_int ~width:5 4))
                 ~msb0:vdd
                 ~upd0:gnd)
          ; when_
              c.ld_eop
              [ busy <-- vdd; ph <-- one 2; cnt <-- zero 5; se0 <-- vdd; tmr <-- eff_per
              ; lvl_n <-- ~:base_lvl; ones <-- base_ones ]
          ; when_ c.crci [ crc <-- mux2 crc16 (Signal.ones 16) (of_int ~width:16 0x1F) ]
          ; when_ c.set_period [ per <-- c.value ]
          ]
      ];
    (* busy after the advance: a ready, busy serializer finishes in this step *)
    let busy_after = busy.value &: ~:ready in
    { busy = busy.value; ready; busy_after; se0 = se0.value; lvl }
  ;;
end

type sram = Signal.t Sram256.I.t -> Signal.t Sram256.O.t

(* [bug] plants a known defect, for formal negative controls only (default: none). *)
type bug =
  [ `No_prev_running_gate (* accept writes in the first non-running cycle *)
  | `No_write_through (* never read during a write *)
  | `Timeout_early (* blocking timeout one step early *)
  ]

let create ?(bug : bug option) ~(sram : sram) (i : _ I.t) =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock ~clear:~:(i.rst_sync_n) () in
  let r w = Variable.reg spec ~width:w in
  let pc = r 8
  and out = r 8
  and oe = r 8
  and xo = r 2
  and to_ = r 8
  and z = r 1
  and tf = r 1
  and mode = r 2 (* 0 none, 1 WAIT, 2 blocking *)
  and wcnt = r 12
  and prevp = r 8
  and live = r 1
  and faulted = r 1
  and cause = r 2
  and bpend = r 1
  and was_running = r 1 in
  let regs = Array.init 6 ~f:(fun _ -> r 8) in
  let rv k = regs.(k).value in
  (* ---- run control ---- *)
  let running = i.rst_sync_n &: i.run &: i.loaded &: ~:(faulted.value) -- "lane_running" in
  let rob = bit i.cfg 0 in
  let blame_now = bpend.value |: (i.blame_in &: rob) in
  let step = i.tick &: running in
  let step_blame = step &: blame_now in
  let exec = step &: ~:blame_now in
  (* ---- fetch ---- *)
  let next_pc = Variable.wire ~default:pc.value in
  let prev_gate =
    match bug with
    | Some `No_prev_running_gate -> vdd
    | _ -> ~:(was_running.value)
  in
  let wack = i.imem_we &: i.rst_sync_n &: ~:running &: prev_gate -- "imem_wack" in
  let sram_o =
    sram
      (Sram256.tie
         ~clock:i.clock
         ~wen:wack
         ~ren:
           (match bug with
            | Some `No_write_through -> ~:wack
            | _ -> ~:wack |: (i.imem_waddr ==: next_pc.value))
         ~addr:(mux2 wack i.imem_waddr next_pc.value)
         ~din:i.imem_wdata)
  in
  (* not renamed: the SRAM output register keeps its name (formal free-init check) *)
  let ir = sram_o.a_dout in
  let op = select ir 15 12
  and arg = select ir 11 0 in
  let a8 = select arg 7 0
  and d3 = select arg 10 8 in
  let pc1 = pc.value +:. 1 in
  let fetch_bound = (mode.value ==:. 0) &: (pc.value >=: i.len) in
  let normal = exec &: (mode.value <>:. 1) &: ~:fetch_bound in
  let halt_now = normal &: (op ==:. 0xE) &: (select arg 3 0 ==:. 1) in
  let fault_now = exec &: fetch_bound |: halt_now in
  let lane_reset = ~:running |: step_blame |: fault_now in
  (* ---- FIFOs and serializer command wires ---- *)
  let w1 () = Variable.wire ~default:gnd in
  let tx_pop = w1 ()
  and rx_push = w1 ()
  and ld_byte = w1 ()
  and ld_crc = w1 ()
  and ld_eop = w1 ()
  and crci = w1 ()
  and set_period = w1 ()
  and crc_upd = w1 () in
  let xsel = select arg 2 0 in
  let xsel0 = mux2 (xsel >=:. 6) (zero 3) xsel in
  let reg_read code = mux code (List.init 8 ~f:(fun k -> if k < 6 then rv k else zero 8)) in
  let x_val = reg_read xsel0 in
  let tx =
    Fifo.create ~spec ~name:"txf" ~push:i.tx_push ~push_data:i.tx_wdata ~pop:tx_pop.value
  in
  let rx = Fifo.create ~spec ~name:"rxf" ~push:rx_push.value ~push_data:x_val ~pop:i.rx_pop in
  let ser =
    Ser.create
      ~spec
      ~cfg:i.cfg
      { Ser.adv = exec
      ; clr = lane_reset
      ; ld_byte = ld_byte.value
      ; ld_crc = ld_crc.value
      ; ld_eop = ld_eop.value
      ; crci = crci.value
      ; set_period = set_period.value
      ; value = x_val
      ; crc_upd = crc_upd.value
      }
  in
  (* ---- instruction semantics ---- *)
  let write_reg code v =
    switch code (List.init 6 ~f:(fun k -> of_int ~width:3 k, [ regs.(k) <-- v ]))
  in
  let set_pin vec p v =
    let m = binary_to_onehot p in
    (vec &: ~:m) |: mux2 v m (zero 8)
  in
  let pin_p = select arg 2 0 in
  let pin_now = mux pin_p (bits_lsb i.pins)
  and pin_before = mux pin_p (bits_lsb prevp.value) in
  let advance_pc = [ next_pc <-- pc1 ] in
  (* blocking instruction: [cond] this step, [act] on success *)
  let blocking cond act =
    [ if_
        cond
        (act @ [ tf <-- gnd; mode <-- zero 2; next_pc <-- pc1 ])
        [ if_
            (mode.value ==:. 0)
            [ mode <-- of_int ~width:2 2; wcnt <-- uresize to_.value 12 ]
            [ if_
                (wcnt.value ==:. match bug with Some `Timeout_early -> 2 | _ -> 1)
                [ tf <-- vdd; mode <-- zero 2; next_pc <-- pc1 ]
                [ when_ (wcnt.value >:. 1) [ wcnt <-- wcnt.value -:. 1 ] ]
            ]
        ]
    ]
  in
  let br_cond =
    mux
      (select arg 11 8)
      [ vdd; z.value; ~:(z.value); tf.value; ~:(tf.value); tx.level ==:. 0; tx.level <>:. 0
      ; rx.level >=:. 8; ser.ready; ser.busy_after; rv 5 <>:. 0; gnd ]
  in
  let mov_src =
    mux (select arg 6 4) [ rv 0; rv 1; rv 2; rv 3; rv 4; rv 5; i.pins; uresize ser.busy_after 8 ]
  in
  let cmp_src = mux d3 [ rv 0; rv 1; rv 2; rv 3; rv 4; rv 5; i.pins; zero 8 ] in
  let addi_sum = reg_read d3 +: a8 in
  let sr = rv 4 in
  let instr =
    switch
      op
      [ of_int ~width:4 0x0, [ next_pc <-- a8 ]
      ; of_int ~width:4 0x1, [ next_pc <-- mux2 br_cond a8 pc1 ]
      ; of_int ~width:4 0x2, [ out <-- a8 ] @ advance_pc
      ; of_int ~width:4 0x3, [ oe <-- a8 ] @ advance_pc
      ; ( of_int ~width:4 0x4
        , advance_pc
          @ [ switch
                (select arg 5 4)
                [ of_int ~width:2 0, [ out <-- set_pin out.value pin_p (lsb sr); regs.(4) <-- srl sr 1 ]
                ; of_int ~width:2 1, [ out <-- set_pin out.value pin_p (msb sr); regs.(4) <-- sll sr 1 ]
                ; of_int ~width:2 2, [ regs.(4) <-- pin_now @: select sr 7 1 ]
                ; of_int ~width:2 3, [ regs.(4) <-- select sr 6 0 @: pin_now ]
                ]
            ] )
      ; ( of_int ~width:4 0x5
        , [ if_ (arg ==:. 0) advance_pc [ mode <-- of_int ~width:2 1; wcnt <-- arg ] ] )
      ; ( of_int ~width:4 0x6
        , blocking
            (mux
               (select arg 5 4)
               [ ~:pin_now; pin_now; pin_now &: ~:pin_before; ~:pin_now &: pin_before ])
            [] )
      ; ( of_int ~width:4 0x7
        , advance_pc
          @ [ if_
                (d3 ==:. 6)
                [ to_ <-- a8 ]
                [ if_ (d3 ==:. 7) [ xo <-- select a8 1 0 ] [ write_reg d3 a8 ] ]
            ] )
      ; ( of_int ~width:4 0x8
        , advance_pc
          @ [ if_
                (d3 ==:. 6)
                [ out <-- mov_src ]
                [ if_ (d3 ==:. 7) [ oe <-- mov_src ] [ write_reg d3 mov_src ] ]
            ] )
      ; of_int ~width:4 0x9, advance_pc @ [ z <-- (cmp_src ==: a8) ]
      ; ( of_int ~width:4 0xA
        , advance_pc @ [ when_ (d3 <:. 6) [ write_reg d3 addi_sum; z <-- (addi_sum ==:. 0) ] ] )
      ; ( of_int ~width:4 0xB
        , [ switch
              (select arg 11 10)
              [ ( of_int ~width:2 0
                , blocking (tx.level <>:. 0) [ tx_pop <-- vdd; write_reg xsel0 tx.head ] )
              ; of_int ~width:2 1, blocking (rx.level <:. 8) [ rx_push <-- vdd ]
              ; of_int ~width:2 2, advance_pc
              ; of_int ~width:2 3, advance_pc
              ]
          ] )
      ; ( of_int ~width:4 0xC
        , [ switch
              (select arg 11 9)
              [ ( of_int ~width:3 0
                , blocking ser.ready [ ld_byte <-- vdd ] )
              ; of_int ~width:3 1, [ crci <-- vdd ] @ advance_pc
              ; of_int ~width:3 2, blocking ser.ready [ ld_crc <-- vdd ]
              ; of_int ~width:3 3, blocking ser.ready [ ld_eop <-- vdd ]
              ; of_int ~width:3 4, [ set_period <-- vdd ] @ advance_pc
              ; of_int ~width:3 5, blocking ser.ready []
              ; ( of_int ~width:3 6
                , blocking ser.ready [ ld_byte <-- vdd; crc_upd <-- bit i.cfg 5 ] )
              ; of_int ~width:3 7, advance_pc
              ]
          ] )
      ; ( of_int ~width:4 0xD
        , let lc' = rv 5 -:. 1 in
          [ regs.(5) <-- lc'; next_pc <-- mux2 (lc' <>:. 0) a8 pc1 ] )
      ; ( of_int ~width:4 0xE
        , [ switch
              (select arg 3 0)
              (List.init 16 ~f:(fun k ->
                 ( of_int ~width:4 k
                 , match k with
                   | 1 -> [] (* HALT: fault, handled by lane_reset *)
                   | 2 -> (tf <-- gnd) :: advance_pc
                   | _ -> advance_pc )))
          ] )
      ; of_int ~width:4 0xF, advance_pc
      ]
  in
  let new_fault = step_blame |: fault_now in
  let clear = i.clear_fault &: ~:new_fault in
  compile
    [ was_running <-- running
    ; if_
        lane_reset
        ([ next_pc <-- zero 8; out <-- zero 8; oe <-- zero 8; xo <-- zero 2; to_ <-- zero 8
         ; z <-- gnd; tf <-- gnd; mode <-- zero 2; wcnt <-- zero 12; prevp <-- zero 8
         ; live <-- gnd ]
         @ Array.to_list (Array.map regs ~f:(fun v -> v <-- zero 8)))
        [ when_
            exec
            [ live <-- vdd
            ; prevp <-- i.pins
            ; if_
                (mode.value ==:. 1)
                [ if_ (wcnt.value <=:. 1) [ mode <-- zero 2; next_pc <-- pc1 ] [ wcnt <-- wcnt.value -:. 1 ] ]
                [ instr ]
            ]
        ]
    ; pc <-- next_pc.value
    ; (* faults and the blame latch *)
      if_
        new_fault
        [ faulted <-- vdd; cause <-- mux2 step_blame (of_int ~width:2 2) (mux2 fetch_bound (of_int ~width:2 1) (of_int ~width:2 3)) ]
        [ when_ clear [ faulted <-- gnd; cause <-- zero 2 ] ]
    ; if_ step [ bpend <-- gnd ] [ if_ clear [ bpend <-- gnd ] [ when_ (i.blame_in &: rob) [ bpend <-- vdd ] ] ]
    ];
  (* ---- pins (from the state at the start of the cycle) ---- *)
  let ser_pin = select i.cfg2 2 0
  and pb = select i.cfg2 6 4 in
  let pair = bit i.cfg 1 in
  let dp = ~:(ser.se0) &: ~:(ser.lvl)
  and dm = ~:(ser.se0) &: ser.lvl
  and sv = ~:(ser.se0) &: ser.lvl in
  let pin k =
    let kk = of_int ~width:3 k in
    let is_dp = pair &: (pb ==: kk)
    and is_dm = pair &: (pb +:. 1 ==: kk)
    and is_sp = ~:pair &: (ser_pin ==: kk) in
    let drive = ser.busy &: (is_dp |: is_dm |: is_sp) in
    let v = mux2 is_dp dp (mux2 is_dm dm sv) in
    let o = mux2 drive v (bit out.value k) in
    let e = drive |: bit oe.value k in
    let en = live.value &: bit i.own k in
    let odk = bit i.od k in
    en &: ~:odk &: o, en &: mux2 odk ~:o e
  in
  let pins = List.init 8 ~f:pin in
  { O.uio_out = concat_lsb (List.map pins ~f:fst)
  ; uio_oe = concat_lsb (List.map pins ~f:snd)
  ; xo = xo.value
  ; faulted = faulted.value
  ; cause = cause.value
  ; pc = pc.value
  ; tx_level = tx.level
  ; rx_level = rx.level
  ; rx_head = mux2 (rx.level ==:. 0) (zero 8) rx.head
  ; pop_ev = tx_pop.value
  ; pop_data = mux2 tx_pop.value tx.head (zero 8)
  ; push_ev = rx_push.value
  ; push_data = mux2 rx_push.value x_val (zero 8)
  ; imem_wack = wack
  }
;;

(* Mutation-campaign hook (formal/src/mutate_v2.ml, plan step 9): when set, Top_v1 builds its
   lanes with it instead of [create]. Never set in the shipped flow. *)
let hook : (sram:sram -> Signal.t I.t -> Signal.t O.t) option ref = ref None

let instance ~sram i = match !hook with Some f -> f ~sram i | None -> create ~sram i
