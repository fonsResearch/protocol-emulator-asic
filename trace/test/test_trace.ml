open! Core
open Hardcaml
open Pemu_trace
open Pemu_spec

(* Build a trace from the spec interpreter: inputs applied, outputs observed per cycle. *)
let trace_of_interp (vecs : Interp.inputs list) : Pin_trace.t =
  let st = Interp.create ~imem:(Array.create ~len:Isa.imem_depth 0) in
  List.mapi vecs ~f:(fun cycle (i : Interp.inputs) ->
    let o = Interp.outputs st in
    Interp.step st i;
    { Pin_trace.cycle
    ; rst_n = i.rst_sync_n
    ; ui_in = i.ui_in
    ; uio_in = i.uio_in
    ; uo_out = o.uo_out
    ; uio_out = o.uio_out
    ; uio_oe = o.uio_oe
    })
;;

let vecs () =
  let v ?(rst = true) ?(run = false) ?(wstb = false) b : Interp.inputs =
    { rst_sync_n = rst; ui_in = (if run then 0x80 else 0) lor (if wstb then 0x40 else 0); uio_in = b }
  in
  let rep n x = List.init n ~f:(fun _ -> x) in
  let load ws =
    List.concat_map ws ~f:(fun w ->
      List.concat_map [ w land 0xff; w lsr 8 ] ~f:(fun b -> rep 4 (v b) @ rep 4 (v ~wstb:true b)))
  in
  rep 2 (v ~rst:false 0)
  @ load (Array.to_list (Isa.assemble (Programs.uart_tx ~d:3)))
  @ rep 60 (v ~run:true 0x81)
;;

module Sim = Cyclesim.With_interface (Pemu_rtl.Engine.I) (Pemu_rtl.Engine.O)

let rtl_sim () = Sim.create (Pemu_rtl.Engine.create ~sram:(Pemu_rtl.Sram.behavioural ?name_prefix:None))

let%expect_test "text format: header, lines, round trip" =
  let t = trace_of_interp (vecs ()) in
  let s = Pin_trace.to_string t in
  List.iter (List.take (String.split_lines s) 4) ~f:print_endline;
  printf "samples=%d round_trip_equal=%b\n" (List.length t) (Pin_trace.equal t (Pin_trace.of_string s));
  [%expect {|
    # pemu-trace v1: cycle rst_n ui_in uio_in uo_out uio_out uio_oe
    0 0 00 00 00 00 00
    1 0 00 00 00 00 00
    2 1 00 01 00 00 00
    samples=1086 round_trip_equal=true
    |}]
;;

let%expect_test "replay: spec-derived trace replays on the RTL with no mismatch" =
  let t = trace_of_interp (vecs ()) in
  print_s [%sexp (Pin_trace.replay (rtl_sim ()) t : Pin_trace.mismatch option)];
  [%expect {| () |}]
;;

let%expect_test "replay: a corrupted expected output is reported at the right cycle" =
  let t = trace_of_interp (vecs ()) in
  let n = List.length t - 10 in
  let t' = List.map t ~f:(fun s -> if s.cycle = n then { s with uo_out = s.uo_out lxor 1 } else s) in
  (match Pin_trace.replay (rtl_sim ()) t' with
   | Some m -> printf "mismatch at cycle %d (corrupted %d)\n" m.at_cycle n
   | None -> print_endline "no mismatch (WRONG)");
  [%expect {| mismatch at cycle 1076 (corrupted 1076) |}]
;;
