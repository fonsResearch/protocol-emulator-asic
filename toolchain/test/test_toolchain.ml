(* Toolchain checks (doc/toolchain.md section 5). *)
open! Core
module A = Pemu_toolchain.Asm
module S = Pemu_toolchain.Shipped
module Cc = Pemu_toolchain.Cc
module I = Pemu_spec_v1.Isa1
module L = Pemu_monitor_v1.Lang

let words_of prog = Array.to_list (Array.sub (I.assemble prog) ~pos:0 ~len:(List.length prog))

let%expect_test "decoder: canonical words only, and decode is the inverse of encode" =
  (* every 16-bit word: if it decodes, re-encoding gives the word back (canonicality); count them *)
  let n = ref 0 and bad = ref 0 in
  for w = 0 to 0xFFFF do
    match A.decode w with
    | Some x -> incr n; if I.encode x <> w then incr bad
    | None -> ()
  done;
  printf "canonical words %d, re-encode mismatches %d\n" !n !bad;
  [%expect {| canonical words 14752, re-encode mismatches 0 |}]
;;

let%expect_test "shipped firmware: disassemble -> assemble round trip, instruction by instruction" =
  List.iter (S.programs ()) ~f:(fun p ->
    let w = words_of p.prog in
    let dec_ok = List.for_all2_exn w p.prog ~f:(fun w x -> [%equal: I.t option] (A.decode w) (Some x)) in
    let src = A.disassemble w in
    match A.assemble src with
    | Error e -> printf "%-22s assemble error line %d: %s\n" p.name e.line e.msg
    | Ok o ->
      printf "%-22s %3d words  decode %s  round trip %s\n" p.name (List.length w) (if dec_ok then "ok" else "MISMATCH")
        (if [%equal: int list] (Array.to_list o.words) w then "identical" else "DIFFERS"));
  [%expect {|
    uart_tx_d4              12 words  decode ok  round trip identical
    uart_rx_d8_pin1          8 words  decode ok  round trip identical
    spi_ctl_m0              15 words  decode ok  round trip identical
    spi_tgt_m0              13 words  decode ok  round trip identical
    i2c_ctl_fm             173 words  decode ok  round trip identical
    i2c_ctl_sm             175 words  decode ok  round trip identical
    i2c_tgt_0x50           142 words  decode ok  round trip identical
    usb_ls_tx               40 words  decode ok  round trip identical
    uart_tx_bad_start_d4    12 words  decode ok  round trip identical
    |}]
;;

let%expect_test "lint on the shipped firmware with its lane configuration" =
  List.iter (S.programs ()) ~f:(fun p ->
    let ws = A.lint ~own:p.own ~od:p.od (Array.of_list (List.map p.prog ~f:Option.some)) in
    printf "%-22s %s\n" p.name
      (if List.is_empty ws then "clean" else String.concat ~sep:"; " (List.map ws ~f:(fun w -> sprintf "%d: %s" w.addr w.what))));
  [%expect {|
    uart_tx_d4             clean
    uart_rx_d8_pin1        clean
    spi_ctl_m0             clean
    spi_tgt_m0             clean
    i2c_ctl_fm             clean
    i2c_ctl_sm             clean
    i2c_tgt_0x50           clean
    usb_ls_tx              clean
    uart_tx_bad_start_d4   clean
    |}]
;;

