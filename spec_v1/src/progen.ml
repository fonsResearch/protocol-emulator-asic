(* Random legal ISA v1 programs and CRC-framed programs, shared by the spec and RTL
   differential tests. *)
open! Core

let regs = Isa1.[ R0; R1; R2; R3; Sr; Lc ]
let regs5 = Isa1.[ R0; R1; R2; R3; Sr ]

let rand_instr st ~len : Isa1.t =
  let open Isa1 in
  let pick l = List.nth_exn l (Random.State.int st (List.length l)) in
  let tgt () = Random.State.int st (len + 1) in
  let v () = Random.State.int st 256 in
  let small () = pick [ 0; 1; 2; 3; 5; 255; v () ] in
  match Random.State.int st 20 with
  | 0 -> Jmp (tgt ())
  | 1 -> Br (Random.State.int st 16, tgt ())
  | 2 -> Out (v ())
  | 3 -> Oen (v ())
  | 4 -> Pin (Random.State.int st 8, pick [ Out_lsb; Out_msb; In_lsb; In_msb ])
  | 5 -> Wait (pick [ 0; 1; 2; 3; 7 ])
  | 6 -> Wtp (Random.State.int st 8, pick [ Low; High; Rising; Falling ])
  | 7 ->
    Ldi
      ( pick [ L (pick regs); To_lo; Xo ]
      , (match Random.State.int st 3 with 0 -> pick [ 0; 1; 2; 3 ] | _ -> small ()) )
  | 8 ->
    Mov
      ( pick [ M (pick regs); Out_reg; Oe_reg ]
      , pick [ S (pick regs); Pins; Ser_status ] )
  | 9 -> Cmp (pick [ C (pick regs); Cpins ], small ())
  | 10 -> Addi (pick regs, small ())
  | 11 -> Pop (pick regs5)
  | 12 -> Push (pick regs5)
  | 13 | 14 | 15 ->
    Ser (pick [ Send (pick regs5); Sendc (pick regs5); Crci; Crcs; Eop; Period (pick regs5); Idle ])
  | 16 -> Djnz (tgt ())
  | 17 -> Nop
  | 18 -> if Random.State.int st 4 = 0 then Halt else Nop
  | _ -> Clrt
;;

(* Structured family: CRC-protected frames (CRCI; n x POP/SENDC; CRCS; EOP; IDLE), so that
   coding paths (CRC5/16, stuffing, NRZI, EOP, contiguous SENDs) are visible on owned pins. *)
let frame_prog st : Isa1.t list =
  let open Isa1 in
  let n = 1 + Random.State.int st 4 and per = Random.State.int st 4 in
  [ Ldi (L Lc, n); Ldi (L R1, per); Ser (Period R1); Ser Crci; Pop R0; Ser (Sendc R0)
  ; Djnz 4; Ser Crcs; Ser Eop; Ser Idle; Wait (Random.State.int st 3); Jmp 0 ]
;;
