(* Monitor ISA v1 spec circuit for one lane's package context and its 8 units
   (doc/contracts/monitor_isa_v1.md sections 1-5), written as explicit next-state functions.
   The instruction source ([fetch unit pc] -> 82-bit word) and the tables are parameters:
   constants for a ROM package ([of_package]), or free signals in a proof harness.
   Outputs: per unit, a firing in this cycle with its role and code. *)
open! Core
open Hardcaml
open Signal
module M = Mprog

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_sync_n : 'a
    ; running : 'a
    ; tick : 'a
    ; ui_in : 'a [@bits 8]
    ; uio_in : 'a [@bits 8]
    ; uo_out : 'a [@bits 8]
    ; uio_out : 'a [@bits 8]
    ; uio_oe : 'a [@bits 8]
    ; pop_ev : 'a
    ; pop_data : 'a [@bits 8]
    ; push_ev : 'a
    ; push_data : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

let n_units = 8

module O = struct
  type 'a t =
    { fire : 'a [@bits 8] (* unit k fires in this cycle *)
    ; role : 'a [@bits 8] (* 1 = blame *)
    ; codes : 'a list [@length 8] [@bits 8]
    }
  [@@deriving hardcaml]
end

type tables =
  { remap : Signal.t array (* 16 x 6 *)
  ; preds : Signal.t array (* 16 x 29; entries 0 and 15 are ignored (true, false) *)
  ; windows : Signal.t array (* 8 x 12 *)
  ; code_role : Signal.t array (* 16 x 1 *)
  ; code_val : Signal.t array (* 16 x 8 *)
  ; starts : Signal.t array (* per unit, 7 *)
  ; guards : (Signal.t * Signal.t * Signal.t * Signal.t * Signal.t) array
      (* per unit: enable, predicate 4, start 7, end 7, handler 7 *)
  ; present : bool array (* per unit: a program is loaded *)
  }

let bits_of_list l = List.map l ~f:(fun b -> if b then vdd else gnd) |> concat_lsb

let tables_of_package (p : M.t) =
  let k n v = of_int ~width:n v in
  let unit_or i f d = if i < Array.length p.units then f p.units.(i) else d in
  { remap = Array.map p.remap ~f:(k 6)
  ; preds =
      Array.mapi p.preds ~f:(fun i pr ->
        if i = 0 || i = 15 || M.equal_pred pr M.pred_false || M.equal_pred pr M.pred_true
        then zero M.pred_width
        else bits_of_list (M.encode_pred pr))
  ; windows = Array.map p.windows ~f:(k 12)
  ; code_role =
      Array.map p.codes ~f:(function Some (Lang.Blame, _) -> vdd | _ -> gnd)
  ; code_val = Array.map p.codes ~f:(function Some (_, c) -> k 8 c | None -> zero 8)
  ; starts = Array.init n_units ~f:(fun i -> unit_or i (fun u -> k 7 u.start) (zero 7))
  ; guards =
      Array.init n_units ~f:(fun i ->
        match unit_or i (fun u -> u.guard) None with
        | None -> gnd, zero 4, zero 7, zero 7, zero 7
        | Some (g, s, e, h) -> vdd, k 4 g, k 7 s, k 7 e, k 7 h)
  ; present = Array.init n_units ~f:(fun i -> i < Array.length p.units)
  }
;;

let rom_fetch (p : M.t) i pc =
  if i >= Array.length p.units
  then zero M.instr_width
  else (
    let code = p.units.(i).code in
    mux pc (List.init 128 ~f:(fun a ->
      if a < Array.length code then bits_of_list (M.encode_instr code.(a)) else zero M.instr_width)))
;;

(* field accessor for an 82-bit instruction word *)
let field =
  let offs =
    List.folding_map M.instr_fields ~init:0 ~f:(fun off (n, w) -> off + w, (n, (off, w)))
  in
  fun word name ->
    let off, w = List.Assoc.find_exn offs ~equal:String.equal name in
    select word (off + w - 1) off
