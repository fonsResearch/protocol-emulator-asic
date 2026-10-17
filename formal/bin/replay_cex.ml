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
      let v = Hashtbl.find init_vals n |> Option.value ~default:0 in
      let v = if Char.equal f0.[idx] '1' then v lor (1 lsl bit) else v in
      Hashtbl.set init_vals ~key:n ~data:v);
  Hashtbl.iteri init_vals ~f:(fun ~key ~data ->
    Cyclesim.Reg.of_int (Option.value_exn (Cyclesim.lookup_reg_by_name sim key)) data);
  let dbg_ports =
    List.filter_map (Circuit.outputs circuit) ~f:(fun s ->
      let n = List.hd_exn (Signal.names s) in
      if String.is_prefix n ~prefix:"dbg_" then Some n else None)
  in
  printf "# harness %s, %d frames, sram dout init: %s\n" name (List.length frames)
    (Hashtbl.to_alist init_vals
     |> List.map ~f:(fun (n, v) -> sprintf "%s=0x%04x" n v)
     |> String.concat ~sep:" ");
  printf "# frame rst_sync_n ui_in uio_in bad %s\n" (String.concat ~sep:" " dbg_ports);
  let first_bad = ref None in
  List.iteri frames ~f:(fun k line ->
    let vals = Hashtbl.create (module String) in
    Hashtbl.iteri inputs ~f:(fun ~key:idx ~data:(n, bit) ->
      if Char.equal line.[idx] '1'
      then Hashtbl.update vals n ~f:(fun v -> Option.value v ~default:0 lor (1 lsl bit))
      else Hashtbl.update vals n ~f:(fun v -> Option.value v ~default:0));
    List.iter (Cyclesim.in_ports sim) ~f:(fun (n, r) ->
      if not (String.equal n "clock")
      then r := Bits.of_int ~width:(Bits.width !r) (Option.value (Hashtbl.find vals n) ~default:0));
    Cyclesim.cycle sim;
    let o n = Bits.to_int !(Cyclesim.out_port ~clock_edge:Before sim n) in
    let bad = o "bad" in
    if bad = 1 && Option.is_none !first_bad then first_bad := Some k;
    let g n =
      match Hashtbl.find vals n with
      | Some v -> sprintf "0x%02x" v
      | None -> "-"
    in
    printf "%3d %s %s %s %d %s\n" k (g "rst_sync_n") (g "ui_in") (g "uio_in") bad
      (List.map dbg_ports ~f:(fun p -> sprintf "0x%x" (o p)) |> String.concat ~sep:" "));
  let expected = List.length frames - 1 in
  match !first_bad with
  | Some k when k = expected -> printf "# REPLAY OK: bad first rises at frame %d (ABC: %d)\n" k expected
  | Some k -> printf "# REPLAY MISMATCH: bad first rises at frame %d, ABC reports %d\n" k expected; exit 1
  | None -> printf "# REPLAY MISMATCH: bad never rises (ABC reports frame %d)\n" expected; exit 1
;;