let%expect_test "assembler errors and lint findings" =
  let t src =
    match A.assemble src with
    | Error e -> printf "error line %d: %s\n" e.line e.msg
    | Ok o ->
      let ws = A.lint ~own:o.meta.own ~od:o.meta.od o.prog in
      printf "ok %s%s\n" (String.concat ~sep:" " (List.map (Array.to_list o.words) ~f:(sprintf "%04X")))
        (if List.is_empty ws then "" else " | " ^ String.concat ~sep:"; " (List.map ws ~f:(fun w -> w.what)))
  in
  t "loop: OUT 1\n JMP loop";
  t "OUT 256";
  t "PUSH lc";
  t "SER SEND r6";
  t "BR maybe, 0";
  t "JMP nowhere";
  t ".equ N 3\n x: WAIT N\n BR nz, x\n HALT";
  t ".own 0x0C\n.od 0x0C\n WAIT 1\n HALT";
  t ".own 0x0C\n.od 0x0C\n OUT 0x0C\n BR 12, 0\n HALT";
  t "ADDI r1, -1\n JMP 5";
  t "a: NOP\na: NOP";
  t ".word 0xF000\n HALT";
  [%expect {|
    ok 2001 0000
    error line 1: ("operand out of range" v (v 256) (lo 0) (hi 255))
    error line 1: "lc" is not a FIFO/SER register operand (r0..r3, sr)
    error line 1: unknown register "r6" (expected one of: r0 r1 r2 r3 sr lc)
    error line 1: unknown condition "maybe" (expected one of: always z nz t nt tx_empty tx_nempty rx_full ser_ready ser_busy lc_nz)
    error line 1: unknown value or label "nowhere"
    ok 5003 1200 E001
    ok 5001 E001 | L1: first instruction is not OUT; open-drain pins 0x0C are pulled low in step 1
    ok 200C 1C00 E001 | L3: BR condition 12 is reserved (never taken)
    ok A1FF 0005 | L2: control target 5 is outside the program (length 2)
    error line 2: duplicate name "a"
    ok F000 E001 | L5: raw .word (not a canonical instruction)
    |}]
;;

let%expect_test "printed view of the ROM library compiles back to the same contracts" =
  let rom = List.map (Cc.rom ()) ~f:(fun (_, c, _) -> c) in
  let printed = Printed_lib.contracts in
  printf "contracts %d printed %d, all equal: %b\n" (List.length rom) (List.length printed)
    (List.equal L.equal rom printed);
  [%expect {| contracts 8 printed 8, all equal: true |}]
;;

let%expect_test "retune: window equivalence" =
  let t idx v =
    match Result.bind (Cc.parse_variant v) ~f:(Cc.retune ~rom_index:idx) with
    | Ok w -> printf "%d %-34s ok [%s]\n" idx v (String.concat ~sep:" " (List.map (Array.to_list w) ~f:Int.to_string))
    | Error e -> printf "%d %-34s refused: %s\n" idx v e
  in
  t 0 "uart_tx:d=4,pin=0";
  t 0 "uart_tx:d=6,pin=0";
  t 0 "uart_tx:d=4,pin=1";
  t 1 "uart_rx:d=10,m=2,pin=1";
  t 2 "spi_ctl:cpol=0,cpha=1,h=2";
  t 4 "i2c_ctl:l=7,h=4,tsu=3,thold=6";
  t 6 "i2c_tgt:h_min=20,l_min=24,hd=20";
  t 7 "usb_ls_tx";
  t 0 "uart_tx:d=4";
  t 0 "uart_tx:d=4,pin=0,x=1";
  [%expect {|
    0 uart_tx:d=4,pin=0                  ok [0 2 4 42 0 0 0 0]
    0 uart_tx:d=6,pin=0                  ok [0 2 6 62 0 0 0 0]
    0 uart_tx:d=4,pin=1                  refused: uart_tx_v1_d4_p1 is not window-equivalent to ROM 0 (uart_tx_v1_d4_p0): differs in remap
    1 uart_rx:d=10,m=2,pin=1             refused: uart_rx_v1_d10_m2_p1 is not window-equivalent to ROM 1 (uart_rx_v1_d8_m2_p1): differs in units
    2 spi_ctl:cpol=0,cpha=1,h=2          refused: spi_ctl_v1_m1_h2 is not window-equivalent to ROM 2 (spi_ctl_v1_m0_h2): differs in units
    4 i2c_ctl:l=7,h=4,tsu=3,thold=6      refused: compile: window table full (8 entries)
    6 i2c_tgt:h_min=20,l_min=24,hd=20    ok [0 1 4095 23 19 18 4 0]
    7 usb_ls_tx                          ok [0 2 4095 1 103 7 15 8]
    0 uart_tx:d=4                        refused: uart_tx: missing parameter pin=
    0 uart_tx:d=4,pin=0,x=1              refused: uart_tx: unknown parameter "x" (parameters: d pin)
    |}]
;;

