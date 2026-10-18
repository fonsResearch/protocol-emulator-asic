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

(* SPI (doc/protocols/spi_v1.md), pins CS uio4, SCLK uio5, MOSI uio6, MISO uio7, MSB first,
   one byte per CS. Written after the contracts Library_v1.spi_ctl / spi_tgt were committed. *)
let spi_own_ctl = 0x70
let spi_own_tgt = 0x80
let spi_cfg_ctl = 0x04 (* msb_first *)
let spi_cfg2_ctl = 6 (* ser_pin = MOSI *)

(* Controller, half period h = 2 steps. Step numbering as in the document: p = POP, c = p + 2
   (CS visible), edges j at c + 2(j+1), CS high at c + 34, PUSH in c + 34.
   CPHA 0: SEND in c (bit k visible c + 4k + 1 .. c + 4k + 4); loop OUT act / PIN / OUT idle /
   DJNZ, PIN in c + 4k + 2 = S_k.
   CPHA 1: SEND in c + 2 (bit k visible c + 4k + 3 .. c + 4k + 6); loop OUT idle / PIN /
   OUT act / DJNZ run 7 times, the last bit peeled (no 17th edge); PIN in c + 4k + 4 = S_k. *)
let spi_ctl ~cpol ~cpha =
  let b2i b = if b then 1 else 0 in
  let idle = 0x10 lor (b2i cpol lsl 5) (* CS high, SCLK idle *)
  and sel_idle = b2i cpol lsl 5
  and sel_act = b2i (not cpol) lsl 5 in
  let init = [ Out idle; Oen spi_own_ctl; Ldi (L R1, 4); Ser (Period R1) ] in
  if not cpha
  then
    init
    @ [ Ldi (L Lc, 8) (* 4 *)
      ; Pop R0 (* 5: p *)
      ; Out sel_idle (* 6: p+1, CS visible in c = p+2 *)
      ; Ser (Send R0) (* 7: c *)
      ; Out sel_act (* 8: c+4k+1, leading edge visible c+4k+2 *)
      ; Pin (7, In_msb) (* 9: c+4k+2 = S_k *)
      ; Out sel_idle (* 10: trailing edge visible c+4k+4 *)
      ; Djnz 8 (* 11 *)
      ; Out idle (* 12: c+33, CS high in c+34 *)
      ; Push Sr (* 13: c+34 *)
      ; Jmp 4 (* 14 *)
      ]
  else
    init
    @ [ Pop R0 (* 4: p *)
      ; Out sel_idle (* 5: p+1 *)
      ; Ldi (L Lc, 7) (* 6: c *)
      ; Out sel_act (* 7: c+1, edge 0 visible c+2 *)
      ; Ser (Send R0) (* 8: c+2, bit 0 visible c+3 *)
      ; Out sel_idle (* 9: c+4k+3, trailing edge visible c+4k+4 *)
      ; Pin (7, In_msb) (* 10: c+4k+4 = S_k *)
      ; Out sel_act (* 11: c+4k+5, leading edge visible c+4k+6 *)
      ; Djnz 9 (* 12 *)
      ; Out sel_idle (* 13: c+31, edge 15 visible c+32 *)
      ; Pin (7, In_msb) (* 14: c+32 = S_7 *)
      ; Out idle (* 15: c+33 *)
      ; Push Sr (* 16: c+34 *)
      ; Jmp 4 (* 17 *)
      ]
;;

(* Target (h_min = 3, g = 6). MISO = sr[7] through MOV out, sr (own = uio7 only); MOSI shifted
   in MSB first by PIN In_msb one step after each sampling edge; CS waits are level waits so a
   CS edge during another instruction is not lost.
   CPHA 0: WTP lead (S_k), PIN, WTP trail, MOV (next bit), DJNZ.
   CPHA 1: WTP lead, MOV (bit k), WTP trail (S_k), PIN, DJNZ. *)
let spi_tgt ~cpol ~cpha =
  let lead = if cpol then Falling else Rising and trail = if cpol then Rising else Falling in
  let head = [ Oen spi_own_tgt (* 0 *); Wtp (4, High) (* 1 *); Pop Sr (* 2 *); Mov (Out_reg, S Sr) (* 3 *); Ldi (L Lc, 8) (* 4 *); Wtp (4, Low) (* 5 *) ] in
  let body =
    if not cpha
    then [ Wtp (5, lead) (* 6 *); Pin (6, In_msb) (* 7 *); Wtp (5, trail) (* 8 *); Mov (Out_reg, S Sr) (* 9 *); Djnz 6 (* 10 *) ]
    else [ Wtp (5, lead) (* 6 *); Mov (Out_reg, S Sr) (* 7 *); Wtp (5, trail) (* 8 *); Pin (6, In_msb) (* 9 *); Djnz 6 (* 10 *) ]
  in
  head @ body @ [ Push Sr (* 11 *); Jmp 1 (* 12 *) ]
;;
