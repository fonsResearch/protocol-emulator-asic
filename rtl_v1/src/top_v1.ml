(* Core v1: host SPI target port (interface v1 section 4), register block with per-lane
   loaders (sections 5, 6), two driver lanes with prescalers, pin combination (section 2).
   Monitor engine and verdict block (section 7): present when a package library [?lib] is
   given (Pemu_monitor_v1.Mon_engine, registers 0x40-0x7F). Then: blame_in of lane L is the
   engine's registered blame of lane L; RUN of a lane with an enabled package is refused
   unless P >= min_p (7, or 13 with two loadable units; assumption T8 and the fetch bound) and,
   in loadable mode, the context is loaded; shown in FLAGS bit 4. Loadable stores: [sram 2]
   and [sram 3]. Default build (user decision 2026-10-18): lane 1 loadable, lane 0 ROM only
   ([?loadable] = [| false; true |]), so one store macro ([sram 3]);
   STATUS bits 6/7 and uo_out[1]/[2] carry fail/blame; CTRL bit4 clears the verdict.
   Without [?lib]: fail = blame = 0 and blame_in = 0, as in core v1.

   Clarifications implemented here (doc/CHANGES.md, interface v1.0.1):
   - a read value is sampled (peeked, no side effect) in the cycle after the last rising SCK
     edge of the previous byte, so that a pop of the byte just completed is visible; an RXF pop
     happens when the byte that carried it completes, so the final sample of a transaction
     does not consume a byte. The host timing requirement (SCK high for at least 4 cycles)
     leaves the sample ahead of the falling edge that shifts it out;
   - per-lane FLAGS register at +13: bit0 TX overflow, bit1 RX underflow, bit2 loaded,
     bit3 program word dropped (all sticky except bit2; write 1 to clear bits 0, 1, 3);
     FIFO_ST at +11 = {rx_level[3:0], tx_level[3:0]};
   - the loader advances only on the lane's imem_wack; a refused word sets the dropped flag.
   Single clock domain; SCK is oversampled through the input synchronisers. *)
open! Core
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_sync_n : 'a
    ; ui_in : 'a [@bits 8]
    ; uio_in : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uo_out : 'a [@bits 8]
    ; uio_out : 'a [@bits 8]
    ; uio_oe : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

(* ---- SPI target, mode 0, MSB first ---- *)
module Spi = struct
  type t =
    { wr : Signal.t (* write strobe: addr, wdata *)
    ; addr : Signal.t
    ; wdata : Signal.t
    ; raddr : Signal.t (* address whose value is sampled this cycle (peek), when rd_sample *)
    ; rd_sample : Signal.t
    ; rd_done : Signal.t (* a read data byte at [addr] completed *)
    ; miso : Signal.t
    }

  let create ~spec ~cs_n ~sck ~mosi ~is_port ~rdata =
    let open Always in
    let r w = Variable.reg spec ~width:w in
    let sck_q = r 1
    and cnt = r 3
    and sh_in = r 8
    and first = r 1
    and rw = r 1
    and addr = r 7
    and sh_out = r 8
    and miso = r 1
    and sample = r 1
    and raddr_q = r 7 in
    let active = ~:cs_n in
    let rise = active &: sck &: ~:(sck_q.value)
    and fall = active &: ~:sck &: sck_q.value in
    let byte = select sh_in.value 6 0 @: mosi in
    let done_ = rise &: (cnt.value ==:. 7) in
    let hdr = done_ &: first.value
    and dat = done_ &: ~:(first.value) in
    let next_addr = mux2 (is_port addr.value) addr.value (addr.value +:. 1) in
    let raddr = mux2 first.value (select byte 6 0) next_addr in
    let rd_sample = (hdr &: msb byte) |: (dat &: rw.value) in
    compile
      [ sck_q <-- sck
      ; if_
          cs_n
          [ cnt <-- zero 3; first <-- vdd; miso <-- gnd; sh_out <-- zero 8 ]
          [ when_ rise [ sh_in <-- byte; cnt <-- cnt.value +:. 1 ]
          ; when_ hdr [ rw <-- msb byte; addr <-- select byte 6 0; first <-- gnd ]
          ; when_ dat [ addr <-- next_addr ]
          ; sample <-- rd_sample
          ; when_ rd_sample [ raddr_q <-- raddr ]
          ; when_ sample.value [ sh_out <-- rdata ]
          ; when_ fall [ miso <-- msb sh_out.value; sh_out <-- sll sh_out.value 1 ]
          ]
      ];
    { wr = dat &: ~:(rw.value)
    ; addr = addr.value
    ; wdata = byte
    ; raddr = raddr_q.value
    ; rd_sample = sample.value
    ; rd_done = dat &: rw.value
    ; miso = miso.value &: active
    }
  ;;
