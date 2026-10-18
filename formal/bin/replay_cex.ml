(* Replay an ABC counterexample (write_cex -a) on the Hardcaml harness in cyclesim.
   usage: replay_cex.exe <harness> <cex file> <yosys map file>
   Checks that [bad] rises at exactly the frame ABC reports (last frame of the cex), i.e.
   that the AIGER model and the Hardcaml semantics agree on this trace. Free SRAM output
   register initial values ("init" map lines) are written into the cyclesim registers. *)
open! Core
open Hardcaml
open Pemu_formal

let () =
  let argv = Sys.get_argv () in
  let name = argv.(1)
  and cex = In_channel.read_lines argv.(2)
  and map = In_channel.read_lines argv.(3) in
  let inputs = Hashtbl.create (module Int)
  and inits = Hashtbl.create (module Int) in
  List.iter map ~f:(fun l ->
    match String.split l ~on:' ' with
    | [ "input"; idx; bit; n ] -> Hashtbl.set inputs ~key:(Int.of_string idx) ~data:(n, Int.of_string bit)
    | [ "init"; idx; bit; n ] ->
      Hashtbl.add_multi inits ~key:(Int.of_string idx) ~data:(n, Int.of_string bit)
    | _ -> ());
  let frames =
    List.drop cex 1
    |> List.take_while ~f:(fun l -> not (String.is_prefix l ~prefix:"#" || String.equal l "."))
  in
  (match List.hd cex with
   | Some l0 when String.for_all l0 ~f:(Char.equal '0') -> ()
   | _ -> failwith "expected all-zero initial latch line");
  let circuit = Registry.find ~debug:true name in
  let sim = Cyclesim.create ~config:Cyclesim.Config.trace_all circuit in
  (* initial values of free SRAM output registers, from frame-0 init inputs. The map lists
     every alias of each init bit; write the alias that is a register in the simulation. *)
  let f0 = List.hd_exn frames in
  let init_vals = Hashtbl.create (module String) in
  let reg_cache = Hashtbl.create (module String) in
  let is_reg n =
    Hashtbl.find_or_add reg_cache n ~default:(fun () ->
      Option.is_some (Cyclesim.lookup_reg_by_name sim n))
  in
  (* Prefer user-given names: generated names (_<uid>) refer to the emitted Verilog's uids, and
     the replay circuit is a separate (debug) build whose uids differ, so a generated alias can
     name an unrelated simulation register (seen on the 4,096-bit memory harness). *)
  let generated n =
    String.length n > 1
    && Char.equal n.[0] '_'
    && String.for_all (String.drop_prefix n 1) ~f:Char.is_digit
  in
  Hashtbl.iteri inits ~f:(fun ~key:idx ~data ->
    let preferred = List.filter data ~f:(fun (n, _) -> not (generated n)) in
    match
      Option.first_some
        (List.find preferred ~f:(fun (n, _) -> is_reg n))
        (List.find data ~f:(fun (n, _) -> is_reg n))
    with
    | None ->
      failwithf
        "init input %d: no alias is a simulation register (%s)"
        idx
        (List.map data ~f:fst |> String.concat ~sep:",")
        ()
    | Some (n, bit) ->
      (* values are kept as sets of set bit indices: registers and inputs may be wider than
         an OCaml int (e.g. an 82-bit instruction word) *)
      let v = Hashtbl.find init_vals n |> Option.value ~default:Int.Set.empty in
      let v = if Char.equal f0.[idx] '1' then Set.add v bit else v in
      Hashtbl.set init_vals ~key:n ~data:v);
  let to_bits ~width set = Bits.concat_lsb (List.init width ~f:(fun i -> Bits.of_bool (Set.mem set i))) in
  let show ~width set =
    if width <= 62 then sprintf "0x%04x" (Bits.to_int (to_bits ~width set))
    else sprintf "%d'b%s" width (Bits.to_bstr (to_bits ~width set))
  in
  let reg_width n = Cyclesim.Reg.width_in_bits (Option.value_exn (Cyclesim.lookup_reg_by_name sim n)) in
  Hashtbl.iteri init_vals ~f:(fun ~key ~data ->
    let r = Option.value_exn (Cyclesim.lookup_reg_by_name sim key) in
    Cyclesim.Reg.of_bits r (to_bits ~width:(Cyclesim.Reg.width_in_bits r) data));
  let dbg_ports =
    List.filter_map (Circuit.outputs circuit) ~f:(fun s ->
      let n = List.hd_exn (Signal.names s) in
      if String.is_prefix n ~prefix:"dbg_" then Some n else None)
  in
  printf "# harness %s, %d frames, sram dout init: %s\n" name (List.length frames)
    (Hashtbl.to_alist init_vals
     |> List.map ~f:(fun (n, v) -> sprintf "%s=%s" n (show ~width:(reg_width n) v))
     |> String.concat ~sep:" ");
  printf "# frame rst_sync_n ui_in uio_in bad %s\n" (String.concat ~sep:" " dbg_ports);
  let first_bad = ref None in
  (* A2 package harnesses: run the reference interpreter (Interp) on the monitor inputs that
     the harness exports (the dbg_m_ ports), and print every firing with its code and site *)
  let module I = Pemu_monitor_v1.Interp in
  let interp =
    match Hashtbl.find Ag_pkg.contracts name with
    | Some c when List.mem dbg_ports "dbg_m_oe" ~equal:String.equal -> Some (c, I.create c)
    | _ -> None
  in
  let firings = Queue.create () in
  List.iteri frames ~f:(fun k line ->
    let vals = Hashtbl.create (module String) in
    Hashtbl.iteri inputs ~f:(fun ~key:idx ~data:(n, bit) ->
      let cur = Option.value (Hashtbl.find vals n) ~default:Int.Set.empty in
      Hashtbl.set vals ~key:n ~data:(if Char.equal line.[idx] '1' then Set.add cur bit else cur));
    List.iter (Cyclesim.in_ports sim) ~f:(fun (n, r) ->
      if not (String.equal n "clock")
      then
        r := to_bits ~width:(Bits.width !r) (Option.value (Hashtbl.find vals n) ~default:Int.Set.empty));
    Cyclesim.cycle sim;
    let o n = Bits.to_int !(Cyclesim.out_port ~clock_edge:Before sim n) in
    let bad = o "bad" in
    if bad = 1 && Option.is_none !first_bad then first_bad := Some k;
    let g n =
      match Hashtbl.find vals n with
      | Some v -> sprintf "0x%02x" (Set.fold v ~init:0 ~f:(fun a b -> a lor (1 lsl b)))
      | None -> "-"
    in
    (match interp with
     | None -> ()
     | Some (_, t) ->
       let b n = o ("dbg_" ^ n) = 1 in
       let fa =
         I.step t
           { I.rst_sync_n = b "m_rst"; running = b "m_running"; tick = b "tick"; ui_in = 0
           ; uio_in = o "dbg_uio_in"; uo_out = 0; uio_out = o "dbg_m_out"; uio_oe = o "dbg_m_oe"
           ; pop_ev = b "m_pop"; pop_data = o "dbg_m_popd"; push_ev = b "m_push"; push_data = o "dbg_m_pushd" }
       in
       (match Sys.getenv "REPLAY_TRACE_WATCHER" with
        | Some wn ->
          List.iter (I.current t) ~f:(fun (w, cur) ->
            if String.equal w wn
            then
              Queue.enqueue firings
                (sprintf "# %s frame %d: %s" w k
                   (match cur with Some st -> String.prefix (Sexp.to_string (Pemu_monitor_v1.Lang.sexp_of_stmt st)) 160 | None -> "-")))
        | None -> ());
       List.iter fa ~f:(fun (r, c) ->
         let site =
           match I.fired_site t ~code:c with
           | Some (w, n, st) -> sprintf "%s #%d %s" w n (Sexp.to_string (Pemu_monitor_v1.Lang.sexp_of_stmt st))
           | None -> "?"
         in
         Queue.enqueue firings (sprintf "# interp frame %d: %s %02X at %s" k (match r with Fail -> "fail" | Blame -> "blame") c site)));
    printf "%3d %s %s %s %d %s\n" k (g "rst_sync_n") (g "ui_in") (g "uio_in") bad
      (List.map dbg_ports ~f:(fun p -> sprintf "0x%x" (o p)) |> String.concat ~sep:" "));
  Queue.iter firings ~f:print_endline;
  let expected = List.length frames - 1 in
  match !first_bad with
  | Some k when k = expected -> printf "# REPLAY OK: bad first rises at frame %d (ABC: %d)\n" k expected
  | Some k -> printf "# REPLAY MISMATCH: bad first rises at frame %d, ABC reports %d\n" k expected; exit 1
  | None -> printf "# REPLAY MISMATCH: bad never rises (ABC reports frame %d)\n" expected; exit 1
;;
