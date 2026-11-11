(* pemu_cc: contract compiler front end (doc/toolchain.md section 3).
     pemu_cc list                         ROM library of the tape-out build
     pemu_cc show PKG                     printed DSL view
     pemu_cc compile PKG [--p N]          validate, compile, table summary, admission
     pemu_cc retune ROM_INDEX VARIANT     window override table, if window-equivalent
     pemu_cc json                         package table for the host package (JSON)
     pemu_cc print-library                compilable printed view of the ROM library
   PKG: ROM index, ROM package name, or variant "family:k=v,..." (pemu_cc list shows families).
   Exit status: 0 ok, 1 rejected, 3 usage. *)
open! Core
module Cc = Pemu_toolchain.Cc
module Cp = Pemu_toolchain.Cprint

let usage () =
  prerr_endline
    "usage: pemu_cc list | show PKG | compile PKG [--p N] | retune ROM_INDEX VARIANT | json | print-library";
  exit 3
;;

let fail msg = eprintf "pemu_cc: %s\n" msg; exit 1
let get = function Ok x -> x | Error e -> fail e
let ints l = "[" ^ String.concat ~sep:", " (List.map l ~f:Int.to_string) ^ "]"

let () =
  match Sys.get_argv () |> Array.to_list |> List.tl_exn with
  | [ "list" ] ->
    printf "ROM library v2inc5 (tape-out), %d slots, clock %d Hz, admission P >= %d\n" Cc.slots Cc.clock_hz Cc.min_p;
    printf "%-5s %-24s %4s %5s %s\n" "index" "name" "P" "units" "admission";
    List.iter (Cc.rom ()) ~f:(fun (i, c, p) ->
      let m = get (Cc.compile c) in
      let u = Array.length m.units in
      printf "%-5d %-24s %4d %5d %s\n" i m.name p u (if u <= Cc.slots && p >= Cc.min_p then "ok" else "NOT ADMISSIBLE"));
    printf "\nvariant families:\n";
    List.iter Cc.families ~f:(fun (f, ks) ->
      printf "  %s%s\n" f (if List.is_empty ks then "" else ":" ^ String.concat ~sep:"," (List.map ks ~f:(fun k -> k ^ "=N"))))
  | [ "show"; pkg ] ->
    let c, _ = get (Cc.resolve pkg) in
    print_endline (Cp.contract c)
  | "compile" :: pkg :: opts ->
    let c, p0 = get (Cc.resolve pkg) in
    let p = match opts with [] -> p0 | [ "--p"; n ] -> Some (Int.of_string n) | _ -> usage () in
    let m = get (Cc.compile c) in
    List.iter (Cc.summary ?p m) ~f:print_endline
  | [ "retune"; idx; variant ] ->
    let rom_index = match Int.of_string_opt idx with Some i -> i | None -> usage () in
    let v = get (Cc.parse_variant variant) in
    let w = get (Cc.retune ~rom_index v) in
    printf "windows %s\n" (ints (Array.to_list w));
    printf "host: pemu.select_package(lane, %d, remap); pemu.load_windows(lane, %s)\n" rom_index (ints (Array.to_list w));
    printf
      "note: the shipped A2 results cover the ROM parameters only; this variant's contract is not proved \
       (doc/toolchain.md section 3.3)\n"
  | [ "json" ] ->
    let pk =
      List.map (Cc.rom ()) ~f:(fun (i, c, p) ->
        let m = get (Cc.compile c) in
        sprintf "    {\"index\": %d, \"name\": %S, \"p\": %d, \"remap\": %s, \"windows\": %s}" i m.name p
          (ints (Array.to_list m.remap)) (ints (Array.to_list m.windows)))
    in
    printf "{\n  \"clock_hz\": %d,\n  \"library\": \"v2inc5\",\n  \"min_p\": %d,\n  \"packages\": [\n%s\n  ]\n}\n" Cc.clock_hz
      Cc.min_p (String.concat ~sep:",\n" pk)
  | [ "print-library" ] -> print_string (Cp.library_module (List.map (Cc.rom ()) ~f:(fun (_, c, _) -> c)))
  | _ -> usage ()
;;
