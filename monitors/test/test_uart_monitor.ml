open! Core
open Hardcaml
open Pemu_monitors
module M = Uart_tx_monitor
module MSim = Cyclesim.With_interface (M.I) (M.O)

(* Independent UART 8N1 waveform generator (from doc/protocols/uart.md). *)
let frame ?(start_len = None) ~b byte =
  let bits = List.init 8 ~f:(fun j -> (byte lsr j) land 1 = 1) in
  let rep n x = List.init n ~f:(fun _ -> x) in
  rep (Option.value start_len ~default:b) false
  @ List.concat_map bits ~f:(fun x -> rep b x)
  @ rep b true
;;

let idle n = List.init n ~f:(fun _ -> true)

let run_model ~b lines =
  let m = M.Model.create ~b in
  List.map lines ~f:(M.Model.step m)
;;

let run_circuit ~b lines =
  let sim = MSim.create (M.create ~b) in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs ~clock_edge:Before sim in
  i.clear := Bits.gnd;
  List.map lines ~f:(fun l ->
    i.line := Bits.of_bool l;
    Cyclesim.cycle sim;
    { M.bad = Bits.to_bool !(o.bad)
    ; frame_done = Bits.to_bool !(o.frame_done)
    ; frame_data = Bits.to_int !(o.frame_data)
    ; timeout = Bits.to_bool !(o.timeout)
    })
;;

(* Summarise observations: decoded frames, first bad cycle, first timeout cycle. *)
let summary (obs : M.obs list) =
  let frames =
    List.filter_mapi obs ~f:(fun c o -> if o.frame_done then Some (c, o.frame_data) else None)
  in
  let first f = List.findi obs ~f:(fun _ o -> f o) |> Option.map ~f:fst in
  sprintf
    "frames=[%s] first_bad=%s first_timeout=%s"
    (String.concat ~sep:" " (List.map frames ~f:(fun (_, d) -> sprintf "%02x" d)))
    (Option.value_map (first (fun o -> o.bad)) ~default:"-" ~f:Int.to_string)
    (Option.value_map (first (fun o -> o.timeout)) ~default:"-" ~f:Int.to_string)
;;

let check ~b lines =
  let m = run_model ~b lines
  and c = run_circuit ~b lines in
  printf "b=%d model=circuit:%b  %s\n" b (List.equal M.equal_obs m c) (summary c)
;;

let%expect_test "well-formed frames decode, no violation (b = 3, 4, 7; gaps 0..5)" =
  List.iter [ 3; 4; 7 ] ~f:(fun b ->
    let bytes = [ 0x00; 0xff; 0xa5; 0x5a; 0x01; 0x80 ] in
    let lines =
      idle 2 @ List.concat (List.mapi bytes ~f:(fun gap byte -> frame ~b byte @ idle gap)) @ idle 3
    in
    check ~b lines);
  [%expect {|
    b=3 model=circuit:true  frames=[00 ff a5 5a 01 80] first_bad=- first_timeout=-
    b=4 model=circuit:true  frames=[00 ff a5 5a 01 80] first_bad=- first_timeout=-
    b=7 model=circuit:true  frames=[00 ff a5 5a 01 80] first_bad=- first_timeout=-
    |}]
;;

let%expect_test "negative cases raise bad at the first violating cycle (b = 4)" =
  let b = 4 in
  (* frame starts at cycle 2 (after 2 idle cycles) in every case below *)
  print_endline "start bit b+1 (byte 0xff): first rise at offset 5, expected bad at cycle 7";
  check ~b (idle 2 @ frame ~start_len:(Some (b + 1)) ~b 0xff @ idle 4);
  print_endline "start bit b-1 (byte 0xff): rise at offset 3, expected bad at cycle 5";
  check ~b (idle 2 @ frame ~start_len:(Some (b - 1)) ~b 0xff @ idle 4);
  print_endline "glitch: data bit 0 of 0x00 goes high at offset 6 (off-grid), expected bad at cycle 8";
  check
    ~b
    (idle 2 @ List.mapi (frame ~b 0x00) ~f:(fun k l -> if k = 6 then true else l) @ idle 4);
  print_endline "stop bit low at offset 37 (stop spans 36..39), expected bad at cycle 39";
  check
    ~b
    (idle 2 @ List.mapi (frame ~b 0xff) ~f:(fun k l -> if k = 37 then false else l) @ idle 4);
  print_endline "line stuck low: bad at offset 36 (stop bit) = cycle 38; timeout when run > 40";
  check ~b (idle 2 @ List.init 60 ~f:(fun _ -> false));
  [%expect {|
    start bit b+1 (byte 0xff): first rise at offset 5, expected bad at cycle 7
    b=4 model=circuit:true  frames=[] first_bad=7 first_timeout=-
    start bit b-1 (byte 0xff): rise at offset 3, expected bad at cycle 5
    b=4 model=circuit:true  frames=[] first_bad=5 first_timeout=-
    glitch: data bit 0 of 0x00 goes high at offset 6 (off-grid), expected bad at cycle 8
    b=4 model=circuit:true  frames=[] first_bad=8 first_timeout=-
    stop bit low at offset 37 (stop spans 36..39), expected bad at cycle 39
    b=4 model=circuit:true  frames=[] first_bad=39 first_timeout=-
    line stuck low: bad at offset 36 (stop bit) = cycle 38; timeout when run > 40
    b=4 model=circuit:true  frames=[] first_bad=38 first_timeout=42
    |}]
