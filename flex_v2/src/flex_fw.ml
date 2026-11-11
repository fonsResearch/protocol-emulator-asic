(* Held-out firmware, assembled from the committed sources (flex_v2/firmware/*.s, embedded by a
   dune rule so that tests and formal harnesses use the same text). *)
open! Core
module Asm = Pemu_toolchain.Asm

type t =
  { prog : Pemu_spec_v1.Isa1.t list
  ; meta : Asm.meta
  ; listing : (int * int * string) list
  }

let assemble_exn src =
  match Asm.assemble src with
  | Error e -> failwithf "asm line %d: %s" e.line e.msg ()
  | Ok o -> { prog = Array.to_list o.prog |> List.filter_opt; meta = o.meta; listing = o.listing }
;;

let onewire_source = Onewire_src.source
let onewire_ctl () = assemble_exn onewire_source

(* address of the first instruction whose source text (label stripped) starts with [prefix] *)
let addr_of t prefix =
  List.find_map_exn t.listing ~f:(fun (a, _, txt) ->
    let txt = match String.lsplit2 txt ~on:':' with Some (_, r) -> String.strip r | None -> txt in
    if String.is_prefix txt ~prefix then Some a else None)
;;

let mutate src ~pattern ~with_ =
  let m = String.substr_replace_first src ~pattern ~with_ in
  if String.equal m src then failwithf "mutant %S does not change the source" pattern ();
  m
;;
