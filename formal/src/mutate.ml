(* Thin mutation engine on the Hardcaml signal graph.

   A design (RTL engine or spec) is elaborated on fresh "formal" input wires, with its memory
   model (RTL: SRAM; spec: imem) replaced by a stub that captures the memory's inputs and
   returns a formal read-data wire. The graph between the formal inputs and the design's
   outputs plus the memory inputs is then copied node by node, with actual input signals
   substituted for the formal wires. Every copied node gets a fresh uid (so a copy can sit in
   the same circuit as other logic), and names are kept. Exactly one node is changed during
   the copy. The memory model is then built on the copied memory inputs, outside the mutation
   scope.

   Mutation sites are enumerated by a DFS over that graph (roots in interface order, children
   in constructor order), so a site index identifies the same code location in every
   elaboration of the same design with the same memory model.

   Operators (6; Enable_drop has no sites in the current designs, whose only enabled
   registers are inside the excluded memory models, so Clear_drop was added):
     Op_swap       Op2: add<->sub, and<->or, xor->or, eq->lt, lt->eq
     Const_invert  Const: bitwise invert
     Off_by_one    Const, width >= 2: value-1 (value+1 if value = 0)
     Enable_drop   Reg with a non-constant enable: enable := 1
     Clear_drop    Reg with a synchronous clear: clear held inactive (reset bug)
     Mux_swap      2-input Mux: swap the cases (= invert the select)

   Unsupported node kinds (Multiport_mem, Mem_read_port, Inst) raise; the designs mutated
   here contain none outside their memory models. *)
open! Core
open Hardcaml
module T = Signal.Type

type op =
  | Op_swap
  | Const_invert
  | Off_by_one
  | Enable_drop
  | Clear_drop
  | Mux_swap
[@@deriving sexp_of, compare, equal]

let op_to_string = function
  | Op_swap -> "op_swap"
  | Const_invert -> "const_invert"
  | Off_by_one -> "off_by_one"
  | Enable_drop -> "enable_drop"
  | Clear_drop -> "clear_drop"
  | Mux_swap -> "mux_swap"
;;

type target =
  | Rtl
  | Spec
[@@deriving sexp_of, equal]

let target_to_string = function
  | Rtl -> "rtl"
  | Spec -> "spec"
;;

let target_of_string = function
  | "rtl" -> Rtl
  | "spec" -> Spec
  | s -> failwithf "unknown target %s" s ()
;;

type site =
  { index : int
  ; op : op
  ; uid : T.Uid.t
  ; desc : string
  }

(* The active mutation, consulted by the harness constructors (formal/src/harness.ml). *)
let active : (target * int) option ref = ref None

let with_active m ~f =
  let saved = !active in
  active := m;
  Exn.protect ~f ~finally:(fun () -> active := saved)
;;

let signal_id_exn (s : T.t) =
  match s with
  | Const { signal_id; _ }
  | Op2 { signal_id; _ }
  | Mux { signal_id; _ }
  | Cat { signal_id; _ }
  | Not { signal_id; _ }
  | Wire { signal_id; _ }
  | Select { signal_id; _ }
  | Reg { signal_id; _ }
  | Multiport_mem { signal_id; _ }
  | Mem_read_port { signal_id; _ }
  | Inst { signal_id; _ } -> signal_id
  | Empty -> failwith "signal_id_exn: Empty"
;;

let register_signals (r : T.register) =
  [ r.reg_clock
  ; r.reg_reset
  ; r.reg_reset_value
  ; r.reg_clear
  ; r.reg_clear_value
  ; r.reg_enable
  ]
;;

