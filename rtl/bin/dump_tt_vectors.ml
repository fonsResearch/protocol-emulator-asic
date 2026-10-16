(* Wrapper-level (tt_um_* pin) replay vectors for the cocotb harness in test/.
   usage: dump_tt_vectors.exe <dir>

   One file <dir>/<scenario>.vec per scenario. One line per clock cycle c:
     rst_n ui_in uio_in  exp_uio_oe exp_uio_out exp_uo_out
   hex fields, inputs as driven during cycle c (sampled at the edge that ends cycle c),
   expected outputs as observed during cycle c (Moore: fixed by the edge that starts it).

   The oracle is the spec interpreter (Pemu_spec.Interp) at the core boundary. The wrapper's
   reset synchroniser (src/tt_um_dean_protocol_emulator.v: async assert, 2-flop sync release)
   is modelled here by hand in [Rst_sync]. That model is NOT proven against the wrapper
   Verilog; the cocotb replay is its only check (a wrong model fails every scenario).

   Every scenario loads all 64 instruction words before the first RUN. Instruction memory has
   no reset (SRAM or flops), so after power-up or a previous scenario its contents differ from
   the spec's zero-initialised model; loading the full image makes the replay deterministic.
   This mirrors the A1 zero-init assumption (log/slice_report.md, decision 2). *)
open! Core
open Pemu_spec

module Rst_sync = struct
  (* r1 drives rst_sync_n. Initial value irrelevant: every scenario starts with rst_n = 0. *)
  type t =
    { mutable r0 : bool
    ; mutable r1 : bool
    }

  let create () = { r0 = false; r1 = false }

  (* value seen by the core during the cycle (async clear acts within the cycle) *)
  let rst_sync_n t ~rst_n = rst_n && t.r1

  let edge t ~rst_n =
    if not rst_n
    then (
      t.r0 <- false;
      t.r1 <- false)
    else (
      t.r1 <- t.r0;
      t.r0 <- true)
  ;;
end

type pin =
  { rst_n : bool
  ; ui_in : int
  ; uio_in : int
  }

let p ?(rst_n = true) ?(run = false) ?(wstb = false) ?(ui_low = 0) uio_in =
  { rst_n
  ; ui_in = (if run then 0x80 else 0) lor (if wstb then 0x40 else 0) lor (ui_low land 0x3f)
  ; uio_in
  }
;;

let repeat n x = List.init n ~f:(fun _ -> x)

(* doc/interface.md section 5: low byte first, uio_in stable >= 3 cycles around each WSTB
   rising edge, WSTB high >= 3 and low >= 3 cycles. 4/4 gives margin. *)
let load_words words =
  List.concat_map words ~f:(fun w ->
    List.concat_map [ w land 0xff; (w lsr 8) land 0xff ] ~f:(fun b ->
      repeat 4 (p b) @ repeat 4 (p ~wstb:true b)))
  @ repeat 4 (p 0)
;;

let pad64 words =
  let n = List.length words in
  if n > Isa.imem_depth then failwith "program longer than imem";
  words @ List.init (Isa.imem_depth - n) ~f:(fun _ -> 0)
;;

let power_on_reset = repeat 4 (p ~rst_n:false 0)

(* Same distribution as rtl/test/test_rtl.ml random_instr (duplicated; keep in sync). *)
let random_instr rs =
  let r n = Random.State.int rs n in
  match r 10 with
  | 0 -> Isa.Jmp (r 64)
  | 1 -> Out (r 256)
  | 2 -> Outb (r 8)
  | 3 -> Ldi (r 256)
  | 4 -> In
  | 5 -> Wait (if r 8 = 0 then r 4096 else r 6)
  | 6 -> Ldc (r 256)
  | 7 -> Djnz (r 64)
  | 8 -> Reserved (8 + r 8)
  | _ -> Out (r 256)
;;

let asm prog = Array.to_list (Isa.assemble prog)

let scenarios () =
  let uart d = pad64 (asm (Programs.uart_tx ~d))
  and qed d = pad64 (asm (Programs.uart_tx_unrolled ~d)) in
  let random seed =
    let rs = Random.State.make [| 11; seed |] in
    let word () =
      if Random.State.int rs 10 = 0
      then Random.State.int rs 0x10000
      else Isa.encode (random_instr rs)
    in
    let phase () =
      List.init
        (300 + Random.State.int rs 300)
        ~f:(fun _ ->
          if Random.State.int rs 500 = 0
          then p ~rst_n:false 0
          else (
            let run = Random.State.int rs 60 <> 0 in
            p
              ~run
              ~wstb:(Random.State.bool rs)
              ~ui_low:(Random.State.int rs 64)
              (Random.State.int rs 256)))
    in
    let w1 = List.init Isa.imem_depth ~f:(fun _ -> word ()) in
    let w2 = List.init (Random.State.int rs 64) ~f:(fun _ -> Isa.encode (random_instr rs)) in
    power_on_reset @ load_words w1 @ phase () @ load_words w2 @ phase ()
  in
  [ ( "uart_d4"
    , (* load, run, one-cycle RUN drop, run *)
      power_on_reset
      @ load_words (uart 4)
      @ repeat 400 (p ~run:true 0xa5)
      @ repeat 1 (p 0xa5)
      @ repeat 300 (p ~run:true 0x5a) )
  ; ( "qed_d5_reload"
    , (* run UART d=3, halt, reload the timed-QED twin at d=5, run *)
      power_on_reset
      @ load_words (uart 3)
      @ repeat 300 (p ~run:true 0x3c)
      @ repeat 6 (p 0)
      @ load_words (qed 5)
      @ repeat 400 (p ~run:true 0xc3) )
  ; ( "reset_then_reload"
    , (* reset mid-run with RUN held high: imem is retained and execution restarts at 0;
         then halt and reload a different program (the demo-board flow after deselect) *)
      power_on_reset
      @ load_words (uart 4)
      @ repeat 250 (p ~run:true 0x81)
      @ repeat 3 (p ~rst_n:false ~run:true 0x81)
      @ repeat 250 (p ~run:true 0x7e)
      @ repeat 6 (p 0)
      @ load_words (qed 3)
      @ repeat 300 (p ~run:true 0x18) )
  ; "random_1", random 1
  ; "random_2", random 2
  ; "random_3", random 3
  ]
;;

let () =
  let dir = (Sys.get_argv ()).(1) in
  List.iter (scenarios ()) ~f:(fun (name, pins) ->
    let st = Interp.create ~imem:(Array.create ~len:Isa.imem_depth 0)
    and rs = Rst_sync.create () in
    let oc = Out_channel.create (dir ^/ name ^ ".vec") in
    List.iter pins ~f:(fun (x : pin) ->
      let o = Interp.outputs st in
      fprintf
        oc
        "%d %02x %02x %02x %02x %02x\n"
        (Bool.to_int x.rst_n)
        x.ui_in
        x.uio_in
        o.uio_oe
        o.uio_out
        o.uo_out;
      let rst_sync_n = Rst_sync.rst_sync_n rs ~rst_n:x.rst_n in
      Interp.step st { rst_sync_n; ui_in = x.ui_in; uio_in = x.uio_in };
      Rst_sync.edge rs ~rst_n:x.rst_n);
    Out_channel.close oc;
    printf "%s %d\n" name (List.length pins))
;;