let%expect_test "examples assemble without errors or warnings" =
  let dir = "../examples" in
  let files =
    Stdlib.Sys.readdir dir |> Array.to_list |> List.filter ~f:(String.is_suffix ~suffix:".s") |> List.sort ~compare:String.compare
  in
  List.iter files ~f:(fun f ->
    match A.assemble (In_channel.read_all (dir ^/ f)) with
    | Error e -> printf "%-24s error line %d: %s\n" f e.line e.msg
    | Ok o ->
      let ws = A.lint ~own:o.meta.own ~od:o.meta.od o.prog in
      printf "%-24s %3d words %s\n" f (Array.length o.words)
        (if List.is_empty ws then "clean" else String.concat ~sep:"; " (List.map ws ~f:(fun w -> w.what))));
  [%expect {|
    blink.s                    7 words clean
    uart_rx_d8.s               8 words clean
    uart_tx_d4.s              12 words clean
    uart_tx_d6.s              12 words clean
    |}]
;;

let example f =
  match A.assemble (In_channel.read_all ("../examples" ^/ f)) with
  | Ok o -> o
  | Error e -> failwithf "%s:%d: %s" f e.line e.msg ()
;;

let%expect_test "hand-written examples assemble to the shipped firmware images" =
  let module P1 = Pemu_spec_v1.Programs_v1 in
  List.iter
    [ "uart_tx_d4.s", P1.uart_tx ~d:4; "uart_tx_d6.s", P1.uart_tx ~d:6; "uart_rx_d8.s", P1.uart_rx ~d:8 ~pin:1 ]
    ~f:(fun (f, prog) ->
      printf "%-14s %s\n" f
        (if [%equal: int list] (Array.to_list (example f).words) (words_of prog) then "= shipped image" else "DIFFERS"));
  [%expect {|
    uart_tx_d4.s   = shipped image
    uart_tx_d6.s   = shipped image
    uart_rx_d8.s   = shipped image
    |}]
;;

(* the retune flow end to end in Psim: d = 6 firmware under the window-retuned ROM 0 contract *)
let%expect_test "retuned UART TX (d = 6, P = 42) runs clean and sends the host bytes" =
  let module Psim = Pemu_protocols_v1.Psim in
  let o = example "uart_tx_d6.s" in
  let prog = Array.to_list o.prog |> List.filter_opt in
  let contract = Result.ok_or_failwith (Cc.parse_variant "uart_tx:d=6,pin=0") in
  let w = Result.ok_or_failwith (Cc.retune ~rom_index:0 contract) in
  let setup =
    { Psim.prog; own = o.meta.own; od = 0; cfg = 0; cfg2 = 0; p = 42; contract; open_drain_wired_and = 0 }
  in
  let bytes = [ 0x48; 0x69; 0x0A ] and cycles = 12_000 in
  let r =
    Psim.run ~tx_bytes:bytes ~rx_pop_every:1_000_000_000 ~setup ~cycles
      ~peer:(fun _ -> { Psim.drive_oe = 0; drive_val = 0 }) ()
  in
  (* UART decode of pad 0: 43 cycles per step, 6 steps per bit *)
  let bit = 43 * 6 in
  let pin cy = r.pads.(cy) land 1 in
  let rec dec cy acc =
    if cy + (10 * bit) >= cycles
    then List.rev acc
    else if pin cy = 1 && pin (cy + 1) = 0
    then (
      let s = cy + 1 in
      let b = List.init 8 ~f:(fun i -> pin (s + ((i + 1) * bit) + (bit / 2)) lsl i) |> List.fold ~init:0 ~f:( lor ) in
      let stop = pin (s + (9 * bit) + (bit / 2)) in
      dec (s + (9 * bit) + (bit / 2)) ((b, stop) :: acc))
    else dec (cy + 1) acc
  in
  printf "windows [%s]\nfirings [%s]\ndecoded %s\n"
    (String.concat ~sep:" " (List.map (Array.to_list w) ~f:Int.to_string))
    (Psim.show_firings r)
    (String.concat ~sep:" " (List.map (dec 0 []) ~f:(fun (b, s) -> sprintf "%02X%s" b (if s = 1 then "" else "(no stop)"))));
  [%expect {|
    windows [0 2 6 62 0 0 0 0]
    firings []
    decoded 48 69 0A
    |}]
;;