;;

let%expect_test "co-simulation: circuit vs model on random corrupted line sequences" =
  let rs = Random.State.make [| 42 |] in
  let n = 500
  and mismatches = ref 0
  and with_bad = ref 0 in
  for _ = 1 to n do
    let b = 1 + Random.State.int rs 8 in
    let base =
      idle (Random.State.int rs 4)
      @ List.concat
          (List.init (1 + Random.State.int rs 4) ~f:(fun _ ->
             frame ~b (Random.State.int rs 256) @ idle (Random.State.int rs 3)))
    in
    let lines =
      List.map base ~f:(fun l -> if Random.State.int rs 40 = 0 then not l else l)
      @ (if Random.State.int rs 10 = 0 then List.init (12 * b) ~f:(fun _ -> false) else [])
    in
    let m = run_model ~b lines
    and c = run_circuit ~b lines in
    if not (List.equal M.equal_obs m c) then incr mismatches;
    if List.exists c ~f:(fun o -> o.bad) then incr with_bad
  done;
  printf "sequences=%d mismatches=%d sequences_with_bad=%d\n" n !mismatches !with_bad;
  [%expect {| sequences=500 mismatches=0 sequences_with_bad=413 |}]
;;

(* Integration: the monitor observes uo_out[0] of the RTL core running the reference UART
   program (and the known-bad variant). *)
module RSim = Cyclesim.With_interface (Pemu_rtl.Engine.I) (Pemu_rtl.Engine.O)

let rtl_uart_line ~prog ~byte ~cycles =
  let open Pemu_spec in
  let sim = RSim.create (Pemu_rtl.Engine.create ~sram:(Pemu_rtl.Sram.behavioural ?name_prefix:None)) in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs ~clock_edge:Before sim in
  let drive ~rst ~ui ~uio =
    i.rst_sync_n := Bits.of_bool rst;
    i.ui_in := Bits.of_int ~width:8 ui;
    i.uio_in := Bits.of_int ~width:8 uio;
    Cyclesim.cycle sim;
    Bits.to_int !(o.uo_out) land 1 = 1
  in
  let q = Queue.create () in
  let rec_ ~rst ~ui ~uio = Queue.enqueue q (drive ~rst ~ui ~uio) in
  for _ = 1 to 2 do rec_ ~rst:false ~ui:0 ~uio:0 done;
  Array.iter (Isa.assemble prog) ~f:(fun w ->
    List.iter [ w land 0xff; w lsr 8 ] ~f:(fun b ->
      for _ = 1 to 4 do rec_ ~rst:true ~ui:0 ~uio:b done;
      for _ = 1 to 4 do rec_ ~rst:true ~ui:0x40 ~uio:b done));
  for _ = 1 to cycles do rec_ ~rst:true ~ui:0x80 ~uio:byte done;
  Queue.to_list q
;;

(* Note on [first_timeout]: while the core is halted (reset + program load) it drives
   uo_out = 0x00 (ISA v0.1 section 8.3), which a UART receiver sees as a break longer than
   10 bit periods. The monitor correctly flags this. It is the known v0 halt-value issue,
   planned to be addressed in v1 (protocol pins on uio with uio_oe = 0 while halted). *)
let%expect_test "integration: monitor on RTL uo_out[0], reference program vs known-bad variant" =
  let open Pemu_spec in
  List.iter [ 3; 4; 9 ] ~f:(fun d ->
    let good = rtl_uart_line ~prog:(Programs.uart_tx ~d) ~byte:0x96 ~cycles:(35 * d) in
    let bad = rtl_uart_line ~prog:(Programs.uart_tx_bad_start ~d) ~byte:0x96 ~cycles:(35 * d) in
    printf "d=%d good: %s\n" d (summary (run_circuit ~b:d good));
    printf "d=%d bad : %s\n" d (summary (run_circuit ~b:d bad)));
  [%expect {|
    d=3 good: frames=[96 96 96] first_bad=- first_timeout=30
    d=3 bad : frames=[] first_bad=1038 first_timeout=30
    d=4 good: frames=[96 96 96] first_bad=- first_timeout=40
    d=4 bad : frames=[] first_bad=1040 first_timeout=40
    d=9 good: frames=[96 96 96] first_bad=- first_timeout=90
    d=9 bad : frames=[] first_bad=1050 first_timeout=90
    |}]
;;
