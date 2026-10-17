(* Core v1 through its pins: a bit-banged SPI host (mode 0; SCK half period 6 cycles; MOSI
   changed while SCK is low; MISO sampled in the cycle before each rising edge) loads and runs
   programs. Behavioural SRAMs. *)
open! Core
open Hardcaml
open Pemu_spec_v1
open Pemu_rtl_v1
module Sim = Cyclesim.With_interface (Top_v1.I) (Top_v1.O)

type h =
  { sim : (Bits.t ref Top_v1.I.t, Bits.t ref Top_v1.O.t) Cyclesim.t
  ; mutable cs_n : bool
  ; mutable sck : bool
  ; mutable mosi : bool
  ; mutable uio_in : int
  ; mutable trace : (int * int * int) list (* uo_out, uio_out, uio_oe per cycle, reversed *)
  }

let cycle h =
  let i = Cyclesim.inputs h.sim
  and o = Cyclesim.outputs ~clock_edge:Before h.sim in
  i.rst_sync_n := Bits.vdd;
  i.ui_in
  := Bits.of_int ~width:8 ((Bool.to_int h.cs_n) lor (Bool.to_int h.sck lsl 1) lor (Bool.to_int h.mosi lsl 2));
  i.uio_in := Bits.of_int ~width:8 h.uio_in;
  Cyclesim.cycle h.sim;
  h.trace <- (Bits.to_int !(o.uo_out), Bits.to_int !(o.uio_out), Bits.to_int !(o.uio_oe)) :: h.trace
;;

let wait h n = for _ = 1 to n do cycle h done

let miso h =
  match h.trace with
  | (uo, _, _) :: _ -> uo land 1
  | [] -> 0
;;

let xfer_byte h b =
  let r = ref 0 in
  for k = 7 downto 0 do
    h.mosi <- (b lsr k) land 1 = 1;
    wait h 6;
    r := (!r lsl 1) lor miso h;
    h.sck <- true;
    wait h 6;
    h.sck <- false
  done;
  !r
;;

let transaction h bytes =
  h.cs_n <- false;
  wait h 6;
  let out = List.map bytes ~f:(xfer_byte h) in
  wait h 6;
  h.cs_n <- true;
  wait h 8;
  out
;;

let write h addr data = ignore (transaction h ((addr land 0x7F) :: data) : int list)
let read h addr n = List.tl_exn (transaction h ((0x80 lor addr) :: List.init n ~f:(fun _ -> 0)))

let create () =
  let sim =
    Sim.create ~config:Cyclesim.Config.trace_all
      (Top_v1.create ~sram:(fun _ i -> fst (Sram256.behavioural i)))
  in
  let h = { sim; cs_n = true; sck = false; mosi = false; uio_in = 0xFF; trace = [] } in
  let i = Cyclesim.inputs sim in
  i.rst_sync_n := Bits.gnd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  wait h 4;
  h
;;

let load h ~lane prog =
  let b = 0x10 + (16 * lane) in
  let words = Isa1.assemble prog in
  write h (b + 4) [ List.length prog ];
  write h (b + 7) [ 0 ];
  write h (b + 8) (List.concat_map (List.init (List.length prog) ~f:Fn.id) ~f:(fun a ->
    [ words.(a) land 0xFF; words.(a) lsr 8 ]))
;;

(* decode one 8N1 frame on uio pin [pin] from the cycle trace, [bit_cycles] per bit *)
let decode_uart trace ~pin ~bit_cycles =
  let line =
    List.rev_map trace ~f:(fun (_, out, oe) ->
      if (oe lsr pin) land 1 = 1 then (out lsr pin) land 1 else 1)
    |> Array.of_list
  in
  match Array.findi line ~f:(fun i v -> i > 0 && v = 0 && line.(i - 1) = 1) with
  | None -> None
  | Some (s, _) ->
    let at k = line.(s + (k * bit_cycles) + (bit_cycles / 2)) in
    let data = List.init 8 ~f:(fun k -> at (k + 1) lsl k) |> List.fold ~init:0 ~f:( lor ) in
    Some (at 0, data, at 9)
;;

