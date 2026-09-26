(* Reference programs from doc/isa/isa_v0.md sections 6 and 7. *)
open! Core
open Isa

(* UART 8N1 TX on uo_out[0], bit period [d] cycles, d >= 3 (section 6). *)
let uart_tx ~d =
  if d < 3 then raise_s [%message "uart_tx requires d >= 3" (d : int)];
  [ Out 0x01 (* 0: idle high *)
  ; In (* 1: sr <- byte *)
  ; Ldc 8 (* 2 *)
  ; Out 0x00 (* 3: start bit *)
  ; Wait (d - 2) (* 4 *)
  ; Outb 0 (* 5: data bit *)
  ; Wait (d - 3) (* 6 *)
  ; Djnz 5 (* 7 *)
  ; Out 0x01 (* 8: stop bit *)
  ; Wait (d - 2) (* 9 *)
  ; Jmp 1 (* 10 *)
  ]
;;

(* Known-bad variant (section 6): lines 2 and 3 swapped; the start bit lasts d+1 cycles. *)
let uart_tx_bad_start ~d =
  match uart_tx ~d with
  | a :: b :: ldc :: out0 :: rest -> a :: b :: out0 :: ldc :: rest
  | _ -> assert false
;;

(* Timed-QED transform T (section 7): the counted loop at 5..7 is unrolled into 8 copies
   of [Outb 0; Wait (d-2)]. The final JMP target (1) is before the loop, so it is unchanged. *)
let uart_tx_unrolled ~d =
  if d < 3 then raise_s [%message "uart_tx_unrolled requires d >= 3" (d : int)];
  [ Out 0x01; In; Ldc 8; Out 0x00; Wait (d - 2) ]
  @ List.concat (List.init 8 ~f:(fun _ -> [ Outb 0; Wait (d - 2) ]))
  @ [ Out 0x01; Wait (d - 2); Jmp 1 ]
;;
