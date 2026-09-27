(* Executable specification as a Hardcaml circuit: the same semantics as [Interp], written
   for clarity rather than area. Instruction memory is 64 registers read combinationally
   (ISA-level view); the RTL instead uses a synchronous-read SRAM, and the RTL-vs-spec miter
   checks that the RTL's fetch pipeline preserves the ISA timing contract.

   imem registers carry stable names [spec_imem_<i>] for the formal harness. *)
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

(* Instruction memory as a pluggable function (combinational read, synchronous write), so
   that tools (formal/src/mutate.ml) can treat it as a memory model outside the logic.
   - [imem_registers]: the specification: 64 x 16 registers, no reset, written by the load
     protocol only.
   - [imem_rom words]: formal/test-only: a constant program; writes are ignored. *)
module Imem = struct
  type 'a t =
    { clock : 'a
    ; we : 'a
    ; waddr : 'a
    ; wdata : 'a
    ; raddr : 'a
    }
end

let imem_registers (m : Signal.t Imem.t) =
  let spec_noclear = Reg_spec.create ~clock:m.clock () in
  mux
    m.raddr
    (List.init Isa.imem_depth ~f:(fun a ->
       let we = m.we &: (m.waddr ==:. a) in
       reg spec_noclear ~enable:we m.wdata -- sprintf "spec_imem_%d" a))
;;

let imem_rom (words : int array) (m : Signal.t Imem.t) =
  ignore (m.clock, m.we, m.waddr, m.wdata);
  mux m.raddr (List.init Isa.imem_depth ~f:(fun a -> of_int ~width:16 words.(a)))
;;

(* [rom]: shorthand for [~imem:(imem_rom rom)]. The default is [imem_registers]. *)
let create ?rom ?imem (i : _ I.t) =
  let imem =
    match imem, rom with
    | Some f, None -> f
    | None, Some words -> imem_rom words
    | None, None -> imem_registers
    | Some _, Some _ -> raise_s [%message "Spec_circuit.create: both ?rom and ?imem given"]
  in
  let open Always in
  (* rst_sync_n is used as a synchronous clear (all registers except imem). *)
  let spec = Reg_spec.create ~clock:i.clock ~clear:(~:(i.rst_sync_n)) () in
  let r w = Variable.reg spec ~width:w in
  (* synchronisers *)
  let s1_run = reg spec (bit i.ui_in 7) in
  let s2_run = reg spec s1_run -- "spec_running" in
  let s1_wstb = reg spec (bit i.ui_in 6) in
  let s2_wstb = reg spec s1_wstb in
  let s3_wstb = reg spec s2_wstb in
  let s1_uio = reg spec i.uio_in in
  let s2_uio = reg spec s1_uio in
  let running = s2_run in
  let write_event = s2_wstb &: ~:s3_wstb in
  (* architectural state *)
  let pc = r Isa.pc_width
  and out = r 8
  and sr = r 8
  and lc = r 8
  and waiting = r 1
  and wait_cnt = r 12
  and load_addr = r Isa.pc_width
  and load_hi = r 1
  and load_lo = r 8 in
  (* instruction memory (see [Imem]) *)
  let instr =
    imem
      { Imem.clock = i.clock
      ; we = running ==:. 0 &: write_event &: load_hi.value
      ; waddr = load_addr.value
      ; wdata = s2_uio @: load_lo.value
      ; raddr = pc.value
      }
  in
  let op = select instr 15 12
  and arg = select instr 11 0 in
  let arg8 = select arg 7 0
  and arg6 = select arg 5 0
  and pin = select arg 2 0 in
  let pc_inc = pc.value +:. 1 in
  let is o = op ==:. o in
  (* OUTB: out[pin] <- sr[0] *)
  let outb_value =
    let mask = binary_to_onehot pin in
    out.value &: ~:mask |: (mux2 (lsb sr.value) mask (zero 8))
  in
  let lc_dec = lc.value -:. 1 in
  compile
    [ if_
        (running ==:. 0)
        [ (* halted cycle *)
          pc <--. 0
        ; out <--. 0
        ; sr <--. 0
        ; lc <--. 0
        ; waiting <--. 0
        ; wait_cnt <--. 0
        ; when_
            write_event
            [ if_
                (load_hi.value ==:. 0)
                [ load_lo <-- s2_uio; load_hi <--. 1 ]
                [ load_addr <-- load_addr.value +:. 1; load_hi <--. 0 ]
            ]
        ]
        [ load_addr <--. 0
        ; load_hi <--. 0
        ; load_lo <--. 0
        ; if_
            waiting.value
            [ if_
                (wait_cnt.value ==:. 0)
                [ waiting <--. 0; pc <-- pc_inc ]
                [ wait_cnt <-- wait_cnt.value -:. 1 ]
            ]
            [ if_ (is 0x0) [ pc <-- arg6 ]
              @@ elif (is 0x1) [ out <-- arg8; pc <-- pc_inc ]
              @@ elif
                   (is 0x2)
                   [ out <-- outb_value; sr <-- srl sr.value 1; pc <-- pc_inc ]
              @@ elif (is 0x3) [ sr <-- arg8; pc <-- pc_inc ]
              @@ elif (is 0x4) [ sr <-- s2_uio; pc <-- pc_inc ]
              @@ elif
                   (is 0x5)
                   [ if_
                       (arg ==:. 0)
                       [ pc <-- pc_inc ]
                       [ waiting <--. 1; wait_cnt <-- arg -:. 1 ]
                   ]
              @@ elif (is 0x6) [ lc <-- arg8; pc <-- pc_inc ]
              @@ elif
                   (is 0x7)
                   [ lc <-- lc_dec; pc <-- mux2 (lc_dec <>:. 0) arg6 pc_inc ]
              @@ [ (* reserved: NOP *) pc <-- pc_inc ]
            ]
        ]
    ];
  { O.uo_out = out.value; uio_out = zero 8; uio_oe = zero 8 }
;;

let circuit () =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:"pemu_spec" create
;;