let%expect_test "core v1 over SPI: ID, UART TX on lane 0, OWN overlap, RX FIFO and HALT on lane 1" =
  let h = create () in
  printf "ID 0x%02X\n" (List.hd_exn (read h 0x00 1));
  (* lane 0: UART TX, d = 3 steps per bit, P = 9 -> 30 cycles per bit *)
  write h 0x10 [ 0x01 ];
  write h 0x12 [ 9; 0 ];
  load h ~lane:0 (Programs_v1.uart_tx ~d:3);
  printf "L0 FLAGS 0x%02X (loaded = bit2)\n" (List.hd_exn (read h 0x1D 1));
  (* lane 1: OWN overlapping lane 0 is rejected *)
  write h 0x20 [ 0x03 ];
  let rej = List.hd_exn (read h 0x20 1) in
  write h 0x20 [ 0x02 ];
  printf "L1 OWN after 0x03: 0x%02X, after 0x02: 0x%02X\n" rej (List.hd_exn (read h 0x20 1));
  load h ~lane:1 Isa1.[ Ldi (L R0, 0x42); Push R0; Ldi (L R0, 0x43); Push R0; Halt ];
  h.trace <- [];
  write h 0x19 [ 0xA5 ];
  write h 0x01 [ 0x03 ];
  wait h 400;
  (match decode_uart h.trace ~pin:0 ~bit_cycles:30 with
   | Some (start, data, stop) -> printf "UART on uio[0]: start %d data 0x%02X stop %d\n" start data stop
   | None -> print_endline "UART: no frame");
  let st = List.hd_exn (read h 0x02 1)
  and fault = List.hd_exn (read h 0x03 1)
  and fifo = List.hd_exn (read h 0x2B 1) in
  printf "STATUS 0x%02X FAULT 0x%02X L1 FIFO_ST 0x%02X\n" st fault fifo;
  let rx = read h 0x2A 2 in
  printf "L1 RXF read x2: %s; FIFO_ST after 0x%02X; L1 FLAGS 0x%02X\n"
    (String.concat ~sep:" " (List.map rx ~f:(sprintf "0x%02X")))
    (List.hd_exn (read h 0x2B 1)) (List.hd_exn (read h 0x2D 1));
  let uo, _, _ = List.hd_exn h.trace in
  printf "uo_out[7] any-fault %d; MISO idle %d\n" ((uo lsr 7) land 1) (uo land 1);
  [%expect {|
    ID 0xA1
    L0 FLAGS 0x04 (loaded = bit2)
    L1 OWN after 0x03: 0x00, after 0x02: 0x02
    UART on uio[0]: start 0 data 0xA5 stop 1
    STATUS 0x2D FAULT 0x30 L1 FIFO_ST 0x20
    L1 RXF read x2: 0x42 0x43; FIFO_ST after 0x00; L1 FLAGS 0x04
    uo_out[7] any-fault 1; MISO idle 0
    |}]
;;

(* Structural non-interference: the fan-in cone of every input of lane L contains no signal
   built by the other lane's prescaler or Lane_rtl.create, except through the other lane's
   OWN register (the designed host-side coupling: OWN overlap rejection, and whether the
   other lane is halted decides whether its OWN can change). Without that boundary the check
   must find the coupling (sensitivity). *)
let%expect_test "structural non-interference between lanes" =
  let i =
    { Top_v1.I.clock = Signal.input "clock" 1
    ; rst_sync_n = Signal.input "rst_sync_n" 1
    ; ui_in = Signal.input "ui_in" 8
    ; uio_in = Signal.input "uio_in" 8
    }
  in
  let _, d = Top_v1.create_with_debug ~sram:(fun _ x -> fst (Sram256.behavioural x)) i in
  let in_ranges l u = List.exists d.lane_uids.(l) ~f:(fun (a, b) -> u > a && u < b) in
  let hits ~l ~boundary =
    let other = 1 - l in
    let roots =
      Lane_rtl.I.to_list d.lane_inputs.(l)
      |> List.filter ~f:(fun s -> not (Signal.is_empty s))
    in
    let g =
      Signal_graph.create ?upto:(if boundary then Some [ d.own.(other) ] else None) roots
    in
    Signal_graph.fold g ~init:0 ~f:(fun n s ->
      if in_ranges other (Signal.Type.Uid.to_int (Signal.uid s)) then n + 1 else n)
  in
  List.iter [ 0; 1 ] ~f:(fun l ->
    printf "lane %d inputs: other-lane signals reached with OWN boundary %d, without %d\n" l
      (hits ~l ~boundary:true) (hits ~l ~boundary:false));
  [%expect {|
    lane 0 inputs: other-lane signals reached with OWN boundary 0, without 3712
    lane 1 inputs: other-lane signals reached with OWN boundary 0, without 3712
    |}]
;;