;;

let sat12 x = mux2 (x ==:. 4095) x (x +:. 1)

(* unit state *)
type ustate =
  { pc : Signal.t
  ; k : Signal.t
  ; m0 : Signal.t
  ; m1 : Signal.t
  ; rg : Signal.t
  ; stopped : Signal.t
  }

let ustate_widths = [ 7; 12; 12; 12; 16; 1 ]
let ustate_to_list s = [ s.pc; s.k; s.m0; s.m1; s.rg; s.stopped ]

let ustate_of_list = function
  | [ pc; k; m0; m1; rg; stopped ] -> { pc; k; m0; m1; rg; stopped }
  | _ -> raise_s [%message "ustate_of_list"]
;;

(* reset state of a unit: pc = start, everything else 0 *)
let ustate_reset ~start = { pc = start; k = zero 12; m0 = zero 12; m1 = zero 12; rg = zero 16; stopped = gnd }

type events =
  { pop_ev : Signal.t
  ; pop_data : Signal.t
  ; push_ev : Signal.t
  ; push_data : Signal.t
  }

(* Observation front end of one lane (sections 2-3): synchronisers, remap, history and the
   predicate bank. Returns the gated running/step signals and the 16 bank bits. *)
let observe ~(tables : tables) (i : _ I.t) =
  let spec = Reg_spec.create ~clock:i.clock ~clear:~:(i.rst_sync_n) () in
  let regw name w =
    let d = wire w in
    let q = reg spec d -- name in
    q, d
  in
  let sync x = reg spec (reg spec x) in
  let s2_ui = sync i.ui_in
  and s2_uio = sync i.uio_in in
  let drive = i.uio_oe &: ~:(i.uio_out) in
  let g =
    bits_lsb i.uo_out @ bits_lsb i.uio_out @ bits_lsb i.uio_oe @ bits_lsb s2_ui @ bits_lsb s2_uio
    @ bits_lsb drive @ [ i.pop_ev; i.push_ev ]
  in
  (* nothing runs under reset (as the model) *)
  let running = i.rst_sync_n &: i.running in
  let step = running &: i.tick in
  (* local observables, history, seen *)
  let now = Array.map tables.remap ~f:(fun r -> mux r g) in
  let hist = Array.init 16 ~f:(fun k -> regw (sprintf "mon_hist%d" k) 4) in
  let seen, seen_d = regw "mon_seen" 3 in
  Array.iteri hist ~f:(fun k (q, d) ->
    d <== mux2 (~:running) (zero 4) (mux2 step (select (q @: now.(k)) 3 0) q));
  seen_d <== mux2 (~:running) (zero 3) (mux2 (step &: (seen <:. 4)) (seen +:. 1) seen);
  (* per observable, its values at delays 0..4 (delay d > 0 reads 0 until observed) *)
  let col =
    List.init 16 ~f:(fun k ->
      concat_lsb
        (now.(k) :: List.init 4 ~f:(fun d -> bit (fst hist.(k)) d &: (seen >=:. d + 1))))
  in
  let eval_pred (w : Signal.t) =
    let lit off =
      let obs = select w (off + 3) off
      and kind = select w (off + 5) (off + 4)
      and delay = select w (off + 7) (off + 6)
      and neg = bit w (off + 8) in
      (* one observable select, then the delay tap *)
      let v5 = mux obs col in
      let x = mux delay (List.init 4 ~f:(fun dd -> bit v5 dd))
      and y = mux delay (List.init 4 ~f:(fun dd -> bit v5 (dd + 1)))
      and valid = mux delay (List.init 4 ~f:(fun dd -> seen >=:. dd + 1)) in
      let r = mux kind [ x; valid &: x &: ~:y; valid &: ~:x &: y; valid &: (x ^: y) ] in
      r ^: neg
    in
    let op o a b = mux2 o (a |: b) (a &: b) in
    op (bit w 28) (op (bit w 27) (lit 0) (lit 9)) (lit 18)
  in
  let bank =
    Array.init 16 ~f:(fun k ->
      if k = 0 then vdd else if k = 15 then gnd else eval_pred tables.preds.(k))
    |> Array.to_list
  in
  running, step, bank
