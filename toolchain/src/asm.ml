(* Text assembler, disassembler and lint for ISA v1 (doc/isa/isa_v1.md section 5; syntax in
   doc/toolchain.md). Encoding is delegated to Isa1.encode, so the assembler cannot disagree with
   the encoder the proofs and the RTL tests use. The decoder is defined by canonicality: a word
   decodes to an instruction only if Isa1.encode gives the same word back; any other word (reserved
   opcode, nonzero unused field, reserved operand code) is shown as [.word]. *)
open! Core
module I = Pemu_spec_v1.Isa1

type error =
  { line : int
  ; msg : string
  }
[@@deriving sexp_of]

exception Asm_error of error

let err line fmt = ksprintf (fun msg -> raise (Asm_error { line; msg })) fmt

(* ---- operand names ---- *)

let regs = [ "r0", I.R0; "r1", I.R1; "r2", I.R2; "r3", I.R3; "sr", I.Sr; "lc", I.Lc ]

(* BR conditions (section 5): numbers 0..15 are accepted too; 11..15 are reserved (never taken) *)
let conds =
  [ "always", 0; "z", 1; "nz", 2; "t", 3; "nt", 4; "tx_empty", 5; "tx_nempty", 6; "rx_full", 7
  ; "ser_ready", 8; "ser_busy", 9; "lc_nz", 10 ]
;;

let pin_ops = [ "out_lsb", I.Out_lsb; "out_msb", I.Out_msb; "in_lsb", I.In_lsb; "in_msb", I.In_msb ]
let pin_conds = [ "low", I.Low; "high", I.High; "rising", I.Rising; "falling", I.Falling ]
let name_of l x ~equal = fst (List.find_exn l ~f:(fun (_, y) -> equal x y))
let reg_name = name_of regs ~equal:I.equal_reg8

(* ---- lexing ---- *)

let strip_comment s =
  match String.lfindi s ~f:(fun _ c -> Char.equal c ';' || Char.equal c '#') with
  | Some i -> String.prefix s i
  | None -> s
;;

let is_ident s =
  (not (String.is_empty s))
  && (Char.is_alpha s.[0] || Char.equal s.[0] '_')
  && String.for_all s ~f:(fun c -> Char.is_alphanum c || Char.equal c '_')
;;

type line =
  { lno : int
  ; label : string option
  ; mnem : string option (* lower case; directives keep the dot *)
  ; ops : string list (* trimmed, original case *)
  ; text : string
  }

let split_ops s =
  if String.is_empty (String.strip s) then [] else List.map (String.split s ~on:',') ~f:String.strip
;;

let lex_line lno text =
  let s = String.strip (strip_comment text) in
  let label, rest =
    match String.lsplit2 s ~on:':' with
    | Some (l, r) when is_ident (String.strip l) -> Some (String.strip l), String.strip r
    | _ -> None, s
  in
  if String.is_empty rest
  then { lno; label; mnem = None; ops = []; text }
  else (
    let m, r = match String.lsplit2 rest ~on:' ' with Some (m, r) -> m, r | None -> rest, "" in
    let m = String.lowercase m in
    if String.equal m "ser"
    then (
      (* SER <op> [x]: the operation name is the first operand *)
      let r = String.strip r in
      let a, x = match String.lsplit2 r ~on:' ' with Some (a, x) -> a, String.strip x | None -> r, "" in
      { lno; label; mnem = Some m; ops = String.strip a :: split_ops x; text })
    else if String.equal m ".equ"
    then (
      (* .equ NAME value *)
      let r = String.strip r in
      match String.lsplit2 r ~on:' ' with
      | Some (nm, e) -> { lno; label; mnem = Some m; ops = [ String.strip nm; String.strip e ]; text }
      | None -> { lno; label; mnem = Some m; ops = [ r ]; text })
    else { lno; label; mnem = Some m; ops = split_ops r; text })
;;

(* ---- values ---- *)

let parse_int s =
  let s' = String.lowercase (String.strip s) in
  let neg, body = if String.is_prefix s' ~prefix:"-" then true, String.drop_prefix s' 1 else false, s' in
  let ok =
    (not (String.is_empty body))
    && Char.is_digit body.[0]
    && String.for_all body ~f:(fun c -> Char.is_alphanum c || Char.equal c '_')
  in
  if not ok then None else Option.map (Int.of_string_opt body) ~f:(fun v -> if neg then -v else v)
;;

