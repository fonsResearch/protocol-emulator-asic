(* Classify register-bit pairs of the SPI target CPOL symmetry miter (m3 vs m1 with SCLK
   inverted) by random simulation: always equal, always complement, or other, counted only in
   cycles at least [warm] cycles after reset release with run held high. *)
open! Core
open Hardcaml
module A = Pemu_formal.Ag_pkg
module P1 = Pemu_spec_v1.Programs_v1
module Lib = Pemu_monitor_v1.Library_v1

let () =
  let pkg (cpol, cpha) = P1.spi_tgt ~cpol ~cpha, Lib.spi_tgt ~cpol ~cpha ~h_min:3 ~g:6 in
  let circ, wa, wb, shared, mems, names =
    A.sym_regs_circuit ~rx_never_full:true ~pop_pcs:[ 2 ] ~mode:`U ~flip:0x20 ~a:(pkg (true, true))
      ~b:(pkg (false, true)) ~own:P1.spi_own_tgt ~od:0 ~cfg:0 ~cfg2:0 ()
  in
  printf "regs A %d (%d bits), regs B %d (%d bits), shared %d, memories %d, widths equal %b\n"
    (List.length wa) (List.sum (module Int) wa ~f:Fn.id) (List.length wb) (List.sum (module Int) wb ~f:Fn.id)
    shared mems (List.equal Int.equal wa wb);
  let sim = Cyclesim.create circ in
  let ra = Cyclesim.out_port sim "regs_a" and rb = Cyclesim.out_port sim "regs_b" in
  let dif = Cyclesim.out_port sim "obs_diff" in
  let n = List.sum (module Int) wa ~f:Fn.id in
  let eq = Array.create ~len:n true and cp = Array.create ~len:n true in
  let rng = Random.State.make [| 5 |] in
  let set name v = let p = Cyclesim.in_port sim name in p := Bits.of_int ~width:(Bits.width !p) v in
  let diffs = ref 0 in
  for run = 0 to 19 do
    for c = 0 to 1999 do
      let r i = Random.State.int rng i in
      set "rst_sync_n" (if c = 0 then 0 else 1); set "run" (if c < 3 then 0 else 1);
      set "tick" (r 2); set "uio_in" (r 256); set "tx_push" (r 2); set "tx_wdata" (r 256);
      set "rx_pop" 1; set "clear_fault" (if r 50 = 0 then 1 else 0);
      Cyclesim.cycle sim;
      if Bits.to_bool !dif then incr diffs;
      if c >= 12 then (
        let a = !ra and b = !rb in
        for i = 0 to n - 1 do
          let x = Bits.to_bool (Bits.select a i i) and y = Bits.to_bool (Bits.select b i i) in
          if Bool.(x <> y) then eq.(i) <- false;
          if Bool.(x = y) then cp.(i) <- false
        done)
    done;
    ignore run
  done;
  let ne = Array.count eq ~f:Fn.id and nc = Array.count cp ~f:Fn.id in
  printf "bits: equal %d, complement %d, other %d; obs differences %d\n" ne nc (n - ne - nc) !diffs;
  (* report complement/other bits by register index *)
  let off = ref 0 in
  List.iteri wa ~f:(fun k w ->
    let bits = List.init w ~f:(fun j -> !off + j) in
    let c = List.filter bits ~f:(fun i -> cp.(i)) and o = List.filter bits ~f:(fun i -> not eq.(i) && not cp.(i)) in
    if not (List.is_empty c && List.is_empty o) then
      printf "  reg %3d %-16s width %2d: complement bits %s other bits %s\n" k
        (List.nth_exn names k) w (String.concat ~sep:"," (List.map c ~f:(fun i -> Int.to_string (i - !off))))
        (String.concat ~sep:"," (List.map o ~f:(fun i -> Int.to_string (i - !off))));
    off := !off + w)
;;
