(* Test helpers: input-sequence builders and drivers for the interpreter and the circuit. *)
open! Core
open Pemu_spec

type vec = Interp.inputs

let v ?(rst_sync_n = true) ?(run = false) ?(wstb = false) ?(ui_low = 0) uio_in : vec =
  { rst_sync_n
  ; ui_in = (if run then 0x80 else 0) lor (if wstb then 0x40 else 0) lor (ui_low land 0x3f)
  ; uio_in
  }
;;

let repeat n x = List.init n ~f:(fun _ -> x)

(* Program-load byte sequence per interface section 5: each byte is held with WSTB low
   for 4 cycles, then WSTB high for 4 cycles (>= 3 cycles setup/hold/pulse). *)
let load_bytes bytes =
  List.concat_map bytes ~f:(fun b -> repeat 4 (v b) @ repeat 4 (v ~wstb:true b))
  @ repeat 4 (v 0)
;;

let load_words words =
  load_bytes (List.concat_map words ~f:(fun w -> [ w land 0xff; (w lsr 8) land 0xff ]))
;;

let reset_seq = repeat 2 (v ~rst_sync_n:false 0)

(* Run the interpreter over a vector list; return the uo_out value of every cycle. *)
let run_interp ?(imem = Array.create ~len:Isa.imem_depth 0) vecs =
  let st = Interp.create ~imem in
  let q = Queue.create () in
  List.iter vecs ~f:(fun i ->
    Queue.enqueue q (Interp.outputs st);
    Interp.step st i);
  Queue.to_list q, st
;;

module Sim = Hardcaml.Cyclesim.With_interface (Spec_circuit.I) (Spec_circuit.O)

let make_sim () = Sim.create Spec_circuit.create

(* Drive the circuit; outputs are sampled BEFORE each clock edge, i.e. during the cycle. *)
let run_circuit sim vecs =
  let open Hardcaml in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs ~clock_edge:Before sim in
  let q = Queue.create () in
  List.iter vecs ~f:(fun (i : vec) ->
    inp.Spec_circuit.I.rst_sync_n := Bits.of_bool i.rst_sync_n;
    inp.ui_in := Bits.of_int ~width:8 i.ui_in;
    inp.uio_in := Bits.of_int ~width:8 i.uio_in;
    Cyclesim.cycle sim;
    Queue.enqueue
      q
      { Interp.uo_out = Bits.to_int !(outp.Spec_circuit.O.uo_out)
      ; uio_out = Bits.to_int !(outp.uio_out)
      ; uio_oe = Bits.to_int !(outp.uio_oe)
      });
  Queue.to_list q
;;

(* Run-length encode one output bit: [(level, cycles)]. *)
let rle_bit bit (outs : Interp.outputs list) =
  let levels = List.map outs ~f:(fun o -> (o.uo_out lsr bit) land 1) in
  List.fold levels ~init:[] ~f:(fun acc l ->
    match acc with
    | (l', n) :: rest when l = l' -> (l, n + 1) :: rest
    | _ -> (l, 1) :: acc)
  |> List.rev
;;

let print_rle rle =
  print_endline (String.concat ~sep:" " (List.map rle ~f:(fun (l, n) -> sprintf "%d:%d" l n)))
;;