type env =
  { labels : (string, int) Hashtbl.t
  ; equs : (string, int) Hashtbl.t
  }

let term env lno s =
  let s = String.strip s in
  match parse_int s with
  | Some v -> v
  | None ->
    (match Hashtbl.find env.equs s with
     | Some v -> v
     | None ->
       (match Hashtbl.find env.labels s with
        | Some v -> v
        | None -> err lno "unknown value or label %S" s))
;;

(* value := term (('+' | '-') term)*, left associative; a leading '-' belongs to the first term *)
let rec value env lno s =
  let s = String.strip s in
  match String.rfindi s ~f:(fun i c -> i > 0 && (Char.equal c '+' || Char.equal c '-')) with
  | Some i when not (String.is_empty (String.strip (String.prefix s i))) ->
    let l = value env lno (String.prefix s i) and r = term env lno (String.drop_prefix s (i + 1)) in
    if Char.equal s.[i] '+' then l + r else l - r
  | _ -> term env lno s
;;

let lookup what l lno s =
  match List.Assoc.find l ~equal:String.equal (String.lowercase s) with
  | Some x -> x
  | None -> err lno "unknown %s %S (expected one of: %s)" what s (String.concat ~sep:" " (List.map l ~f:fst))
;;

let reg lno s = lookup "register" regs lno s

(* section 10 item 8: FIFO/SER register operands are r0..r3, sr (codes 0..4); 5..7 are rejected *)
let fifo_reg lno s =
  let r = reg lno s in
  if I.equal_reg8 r I.Lc then err lno "%S is not a FIFO/SER register operand (r0..r3, sr)" s else r
;;

(* ---- one instruction ---- *)

let instr env (l : line) m ops : I.t =
  let lno = l.lno in
  let n k = if List.length ops <> k then err lno "%s takes %d operand(s), got %d" m k (List.length ops) in
  let op i = List.nth_exn ops i in
  let v i = value env lno (op i) in
  match m with
  | "jmp" -> n 1; Jmp (v 0)
  | "br" ->
    n 2;
    let c = match parse_int (op 0) with Some c -> c | None -> lookup "condition" conds lno (op 0) in
    Br (c, v 1)
  | "out" -> n 1; Out (v 0)
  | "oen" -> n 1; Oen (v 0)
  | "pin" -> n 2; Pin (v 0, lookup "pin operation" pin_ops lno (op 1))
  | "wait" -> n 1; Wait (v 0)
  | "wtp" -> n 2; Wtp (v 0, lookup "pin condition" pin_conds lno (op 1))
  | "ldi" ->
    n 2;
    let d : I.ldi_dst =
      match String.lowercase (op 0) with
      | "to_lo" -> To_lo
      | "xo" -> Xo
      | _ -> L (reg lno (op 0))
    in
    Ldi (d, v 1)
  | "mov" ->
    n 2;
    let d : I.mov_dst =
      match String.lowercase (op 0) with
      | "out" -> Out_reg
      | "oe" -> Oe_reg
      | _ -> M (reg lno (op 0))
    in
    let s : I.mov_src =
      match String.lowercase (op 1) with
      | "pins" -> Pins
      | "ser_status" -> Ser_status
      | _ -> S (reg lno (op 1))
    in
    Mov (d, s)
  | "cmp" ->
    n 2;
    let s : I.cmp_src = if String.equal (String.lowercase (op 0)) "pins" then Cpins else C (reg lno (op 0)) in
    Cmp (s, v 1)
  | "addi" ->
    n 2;
    (* a negative immediate is taken modulo 256 (ADDI r, -1 decrements) *)
    let x = v 1 in
    Addi (reg lno (op 0), if x < 0 && x >= -256 then x land 0xFF else x)
  | "pop" -> n 1; Pop (fifo_reg lno (op 0))
  | "push" -> n 1; Push (fifo_reg lno (op 0))
  | "ser" ->
    let a = String.lowercase (op 0) in
    let x () = if List.length ops <> 2 then err lno "SER %s takes one register operand" a else fifo_reg lno (op 1) in
    let none () = if List.length ops <> 1 then err lno "SER %s takes no operand" a in
    Ser
      (match a with
       | "send" -> Send (x ())
       | "sendc" -> Sendc (x ())
       | "period" -> Period (x ())
       | "crci" -> none (); Crci
       | "crcs" -> none (); Crcs
       | "eop" -> none (); Eop
       | "idle" -> none (); Idle
       | _ -> err lno "unknown SER operation %S (send sendc period crci crcs eop idle)" a)
  | "djnz" -> n 1; Djnz (v 0)
  | "nop" -> n 0; Nop
  | "halt" -> n 0; Halt
  | "clrt" -> n 0; Clrt
  | _ -> err lno "unknown mnemonic %S" m