end

(* register offsets within a lane's 16-byte window *)
let off_own = 0
let off_od = 1
let off_p_lo = 2
let off_p_hi = 3
let off_len = 4
let off_cfg = 5
let off_cfg2 = 6
let off_prog_start = 7
let off_prog_data = 8
let off_txf = 9
let off_rxf = 10
let off_fifo_st = 11
let off_pc = 12
let off_flags = 13
let lane_base l = 0x10 + (16 * l)
let id_value = 0xA1

type lane_ctl =
  { run : Signal.t
  ; own : Signal.t
  ; od : Signal.t
  ; p : Signal.t
  ; len : Signal.t
  ; cfg : Signal.t
  ; cfg2 : Signal.t
  ; loaded : Signal.t
  ; clear_fault : Signal.t
  ; tx_push : Signal.t
  ; tx_wdata : Signal.t
  ; rx_pop : Signal.t
  ; imem_we : Signal.t
  ; imem_waddr : Signal.t
  ; imem_wdata : Signal.t
  ; read : Signal.t -> Signal.t (* offset (4 bits) -> value *)
  }

type lane_status =
  { faulted : Signal.t
  ; cause : Signal.t
  ; pc : Signal.t
  ; tx_level : Signal.t
  ; rx_level : Signal.t
  ; rx_head : Signal.t
  ; wack : Signal.t
  }

(* One lane's registers and loader. [other_own] is the other lane's ownership mask.
   [running] is this lane's running condition (computed by the caller). *)
(* [bug] (formal negative controls only): `Loaded_early raises loaded one word early;
   `No_overlap_check accepts any OWN value. *)
let lane_regs
    ?(bug : [ `Loaded_early | `No_overlap_check ] option)
    ~spec
    ~l
    ~(spi : Spi.t)
    ~run_bit
    ~clr_fault
    ~other_own
    ~running
    ~(st : lane_status)
    ?(refused = gnd)
    ()
  =
  let open Always in
  let r w = Variable.reg spec ~width:w in
  let own = r 8
  and od = r 8
  and p = r 16
  and len = r 8
  and cfg = r 8
  and cfg2 = r 8
  and load_addr = r 8
  and phase = r 1
  and lo = r 8
  and loaded = r 1
  and dropped = r 1
  and ovf = r 1
  and unf = r 1 in
  let base = lane_base l in
  let in_window a = select a 6 4 ==:. base lsr 4 in
  let off a = select a 3 0 in
  let wr_at o = spi.wr &: in_window spi.addr &: (off spi.addr ==:. o) in
  let halted = ~:running in
  let w1 () = Variable.wire ~default:gnd in
  let imem_we = w1 () in
  let tx_push = wr_at off_txf in
  let rx_pop = spi.rd_done &: in_window spi.addr &: (off spi.addr ==:. off_rxf) in
  compile
    [ when_
        (wr_at off_own
         &: halted
         &: (match bug with
             | Some `No_overlap_check -> vdd
             | _ -> (spi.wdata &: other_own) ==:. 0))
        [ own <-- spi.wdata ]
    ; when_ (wr_at off_od &: halted) [ od <-- spi.wdata ]
    ; when_ (wr_at off_p_lo &: halted) [ p <-- select p.value 15 8 @: spi.wdata ]
    ; when_ (wr_at off_p_hi &: halted) [ p <-- spi.wdata @: select p.value 7 0 ]
    ; when_ (wr_at off_len &: halted) [ len <-- spi.wdata; loaded <-- gnd ]
    ; when_ (wr_at off_cfg &: halted) [ cfg <-- spi.wdata ]
    ; when_ (wr_at off_cfg2 &: halted) [ cfg2 <-- spi.wdata ]
    ; when_
        (wr_at off_prog_start &: halted)
        [ load_addr <-- zero 8; loaded <-- gnd; phase <-- gnd; dropped <-- gnd ]
    ; when_
        (wr_at off_prog_data &: halted)
        [ if_
            (phase.value ==:. 0)
            [ lo <-- spi.wdata; phase <-- vdd ]
            [ phase <-- gnd
            ; imem_we <-- vdd
            ; if_
                st.wack
                [ load_addr <-- load_addr.value +:. 1
                ; when_
                    ((len.value <>:. 0)
                     &: (load_addr.value +:. (match bug with Some `Loaded_early -> 2 | _ -> 1)
                         ==: len.value))
                    [ loaded <-- vdd ]
                ]
                [ dropped <-- vdd ]
            ]
        ]
    ; when_ (tx_push &: (st.tx_level >=:. 8)) [ ovf <-- vdd ]
    ; when_ (rx_pop &: (st.rx_level ==:. 0)) [ unf <-- vdd ]
    ; when_
        (wr_at off_flags)
        [ when_ (bit spi.wdata 0) [ ovf <-- gnd ]
        ; when_ (bit spi.wdata 1) [ unf <-- gnd ]
        ; when_ (bit spi.wdata 3) [ dropped <-- gnd ]
        ]
    ];
  let flags = zero 3 @: refused @: dropped.value @: loaded.value @: unf.value @: ovf.value in
  let read o =
    mux
      o
      [ own.value; od.value; select p.value 7 0; select p.value 15 8; len.value; cfg.value
      ; cfg2.value; zero 8; zero 8; zero 8; st.rx_head
      ; select st.rx_level 3 0 @: select st.tx_level 3 0
      ; st.pc; flags; zero 8; zero 8 ]
  in
  { run = run_bit
  ; own = own.value
  ; od = od.value
  ; p = p.value
  ; len = len.value
  ; cfg = cfg.value
  ; cfg2 = cfg2.value
  ; loaded = loaded.value
  ; clear_fault = clr_fault
  ; tx_push
  ; tx_wdata = spi.wdata
  ; rx_pop
  ; imem_we = imem_we.value
  ; imem_waddr = load_addr.value
  ; imem_wdata = spi.wdata @: lo.value
  ; read
  }
