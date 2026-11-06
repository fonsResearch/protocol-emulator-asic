(* Monitor ISA v1 (doc/contracts/monitor_isa_v1.md sections 3-5): a compiled package. *)
open! Core

type literal =
  { obs : int (* local observable 0..15 *)
  ; kind : int (* 0 level, 1 rise, 2 fall, 3 changed *)
  ; delay : int (* 0..3 *)
  ; neg : bool
  }
[@@deriving sexp, equal, compare]

(* (l0 op1 l1) op2 l2; op = true means OR. Unused literal slots hold a neutral constant via
   [Const]. *)
type lit_or_const =
  | L of literal
  | Const of bool
[@@deriving sexp, equal, compare]

type pred =
  { l0 : lit_or_const
  ; l1 : lit_or_const
  ; l2 : lit_or_const
  ; or1 : bool
  ; or2 : bool
  }
[@@deriving sexp, equal, compare]

type modifier =
  | No_mod
  | And_reg of int
  | Xnor_reg of int
  | And_elapsed of int * int (* mark, window-table index *)
[@@deriving sexp, equal]

type op =
  | Await
  | Await_idle
  | Hold_for
  | Hold_until
  | Skip
  | Take_tx
  | Take_rx
[@@deriving sexp, equal]

let stop_addr = 127

type instr =
  { op : op
  ; pe : int
  ; pr : int
  ; pcond : int
  ; md : modifier
  ; md_pr : bool (* the modifier applies to the requirement predicate *)
  ; md_exp : bool (* the modifier applies to the expect predicate *)
  ; lo : int (* window-table index *)
  ; hi : int
  ; since : int (* 0 anchor, 1 mark 0, 2 mark 1 *)
  ; chk : int (* code-table index; 0 = none *)
  ; early : int
  ; mark : int (* 0 none, 1 mark 0, 2 mark 1 *)
  ; smp : (int * int) option (* register bit, predicate *)
  ; mat : int option (* check index *)
  ; exp : int (* predicate, 0 = none *)
  ; exp_chk : int
  ; bp : int (* branch predicate, 0 = never *)
  ; next : int
  ; alt : int
  ; tsel : int
  }
[@@deriving sexp, equal]

type unit_prog =
  { start : int
  ; guard : (int * int * int * int) option (* predicate, range start, range end, handler *)
  ; code : instr array
  }
[@@deriving sexp, equal]

type t =
  { name : string
  ; remap : int array (* 16 local -> global source *)
  ; preds : pred array (* index 0 = true, 15 = false; 1..14 from the bank *)
  ; windows : int array (* 8 entries, entry 0 = 0 *)
  ; codes : (Lang.role * int) option array (* 16 entries, entry 0 = none *)
  ; units : unit_prog array (* <= 8 *)
  }
[@@deriving sexp, equal]

let pred_true = { l0 = Const true; l1 = Const true; l2 = Const true; or1 = false; or2 = false }
let pred_false = { l0 = Const false; l1 = Const false; l2 = Const false; or1 = false; or2 = false }

(* ---- binary encoding (doc/contracts/monitor_isa_v1.md section 4; fields LSB first) ---- *)
let instr_fields =
  [ "op", 3; "pe", 4; "pr", 4; "pcond", 4; "mod", 2; "marg", 4; "md_pr", 1; "md_exp", 1; "lo", 3
  ; "hi", 3; "since", 2; "chk", 4; "early", 4; "mark", 2; "smp_en", 1; "smp_bit", 4; "smp_p", 4
  ; "mat_en", 1; "mat_chk", 4; "exp", 4; "exp_chk", 4; "bp", 4; "next", 7; "alt", 7; "tsel", 1 ]
;;

let instr_width = List.sum (module Int) instr_fields ~f:snd

let op_code = function
  | Await -> 0
  | Await_idle -> 1
  | Hold_for -> 2
  | Hold_until -> 3
  | Skip -> 4
  | Take_tx -> 5
  | Take_rx -> 6
;;

let op_of_code = function
  | 0 -> Await
  | 1 -> Await_idle
  | 2 -> Hold_for
  | 3 -> Hold_until
  | 4 -> Skip
  | 5 -> Take_tx
  | 6 -> Take_rx
  | c -> raise_s [%message "reserved op" (c : int)]
;;