let children (s : T.t) =
  let l =
    match s with
    | Empty | Const _ -> []
    | Op2 { arg_a; arg_b; _ } -> [ arg_a; arg_b ]
    | Mux { select; cases; _ } -> select :: cases
    | Cat { args; _ } -> args
    | Not { arg; _ } | Select { arg; _ } -> [ arg ]
    | Wire { driver; _ } -> [ !driver ]
    | Reg { d; register; _ } -> d :: register_signals register
    | Multiport_mem _ | Mem_read_port _ | Inst _ ->
      failwith "Mutate: unsupported node kind (memory/instantiation) inside mutation scope"
  in
  List.filter l ~f:(function
    | T.Empty -> false
    | _ -> true)
;;

let is_const_one = function
  | T.Const { constant; _ } -> Bits.width constant = 1 && Bits.to_int constant = 1
  | _ -> false
;;

let ops_at (s : T.t) =
  match s with
  | Op2 { op; _ } ->
    (match op with
     | Signal_add | Signal_sub | Signal_and | Signal_or | Signal_xor | Signal_eq | Signal_lt ->
       [ Op_swap ]
     | Signal_mulu | Signal_muls -> [])
  | Const { constant; _ } ->
    if Bits.width constant >= 2 && Bits.width constant <= 62
    then [ Const_invert; Off_by_one ]
    else [ Const_invert ]
  | Reg { register; _ } ->
    (match register.reg_enable with
     | Empty -> []
     | e when is_const_one e -> []
     | _ -> [ Enable_drop ])
    @
    (match register.reg_clear with
     | Empty -> []
     | _ -> [ Clear_drop ])
  | Mux { cases = [ _; _ ]; _ } -> [ Mux_swap ]
  | _ -> []
;;

let describe (s : T.t) =
  let names = Signal.names s in
  let kind =
    match s with
    | Op2 { op; _ } -> Sexp.to_string (T.sexp_of_signal_op op)
    | Const { constant; _ } -> sprintf "const 0x%x" (Bits.to_int constant)
    | Reg _ -> "reg"
    | Mux _ -> "mux2"
    | _ -> "other"
  in
  sprintf
    "%s w=%d%s"
    kind
    (Signal.width s)
    (if List.is_empty names then "" else " " ^ String.concat ~sep:"/" names)
;;

(* DFS preorder over the mutation scope. [stop] = uids of formal input wires. *)
let enumerate ~stop roots =
  let visited = Hash_set.Poly.create () in
  let sites = ref [] in
  let n = ref 0 in
  let rec go s =
    match s with
    | T.Empty -> ()
    | _ ->
      let uid = Signal.uid s in
      if not (Hash_set.mem visited uid || Hash_set.mem stop uid)
      then (
        Hash_set.add visited uid;
        List.iter (ops_at s) ~f:(fun op ->
          sites := { index = !n; op; uid; desc = describe s } :: !sites;
          incr n);
        List.iter (children s) ~f:go)
  in
  List.iter roots ~f:go;
  List.rev !sites
;;

let fresh_signal_id (orig : T.signal_id) =
  match Signal.wire orig.s_width with
  | T.Wire { signal_id; _ } ->
    { signal_id with
      s_metadata = Option.map orig.s_metadata ~f:(fun m -> { m with names = m.names })
    }
  | _ -> assert false
;;

let swap_op : T.signal_op -> T.signal_op = function
  | Signal_add -> Signal_sub
  | Signal_sub -> Signal_add
  | Signal_and -> Signal_or
  | Signal_or -> Signal_and
  | Signal_xor -> Signal_or
  | Signal_eq -> Signal_lt
  | Signal_lt -> Signal_eq
  | (Signal_mulu | Signal_muls) as o -> o
;;

(* Returns a memoised copy function. [subst]: formal wire uid -> actual signal. [mutation]:
   (uid, op) of the single node to change, or None for an identity copy. *)
