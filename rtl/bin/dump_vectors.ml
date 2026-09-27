(* Write stimulus and expected-output files for the gate/macro-level Verilog check.
   usage: dump_vectors.exe <dir>
   vectors.hex: one line per cycle, {rst_sync_n, ui_in[7:0], uio_in[7:0]} as 5 hex digits
   expected.hex: one line per cycle, {uio_oe, uio_out, uo_out} as 6 hex digits, sampled
   during the cycle (before the clock edge), from the spec interpreter. *)
open! Core
open Pemu_spec

let v ?(rst_sync_n = true) ?(run = false) ?(wstb = false) uio_in : Interp.inputs =
  { rst_sync_n; ui_in = (if run then 0x80 else 0) lor (if wstb then 0x40 else 0); uio_in }
;;

let repeat n x = List.init n ~f:(fun _ -> x)

let load_words words =
  List.concat_map words ~f:(fun w ->
    List.concat_map [ w land 0xff; (w lsr 8) land 0xff ] ~f:(fun b ->
      repeat 4 (v b) @ repeat 4 (v ~wstb:true b)))
  @ repeat 4 (v 0)
;;

let () =
  let dir = (Sys.get_argv ()).(1) in
  let prog d = Array.to_list (Isa.assemble (Programs.uart_tx ~d)) in
  let qed d = Array.to_list (Isa.assemble (Programs.uart_tx_unrolled ~d)) in
  let vecs =
    repeat 3 (v ~rst_sync_n:false 0)
    @ load_words (prog 4)
    @ repeat 200 (v ~run:true 0xa5)
    @ repeat 1 (v 0xa5)
    @ repeat 150 (v ~run:true 0x5a)
    @ repeat 5 (v 0)
    @ load_words (qed 5)
    @ repeat 300 (v ~run:true 0xc3)
  in
  let st = Interp.create ~imem:(Array.create ~len:Isa.imem_depth 0) in
  let vo = Out_channel.create (dir ^/ "vectors.hex")
  and eo = Out_channel.create (dir ^/ "expected.hex") in
  List.iter vecs ~f:(fun (i : Interp.inputs) ->
    let o = Interp.outputs st in
    fprintf vo "%05x\n" ((Bool.to_int i.rst_sync_n lsl 16) lor (i.ui_in lsl 8) lor i.uio_in);
    fprintf eo "%02x%02x%02x\n" o.uio_oe o.uio_out o.uo_out;
    Interp.step st i);
  Out_channel.close vo;
  Out_channel.close eo;
  printf "%d cycles\n" (List.length vecs)
;;