;;

(* ---- assembler ---- *)

type item =
  | Ins of I.t
  | Word of int

type meta =
  { own : int
  ; od : int
  ; cfg : int
  ; cfg2 : int
  }

let meta_directives = [ ".own"; ".od"; ".cfg"; ".cfg2" ]

type output =
  { meta : meta (* lane configuration from .own/.od/.cfg/.cfg2 (default 0) *)
  ; words : int array (* program words; length = program length *)
  ; prog : I.t option array (* instruction per word (None for a raw .word) *)
  ; listing : (int * int * string) list (* address, word, source text *)
  ; labels : (string * int) list
  }

let encode_item lno = function
  | Ins x -> (try I.encode x with e -> err lno "%s" (Exn.to_string e))
  | Word w -> if w < 0 || w > 0xFFFF then err lno ".word out of range: %d" w else w
;;

let assemble_lines (lines : line list) =
  let env = { labels = Hashtbl.create (module String); equs = Hashtbl.create (module String) } in
  let define lno nm v (tbl : (string, int) Hashtbl.t) =
    if Hashtbl.mem env.labels nm || Hashtbl.mem env.equs nm then err lno "duplicate name %S" nm;
    if Option.is_some (List.Assoc.find regs ~equal:String.equal (String.lowercase nm))
    then err lno "%S is a register name" nm;
    Hashtbl.set tbl ~key:nm ~data:v
  in
  (* pass 1: label addresses and .equ values (an .equ may use earlier .equ names and numbers) *)
  let pc = ref 0 in
  let meta = ref { own = 0; od = 0; cfg = 0; cfg2 = 0 } in
  List.iter lines ~f:(fun l ->
    Option.iter l.label ~f:(fun lb -> define l.lno lb !pc env.labels);
    match l.mnem with
    | None -> ()
    | Some ".equ" ->
      (match l.ops with
       | [ nm; e ] when is_ident nm -> define l.lno nm (value env l.lno e) env.equs
       | _ -> err l.lno ".equ NAME value")
    | Some d when List.mem meta_directives d ~equal:String.equal ->
      (match l.ops with
       | [ x ] ->
         let v = value env l.lno x in
         if v < 0 || v > 255 then err l.lno "%s takes a byte, got %d" d v;
         let m = !meta in
         meta :=
           (match d with
            | ".own" -> { m with own = v }
            | ".od" -> { m with od = v }
            | ".cfg" -> { m with cfg = v }
            | _ -> { m with cfg2 = v })
       | _ -> err l.lno "%s takes one value" d)
    | Some d when String.is_prefix d ~prefix:"." && not (String.equal d ".word") -> err l.lno "unknown directive %S" d
    | Some _ -> incr pc);
  if !pc > I.imem_depth then err 0 "program has %d words; the instruction memory holds %d" !pc I.imem_depth;
  (* pass 2 *)
  let items =
    List.filter_map lines ~f:(fun l ->
      match l.mnem with
      | None | Some ".equ" -> None
      | Some d when List.mem meta_directives d ~equal:String.equal -> None
      | Some ".word" ->
        (match l.ops with
         | [ x ] -> Some (l, Word (value env l.lno x))
         | _ -> err l.lno ".word takes one value")
      | Some m -> Some (l, Ins (instr env l m l.ops)))
  in
  let words = Array.of_list (List.map items ~f:(fun (l, it) -> encode_item l.lno it)) in
  let prog = Array.of_list (List.map items ~f:(function _, Ins x -> Some x | _, Word _ -> None)) in
  let listing = List.mapi items ~f:(fun a (l, _) -> a, words.(a), String.strip l.text) in
  let labels = Hashtbl.to_alist env.labels |> List.sort ~compare:(fun (_, a) (_, b) -> Int.compare a b) in
  { meta = !meta; words; prog; listing; labels }
;;

let assemble (src : string) =
  match String.split_lines src |> List.mapi ~f:(fun i t -> lex_line (i + 1) t) |> assemble_lines with
  | o -> Ok o
  | exception Asm_error e -> Error e
;;

(* ---- decoder ---- *)

