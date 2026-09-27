(* RTL tests. The input-sequence builders and the spec interpreter come from pemu_spec
   (agent-independence deferred; see isolation_rules.md). *)
open! Core
open Hardcaml
open Pemu_spec
module Sim = Cyclesim.With_interface (Pemu_rtl.Engine.I) (Pemu_rtl.Engine.O)

type vec = Interp.inputs

let v ?(rst_sync_n = true) ?(run = false) ?(wstb = false) ?(ui_low = 0) uio_in : vec =
  { rst_sync_n
  ; ui_in = (if run then 0x80 else 0) lor (if wstb then 0x40 else 0) lor (ui_low land 0x3f)
  ; uio_in
  }
;;

let repeat n x = List.init n ~f:(fun _ -> x)

let load_words words =
  List.concat_map words ~f:(fun w ->
    List.concat_map [ w land 0xff; (w lsr 8) land 0xff ] ~f:(fun b ->
      repeat 4 (v b) @ repeat 4 (v ~wstb:true b)))
  @ repeat 4 (v 0)
;;

let reset_seq = repeat 2 (v ~rst_sync_n:false 0)

let make_sim ?(trace = false) () =
  let config = if trace then Cyclesim.Config.trace_all else Cyclesim.Config.default in
  Sim.create ~config (Pemu_rtl.Engine.create ~sram:(Pemu_rtl.Sram.behavioural ?name_prefix:None))
;;

let run_rtl sim vecs =
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs ~clock_edge:Before sim in
  let q = Queue.create () in
  List.iter vecs ~f:(fun (i : vec) ->
    inp.Pemu_rtl.Engine.I.rst_sync_n := Bits.of_bool i.rst_sync_n;
    inp.ui_in := Bits.of_int ~width:8 i.ui_in;
    inp.uio_in := Bits.of_int ~width:8 i.uio_in;
    Cyclesim.cycle sim;
    Queue.enqueue
      q
      { Interp.uo_out = Bits.to_int !(outp.Pemu_rtl.Engine.O.uo_out)
      ; uio_out = Bits.to_int !(outp.uio_out)
      ; uio_oe = Bits.to_int !(outp.uio_oe)
      });
  Queue.to_list q
;;

let run_interp vecs =
  let st = Interp.create ~imem:(Array.create ~len:Isa.imem_depth 0) in
  let q = Queue.create () in
  List.iter vecs ~f:(fun i ->
    Queue.enqueue q (Interp.outputs st);
    Interp.step st i);
  Queue.to_list q
;;

