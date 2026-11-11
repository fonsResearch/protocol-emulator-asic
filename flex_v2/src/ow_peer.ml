(* 1-Wire device for Psim: a DS18B20 subset at standard speed (READ ROM 0x33, SKIP ROM 0xCC, READ
   SCRATCHPAD 0xBE, WRITE SCRATCHPAD 0x4E), with fault knobs for the blame scenarios.  Time in
   cycles; [cpu] cycles per microsecond.  The device sees only the bus (the previous cycle's
   resolved pad), as a real device does. *)
open! Core
module Psim = Pemu_protocols_v1.Psim

let crc8 bytes =
  List.fold bytes ~init:0 ~f:(fun crc b ->
    let c = ref crc and b = ref b in
    for _ = 1 to 8 do
      let mix = (!c lxor !b) land 1 in
      c := !c lsr 1;
      if mix = 1 then c := !c lxor 0x8C;
      b := !b lsr 1
    done;
    !c)
;;

let with_crc bytes = bytes @ [ crc8 bytes ]
let default_rom = with_crc [ 0x28; 0x5A; 0x3C; 0x11; 0x07; 0x00; 0x00 ]
let default_scratch = [ 0x91; 0x01; 0x4B; 0x46; 0x7F; 0xFF; 0x0F; 0x10 ]

type timing =
  { presence_wait_us : int (* release to presence start, 15 - 60 *)
  ; presence_us : int (* 60 - 240; 0: no presence *)
  ; sample_us : int (* write-slot sample point after the fall, 15 - 60 *)
  ; read0_us : int (* read-0 hold after the fall, to 15 at least, at most 60 *)
  ; spontaneous : (int * int) option (* a low of [len] us at [at] us, unprovoked *)
  }

let nominal = { presence_wait_us = 30; presence_us = 120; sample_us = 30; read0_us = 30; spontaneous = None }

type mode =
  | Idle
  | Rx of (int -> unit) (* receive a byte, then call *)
  | Tx of int list (* bits to send, LSB first per byte *)

type t =
  { log : string Queue.t (* commands and bytes the device received *)
  ; mutable scratch : int list
  }

let bits_of bytes = List.concat_map bytes ~f:(fun b -> List.init 8 ~f:(fun i -> (b lsr i) land 1))
let pin = 2

let create ?(timing = nominal) ?(rom = default_rom) ?(scratch = default_scratch) ~cpu () =
  let st = { log = Queue.create (); scratch } in
  let us n = n * cpu in
  let drives = ref (match timing.spontaneous with Some (a, l) -> [ us a, us (a + l) ] | None -> []) in
  let mode = ref Idle
  and rx_bits = ref 0
  and rx_n = ref 0
  and fall = ref None
  and sample_at = ref (-1)
  and prev_bus = ref true
  and drove = ref false
  and after_tx = ref (fun () -> ()) in
  let rec rom_cmd b =
    Queue.enqueue st.log (sprintf "rom %02X" b);
    match b with
    | 0x33 -> mode := Tx (bits_of rom); after_tx := fun () -> mode := Rx fn_cmd
    | 0xCC -> mode := Rx fn_cmd
    | _ -> mode := Idle
  and fn_cmd b =
    Queue.enqueue st.log (sprintf "fn %02X" b);
    match b with
    | 0xBE -> mode := Tx (bits_of (with_crc st.scratch)); after_tx := fun () -> mode := Idle
    | 0x4E -> write_sp [] 3
    | _ -> mode := Idle
  and write_sp acc k =
    if k = 0
    then (
      let th, tl, cfg = match List.rev acc with [ a; b; c ] -> a, b, c | _ -> assert false in
      st.scratch <- List.mapi st.scratch ~f:(fun i x -> match i with 2 -> th | 3 -> tl | 4 -> cfg | _ -> x);
      Queue.enqueue st.log "scratch written";
      mode := Idle)
    else
      mode
      := Rx
           (fun b ->
             Queue.enqueue st.log (sprintf "data %02X" b);
             write_sp (b :: acc) (k - 1))
  in
  let peer (v : Psim.chip_view) : Psim.peer_drive =
    let cy = v.cycle in
    let bus = (v.pad lsr pin) land 1 = 1 in
    (* a fall the device did not cause: a slot or a reset starts *)
    if (not bus) && !prev_bus && not !drove
    then (
      fall := Some cy;
      match !mode with
      | Tx (b :: rest) ->
        if b = 0 then drives := (cy, cy + us timing.read0_us) :: !drives;
        mode := Tx rest;
        if List.is_empty rest then !after_tx ()
      | Rx _ -> sample_at := cy + us timing.sample_us
      | Tx [] | Idle -> ());
    if cy = !sample_at
    then (
      match !mode with
      | Rx k ->
        rx_bits := !rx_bits lor (Bool.to_int bus lsl !rx_n);
        incr rx_n;
        if !rx_n = 8
        then (
          let b = !rx_bits in
          rx_bits := 0;
          rx_n := 0;
          k b)
      | _ -> ());
    (* a rise: the end of the master's pull; a long one is a reset *)
    (if bus && not !prev_bus
     then
       match !fall with
       | Some f when cy - f >= us 480 ->
         fall := None;
         rx_bits := 0;
         rx_n := 0;
         sample_at := -1;
         Queue.enqueue st.log "reset";
         if timing.presence_us > 0
         then drives := (cy + us timing.presence_wait_us, cy + us (timing.presence_wait_us + timing.presence_us)) :: !drives;
         mode := Rx rom_cmd
       | _ -> fall := None);
    prev_bus := bus;
    let low = List.exists !drives ~f:(fun (a, b) -> cy >= a && cy < b) in
    drove := low;
    if low then { drive_oe = 1 lsl pin; drive_val = 0 } else { drive_oe = 0; drive_val = 0 }
  in
  st, peer
;;