let reg_of_code = function
  | 0 -> Some I.R0
  | 1 -> Some I.R1
  | 2 -> Some I.R2
  | 3 -> Some I.R3
  | 4 -> Some I.Sr
  | 5 -> Some I.Lc
  | _ -> None
;;

let decode w : I.t option =
  let op = (w lsr 12) land 0xF and a = w land 0xFFF in
  let r = reg_of_code in
  let cand : I.t option =
    match op with
    | 0x0 -> Some (Jmp (a land 0xFF))
    | 0x1 -> Some (Br (a lsr 8, a land 0xFF))
    | 0x2 -> Some (Out (a land 0xFF))
    | 0x3 -> Some (Oen (a land 0xFF))
    | 0x4 -> Some (Pin (a land 7, List.nth_exn [ I.Out_lsb; Out_msb; In_lsb; In_msb ] ((a lsr 4) land 3)))
    | 0x5 -> Some (Wait a)
    | 0x6 -> Some (Wtp (a land 7, List.nth_exn [ I.Low; High; Rising; Falling ] ((a lsr 4) land 3)))
    | 0x7 ->
      let dst : I.ldi_dst option =
        match (a lsr 8) land 7 with
        | 6 -> Some To_lo
        | 7 -> Some Xo
        | k -> Option.map (r k) ~f:(fun x -> I.L x)
      in
      Option.map dst ~f:(fun d -> I.Ldi (d, a land 0xFF))
    | 0x8 ->
      let dst : I.mov_dst option =
        match (a lsr 8) land 7 with
        | 6 -> Some Out_reg
        | 7 -> Some Oe_reg
        | k -> Option.map (r k) ~f:(fun x -> I.M x)
      in
      let src : I.mov_src option =
        match (a lsr 4) land 7 with
        | 6 -> Some Pins
        | 7 -> Some Ser_status
        | k -> Option.map (r k) ~f:(fun x -> I.S x)
      in
      Option.both dst src |> Option.map ~f:(fun (d, s) -> I.Mov (d, s))
    | 0x9 ->
      let src : I.cmp_src option =
        match (a lsr 8) land 7 with
        | 6 -> Some Cpins
        | k -> Option.map (r k) ~f:(fun x -> I.C x)
      in
      Option.map src ~f:(fun s -> I.Cmp (s, a land 0xFF))
    | 0xA -> Option.map (r ((a lsr 8) land 7)) ~f:(fun d -> I.Addi (d, a land 0xFF))
    | 0xB ->
      let x = r (a land 7) in
      (match (a lsr 10) land 3 with
       | 0 -> Option.map x ~f:(fun x -> I.Pop x)
       | 1 -> Option.map x ~f:(fun x -> I.Push x)
       | _ -> None)
    | 0xC ->
      let x = r (a land 7) in
      (match (a lsr 9) land 7 with
       | 0 -> Option.map x ~f:(fun x -> I.Ser (Send x))
       | 1 -> Some (Ser Crci)
       | 2 -> Some (Ser Crcs)
       | 3 -> Some (Ser Eop)
       | 4 -> Option.map x ~f:(fun x -> I.Ser (Period x))
       | 5 -> Some (Ser Idle)
       | 6 -> Option.map x ~f:(fun x -> I.Ser (Sendc x))
       | _ -> None)
    | 0xD -> Some (Djnz (a land 0xFF))
    | 0xE ->
      (match a with
       | 0 -> Some Nop
       | 1 -> Some Halt
       | 2 -> Some Clrt
       | _ -> None)
    | _ -> None
  in
  (* canonical words only *)
  Option.bind cand ~f:(fun x ->
    match I.encode x with
    | e when e = w -> Some x
    | _ -> None
    | exception _ -> None)
;;

(* ---- printer (inverse of the parser) ---- *)