;;

(* One step of one unit (section 5) given its fetched instruction [w]. [act] = this unit
   evaluates in this cycle (a step of the lane and the unit is not stopped). Returns the
   next state (restart excluded), the firing and the code-table index of the firing. *)
let unit_step ~pb ~win ~guard ~w ~(st : ustate) ~act ~(ev : events) =
  let { pc; k; m0; m1; rg; stopped } = st in
    let ki = sat12 k
    and m0i = sat12 m0
    and m1i = sat12 m1 in
    let gen, gp, gs, ge, gh = guard in
    let guard_hit = gen &: (pc >=: gs) &: (pc <=: ge) &: pb gp in
        let f = field w in
    let op = f "op" in
    let since = f "since" in
    let kappa = mux since [ ki; m0i; m1i; ki ] in
    let lo = win (f "lo")
    and hi = win (f "hi") in
    let mode = f "mod"
    and marg = f "marg" in
    let modv ~reg_v ~m0v ~m1v x =
      let regb = mux (select marg 3 0) (bits_lsb reg_v) in
      let mv = mux2 (bit marg 3) m1v m0v in
      let el = mv >=: win (select marg 2 0) in
      mux mode [ x; x &: regb; ~:(x ^: regb); x &: el ]
    in
    let e_val = pb (f "pe") &: pb (f "pcond") in
    let pr0 = pb (f "pr") in
    let r_val =
      ~:(pb (f "pcond"))
      |: mux2 (f "md_pr") (modv ~reg_v:rg ~m0v:m0i ~m1v:m1i pr0) pr0
    in
    let is o = op ==:. M.op_code o in
    let take = is Take_tx |: is Take_rx in
    let ev_take = mux2 (is Take_tx) ev.pop_ev ev.push_ev in
    let evv = mux2 take ev_take e_val in
    let chk = f "chk"
    and early = f "early" in
    let await_complete = evv &: (kappa >=: lo)
    and await_early = evv &: (kappa <: lo) &: (early <>:. 0)
    and await_to = ~:evv &: (kappa >=: hi) &: (chk <>:. 0) in
    let hu_complete = e_val &: (kappa >=: lo) in
    let hu_early = e_val &: (kappa <: lo) &: (early <>:. 0) in
    let hu_viol = ~:r_val |: (kappa >=: hi) in
    let complete =
      mux op
        [ await_complete; e_val; r_val &: (ki >=: hi); hu_complete; ki >=: hi; await_complete
        ; await_complete; gnd ]
    in
    let op_fire =
      mux op
        [ await_early |: await_to; gnd; ~:r_val; ~:hu_complete &: (hu_early |: hu_viol); gnd
        ; await_early |: await_to; await_early |: await_to; gnd ]
    in
    let op_code_idx =
      mux op
        [ mux2 await_early early chk; zero 4; chk; mux2 hu_early early chk; zero 4
        ; mux2 await_early early chk; mux2 await_early early chk; zero 4 ]
    in
    (* completion bundle *)
    let mark = f "mark" in
    let m0b = mux2 (mark ==:. 1) (zero 12) m0i
    and m1b = mux2 (mark ==:. 2) (zero 12) m1i in
    let tsel = f "tsel" in
    let tdata = mux2 (is Take_tx) ev.pop_data ev.push_data in
    let reg1 =
      mux2 take (mux2 tsel (tdata @: select rg 7 0) (select rg 15 8 @: tdata)) rg
    in
    let smp_bit = f "smp_bit" in
    let smp_val = pb (f "smp_p") in
    let reg2 =
      mux2 (f "smp_en")
        (let oh = binary_to_onehot smp_bit in
         (reg1 &: ~:oh) |: mux2 smp_val oh (zero 16))
        reg1
    in
    let mat_fire =
      f "mat_en" &: ~:(ev.push_ev &: (ev.push_data ==: select reg2 7 0))
    in
    let exp_idx = f "exp" in
    let e0 = pb exp_idx in
    let exp_v = mux2 (f "md_exp") (modv ~reg_v:reg2 ~m0v:m0b ~m1v:m1b e0) e0 in
    (* an expect is present iff its predicate index is non-zero or it carries the modifier
       (a bare Reg_bit / Elapsed_ge requirement compiles to index 0 = true + modifier) *)
    let exp_fire = ((exp_idx <>:. 0) |: f "md_exp") &: ~:exp_v in
    let b_fire = complete &: (mat_fire |: exp_fire) in
    let b_code_idx = mux2 mat_fire (f "mat_chk") (f "exp_chk") in
    let fire = act &: ~:guard_hit &: (op_fire |: b_fire) in
    let code_idx = mux2 op_fire op_code_idx b_code_idx in
    let ok_complete = act &: ~:guard_hit &: complete &: ~:b_fire in
    let bp = f "bp" in
    let nxt = mux2 ((bp <>:. 0) &: pb bp) (f "alt") (f "next") in
    let to_stop = nxt ==:. M.stop_addr in
  let next =
    { pc = mux2 (act &: guard_hit) gh (mux2 (ok_complete &: ~:to_stop) nxt pc)
    ; k = mux2 (act &: (guard_hit |: ok_complete)) (zero 12) (mux2 act ki k)
    ; m0 = mux2 ok_complete m0b (mux2 act m0i m0)
    ; m1 = mux2 ok_complete m1b (mux2 act m1i m1)
    ; rg = mux2 ok_complete reg2 rg
    ; stopped = stopped |: fire |: (ok_complete &: to_stop)
    }
  in
  next, fire, code_idx
