(* Mutation driver.
     mutants.exe list <rtl|spec>                  CSV: index,op,desc
     mutants.exe emit <rtl|spec> <index> <dir>    oracle harness Verilog; prints "<oracle> <name>"
     mutants.exe sim  <rtl|spec> <index> <nprog>  random differential simulation (oracle SIM)
   index "id" = identity copy (no mutation), used to validate the copier. *)
open! Core
open Hardcaml
open Pemu_formal
open Pemu_spec

let random_instr rs =
  let r n = Random.State.int rs n in
  match r 10 with
  | 0 -> Isa.Jmp (r 64)
  | 1 -> Out (r 256)
  | 2 -> Outb (r 8)
  | 3 -> Ldi (r 256)
  | 4 -> In
  | 5 -> Wait (if r 8 = 0 then r 4096 else r 6)
  | 6 -> Ldc (r 256)
  | 7 -> Djnz (r 64)
  | 8 -> Reserved (8 + r 8)
  | _ -> Out (r 256)
;;

(* (rst_sync_n, ui_in, uio_in) per cycle; same shape as the RTL cross-check test *)
let v ?(rst = 1) ?(run = false) ?(wstb = false) ?(low = 0) uio =
  rst, (if run then 0x80 else 0) lor (if wstb then 0x40 else 0) lor (low land 0x3f), uio
;;

let rep n x = List.init n ~f:(fun _ -> x)

let load_words words =
  List.concat_map words ~f:(fun w ->
    List.concat_map [ w land 0xff; (w lsr 8) land 0xff ] ~f:(fun b ->
      rep 4 (v b) @ rep 4 (v ~wstb:true b)))
  @ rep 4 (v 0)
;;

let stimulus rs =
  let words =
    List.init (1 + Random.State.int rs 64) ~f:(fun _ ->
      if Random.State.int rs 10 = 0
      then Random.State.int rs 0x10000
      else Isa.encode (random_instr rs))
  in
  let phase () =
    List.init (200 + Random.State.int rs 200) ~f:(fun _ ->
      let run = Random.State.int rs 60 <> 0 in
      if Random.State.int rs 700 = 0
      then v ~rst:0 0
      else
        v ~run ~wstb:(Random.State.bool rs) ~low:(Random.State.int rs 64) (Random.State.int rs 256))
  in
  let words2 = List.init (Random.State.int rs 64) ~f:(fun _ -> Isa.encode (random_instr rs)) in
  rep 2 (v ~rst:0 0) @ load_words words @ phase () @ load_words words2 @ phase ()
;;

let sim target index nprog =
  let circuit =
    Mutate.with_active (Some (target, index)) ~f:(fun () -> Harness.a1_miter ())
  in
  let s = Cyclesim.create circuit in
  let rst = Cyclesim.in_port s "rst_sync_n"
  and ui = Cyclesim.in_port s "ui_in"
  and uio = Cyclesim.in_port s "uio_in"
  and bad = Cyclesim.out_port ~clock_edge:Before s "bad" in
  let rs = Random.State.make [| 11; 20260927 |] in
  let cycles = ref 0 in
  let killed = ref None in
  (try
     for p = 1 to nprog do
       List.iter (stimulus rs) ~f:(fun (r, u, x) ->
         rst := Bits.of_int ~width:1 r;
         ui := Bits.of_int ~width:8 u;
         uio := Bits.of_int ~width:8 x;
         Cyclesim.cycle s;
         incr cycles;
         if Bits.to_int !bad = 1
         then (
           killed := Some (p, !cycles);
           raise Exit))
     done
   with
   | Exit -> ());
  match !killed with
  | Some (p, c) -> printf "KILLED program=%d cycle=%d\n" p c
  | None -> printf "SURVIVED programs=%d cycles=%d\n" nprog !cycles
;;

let () =
  let a = Sys.get_argv () in
  match Array.to_list a |> List.tl_exn with
  | [ "list"; t ] ->
    let t = Mutate.target_of_string t in
    List.iter (Mutate.sites t) ~f:(fun s ->
      printf "%d,%s,%s\n" s.index (Mutate.op_to_string s.op) s.desc)
  | [ "emit"; t; i; dir ] ->
    let t = Mutate.target_of_string t
    and i = if String.equal i "id" then -1 else Int.of_string i in
    Mutate.with_active (Some (t, i)) ~f:(fun () ->
      List.iter (Harness.oracles t) ~f:(fun (o, c) ->
        Rtl.output ~output_mode:(To_file (dir ^/ Circuit.name c ^ ".v")) Verilog c;
        printf "%s %s\n" o (Circuit.name c)))
  | [ "sim"; t; i; n ] ->
    sim
      (Mutate.target_of_string t)
      (if String.equal i "id" then -1 else Int.of_string i)
      (Int.of_string n)
  | _ -> failwith "usage: mutants.exe (list T | emit T I DIR | sim T I NPROG)"
;;