let mod_fields = function
  | No_mod -> 0, 0
  | And_reg b -> 1, b
  | Xnor_reg b -> 2, b
  | And_elapsed (m, j) -> 3, (m lsl 3) lor j
;;

let mod_of_fields m a =
  match m with
  | 0 -> No_mod
  | 1 -> And_reg a
  | 2 -> Xnor_reg a
  | _ -> And_elapsed ((a lsr 3) land 1, a land 7)
;;

let field_values (i : instr) =
  let md, marg = mod_fields i.md in
  let smp_en, smp_bit, smp_p = match i.smp with None -> 0, 0, 0 | Some (b, p) -> 1, b, p in
  let mat_en, mat_chk = match i.mat with None -> 0, 0 | Some c -> 1, c in
  [ op_code i.op; i.pe; i.pr; i.pcond; md; marg; Bool.to_int i.md_pr; Bool.to_int i.md_exp; i.lo
  ; i.hi; i.since; i.chk; i.early; i.mark; smp_en; smp_bit; smp_p; mat_en; mat_chk; i.exp
  ; i.exp_chk; i.bp; i.next; i.alt; i.tsel ]
;;

(* as a list of bits, LSB first *)
let encode_instr (i : instr) =
  List.concat_map (List.zip_exn instr_fields (field_values i)) ~f:(fun ((n, w), v) ->
    if v < 0 || v >= 1 lsl w then raise_s [%message "field out of range" n (v : int) (w : int)];
    List.init w ~f:(fun k -> (v lsr k) land 1 = 1))
;;

let decode_instr (bits : bool list) : instr =
  let tbl = Hashtbl.create (module String) in
  let rest =
    List.fold instr_fields ~init:bits ~f:(fun bs (n, w) ->
      let v = List.foldi (List.take bs w) ~init:0 ~f:(fun k a b -> if b then a lor (1 lsl k) else a) in
      Hashtbl.set tbl ~key:n ~data:v;
      List.drop bs w)
  in
  ignore (rest : bool list);
  let f = Hashtbl.find_exn tbl in
  { op = op_of_code (f "op"); pe = f "pe"; pr = f "pr"; pcond = f "pcond"
  ; md = mod_of_fields (f "mod") (f "marg"); md_pr = f "md_pr" = 1; md_exp = f "md_exp" = 1
  ; lo = f "lo"; hi = f "hi"; since = f "since"; chk = f "chk"; early = f "early"; mark = f "mark"
  ; smp = (if f "smp_en" = 1 then Some (f "smp_bit", f "smp_p") else None)
  ; mat = (if f "mat_en" = 1 then Some (f "mat_chk") else None); exp = f "exp"
  ; exp_chk = f "exp_chk"; bp = f "bp"; next = f "next"; alt = f "alt"; tsel = f "tsel" }
;;

(* predicate: 3 literals x (obs 4, kind 2, delay 2, neg 1) + or1 + or2 = 29 bits *)
let pred_width = 29

let encode_pred (p : pred) =
  let lit = function
    | L l ->
      List.init 4 ~f:(fun k -> (l.obs lsr k) land 1 = 1)
      @ List.init 2 ~f:(fun k -> (l.kind lsr k) land 1 = 1)
      @ List.init 2 ~f:(fun k -> (l.delay lsr k) land 1 = 1)
      @ [ l.neg ]
    | Const _ -> raise_s [%message "constant literal cannot be encoded"]
  in
  lit p.l0 @ lit p.l1 @ lit p.l2 @ [ p.or1; p.or2 ]
;;

let decode_pred bits : pred =
  let num bs = List.foldi bs ~init:0 ~f:(fun k a b -> if b then a lor (1 lsl k) else a) in
  let lit bs =
    L { obs = num (List.take bs 4); kind = num (List.sub bs ~pos:4 ~len:2)
      ; delay = num (List.sub bs ~pos:6 ~len:2); neg = List.nth_exn bs 8 }
  in
  { l0 = lit (List.take bits 9); l1 = lit (List.sub bits ~pos:9 ~len:9)
  ; l2 = lit (List.sub bits ~pos:18 ~len:9); or1 = List.nth_exn bits 27; or2 = List.nth_exn bits 28 }
;;