;;

let is_port a =
  let off = select a 3 0
  and win = select a 6 4 in
  (((win ==:. 1) |: (win ==:. 2))
   &: ((off ==:. off_prog_data) |: (off ==:. off_txf) |: (off ==:. off_rxf)))
  |: Pemu_monitor_v1.Mon_engine.is_port a
;;

(* Host front end: ui_in[2:0] synchroniser, host SPI target, CTRL decode and the RUN bits.
   A separate function so that formal/src/top_props.ml (run_after_reset) checks this code. *)
type host_port =
  { spi : Spi.t
  ; rdata : Signal.t (* read data, driven by the caller *)
  ; ctrl_wr : Signal.t
  ; run_bits : Signal.t
  }

let host_port ~spec ~ui_in =
  let sync x = reg spec (reg spec x) in
  let s_ui = sync (select ui_in 2 0) -- "s2_ui" in
  let cs_n = bit s_ui 0
  and sck = bit s_ui 1
  and mosi = bit s_ui 2 in
  let rdata = wire 8 in
  let spi = Spi.create ~spec ~cs_n ~sck ~mosi ~is_port ~rdata in
  let ctrl_wr = spi.wr &: (spi.addr ==:. 0x01) in
  let run_bits = reg spec ~enable:ctrl_wr (select spi.wdata 1 0) -- "ctrl_run" in
  { spi; rdata; ctrl_wr; run_bits }
;;