let rle_bit bit (outs : Interp.outputs list) =
  List.fold outs ~init:[] ~f:(fun acc o ->
    let l = (o.uo_out lsr bit) land 1 in
    match acc with
    | (l', n) :: rest when l = l' -> (l, n + 1) :: rest
    | _ -> (l, 1) :: acc)
  |> List.rev
  |> List.map ~f:(fun (l, n) -> sprintf "%d:%d" l n)
  |> String.concat ~sep:" "
;;

let first_diff a b =
  List.zip_exn a b
  |> List.findi ~f:(fun _ (x, y) -> not (Interp.equal_outputs x y))
  |> Option.map ~f:fst
;;

let prog_vecs ?(uio = 0) ~run_cycles prog =
  reset_seq
  @ load_words (Array.to_list (Isa.assemble prog))
  @ repeat run_cycles (v ~run:true uio)
;;

let%expect_test "RTL: UART TX D=4 byte 0xA5 matches the spec interpreter cycle for cycle" =
  let vecs = prog_vecs ~uio:0xa5 ~run_cycles:70 (Programs.uart_tx ~d:4) in
  let r = run_rtl (make_sim ()) vecs
  and s = run_interp vecs in
  printf "first_diff=%s\n" (Option.value_map (first_diff r s) ~default:"none" ~f:Int.to_string);
  print_endline (rle_bit 0 r);
  [%expect {|
    first_diff=none
    0:1033 1:3 0:4 1:4 0:4 1:4 0:8 1:4 0:4 1:11 0:4 1:4 0:4 1:4 0:5
    |}]
;;

let%expect_test "RTL waveform: first running cycles of OUT/WAIT/JMP (instr is SRAM A_DOUT)" =
  let prog = Isa.[ Out 0x01; Wait 2; Out 0x02; Jmp 0 ] in
  let vecs = prog_vecs ~run_cycles:12 prog in
  let sim = make_sim ~trace:true () in
  let waves, sim = Hardcaml_waveterm.Waveform.create sim in
  ignore (run_rtl sim vecs : Interp.outputs list);
  let open Hardcaml_waveterm in
  Waveform.print
    ~start_cycle:(List.length vecs - 14)
    ~display_width:92
    ~display_height:24
    ~display_rules:
      [ Display_rule.port_name_is_one_of [ "running"; "waiting" ]
      ; Display_rule.port_name_is_one_of
          ~wave_format:Hex
          [ "pc"; "next_pc"; "instr"; "uo_out" ]
      ]
    waves;
  [%expect {|
    ┌Signals───────────┐┌Waves─────────────────────────────────────────────────────────────────┐
    │                  ││────────────────────────────────┬─────────────────────────────────────│
    │running           ││ 0                              │1                                    │
    │                  ││────────────────────────────────┴─────────────────────────────────────│
    │                  ││────────────────────────────────────────────────┬───────────────┬─────│
    │waiting           ││ 0                                              │1              │0    │
    │                  ││────────────────────────────────────────────────┴───────────────┴─────│
    │                  ││────────────────────────────────────────┬─────────────────────────────│
    │uo_out            ││ 00                                     │01                           │
    │                  ││────────────────────────────────────────┴─────────────────────────────│
    │                  ││────────────────────────────────────────┬───────────────────────┬─────│
    │instr             ││ 1001                                   │5002                   │1002 │
    │                  ││────────────────────────────────────────┴───────────────────────┴─────│
    │                  ││────────────────────────────────────────────────────────┬───────┬─────│
    │next_pc           ││ 01                                                     │02     │03   │
    │                  ││────────────────────────────────────────────────────────┴───────┴─────│
    │                  ││────────────────────────────────────────┬───────────────────────┬─────│
    │pc                ││ 00                                     │01                     │02   │
    │                  ││────────────────────────────────────────┴───────────────────────┴─────│
    │                  ││                                                                      │
    │                  ││                                                                      │
    │                  ││                                                                      │
    │                  ││                                                                      │
    └──────────────────┘└──────────────────────────────────────────────────────────────────────┘
    |}]
;;

let%expect_test "RTL: halt mid-program then restart re-fetches imem[0] correctly" =
  let prog = Programs.uart_tx ~d:5 in
  let vecs =
    reset_seq
    @ load_words (Array.to_list (Isa.assemble prog))
    @ repeat 23 (v ~run:true 0x3c)
    @ repeat 1 (v 0x3c) (* single-cycle RUN drop *)
    @ repeat 40 (v ~run:true 0x3c)
    @ repeat 6 (v 0x3c)
    @ repeat 60 (v ~run:true 0x3c)
  in
  let r = run_rtl (make_sim ()) vecs
  and s = run_interp vecs in
  printf "first_diff=%s\n" (Option.value_map (first_diff r s) ~default:"none" ~f:Int.to_string);
  [%expect {| first_diff=none |}]
;;

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

let%expect_test "cross-check: RTL vs spec interpreter on random programs, loads and RUN toggles" =
  let rs = Random.State.make [| 7; 20260927 |] in
  let programs = 300
  and failures = ref 0
  and cycles = ref 0 in
  for _ = 1 to programs do
    let words =
      List.init (1 + Random.State.int rs 64) ~f:(fun _ ->
        if Random.State.int rs 10 = 0
        then Random.State.int rs 0x10000
        else Isa.encode (random_instr rs))
    in
    let phase () =
      List.init (200 + Random.State.int rs 200) ~f:(fun _ ->
        let run = Random.State.int rs 60 <> 0 in
        if Random.State.int rs 700 = 0
        then v ~rst_sync_n:false 0
        else
          v ~run ~wstb:(Random.State.bool rs) ~ui_low:(Random.State.int rs 64) (Random.State.int rs 256))
    in
    (* load, run with toggles, reload (with RUN low) a second random program, run again *)
    let words2 = List.init (Random.State.int rs 64) ~f:(fun _ -> Isa.encode (random_instr rs)) in
    let vecs = reset_seq @ load_words words @ phase () @ load_words words2 @ phase () in
    cycles := !cycles + List.length vecs;
    let r = run_rtl (make_sim ()) vecs
    and s = run_interp vecs in
    match first_diff r s with
    | None -> ()
    | Some c ->
      incr failures;
      if !failures <= 3 then printf "mismatch at cycle %d\n" c
  done;
  printf "programs=%d failures=%d cycles>=%dk\n" programs !failures (!cycles / 1000);
  [%expect {| programs=300 failures=0 cycles>=475k |}]
;;