let copier ~subst ~mutation =
  let memo = Hashtbl.Poly.create () in
  let rec copy (s : T.t) : T.t =
    match s with
    | Empty -> Empty
    | _ ->
      let uid = Signal.uid s in
      (match Hashtbl.find subst uid with
       | Some actual -> actual
       | None ->
         (match Hashtbl.find memo uid with
          | Some c -> c
          | None ->
            let mut =
              match mutation with
              | Some (muid, op) when T.Uid.equal muid uid -> Some op
              | _ -> None
            in
            let signal_id = fresh_signal_id (signal_id_exn s) in
            (match s with
             | Wire { driver; _ } ->
               (* break cycles: register the new wire before copying its driver *)
               let d = ref T.Empty in
               let w = T.Wire { signal_id; driver = d } in
               Hashtbl.set memo ~key:uid ~data:w;
               (match !driver with
                | Empty -> failwith "Mutate: undriven wire inside mutation scope"
                | drv -> d := copy drv);
               w
             | _ ->
               let c =
                 match s, mut with
                 | Const { constant; _ }, None -> T.Const { signal_id; constant }
                 | Const { constant; _ }, Some Const_invert ->
                   T.Const { signal_id; constant = Bits.( ~: ) constant }
                 | Const { constant; _ }, Some Off_by_one ->
                   let v = Bits.to_int constant in
                   let w = Bits.width constant in
                   T.Const
                     { signal_id; constant = Bits.of_int ~width:w (if v = 0 then 1 else v - 1) }
                 | Op2 { op; arg_a; arg_b; _ }, m ->
                   let op = if Option.equal equal_op m (Some Op_swap) then swap_op op else op in
                   T.Op2 { signal_id; op; arg_a = copy arg_a; arg_b = copy arg_b }
                 | Mux { select; cases; _ }, m ->
                   let cases = List.map cases ~f:copy in
                   let cases =
                     if Option.equal equal_op m (Some Mux_swap) then List.rev cases else cases
                   in
                   T.Mux { signal_id; select = copy select; cases }
                 | Cat { args; _ }, None -> T.Cat { signal_id; args = List.map args ~f:copy }
                 | Not { arg; _ }, None -> T.Not { signal_id; arg = copy arg }
                 | Select { arg; high; low; _ }, None ->
                   T.Select { signal_id; arg = copy arg; high; low }
                 | Reg { register = r; d; _ }, m ->
                   let reg_enable =
                     if Option.equal equal_op m (Some Enable_drop)
                     then Signal.of_int ~width:1 1
                     else copy r.reg_enable
                   in
                   let reg_clear =
                     if Option.equal equal_op m (Some Clear_drop)
                     then (
                       match r.reg_clear_level with
                       | High -> Signal.of_int ~width:1 0
                       | Low -> Signal.of_int ~width:1 1)
                     else copy r.reg_clear
                   in
                   let register =
                     { r with
                       reg_clock = copy r.reg_clock
                     ; reg_reset = copy r.reg_reset
                     ; reg_reset_value = copy r.reg_reset_value
                     ; reg_clear
                     ; reg_clear_value = copy r.reg_clear_value
                     ; reg_enable
                     }
                   in
                   T.Reg { signal_id; register; d = copy d }
                 | _, Some op ->
                   raise_s
                     [%message "Mutate: operator not applicable" (op : op) (describe s : string)]
                 | (Multiport_mem _ | Mem_read_port _ | Inst _ | Empty | Wire _), None ->
                   failwith "Mutate: unsupported node kind inside mutation scope"
               in
               Hashtbl.set memo ~key:uid ~data:c;
               c)))
  in
  copy
;;

(* ---- design wrappers ------------------------------------------------------------------ *)

module E = Pemu_rtl.Engine
module Sram = Pemu_rtl.Sram
module Sc = Pemu_spec.Spec_circuit

let uid_set l =
  let h = Hash_set.Poly.create () in
  List.iter l ~f:(fun s -> Hash_set.add h (Signal.uid s));
  h
;;

