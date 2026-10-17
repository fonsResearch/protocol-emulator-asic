(* Properties of the core v1 host side (rtl_v1/Top_v1) and of lane pin gating.

   load_gate      interface section 6.3: if loaded = 1 then every imem[a] with a < LEN was
                  written (an accepted write, imem_we && imem_wack) since the last reset or
                  accepted PROG_START. One lane's register block with every input free: SPI
                  strobes, address and data, the lane status (wack, faulted, levels) and the
                  running condition. Symbolic address a* (register free_astar, free initial
                  value, held) with a ghost bit "written since PROG_START".
   own_disjoint   both lanes' register blocks, inputs free: own0 & own1 = 0 always.
   lane_pin_gate  lane RTL (abstract SRAM, inputs free): uio_out and uio_oe are 0 outside own.
   With own_disjoint this gives no contention on uio: at most one lane drives each pin.
   Negative controls: loader raises loaded one word early; overlap check removed. *)
open! Core
open Hardcaml
open Signal
module T = Pemu_rtl_v1.Top_v1
module R = Pemu_rtl_v1.Lane_rtl

let free_spi () : T.Spi.t =
  { wr = input "spi_wr" 1
  ; addr = input "spi_addr" 7
  ; wdata = input "spi_wdata" 8
  ; raddr = input "spi_raddr" 7
  ; rd_sample = input "spi_rd_sample" 1
  ; rd_done = input "spi_rd_done" 1
  ; miso = gnd
  }
;;

let free_status n : T.lane_status =
  { faulted = input (n ^ "faulted") 1
  ; cause = input (n ^ "cause") 2
  ; pc = input (n ^ "pc") 8
  ; tx_level = input (n ^ "tx_level") 4
  ; rx_level = input (n ^ "rx_level") 4
  ; rx_head = input (n ^ "rx_head") 8
  ; wack = input (n ^ "wack") 1
  }
;;

let load_gate ?debug ?bug ~name () =
  let clock = input "clock" 1
  and rst_sync_n = input "rst_sync_n" 1 in
  let spec = Reg_spec.create ~clock ~clear:~:rst_sync_n () in
  let spi = free_spi () in
  let st = free_status "st_" in
  let running = input "running" 1 in
  let c =
    T.lane_regs
      ?bug
      ~spec
      ~l:0
      ~spi
      ~run_bit:gnd
      ~clr_fault:gnd
      ~other_own:(input "other_own" 8)
      ~running
      ~st
      ()
  in
  (* symbolic address, free and constant *)
  let astar_d = wire 8 in
  let astar = reg (Reg_spec.create ~clock ()) astar_d -- "free_astar" in
  astar_d <== astar;
  (* ghost: accepted write to a* since reset or accepted PROG_START *)
  let start_acc =
    spi.wr &: (spi.addr ==:. T.lane_base 0 + T.off_prog_start) &: ~:running
  in
  let wrote = c.imem_we &: st.wack &: (c.imem_waddr ==: astar) in
  let w_d = wire 1 in
  let written = reg spec w_d -- "ghost_written" in
  w_d <== mux2 start_acc gnd (mux2 wrote vdd written);
  let bad = c.loaded &: (astar <: c.len) &: ~:written in
  Harness.bad_circuit ?debug ~dbg:[ "loaded", c.loaded; "len", c.len; "written", written ] ~name bad
;;

let own_disjoint ?debug ?bug ~name () =
  let clock = input "clock" 1
  and rst_sync_n = input "rst_sync_n" 1 in
  let spec = Reg_spec.create ~clock ~clear:~:rst_sync_n () in
  let spi = free_spi () in
  let own = Array.init 2 ~f:(fun _ -> wire 8) in
  let c =
    Array.init 2 ~f:(fun l ->
      T.lane_regs
        ?bug:(if l = 1 then bug else None)
        ~spec
        ~l
        ~spi
        ~run_bit:gnd
        ~clr_fault:gnd
        ~other_own:own.(1 - l)
        ~running:(input (sprintf "running%d" l) 1)
        ~st:(free_status (sprintf "st%d_" l))
        ())
  in
  Array.iteri c ~f:(fun l x -> own.(l) <== x.own);
  Harness.bad_circuit ?debug ~dbg:[ "own0", own.(0); "own1", own.(1) ] ~name (own.(0) &: own.(1) <>:. 0)
;;

let lane_pin_gate ?debug ~name () =
  let { A1_lane.ri; _ } = A1_lane.lane_inputs () in
  let rdata = input "free_rdata" 16 in
  let r = R.create ~sram:(A1_lane.free_read_sram ~rdata) ri in
  let outside = ~:(ri.own) in
  Harness.bad_circuit ?debug ~name ((r.uio_out |: r.uio_oe) &: outside <>:. 0)
;;

let all ?debug () =
  [ load_gate ?debug ~name:"load_gate" ()
  ; load_gate ?debug ~bug:`Loaded_early ~name:"load_gate_neg" ()
  ; own_disjoint ?debug ~name:"own_disjoint" ()
  ; own_disjoint ?debug ~bug:`No_overlap_check ~name:"own_disjoint_neg" ()
  ; lane_pin_gate ?debug ~name:"lane_pin_gate" ()
  ]
;;
