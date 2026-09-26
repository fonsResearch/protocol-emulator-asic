open! Core
open Pemu_spec
open Harness

let%expect_test "encode/decode: decode is total; encode(decode w) clears only must-be-zero bits" =
  let mismatches = ref 0 in
  for w = 0 to 0xffff do
    let op = w lsr 12 in
    let mbz_mask =
      match op with
      | 0x0 | 0x7 -> 0x0fc0
      | 0x1 | 0x3 | 0x6 -> 0x0f00
      | 0x2 -> 0x0ff8
      | 0x4 -> 0x0fff
      | 0x5 -> 0
      | _ -> 0x0fff
    in
    if Isa.encode (Isa.decode w) <> w land lnot mbz_mask then incr mismatches
  done;
  printf "mismatches: %d\n" !mismatches;
  [%expect {| mismatches: 0 |}]
;;

(* Trace the interpreter from reset with RUN held high; print cycle, running, pc, out. *)
let trace_prog ?(uio = 0) ~cycles prog =
  let imem = Isa.assemble prog in
  let st = Interp.create ~imem in
  List.iter reset_seq ~f:(Interp.step st);
  for c = 0 to cycles - 1 do
    printf
      "c%02d run=%d pc=%02d wait=%d/%d out=%02x\n"
      c
      (Bool.to_int (Interp.running st))
      st.pc
      (Bool.to_int st.waiting)
      st.wait_cnt
      st.out;
    Interp.step st (v ~run:true uio)
  done
;;

let%expect_test "timing: RUN latency, OUT pin latency, WAIT k = k+1 cycles, JMP" =
  trace_prog ~cycles:12 Isa.[ Out 0x01; Wait 2; Out 0x02; Jmp 0 ];
  [%expect {|
    c00 run=0 pc=00 wait=0/0 out=00
    c01 run=0 pc=00 wait=0/0 out=00
    c02 run=1 pc=00 wait=0/0 out=00
    c03 run=1 pc=01 wait=0/0 out=01
    c04 run=1 pc=01 wait=1/1 out=01
    c05 run=1 pc=01 wait=1/0 out=01
    c06 run=1 pc=02 wait=0/0 out=01
    c07 run=1 pc=03 wait=0/0 out=02
    c08 run=1 pc=00 wait=0/0 out=02
    c09 run=1 pc=01 wait=0/0 out=01
    c10 run=1 pc=01 wait=1/1 out=01
    c11 run=1 pc=01 wait=1/0 out=01
    |}]
;;

let%expect_test "timing: LDC/DJNZ loop, OUTB shifts sr LSB-first, LDI, IN" =
  trace_prog ~uio:0x5a ~cycles:14 Isa.[ Ldi 0x05; Ldc 3; Outb 1; Djnz 2; In; Outb 7; Jmp 5 ];
  [%expect {|
    c00 run=0 pc=00 wait=0/0 out=00
    c01 run=0 pc=00 wait=0/0 out=00
    c02 run=1 pc=00 wait=0/0 out=00
    c03 run=1 pc=01 wait=0/0 out=00
    c04 run=1 pc=02 wait=0/0 out=00
    c05 run=1 pc=03 wait=0/0 out=02
    c06 run=1 pc=02 wait=0/0 out=02
    c07 run=1 pc=03 wait=0/0 out=00
    c08 run=1 pc=02 wait=0/0 out=00
    c09 run=1 pc=03 wait=0/0 out=02
    c10 run=1 pc=04 wait=0/0 out=02
    c11 run=1 pc=05 wait=0/0 out=02
    c12 run=1 pc=06 wait=0/0 out=02
    c13 run=1 pc=05 wait=0/0 out=02
    |}]
;;

let%expect_test "timing: reserved opcode is a 1-cycle NOP; WAIT 0 is a 1-cycle NOP" =
  trace_prog ~cycles:7 Isa.[ Reserved 0x9; Wait 0; Out 0x03; Jmp 0 ];
  [%expect {|
    c00 run=0 pc=00 wait=0/0 out=00
    c01 run=0 pc=00 wait=0/0 out=00
    c02 run=1 pc=00 wait=0/0 out=00
    c03 run=1 pc=01 wait=0/0 out=00
    c04 run=1 pc=02 wait=0/0 out=00
    c05 run=1 pc=03 wait=0/0 out=03
    c06 run=1 pc=00 wait=0/0 out=03
    |}]
;;

(* Run the UART program from reset with byte [b] held on uio_in; RLE of uo_out[0] from the
   first cycle in which the machine is running. *)