(* ---- loadable store image (doc/contracts/monitor_isa_v1.md section 7) ----
   Context header, 56 words at [ctx_base]:
     0-27   predicates 1-14: predicate k at 2(k-1) (bits 15:0) and 2(k-1)+1 (bits 28:16)
     28-34  windows 1-7 (12 bits)
     35-49  codes 1-15: bit 8 role (1 = blame), bits 7:0 code
     50-52  unit 6 header: start | gen << 7 | gp << 8; gs | ge << 7; gh | base << 8
     53-55  unit 7 header, same layout
   Program of unit 6/7 at its base: instruction a in words base + 6a .. base + 6a + 5, the
   82-bit encoding LSB first, 16 bits per word. Package watchers 0 and 1 map to units 6, 7. *)
let ctx_words = 56

(* v2 serial loadable lane (doc/decisions/inc2_loadable_options.md, option A): the header keeps
   words 0-49 (predicates, windows, codes) and holds one 3-word unit header per slot from word 50,
   unit u at 50 + 3u, so [ctx_words_serial ~slots] = 50 + 3 slots (65 for 5 slots). *)
let ctx_words_serial ~slots = 50 + (3 * slots)

(* Store layout of a package on a serial loadable lane: header words 0-49, unit headers of the
   package's own units at 50 + 3u, programs packed from 50 + 3 nu. The loader still reads
   [ctx_words_serial] words; header words of units beyond nu may then hold program words, which is
   harmless because those units are disabled (LOAD_UNITS bit 0): no slot acts, no fetch starts.
   Capacity: (256 - 50 - 3 nu) / 6 instructions (33 for 2 units, 31 for 5). *)
let serial_layout (p : t) =
  let nu = Array.length p.units in
  let hdr = 50 + (3 * nu) in
  let bases =
    List.folding_map (Array.to_list p.units) ~init:hdr ~f:(fun b (u : unit_prog) -> b + (6 * Array.length u.code), b)
  in
  hdr, bases
;;

let bits_to_int bs = List.foldi bs ~init:0 ~f:(fun k a b -> if b then a lor (1 lsl k) else a)

let store_image ?slots (p : t) ~ctx_base ~bases =
  let nu = Array.length p.units in
  let ctx_words, max_units =
    match slots with None -> ctx_words, 2 | Some s -> 50 + (3 * nu), s
  in
  if nu > max_units
  then raise_s [%message "loadable package has too many units" p.name (nu : int) (max_units : int)];
  let hdr = Array.create ~len:ctx_words 0 in
  for k = 1 to 14 do
    let pr = p.preds.(k) in
    let v =
      if equal_pred pr pred_true || equal_pred pr pred_false then 0 else bits_to_int (encode_pred pr)
    in
    hdr.(2 * (k - 1)) <- v land 0xFFFF;
    hdr.((2 * (k - 1)) + 1) <- v lsr 16
  done;
  for k = 1 to 7 do
    hdr.(28 + k - 1) <- p.windows.(k)
  done;
  for k = 1 to 15 do
    hdr.(35 + k - 1)
    <- (match p.codes.(k) with
        | None -> 0
        | Some (r, c) -> ((match r with Lang.Blame -> 1 | Lang.Fail -> 0) lsl 8) lor c)
  done;
  let progs =
    List.concat
      (List.init nu ~f:(fun u ->
         let up = p.units.(u) in
         let base = List.nth_exn bases u in
         let gen, gp, gs, ge, gh =
           match up.guard with None -> 0, 0, 0, 0, 0 | Some (g, s, e, h) -> 1, g, s, e, h
         in
         let o = 50 + (3 * u) in
         hdr.(o) <- up.start lor (gen lsl 7) lor (gp lsl 8);
         hdr.(o + 1) <- gs lor (ge lsl 7);
         hdr.(o + 2) <- gh lor (base lsl 8);
         List.concat
           (List.mapi (Array.to_list up.code) ~f:(fun a ins ->
              let bits = encode_instr ins in
              List.init 6 ~f:(fun w ->
                let chunk = List.filteri bits ~f:(fun i _ -> i / 16 = w) in
                base + (6 * a) + w, bits_to_int chunk)))))
  in
  let img = List.init ctx_words ~f:(fun i -> ctx_base + i, hdr.(i)) @ progs in
  List.iter img ~f:(fun (a, _) ->
    if a < 0 || a > 255 then raise_s [%message "store image out of range" (a : int)]);
  img
;;
