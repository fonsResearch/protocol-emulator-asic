(* Reference programs for ISA v1 lanes. *)
open! Core
open Isa1

(* UART 8N1 TX on owned pin 0, bit time d steps (d >= 3). WAIT k takes k+1 steps. Bytes come
   from the host TX FIFO (POP blocks while it is empty; the line idles high meanwhile).
   Start bit: OUT 0 + WAIT (d-2) = d steps. Data bit: PIN + WAIT (d-3) + DJNZ = d steps.
   Stop bit: OUT 1 + WAIT (d-2) = d steps, then JMP, POP, LDI before the next start bit. *)
let uart_tx ~d =
  if d < 3 then raise_s [%message "uart_tx requires d >= 3" (d : int)];
  [ Out 1 (* 0 *)
  ; Oen 1 (* 1 *)
  ; Pop Sr (* 2: next byte *)
  ; Ldi (L Lc, 8) (* 3 *)
  ; Out 0 (* 4: start bit *)
  ; Wait (d - 2) (* 5 *)
  ; Pin (0, Out_lsb) (* 6: data bit *)
  ; Wait (d - 3) (* 7 *)
  ; Djnz 6 (* 8 *)
  ; Out 1 (* 9: stop bit *)
  ; Wait (d - 2) (* 10 *)
  ; Jmp 2 (* 11 *)
  ]
;;

(* Known-bad variant: start bit lasts d+1 steps. *)
let uart_tx_bad_start ~d =
  List.mapi (uart_tx ~d) ~f:(fun k ins -> if k = 5 then Wait (d - 1) else ins)
;;

(* UART 8N1 RX on input pin [pin], d steps per bit (doc/protocols/uart_v1.md section 4).
   s0 = the step in which WTP sees the falling edge. Data bit i is sampled (LSB first in) in
   step s0 + (i+1) d + d/2; the byte is pushed in step s0 + 9d + d/2; WTP is ready again in
   step s0 + 9d + d/2 + 2, i.e. before the earliest next start s0 + 10d - m when
   d/2 + 2 + m <= d. Requires d >= 6. *)
let uart_rx ~d ~pin =
  if d < 6 then raise_s [%message "uart_rx requires d >= 6" (d : int)];
  let c = d / 2 in
  [ Wtp (pin, Falling) (* 0: s0 *)
  ; Ldi (L Lc, 8) (* 1 *)
  ; Wait (d + c - 3) (* 2: first PIN in step s0 + d + c *)
  ; Pin (pin, In_lsb) (* 3 *)
  ; Wait (d - 3) (* 4 *)
  ; Djnz 3 (* 5: one bit per d steps *)
  ; Push Sr (* 6: step s0 + 9d + c *)
  ; Jmp 0 (* 7 *)
  ]
;;