let to_text ?(labels = Int.Map.empty) (x : I.t) =
  let tn t = match Map.find labels t with Some s -> s | None -> Int.to_string t in
  match x with
  | Jmp t -> sprintf "JMP %s" (tn t)
  | Br (c, t) ->
    let cn = match List.find conds ~f:(fun (_, k) -> k = c) with Some (s, _) -> s | None -> Int.to_string c in
    sprintf "BR %s, %s" cn (tn t)
  | Out v -> sprintf "OUT 0x%02X" v
  | Oen v -> sprintf "OEN 0x%02X" v
  | Pin (p, a) -> sprintf "PIN %d, %s" p (name_of pin_ops a ~equal:I.equal_pin_op)
  | Wait k -> sprintf "WAIT %d" k
  | Wtp (p, c) -> sprintf "WTP %d, %s" p (name_of pin_conds c ~equal:I.equal_pin_cond)
  | Ldi (d, v) -> sprintf "LDI %s, %d" (match d with L r -> reg_name r | To_lo -> "to_lo" | Xo -> "xo") v
  | Mov (d, s) ->
    sprintf "MOV %s, %s"
      (match d with M r -> reg_name r | Out_reg -> "out" | Oe_reg -> "oe")
      (match s with S r -> reg_name r | Pins -> "pins" | Ser_status -> "ser_status")
  | Cmp (s, v) -> sprintf "CMP %s, %d" (match s with C r -> reg_name r | Cpins -> "pins") v
  | Addi (r, v) -> sprintf "ADDI %s, %d" (reg_name r) v
  | Pop r -> sprintf "POP %s" (reg_name r)
  | Push r -> sprintf "PUSH %s" (reg_name r)
  | Ser op ->
    (match op with
     | Send r -> sprintf "SER SEND %s" (reg_name r)
     | Sendc r -> sprintf "SER SENDC %s" (reg_name r)
     | Period r -> sprintf "SER PERIOD %s" (reg_name r)
     | Crci -> "SER CRCI"
     | Crcs -> "SER CRCS"
     | Eop -> "SER EOP"
     | Idle -> "SER IDLE")
  | Djnz t -> sprintf "DJNZ %s" (tn t)
  | Nop -> "NOP"
  | Halt -> "HALT"
  | Clrt -> "CLRT"
;;

(* disassembly of a word list: labels L<addr> at every jump/branch/djnz target *)
let disassemble (words : int list) =
  let dec = List.map words ~f:(fun w -> w, decode w) in
  let targets =
    List.filter_map dec ~f:(fun (_, d) ->
      match d with
      | Some (Jmp t | Br (_, t) | Djnz t) -> Some t
      | _ -> None)
    |> Int.Set.of_list
  in
  let labels = Set.to_list targets |> List.map ~f:(fun t -> t, sprintf "L%d" t) |> Int.Map.of_alist_exn in
  List.concat_mapi dec ~f:(fun a (w, d) ->
    let lbl = match Map.find labels a with Some s -> [ s ^ ":" ] | None -> [] in
    let body = match d with Some x -> to_text ~labels x | None -> sprintf ".word 0x%04X" w in
    lbl @ [ sprintf "    %-28s ; %3d  %04X" body a w ])
  |> String.concat ~sep:"\n"
  |> fun s -> s ^ "\n"
;;

(* ---- lint (section 10 item 1 and static checks the encoder does not make) ---- *)

type warning =
  { addr : int
  ; what : string
  }

let lint ?(own = 0) ?(od = 0) (prog : I.t option array) =
  let n = Array.length prog in
  let ws = ref [] in
  let warn addr fmt = ksprintf (fun what -> ws := { addr; what } :: !ws) fmt in
  (* L1: owned open-drain pins must be released from the start: out resets to 0, which pulls them
     low, so the first instruction must be OUT with those bits set *)
  let odm = own land od in
  if odm <> 0
  then (
    match if n > 0 then prog.(0) else None with
    | Some (Out v) when v land odm = odm -> ()
    | Some (Out v) -> warn 0 "L1: first OUT 0x%02X leaves open-drain pins 0x%02X pulled low" v (odm land lnot v)
    | _ -> warn 0 "L1: first instruction is not OUT; open-drain pins 0x%02X are pulled low in step 1" odm);
  Array.iteri prog ~f:(fun a x ->
    match x with
    | Some (Jmp t | Br (_, t) | Djnz t) when t >= n ->
      warn a "L2: control target %d is outside the program (length %d)" t n
    | Some (Br (c, _)) when c >= 11 -> warn a "L3: BR condition %d is reserved (never taken)" c
    | Some (Out v | Oen v) when own <> 0 && v land lnot own <> 0 ->
      warn a "L4: writes pin bits 0x%02X the lane does not own (ignored by the pin mux)" (v land lnot own)
    | None -> warn a "L5: raw .word (not a canonical instruction)"
    | _ -> ());
  (* L6: the last instruction must transfer control or halt *)
  (match if n > 0 then prog.(n - 1) else None with
   | Some (Jmp _ | Halt | Br (0, _)) -> ()
   | _ -> if n > 0 then warn (n - 1) "L6: last instruction neither jumps nor halts (runs into unloaded memory)");
  List.rev !ws
;;
