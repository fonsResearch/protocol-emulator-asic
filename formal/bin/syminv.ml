(* Random simulation of the warm-up symmetry invariant (Ag_pkg.sym_inv_harness ~expose):
   checks that the correspondence and the prev_pins fact hold in every cycle with env ok and no
   earlier blame, and collects the unit pcs seen while a cold history entry exists.
   usage: syminv.exe <a_cpol> <a_cpha> <b_cpol> <b_cpha> *)
open! Core
open Hardcaml
module A = Pemu_formal.Ag_pkg
module P1 = Pemu_spec_v1.Programs_v1
module Lib = Pemu_monitor_v1.Library_v1

let () =
  let argv = Sys.get_argv () in
  let b i = String.equal argv.(i) "1" in
  let pkg (cpol, cpha) = P1.spi_tgt ~cpol ~cpha, Lib.spi_tgt ~cpol ~cpha ~h_min:3 ~g:6 in
  let units = [ 0; 1; 2; 3; 4 ] in
  let circ =
    A.sym_inv_harness ~expose:true ~rx_never_full:true ~pop_pcs:[ 2 ] ~mode:`U ~pin:5 ~hist_slot:1
      ~early_units:[] ~a:(pkg (b 1, b 2)) ~b:(pkg (b 3, b 4))
      ~own:P1.spi_own_tgt ~od:0 ~cfg:0 ~cfg2:0 ~name:"syminv" ()
  in
  let sim = Cyclesim.create circ in
  let o n = Cyclesim.out_port sim n in
  let set name v = let p = Cyclesim.in_port sim name in p := Bits.of_int ~width:(Bits.width !p) v in
  let rng = Random.State.make [| 9 |] in
  let pcs = Array.init 5 ~f:(fun _ -> Int.Set.empty) in
  let inv_bad = ref 0 in
  let corr_bad = ref 0 and pp_bad = ref 0 and diff = ref 0 and samples = ref 0 and cold = ref 0 in
  for _run = 1 to 300 do
    let rst_at = Random.State.int rng 3 in
    let run_at = if Random.State.bool rng then 0 else 3 + Random.State.int rng 10 in
    let cs = ref 1 and sclk = ref (Random.State.int rng 2) in
    for c = 0 to 1500 do
      let r i = Random.State.int rng i in
      set "rst_sync_n" (if c <= rst_at || r 2000 = 0 then 0 else 1);
      set "run" (if c < run_at || r 200 = 0 then 0 else 1);
      if c > 200 && r 40 = 0 then cs := 1 - !cs;
      if r 6 = 0 then sclk := 1 - !sclk;
      set "tick" (r 2);
      set "uio_in" ((r 256 land 0xCF) lor (!cs lsl 4) lor (!sclk lsl 5));
      set "tx_push" (r 2); set "tx_wdata" (r 256);
      set "rx_pop" 1; set "clear_fault" (if r 50 = 0 then 1 else 0);
      Cyclesim.cycle sim;
      let v n = Bits.to_int !(o n) in
      if v "nb" = 1 then (
        incr samples;
        if v "obs_diff" = 1 then incr diff;
        if v "corr" = 0 then incr corr_bad;
        if v "inv" = 0 then (incr inv_bad; if !inv_bad <= 3 then printf "  inv false: stc %d pw %d lane_pc %d cold %d\n" (v "stc") (v "pw") (v "lane_pc") (v "cold_hist"));
        if v "pw" = 0 && v "lane_pc" > 2 then incr pp_bad;
        if v "cold_hist" = 1 then (
          incr cold;
          List.iter units ~f:(fun u -> pcs.(u) <- Set.add pcs.(u) (v (sprintf "u%d_pc" u)))))
    done
  done;
  printf "invariant false %d\n" !inv_bad;
  printf "samples (no blame) %d: obs differences %d, correspondence false %d, cold prev_pins with pc > 2 %d, cold-history samples %d\n"
    !samples !diff !corr_bad !pp_bad !cold;
  List.iter units ~f:(fun u ->
    printf "  unit %d pcs while cold history: %s\n" u
      (String.concat ~sep:" " (List.map (Set.to_list pcs.(u)) ~f:Int.to_string)))
;;
