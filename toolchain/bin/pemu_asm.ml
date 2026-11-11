(* pemu_asm: ISA v1 assembler / disassembler (doc/toolchain.md section 2).
     pemu_asm asm FILE.s [-f hex|json|list] [-o OUT] [--own N] [--od N] [--werror]
     pemu_asm disasm FILE        (FILE: hex words one per line, or JSON with "words")
     pemu_asm shipped DIR        (writes the shipped firmware of Programs_v1 as DIR/<name>.s)
   Exit status: 0 ok, 1 assembly error, 2 lint warnings with --werror, 3 usage. *)
open! Core
module A = Pemu_toolchain.Asm
module S = Pemu_toolchain.Shipped

let usage () =
  prerr_endline
    "usage: pemu_asm asm FILE.s [-f hex|json|list] [-o OUT] [--own N] [--od N] [--werror]\n\
    \       pemu_asm disasm FILE\n\
    \       pemu_asm shipped DIR";
  exit 3
;;

let ints l = "[" ^ String.concat ~sep:", " (List.map l ~f:Int.to_string) ^ "]"

let json (o : A.output) =
  sprintf "{\"words\": %s, \"own\": %d, \"od\": %d, \"cfg\": %d, \"cfg2\": %d}\n" (ints (Array.to_list o.words)) o.meta.own
    o.meta.od o.meta.cfg o.meta.cfg2
;;

let int_arg s = match A.parse_int s with Some v -> v | None -> usage ()

let read_words file =
  let txt = In_channel.read_all file in
  let t = String.strip txt in
  if String.is_prefix t ~prefix:"{"
  then (
    (* the "words" list of a JSON object (as written by asm -f json) *)
    let i = String.substr_index_exn t ~pattern:"\"words\"" in
    let a = String.index_from_exn t i '[' and b = String.index_from_exn t i ']' in
    String.sub t ~pos:(a + 1) ~len:(b - a - 1)
    |> String.split ~on:','
    |> List.map ~f:String.strip
    |> List.filter ~f:(Fn.non String.is_empty)
    |> List.map ~f:Int.of_string)
  else
    String.split_lines txt
    |> List.map ~f:(fun l -> String.strip (A.strip_comment l))
    |> List.filter ~f:(Fn.non String.is_empty)
    |> List.map ~f:(fun w -> Int.of_string ("0x" ^ w))
;;

let () =
  match Sys.get_argv () |> Array.to_list |> List.tl_exn with
  | "asm" :: file :: opts ->
    let fmt = ref "hex" and out = ref None and own = ref None and od = ref None and werror = ref false in
    let rec go = function
      | [] -> ()
      | "-f" :: f :: r -> fmt := f; go r
      | "-o" :: f :: r -> out := Some f; go r
      | "--own" :: v :: r -> own := Some (int_arg v); go r
      | "--od" :: v :: r -> od := Some (int_arg v); go r
      | "--werror" :: r -> werror := true; go r
      | _ -> usage ()
    in
    go opts;
    (match A.assemble (In_channel.read_all file) with
     | Error e ->
       eprintf "%s:%d: error: %s\n" file e.line e.msg;
       exit 1
     | Ok o ->
       let own = Option.value !own ~default:o.meta.own and od = Option.value !od ~default:o.meta.od in
       let ws = A.lint ~own ~od o.prog in
       List.iter ws ~f:(fun w -> eprintf "%s: word %d: warning: %s\n" file w.addr w.what);
       let text =
         match !fmt with
         | "hex" -> String.concat (List.map (Array.to_list o.words) ~f:(sprintf "%04X\n"))
         | "json" -> json o
         | "list" ->
           String.concat
             (List.map o.listing ~f:(fun (a, w, src) -> sprintf "%3d  %04X  %s\n" a w src))
           ^ String.concat (List.map o.labels ~f:(fun (n, a) -> sprintf "; label %s = %d\n" n a))
         | _ -> usage ()
       in
       (match !out with
        | Some f -> Out_channel.write_all f ~data:text
        | None -> print_string text);
       if !werror && not (List.is_empty ws) then exit 2)
  | [ "disasm"; file ] -> print_string (A.disassemble (read_words file))
  | [ "shipped"; dir ] ->
    List.iter (S.programs ()) ~f:(fun (p : S.program) ->
      let words = Array.to_list (Array.sub (Pemu_spec_v1.Isa1.assemble p.prog) ~pos:0 ~len:(List.length p.prog)) in
      let hdr =
        sprintf "; %s: shipped firmware (Programs_v1), disassembled by pemu_asm shipped\n.own 0x%02X\n.od 0x%02X\n.cfg 0x%02X\n.cfg2 0x%02X\n"
          p.name p.own p.od p.cfg p.cfg2
      in
      Out_channel.write_all (dir ^/ p.name ^ ".s") ~data:(hdr ^ A.disassemble words);
      printf "%s/%s.s: %d words\n" dir p.name (List.length words))
  | _ -> usage ()
;;