type debug =
  { lane_inputs : Signal.t Lane_rtl.I.t array (* for the structural non-interference check *)
  ; lane_outputs : Signal.t Lane_rtl.O.t array
  ; own : Signal.t array
  ; lane_uids : (int * int) list array
      (* per lane: uid ranges of the signals built by its prescaler and its Lane_rtl.create *)

  ; mon_running : Signal.t array (* per lane: the monitor's running input (test visibility) *)
  }

let create_with_debug ?(loadable = [| false; true |]) ?mon_slots ?verdict_pipe ?param_windows ?lib ~(sram : int -> Lane_rtl.sram) (i : _ I.t) =
  (* [mon_slots] (v2): monitor unit slots per lane, passed to Mon_engine (default 8) *)
  let spec = Reg_spec.create ~clock:i.clock ~clear:~:(i.rst_sync_n) () in
  let sync x = reg spec (reg spec x) in
  let s_uio = sync i.uio_in -- "s2_uio" in
  let { spi; rdata; ctrl_wr; run_bits } = host_port ~spec ~ui_in:i.ui_in in
  (* CTRL *)
  let clr_fault l = ctrl_wr &: bit spi.wdata (5 + l) in
  (* lanes: forward declarations of status wires *)
  let st =
    Array.init 2 ~f:(fun _ ->
      { faulted = wire 1; cause = wire 2; pc = wire 8; tx_level = wire 4; rx_level = wire 4
      ; rx_head = wire 8; wack = wire 1 })
  in
  let own_w = Array.init 2 ~f:(fun _ -> wire 8) in
  let loaded_w = Array.init 2 ~f:(fun _ -> wire 1) in
  (* T8 admission (engine only): a lane with an enabled package runs only if P >= 7 *)
  let admit_w = Array.init 2 ~f:(fun _ -> wire 1) in
  let running l =
    i.rst_sync_n &: bit run_bits l &: admit_w.(l) &: loaded_w.(l) &: ~:(st.(l).faulted)
  in
  let ctl =
    Array.init 2 ~f:(fun l ->
      lane_regs
        ~spec
        ~l
        ~spi
        ~run_bit:(bit run_bits l)
        ~clr_fault:(clr_fault l)
        ~other_own:own_w.(1 - l)
        ~running:(running l)
        ~st:st.(l)
        ~refused:(bit run_bits l &: ~:(admit_w.(l)))
        ())
  in
  Array.iteri ctl ~f:(fun l c ->
    own_w.(l) <== c.own;
    loaded_w.(l) <== c.loaded);
  let blame_w = Array.init 2 ~f:(fun _ -> wire 1) in
  let mark () = Signal.Type.Uid.to_int (Signal.uid (wire 1)) in
  let lane_uids = Array.create ~len:2 [] in
  let lane_in =
    Array.init 2 ~f:(fun l ->
      let c = ctl.(l) in
      let u0 = mark () in
      let tick =
        Prescaler16.create ~clock:i.clock ~rst_sync_n:i.rst_sync_n ~running:(running l) ~p:c.p ()
      in
      lane_uids.(l) <- (u0, mark ()) :: lane_uids.(l);
      { Lane_rtl.I.clock = i.clock
      ; rst_sync_n = i.rst_sync_n
      ; tick
      ; run = c.run &: admit_w.(l)
      ; loaded = c.loaded
      ; len = c.len
      ; own = c.own
      ; od = c.od
      ; cfg = c.cfg
      ; cfg2 = c.cfg2
      ; pins = s_uio
      ; tx_push = c.tx_push
      ; tx_wdata = c.tx_wdata
      ; rx_pop = c.rx_pop
      ; blame_in = blame_w.(l)
      ; clear_fault = c.clear_fault
      ; imem_we = c.imem_we
      ; imem_waddr = c.imem_waddr
      ; imem_wdata = c.imem_wdata
      })
  in
  let lane_out =
    Array.init 2 ~f:(fun l ->
      let u0 = mark () in
      let o = Lane_rtl.create ~sram:(sram l) lane_in.(l) in
      lane_uids.(l) <- (u0, mark ()) :: lane_uids.(l);
      o)
  in
  Array.iteri lane_out ~f:(fun l o ->
    let s = st.(l) in
    s.faulted <== o.faulted;
    s.cause <== o.cause;
    s.pc <== o.pc;
    s.tx_level <== o.tx_level;
    s.rx_level <== o.rx_level;
    s.rx_head <== o.rx_head;
    s.wack <== o.imem_wack);
  (* monitor engine *)
  let uio_out = lane_out.(0).uio_out |: lane_out.(1).uio_out
  and uio_oe = lane_out.(0).uio_oe |: lane_out.(1).uio_oe in
  let eng =
    Option.map lib ~f:(fun lib ->
      let lanes =
        Array.init 2 ~f:(fun l ->
          let o = lane_out.(l) in
          let own = ctl.(l).own in
          (* lane L's xo bits in their uo_out positions (lane 0: [4:3], lane 1: [6:5]) *)
          let uo_view =
            if l = 0 then zero 3 @: o.xo @: zero 3 else zero 1 @: o.xo @: zero 5
          in
          { Pemu_monitor_v1.Mon_engine.running = running l; tick = lane_in.(l).tick
          ; uo_out = uo_view; uio_out = o.uio_out &: own; uio_oe = o.uio_oe &: own
          ; pop_ev = o.pop_ev; pop_data = o.pop_data; push_ev = o.push_ev
          ; push_data = o.push_data })
      in
      (* loadable stores: [sram 2] and [sram 3] (one 256x16 per lane), port tie-offs as the
         lanes' instruction memories *)
      let store l (p : Pemu_monitor_v1.Mon_engine.store_port) =
        (sram (2 + l)
           { Sram256.I.a_clk = i.clock; a_men = vdd; a_wen = p.wen; a_ren = p.ren; a_addr = p.addr
           ; a_din = p.din; a_dly = vdd; a_bm = ones 16; a_bist_clk = gnd; a_bist_en = gnd
           ; a_bist_men = gnd; a_bist_wen = gnd; a_bist_ren = gnd; a_bist_addr = zero 8
           ; a_bist_din = zero 16; a_bist_bm = zero 16 })
          .a_dout
      in
      Pemu_monitor_v1.Mon_engine.create ?slots:mon_slots ?verdict_pipe ?param_windows ~loadable ~clock:i.clock ~rst_sync_n:i.rst_sync_n ~lib ~store
        ~host:{ wr = spi.wr; addr = spi.addr; wdata = spi.wdata
              ; clr_verdict = ctrl_wr &: bit spi.wdata 4 }
        ~lanes ~ui_in:i.ui_in ~uio_in:i.uio_in ())
  in
  let fail, blame =
    match eng with Some e -> e.fail, e.blame | None -> gnd, gnd
  in
  Array.iteri blame_w ~f:(fun l w ->
    w <== (match eng with Some e -> e.blame_to_lane.(l) | None -> gnd));
  Array.iteri admit_w ~f:(fun l w ->
    w
    <== (match eng with
         | Some e -> ~:(e.pkg_en.(l)) |: (e.ready.(l) &: (ctl.(l).p >=: e.min_p.(l)))
         | None -> vdd));
  (* read mux *)
  let status =
    blame @: fail @: lane_out.(1).faulted @: lane_out.(0).faulted @: ctl.(1).loaded
    @: ctl.(0).loaded @: running 1 @: running 0
  in
  let fault_reg = uresize lane_out.(1).cause 4 @: uresize lane_out.(0).cause 4 in
  let ra = spi.raddr in
  let win = select ra 6 4 in
  rdata
  <== mux2
        (win ==:. 0)
        (mux
           (select ra 3 0)
           [ of_int ~width:8 id_value; uresize run_bits 8; status; fault_reg; zero 8 ])
        (mux2
           (win ==:. 1)
           (ctl.(0).read (select ra 3 0))
           (mux2
              (win ==:. 2)
              (ctl.(1).read (select ra 3 0))
              (match eng with Some e -> e.read ra | None -> zero 8)));
  let any_fault = lane_out.(0).faulted |: lane_out.(1).faulted in
  let o =
    { O.uo_out =
        any_fault @: lane_out.(1).xo @: lane_out.(0).xo @: blame @: fail @: spi.miso
    ; uio_out
    ; uio_oe
    }
  in

  ( o
  , { lane_inputs = lane_in
    ; lane_outputs = lane_out
    ; own = Array.map ctl ~f:(fun c -> c.own)
    ; lane_uids
    ; mon_running = Array.init 2 ~f:running
    } )
;;

let create ?loadable ?mon_slots ?verdict_pipe ?param_windows ?lib ~sram i =
  fst (create_with_debug ?loadable ?mon_slots ?verdict_pipe ?param_windows ?lib ~sram i)
