(* Increment-2 area probe (log/increments_v2.md, loadable path): one serial monitor lane
   (Mon_lane, 5 slots) in two forms, emitted as module pemu_core_v1m so that
   flow/map/map_v1m.sh measures it unchanged.
     rom : tables and instruction words from the v2inc1 ROM library (constant-folded), as shipped
     gen : every table entry and five per-unit 82-bit instruction words are free input ports,
           i.e. the general (loadable) evaluator with its storage excluded
   The difference is the logic cost of generality; storage (context and IR registers) and the
   loader/fetcher come on top and are counted separately.
   usage: probe_loadable.exe rom|gen > out.v *)
open! Core
open Hardcaml
open Signal
module S = Pemu_monitor_v1.Mon_spec
module E = Pemu_monitor_v1.Mon_engine
module Ml = Pemu_monitor_v1.Mon_lane
module M = Pemu_monitor_v1.Mprog

let slots = 5

(* stats: per package, instruction count, distinct encodings, distinct encodings without the
   successor fields next/alt, share of instructions with next = pc + 1, and the field values used *)
let stats () =
  let fields = M.instr_fields in
  let idx name = fst (List.findi_exn fields ~f:(fun _ (n, _) -> String.equal n name)) in
  let i_next = idx "next" and i_alt = idx "alt" in
  let all_vals = Array.create ~len:(List.length fields) Int.Set.empty in
  List.iter (Pemu_rtl_v1.Rom_lib.all15 ()) ~f:(fun c ->
    let p = Pemu_monitor_v1.Compile.compile_exn c in
    let instrs =
      Array.to_list p.units
      |> List.concat_map ~f:(fun (u : M.unit_prog) ->
        Array.to_list (Array.mapi u.code ~f:(fun pc ins -> pc, M.field_values ins)))
    in
    let n = List.length instrs in
    let distinct l = List.dedup_and_sort l ~compare:[%compare: int list] |> List.length in
    let full = distinct (List.map instrs ~f:snd) in
    let body =
      distinct (List.map instrs ~f:(fun (_, v) -> List.filteri v ~f:(fun j _ -> j <> i_next && j <> i_alt)))
    in
    let seq = List.count instrs ~f:(fun (pc, v) -> List.nth_exn v i_next = pc + 1) in
    List.iter instrs ~f:(fun (_, v) -> List.iteri v ~f:(fun j x -> all_vals.(j) <- Set.add all_vals.(j) x));
    printf "%-24s units %d instr %3d distinct %3d distinct-without-next/alt %3d next=pc+1 %3d\n" p.name
      (Array.length p.units) n full body seq);
  List.iteri fields ~f:(fun j (name, w) ->
    printf "field %-8s width %d distinct values %d\n" name w (Set.length all_vals.(j)))
;;

let () =
  let mode = (Sys.get_argv ()).(1) in
  if String.equal mode "stats" then (stats (); exit 0);
  let i = S.I.map S.I.port_names_and_widths ~f:(fun (n, w) -> input n w) in
  let tables, present, fetch =
    match mode with
    | "rom" ->
      let lib = List.map (Pemu_rtl_v1.Rom_lib.v2_inc1 ()) ~f:Pemu_monitor_v1.Compile.compile_exn in
      let idx = input "pkg_idx" 4 in
      let remap = Array.init 16 ~f:(fun k -> input (sprintf "remap%d" k) 6) in
      let tables, present = E.lib_tables lib ~idx ~remap in
      tables, present, E.lib_fetch lib ~idx
    | "gen" ->
      let inp n w = input n w in
      let tables : S.tables =
        { remap = Array.init 16 ~f:(fun k -> inp (sprintf "remap%d" k) 6)
        ; preds = Array.init 16 ~f:(fun k -> inp (sprintf "pred%d" k) 29)
        ; windows = Array.init 8 ~f:(fun k -> inp (sprintf "win%d" k) 12)
        ; code_role = Array.init 16 ~f:(fun k -> inp (sprintf "crole%d" k) 1)
        ; code_val = Array.init 16 ~f:(fun k -> inp (sprintf "cval%d" k) 8)
        ; starts = Array.init S.n_units ~f:(fun k -> inp (sprintf "start%d" k) 7)
        ; guards =
            Array.init S.n_units ~f:(fun k ->
              ( inp (sprintf "g_en%d" k) 1, inp (sprintf "g_pred%d" k) 4, inp (sprintf "g_s%d" k) 7
              , inp (sprintf "g_e%d" k) 7, inp (sprintf "g_h%d" k) 7 ))
        ; present = Array.create ~len:S.n_units true
        }
      in
      let ir = List.init slots ~f:(fun k -> inp (sprintf "ir%d" k) M.instr_width) in
      tables, Array.create ~len:S.n_units vdd, fun u _pc -> mux u ir
    | m -> raise_s [%message "mode must be rom or gen" m]
  in
  let o = Ml.create ~slots ~tables ~present ~fetch i in
  let outs = Ml.O.to_list (Ml.O.map2 Ml.O.port_names o ~f:output) in
  let c = Circuit.create_exn ~name:"pemu_core_v1m" outs in
  Rtl.print Verilog c
;;