;;

let create ~(tables : tables) ~(fetch : int -> Signal.t -> Signal.t) (i : _ I.t) =
  (* unit registers have no clear: under reset [running] is low, so restart loads them *)
  let nspec = Reg_spec.create ~clock:i.clock () in
  let running, step, bank = observe ~tables i in
  let pb idx = mux idx bank in
  let win idx = mux idx (Array.to_list tables.windows) in
  let crole idx = mux idx (Array.to_list tables.code_role)
  and cval idx = mux idx (Array.to_list tables.code_val) in
  let ev = { pop_ev = i.pop_ev; pop_data = i.pop_data; push_ev = i.push_ev; push_data = i.push_data } in
  let units =
    List.init n_units ~f:(fun u ->
      if not tables.present.(u)
      then gnd, gnd, zero 8
      else (
        let ds = List.map ustate_widths ~f:wire in
        let qs =
          List.map2_exn ds [ "pc"; "k"; "m0"; "m1"; "reg"; "stopped" ] ~f:(fun d n ->
            reg nspec d -- sprintf "mon_u%d_%s" u n)
        in
        let st = ustate_of_list qs in
        let act = step &: ~:(st.stopped) in
        let w = fetch u st.pc in
        let next, fire, code_idx =
          unit_step ~pb ~win ~guard:tables.guards.(u) ~w ~st ~act ~ev
        in
        let rst_st = ustate_reset ~start:tables.starts.(u) in
        List.iter2_exn ds
          (List.map2_exn (ustate_to_list rst_st) (ustate_to_list next) ~f:(fun r n -> mux2 (~:running) r n))
          ~f:( <== );
        fire, crole code_idx, cval code_idx))
  in
  { O.fire = concat_lsb (List.map units ~f:(fun (f, _, _) -> f))
  ; role = concat_lsb (List.map units ~f:(fun (f, r, _) -> f &: r))
  ; codes = List.map units ~f:(fun (f, _, c) -> mux2 f c (zero 8))
  }
;;

let of_package p i = create ~tables:(tables_of_package p) ~fetch:(rom_fetch p) i
