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

(* winpairs: package pairs of the all15 library that differ only in their window tables (same
   units, instructions, predicates, codes, guards, remap) - the cases a loadable window table can
   turn into each other exactly (option D, doc/decisions/inc2_loadable_options.md) *)
let winpairs () =
  let ps = List.map (Pemu_rtl_v1.Rom_lib.all15 ()) ~f:Pemu_monitor_v1.Compile.compile_exn in
  let body (p : M.t) =
    ( List.map (Array.to_list p.units) ~f:(fun (u : M.unit_prog) ->
        u.start, u.guard, Array.to_list (Array.map u.code ~f:M.field_values))
    , Array.to_list p.remap, Array.to_list p.preds, Array.to_list p.codes )
  in
  let wins (p : M.t) = Array.to_list p.windows in
  List.iter ps ~f:(fun (p : M.t) ->
    printf "windows %-22s %s | lo/hi fields used: %d\n" p.name
      (String.concat ~sep:"," (List.map (Array.to_list p.windows) ~f:Int.to_string))
      (List.count (Array.to_list p.units |> List.concat_map ~f:(fun (u : M.unit_prog) -> Array.to_list u.code))
         ~f:(fun ins -> let v = M.field_values ins in List.nth_exn v 8 <> 0 || List.nth_exn v 9 <> 0)));
  List.iteri ps ~f:(fun i a ->
    List.iteri ps ~f:(fun j b ->
      if i < j && Poly.equal (body a) (body b)
      then printf "%-22s ~ %-22s windows %s | %s\n" a.name b.name
             (String.concat ~sep:"," (List.map (wins a) ~f:Int.to_string))
             (String.concat ~sep:"," (List.map (wins b) ~f:Int.to_string))))
;;

(* variants: for each shipped v2inc1 package, which contract-parameter variants compile to the same
   structure (window-only difference), i.e. are reachable by loading a window table *)
let variants () =
  let module L = Pemu_monitor_v1.Library_v1 in
  let module C = Pemu_monitor_v1.Compile in
  let body (p : M.t) =
    ( List.map (Array.to_list p.units) ~f:(fun (u : M.unit_prog) ->
        u.start, u.guard, Array.to_list (Array.map u.code ~f:M.field_values))
    , Array.to_list p.remap, Array.to_list p.preds, Array.to_list p.codes )
  in
  let try_ c = Or_error.try_with (fun () -> C.compile_exn (c ())) in
  let report name base cands =
    let b = C.compile_exn base in
    let ok, other, bad =
      List.fold cands ~init:([], 0, 0) ~f:(fun (ok, other, bad) (lbl, c) ->
        match try_ c with
        | Error _ -> ok, other, bad + 1
        | Ok v -> if Poly.equal (body v) (body b) then lbl :: ok, other, bad else ok, other + 1, bad)
    in
    printf "%-10s reachable by windows: %s | structural change: %d | rejected: %d\n" name
      (String.concat ~sep:" " (List.rev ok)) other bad
  in
  let r a b = List.range a (b + 1) in
  report "uart_tx" (L.uart_tx ~d:4 ~pin:0) (List.map (r 2 12) ~f:(fun d -> sprintf "d%d" d, (fun () -> L.uart_tx ~d ~pin:0)));
  report "uart_rx" (L.uart_rx ~d:8 ~m:2 ~pin:1)
    (List.concat_map (r 4 16) ~f:(fun d -> List.map (r 1 4) ~f:(fun m -> sprintf "d%dm%d" d m, (fun () -> L.uart_rx ~d ~m ~pin:1))));
  report "spi_ctl" (L.spi_ctl ~cpol:false ~cpha:false ~h:2) (List.map (r 1 12) ~f:(fun h -> sprintf "h%d" h, (fun () -> L.spi_ctl ~cpol:false ~cpha:false ~h)));
  report "spi_tgt" (L.spi_tgt ~cpol:false ~cpha:false ~h_min:3 ~g:6)
    (List.concat_map (r 1 8) ~f:(fun h_min -> List.map (r 2 12) ~f:(fun g -> sprintf "h%dg%d" h_min g, (fun () -> L.spi_tgt ~cpol:false ~cpha:false ~h_min ~g))));
  report "i2c_ctl" (L.i2c_ctl ~l:6 ~h:4 ~tsu:3 ~thold:6)
    (List.concat_map (r 3 9) ~f:(fun l -> List.concat_map (r 3 9) ~f:(fun h ->
       List.map [ 2, 5; 3, 6; 4, 7; 5, 5 ] ~f:(fun (tsu, thold) -> sprintf "l%dh%dt%d/%d" l h tsu thold, (fun () -> L.i2c_ctl ~l ~h ~tsu ~thold)))));
  report "i2c_tgt" (L.i2c_tgt ~h_min:8 ~l_min:18 ~hd:8)
    (List.concat_map [ 4; 8; 16; 32; 59 ] ~f:(fun h_min -> List.concat_map [ 9; 18; 36; 69 ] ~f:(fun l_min ->
       List.map [ 4; 8; 59 ] ~f:(fun hd -> sprintf "h%dl%dhd%d" h_min l_min hd, (fun () -> L.i2c_tgt ~h_min ~l_min ~hd)))))
;;

let () =
  let mode = (Sys.get_argv ()).(1) in
  if String.equal mode "variants" then (variants (); exit 0);
  if String.equal mode "stats" then (stats (); exit 0);
  if String.equal mode "winpairs" then (winpairs (); exit 0);
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
