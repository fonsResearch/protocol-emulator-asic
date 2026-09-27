(* pemu_core: ISA v0.1 / interface v0.1 core with a synchronous-read instruction SRAM.

   Fetch scheme (meets ISA section 5 with 1-cycle instructions and no branch penalty):
   - Running cycle c: the SRAM address is next_pc (the pc of cycle c+1), REN=1, so A_DOUT
     during cycle c+1 is imem[pc(c+1)]. The instruction executing in any running cycle is A_DOUT.
   - During WAIT, next_pc = pc: the same word is re-read and A_DOUT is unchanged.
   - Halted (and reset) cycles: the SRAM reads address 0 every cycle, so the first running
     cycle after any halt sees imem[0] on A_DOUT. When a halted cycle performs a program-load
     write, the port is busy writing:
       * write to address 0: REN=1 -> write-through, A_DOUT <- new imem[0];
       * write to address != 0: REN=0 -> A_DOUT holds, which is imem[0] from an earlier read.
     This is sound because two write events cannot occur in consecutive cycles (a write event is
     a rising edge of synchronised WSTB), and the first halted cycle after a running cycle has
     load_addr = 0 (it is held at 0 while running), so a write there hits address 0.
   - After power-up, at least 2 halted cycles (synchroniser latency) precede the first running
     cycle, so A_DOUT has been read before first use.

   Reset: rst_sync_n (synchronised by the wrapper) is used as a synchronous clear of every
   register except the SRAM contents and A_DOUT. *)
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

type sram = Signal.t Sram.I.t -> Signal.t Sram.O.t

let create ~(sram : sram) (i : _ I.t) =
  let spec = Reg_spec.create ~clock:i.clock ~clear:~:(i.rst_sync_n) () in
  (* input synchronisers (interface section 3) *)
  let s1_run = reg spec (bit i.ui_in 7) -- "s1_run" in
  let s2_run = reg spec s1_run -- "s2_run" in
  let s1_wstb = reg spec (bit i.ui_in 6) -- "s1_wstb" in
  let s2_wstb = reg spec s1_wstb -- "s2_wstb" in
  let s3_wstb = reg spec s2_wstb -- "s3_wstb" in
  let s1_uio = reg spec i.uio_in -- "s1_uio" in
  let s2_uio = reg spec s1_uio -- "s2_uio" in
  let running = s2_run -- "running" in
  let write_event = s2_wstb &: ~:s3_wstb in
  (* state registers; next-state wires are defined below and closed with <== *)
  let w width = wire width in
  let pc_d = w 6
  and out_d = w 8
  and sr_d = w 8
  and lc_d = w 8
  and waiting_d = w 1
  and wait_cnt_d = w 12
  and load_addr_d = w 6
  and load_hi_d = w 1
  and load_lo_d = w 8 in
  let pc = reg spec pc_d -- "pc"
  and out = reg spec out_d -- "out"
  and sr = reg spec sr_d -- "sr"
  and lc = reg spec lc_d -- "lc"
  and waiting = reg spec waiting_d -- "waiting"
  and wait_cnt = reg spec wait_cnt_d -- "wait_cnt"
  and load_addr = reg spec load_addr_d -- "load_addr"
  and load_hi = reg spec load_hi_d -- "load_hi"
  and load_lo = reg spec load_lo_d -- "load_lo" in
  (* program-load write this cycle (interface section 5) *)
  let imem_write = ~:running &: write_event &: load_hi -- "imem_write" in
  (* instruction SRAM *)
  let next_pc = w 6 in
  let sram_o =
    sram
      { Sram.I.a_clk = i.clock
      ; a_men = vdd
      ; a_wen = imem_write
      ; a_ren = running |: ~:imem_write |: (load_addr ==:. 0)
      ; a_addr = mux2 running next_pc (mux2 imem_write load_addr (zero 6))
      ; a_din = s2_uio @: load_lo
      ; a_dly = vdd
      }
  in
  let instr = sram_o.a_dout -- "instr" in
  (* decode *)
  let op = select instr 15 12
  and arg = select instr 11 0 in
  let arg8 = select arg 7 0
  and arg6 = select arg 5 0 in
  let is o = op ==:. o in
  let pc_inc = pc +:. 1 in
  let lc_dec = lc -:. 1 in
  let outb_value =
    let mask = binary_to_onehot (select arg 2 0) in
    out &: ~:mask |: mux2 (lsb sr) mask (zero 8)
  in
  let wait_last = waiting &: (wait_cnt ==:. 0) in
  (* next pc while running *)
  let run_next_pc =
    mux2
      waiting
      (mux2 wait_last pc_inc pc)
      (mux
         op
         [ arg6 (* 0 JMP *)
         ; pc_inc (* 1 OUT *)
         ; pc_inc (* 2 OUTB *)
         ; pc_inc (* 3 LDI *)
         ; pc_inc (* 4 IN *)
         ; mux2 (arg ==:. 0) pc_inc pc (* 5 WAIT *)
         ; pc_inc (* 6 LDC *)
         ; mux2 (lc_dec <>:. 0) arg6 pc_inc (* 7 DJNZ *)
         ; pc_inc (* 8..15 reserved: mux repeats the last element *)
         ])
  in
  next_pc <== (run_next_pc -- "next_pc");
  let executing = running &: ~:waiting in
  pc_d <== mux2 running next_pc (zero 6);
  out_d
  <== mux2
        running
        (mux2 (executing &: is 0x1) arg8 (mux2 (executing &: is 0x2) outb_value out))
        (zero 8);
  sr_d
  <== mux2
        running
        (mux2
           (executing &: is 0x2)
           (srl sr 1)
           (mux2 (executing &: is 0x3) arg8 (mux2 (executing &: is 0x4) s2_uio sr)))
        (zero 8);
  lc_d
  <== mux2
        running
        (mux2 (executing &: is 0x6) arg8 (mux2 (executing &: is 0x7) lc_dec lc))
        (zero 8);
  waiting_d
  <== mux2
        running
        (mux2 waiting ~:wait_last (is 0x5 &: (arg <>:. 0)))
        gnd;
  wait_cnt_d
  <== mux2
        running
        (mux2
           waiting
           (mux2 wait_last (zero 12) (wait_cnt -:. 1))
           (mux2 (is 0x5 &: (arg <>:. 0)) (arg -:. 1) (zero 12)))
        (zero 12);
  (* load state: held at 0 while running; updated on write events while halted *)
  load_addr_d <== mux2 running (zero 6) (mux2 imem_write (load_addr +:. 1) load_addr);
  load_hi_d
  <== mux2 running gnd (mux2 write_event ~:load_hi load_hi);
  load_lo_d
  <== mux2 running (zero 8) (mux2 (write_event &: ~:load_hi) s2_uio load_lo);
  { O.uo_out = out; uio_out = zero 8; uio_oe = zero 8 }
;;

let circuit_behavioural () =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:"pemu_core" (create ~sram:(Sram.behavioural ?name_prefix:None))
;;

let circuit_macro () =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:"pemu_core_macro" (create ~sram:Sram.blackbox)
;;