let uart_rle ~prog ~b ~cycles =
  let imem = Isa.assemble prog in
  let st = Interp.create ~imem in
  List.iter reset_seq ~f:(Interp.step st);
  while not (Interp.running st) do
    Interp.step st (v ~run:true b)
  done;
  let q = Queue.create () in
  for _ = 1 to cycles do
    Queue.enqueue q (Interp.outputs st);
    Interp.step st (v ~run:true b)
  done;
  rle_bit 0 (Queue.to_list q)
;;

let%expect_test "UART TX D=4, byte 0xA5 (LSB first 1,0,1,0,0,1,0,1)" =
  print_rle (uart_rle ~prog:(Programs.uart_tx ~d:4) ~b:0xa5 ~cycles:60);
  [%expect {| 0:1 1:3 0:4 1:4 0:4 1:4 0:8 1:4 0:4 1:11 0:4 1:4 0:4 1:1 |}]
;;

let%expect_test "UART TX known-bad variant D=4: start bit D+1" =
  print_rle (uart_rle ~prog:(Programs.uart_tx_bad_start ~d:4) ~b:0xa5 ~cycles:60);
  [%expect {| 0:1 1:2 0:5 1:4 0:4 1:4 0:8 1:4 0:4 1:10 0:5 1:4 0:4 1:1 |}]
;;

let%expect_test "timed-QED on the spec: P and T(P) give identical uo_out traces" =
  let differing = ref 0
  and runs = ref 0 in
  List.iter [ 3; 4; 5; 7 ] ~f:(fun d ->
    for b = 0 to 255 do
      incr runs;
      let a = uart_rle ~prog:(Programs.uart_tx ~d) ~b ~cycles:(40 * d) in
      let t = uart_rle ~prog:(Programs.uart_tx_unrolled ~d) ~b ~cycles:(40 * d) in
      if not (List.equal (fun (x, n) (y, m) -> x = y && n = m) a t) then incr differing
    done);
  printf "runs=%d differing=%d\n" !runs !differing;
  [%expect {| runs=1024 differing=0 |}]
;;

let%expect_test "program load over pins, then run (interpreter vs circuit)" =
  let words = Array.to_list (Isa.assemble (Programs.uart_tx ~d:4)) in
  let vecs =
    reset_seq @ load_words words @ repeat 70 (v ~run:true 0xa5)
  in
  let outs_i, st = run_interp vecs in
  let outs_c = run_circuit (make_sim ()) vecs in
  printf
    "cycles=%d equal=%b imem_matches_program=%b\n"
    (List.length vecs)
    (List.equal Interp.equal_outputs outs_i outs_c)
    (Array.equal Int.equal st.imem (Isa.assemble (Programs.uart_tx ~d:4)));
  print_rle (List.drop (rle_bit 0 outs_i) 0);
  [%expect {|
    cycles=1100 equal=true imem_matches_program=true
    0:1033 1:3 0:4 1:4 0:4 1:4 0:8 1:4 0:4 1:11 0:4 1:4 0:4 1:4 0:5
    |}]
;;

(* Random instruction with small WAIT counts so programs exercise many instructions. *)
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

let%expect_test "co-simulation: interpreter vs spec-as-circuit on random programs and inputs" =
  let rs = Random.State.make [| 20260927 |] in
  let programs = 200
  and failures = ref 0
  and total_cycles = ref 0 in
  for _ = 1 to programs do
    let n = 1 + Random.State.int rs 64 in
    let words =
      List.init n ~f:(fun _ ->
        if Random.State.int rs 10 = 0
        then Random.State.int rs 0x10000 (* raw word: exercises must-be-zero bits *)
        else Isa.encode (random_instr rs))
    in
    let run_phase =
      List.init (300 + Random.State.int rs 300) ~f:(fun _ ->
        let run = Random.State.int rs 100 <> 0 in
        (* RUN mostly high, occasional drops *)
        let wstb = Random.State.bool rs in
        if Random.State.int rs 500 = 0
        then v ~rst_sync_n:false 0
        else v ~run ~wstb ~ui_low:(Random.State.int rs 64) (Random.State.int rs 256))
    in
    let vecs = reset_seq @ load_words words @ run_phase in
    total_cycles := !total_cycles + List.length vecs;
    let outs_i, _ = run_interp vecs in
    let outs_c = run_circuit (make_sim ()) vecs in
    if not (List.equal Interp.equal_outputs outs_i outs_c) then incr failures
  done;
  printf "programs=%d failures=%d total_cycles>=%d\n" programs !failures (!total_cycles / 1000 * 1000);
  [%expect {| programs=200 failures=0 total_cycles>=201000 |}]
;;
