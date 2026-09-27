(* S2: timed pin trace. One record per clock cycle: the input pins applied in that cycle
   (sampled at the edge that ends it) and the output pins observed DURING the cycle
   (before that edge). Text format, one line per cycle:

     # pemu-trace v1: cycle rst_n ui_in uio_in uo_out uio_out uio_oe
     0 0 00 00 00 00 00
     ...

   Used for simulation replay, formal counterexamples (rendered as traces), and captured
   silicon/FPGA traces. *)
open! Core
open Hardcaml

let header = "# pemu-trace v1: cycle rst_n ui_in uio_in uo_out uio_out uio_oe"

type sample =
  { cycle : int
  ; rst_n : bool
  ; ui_in : int
  ; uio_in : int
  ; uo_out : int
  ; uio_out : int
  ; uio_oe : int
  }
[@@deriving sexp_of, equal, compare]

type t = sample list [@@deriving sexp_of, equal]

let sample_to_line s =
  sprintf
    "%d %d %02x %02x %02x %02x %02x"
    s.cycle
    (Bool.to_int s.rst_n)
    s.ui_in
    s.uio_in
    s.uo_out
    s.uio_out
    s.uio_oe
;;

let sample_of_line line =
  match String.split ~on:' ' (String.strip line) with
  | [ c; r; a; b; x; y; z ] ->
    let h s = Int.of_string ("0x" ^ s) in
    { cycle = Int.of_string c
    ; rst_n = String.equal r "1"
    ; ui_in = h a
    ; uio_in = h b
    ; uo_out = h x
    ; uio_out = h y
    ; uio_oe = h z
    }
  | _ -> raise_s [%message "Pin_trace: malformed line" line]
;;

let to_string (t : t) = String.concat ~sep:"\n" (header :: List.map t ~f:sample_to_line) ^ "\n"

let of_string s : t =
  match String.split_lines s with
  | h :: rest when String.equal (String.strip h) header ->
    List.filter rest ~f:(fun l -> not (String.is_empty (String.strip l)))
    |> List.map ~f:sample_of_line
  | h :: _ -> raise_s [%message "Pin_trace: unsupported header" h]
  | [] -> []
;;

let write_file path t = Out_channel.write_all path ~data:(to_string t)
let read_file path = of_string (In_channel.read_all path)

type mismatch =
  { at_cycle : int
  ; expected : sample
  ; observed_uo_out : int
  ; observed_uio_out : int
  ; observed_uio_oe : int
  }
[@@deriving sexp_of]

(* Replay a trace into a simulation whose ports use the interface names (ui_in, uio_in,
   uo_out, uio_out, uio_oe) plus a reset port [rst_port] driven from [rst_n] (default
   "rst_sync_n" for the core; the TT wrapper uses "rst_n"). Outputs are compared before
   each clock edge. Returns the first mismatch, if any. [skip] cycles at the start are
   driven but not compared (e.g. cycle 0 before the first reset edge). *)
let replay ?(rst_port = "rst_sync_n") ?(skip = 0) sim (t : t) =
  let inp name = Cyclesim.in_port sim name in
  let out name = Cyclesim.out_port ~clock_edge:Before sim name in
  let rst = inp rst_port
  and ui = inp "ui_in"
  and uio = inp "uio_in" in
  let uo = out "uo_out"
  and uioo = out "uio_out"
  and oe = out "uio_oe" in
  let rec go = function
    | [] -> None
    | (s : sample) :: rest ->
      rst := Bits.of_bool s.rst_n;
      ui := Bits.of_int ~width:8 s.ui_in;
      uio := Bits.of_int ~width:8 s.uio_in;
      Cyclesim.cycle sim;
      let o1 = Bits.to_int !uo
      and o2 = Bits.to_int !uioo
      and o3 = Bits.to_int !oe in
      if s.cycle >= skip && (o1 <> s.uo_out || o2 <> s.uio_out || o3 <> s.uio_oe)
      then
        Some
          { at_cycle = s.cycle
          ; expected = s
          ; observed_uo_out = o1
          ; observed_uio_out = o2
          ; observed_uio_oe = o3
          }
      else go rest
  in
  go t
;;
