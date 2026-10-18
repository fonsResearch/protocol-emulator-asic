(* Directed witnesses on A2 harness netlists (cyclesim), for counterexamples too deep for an
   unguided BMC search. A witness is a fully specified input sequence; the tool reports the
   first cycle in which [bad] is 1, or that it stays 0.
   usage: witness.exe uart_rx_stop  (sweeps the second start edge across the first frame's
   stop bit, tick every cycle, on a2_uart_rx_d8_noassume_neg and a2_uart_rx_d8_u) *)
open! Core
open Hardcaml
open Pemu_formal

let run_harness ?(c_check = false) name ~cycles ~(stim : int -> (string * int) list) =
  let circuit = Registry.find name in
  let sim = Cyclesim.create circuit in
  let names = List.map (Circuit.inputs circuit) ~f:(fun s -> List.hd_exn (Signal.names s)) in
  if c_check then printf "  %s inputs: %s\n" name (String.concat ~sep:" " (List.sort names ~compare:String.compare));
  let set n v =
    (* every stimulus name must be a harness input (raises otherwise) *)
    let p = Cyclesim.in_port sim n in
    p := Bits.of_int ~width:(Bits.width !p) v
  in
  let bad = Cyclesim.out_port sim "bad" in
  let first = ref None in
  for c = 0 to cycles - 1 do
    List.iter (stim c) ~f:(fun (n, v) -> set n v);
    Cyclesim.cycle sim;
    if Option.is_none !first && Bits.to_bool !bad then first := Some c
  done;
  !first
;;

(* UART 8N1 at d = 8 steps per bit, one step per cycle: frame 0 (0x5A) starts at cycle t0, the
   second frame (0xC3) starts [f] cycles into frame 0's stop bit (f = 8: no truncation). *)
let uart_rx_stop () =
  let t0 = 20 and d = 8 in
  let line ~f c =
    let bit_at st b c =
      let k = (c - st) / d in
      if c < st || k > 9 then None
      else Some (if k = 0 then 0 else if k = 9 then 1 else (b lsr (k - 1)) land 1)
    in
    let st1 = t0 + (9 * d) + f in
    match bit_at st1 0xC3 c with
    | Some v -> v
    | None -> (match bit_at t0 0x5A c with Some v -> v | None -> 1)
  in
  ignore (run_harness ~c_check:true "a2_uart_rx_d8_u" ~cycles:1 ~stim:(fun _ -> []) : int option);
  for f = 0 to 8 do
    let stim c =
      [ "rst_sync_n", (if c = 0 then 0 else 1); "tick", 1; "run", 1; "rx_pop", 1; "tx_push", 0
      ; "clear_fault", 0; "uio_in", line ~f c lsl 1 ]
    in
    let show = function None -> "never" | Some c -> sprintf "cycle %d" c in
    printf "stop bit %d/8: noassume bad %s; full contract bad %s\n" f
      (show (run_harness "a2_uart_rx_d8_noassume_neg" ~cycles:400 ~stim))
      (show (run_harness "a2_uart_rx_d8_u" ~cycles:400 ~stim))
  done
;;

let () =
  match Sys.get_argv () with
  | [| _; "uart_rx_stop" |] -> uart_rx_stop ()
  | _ -> eprintf "usage: witness.exe uart_rx_stop\n"
;;