(* Elaborate the RTL engine on formal wires with a stub SRAM. *)
let rtl_scope () =
  let formal = E.I.map E.I.port_widths ~f:Signal.wire in
  let dout_formal = Signal.wire Sram.data_width in
  let captured = ref None in
  let o =
    E.create
      ~sram:(fun si ->
        captured := Some si;
        { Sram.O.a_dout = dout_formal })
      formal
  in
  let si = Option.value_exn !captured in
  let roots = E.O.to_list o @ Sram.I.to_list si in
  let stop = uid_set (dout_formal :: E.I.to_list formal) in
  formal, dout_formal, o, si, roots, stop
;;

let spec_scope () =
  let formal = Sc.I.map Sc.I.port_widths ~f:Signal.wire in
  let rdata_formal = Signal.wire 16 in
  let captured = ref None in
  let o =
    Sc.create
      ~imem:(fun m ->
        captured := Some m;
        rdata_formal)
      formal
  in
  let m : Signal.t Sc.Imem.t = Option.value_exn !captured in
  let roots = Sc.O.to_list o @ [ m.clock; m.we; m.waddr; m.wdata; m.raddr ] in
  let stop = uid_set (rdata_formal :: Sc.I.to_list formal) in
  formal, rdata_formal, o, m, roots, stop
;;

let sites target =
  match target with
  | Rtl ->
    let _, _, _, _, roots, stop = rtl_scope () in
    enumerate ~stop roots
  | Spec ->
    let _, _, _, _, roots, stop = spec_scope () in
    enumerate ~stop roots
;;

let mutation_of ~sites index =
  if index < 0
  then None (* identity copy, used to validate the copier *)
  else (
    let s = List.nth_exn sites index in
    Some (s.uid, s.op))
;;

let bind_subst formal actual ~to_list =
  let subst = Hashtbl.Poly.create () in
  List.iter2_exn (to_list formal) (to_list actual) ~f:(fun f a ->
    Hashtbl.set subst ~key:(Signal.uid f) ~data:a);
  subst
;;

(* Mutant RTL: same signature as [E.create ~sram]. [index] = site index, or -1 for an
   identity copy. *)
let rtl ~index ~(sram : E.sram) (actual : Signal.t E.I.t) : Signal.t E.O.t =
  let formal, dout_formal, o, si, roots, stop = rtl_scope () in
  let sites = enumerate ~stop roots in
  let subst = bind_subst formal actual ~to_list:E.I.to_list in
  (* named so that the Yosys init rule for rtl_imem_dout* (free SRAM output at power-up)
     matches whichever alias Yosys attaches the init attribute to *)
  let dout_w = Signal.(wire Sram.data_width -- "rtl_imem_dout_w") in
  Hashtbl.set subst ~key:(Signal.uid dout_formal) ~data:dout_w;
  let copy = copier ~subst ~mutation:(mutation_of ~sites index) in
  let o' = E.O.map o ~f:copy in
  let si' = Sram.I.map si ~f:copy in
  Signal.( <== ) dout_w (sram si').a_dout;
  o'
;;

let spec ~index ~(imem : Signal.t Sc.Imem.t -> Signal.t) (actual : Signal.t Sc.I.t)
  : Signal.t Sc.O.t
  =
  let formal, rdata_formal, o, m, roots, stop = spec_scope () in
  let sites = enumerate ~stop roots in
  let subst = bind_subst formal actual ~to_list:Sc.I.to_list in
  let rdata_w = Signal.wire 16 in
  Hashtbl.set subst ~key:(Signal.uid rdata_formal) ~data:rdata_w;
  let copy = copier ~subst ~mutation:(mutation_of ~sites index) in
  let o' = Sc.O.map o ~f:copy in
  let m' =
    { Sc.Imem.clock = copy m.clock
    ; we = copy m.we
    ; waddr = copy m.waddr
    ; wdata = copy m.wdata
    ; raddr = copy m.raddr
    }
  in
  Signal.( <== ) rdata_w (imem m');
  o'
;;
