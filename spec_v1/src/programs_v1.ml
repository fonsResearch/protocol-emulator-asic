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

(* ---- label assembly (ISA v1 has no call/return; routines are inlined) ---- *)
type item =
  | Lbl of string
  | I of ((string -> int) -> t)

let ins x = I (fun _ -> x)
let waits n = if n <= 0 then [] else [ ins (Wait (n - 1)) ] (* exactly n steps *)

let asm items =
  let tbl = String.Table.create () in
  let _ =
    List.fold items ~init:0 ~f:(fun a -> function
      | Lbl s ->
        if Hashtbl.mem tbl s then raise_s [%message "duplicate label" s];
        Hashtbl.set tbl ~key:s ~data:a;
        a
      | I _ -> a + 1)
  in
  let look s = match Hashtbl.find tbl s with Some a -> a | None -> raise_s [%message "unknown label" s] in
  List.filter_map items ~f:(function Lbl _ -> None | I f -> Some (f look))
;;

(* I2C (doc/protocols/i2c_v1.md): SCL uio2 (0x04), SDA uio3 (0x08), open-drain; out bit 1 =
   released. own = od = 0x0C. *)
let i2c_own = 0x0C
let i2c_od = 0x0C

(* Controller, timing (l, h, tsu, thold) in steps as in Library_v1.i2c_ctl. Registers: r0 = N
   (bytes left), r1 = saved data byte while sr holds an SCL constant, r2 = copy of the address byte,
   then the status, r3 = repeated-start flag, sr = shift register, lc = bit counter.
   Step accounting (an instruction in step s changes pins from step s+1):
   - write bit: see send_bits (SCL toggled by PIN 2 on a constant; no pin read-back);
   - read bit: high: WTP (s), PIN In_msb (s+1, the contract's sampling step, D3), waits(h-2),
     OUT pull; low: waits(l-2), DJNZ, OUT release;
   - ACK received: OUT release SDA, waits, OUT release SCL, WTP (s), PIN In_lsb (s+1),
     CMP (Z = ACK; sr is 0 after 8 MSB-first shifts), waits(h-3), OUT pull;
   - conditions: Sr/STOP visible tsu steps after the first high step; status PUSH two steps
     after the condition; SCL pulled thold steps after START/Sr. *)
let i2c_ctl ~l ~h ~tsu ~thold =
  let m2 = Int.max 0 (l - 6) in
  let ka = Int.max 0 (l - 3) in
  let hdr =
    (* pops a (copy in r2) and c; r3 = c[7] via 7 LSB-first shifts on unowned pin 7; r0 = c[6:0] *)
    [ ins (Pop Sr); ins (Mov (M R2, S Sr)); ins (Pop R0); ins (Mov (M Sr, S R0)) ]
    @ List.init 7 ~f:(fun _ -> ins (Pin (7, Out_lsb)))
    @ [ ins (Mov (M R3, S Sr)); ins (Mov (M Sr, S R0)); ins (Pin (7, Out_msb)); ins (Pin (7, Out_lsb))
      ; ins (Mov (M R0, S Sr)); ins (Mov (M Sr, S R2)) ]
  in
  let send_bits lbl =
    (* sr MSB first; entered in a low phase with SCL pulled for >= 1 step. SCL is toggled with
       PIN 2 on a constant in sr (data saved in r1), so SDA is never rewritten from the line
       (D9: a read-back through the synchroniser is stale at fast ticks and copies a target's
       late ACK release into dSDA). Low phase: MOV sr r1, waits, DJNZ, PIN 3, MOV r1 sr, LDI,
       PIN 2 = 6 + m' steps; high phase: WTP (s), waits(h-2), LDI, PIN 2 (pull visible s+h+1). *)
    (* first cell: pull, LDI, waits, PIN 3, MOV, LDI, PIN 2 = 4 + waits steps low *)
    [ ins (Ldi (L Lc, 8)) ] @ waits (Int.max 0 (l - 4))
    @ [ Lbl lbl
      ; ins (Pin (3, Out_msb))
      ; ins (Mov (M R1, S Sr))
      ; ins (Ldi (L Sr, 0xFF))
      ; ins (Pin (2, Out_msb))
      ; ins (Wtp (2, High))
      ]
    @ waits (h - 2)
    @ [ ins (Ldi (L Sr, 0x00)); ins (Pin (2, Out_msb)); ins (Mov (M Sr, S R1)) ]
    @ waits m2
    @ [ I (fun f -> Djnz (f lbl)) ]
  in
  let ack_rx =
    (* leaves Z = ACK; ends with SCL pulled, SDA released *)
    [ ins (Out 0x08) ] @ waits ka
    @ [ ins (Out 0x0C); ins (Wtp (2, High)); ins (Pin (3, In_lsb)); ins (Cmp (C Sr, 0)) ]
    @ waits (h - 3)
    @ [ ins (Out 0x08) ]
  in
  let rw_is_write =
    (* Z <- (a[0] = 0): a << 7 via 7 MSB-first shifts on unowned pin 7 *)
    [ ins (Mov (M Sr, S R2)) ] @ List.init 7 ~f:(fun _ -> ins (Pin (7, Out_msb))) @ [ ins (Cmp (C Sr, 0)) ]
  in
  let br c lbl = I (fun f -> Br (c, f lbl)) and jmp lbl = I (fun f -> Jmp (f lbl)) in
  asm
    ([ ins (Out 0x0C) ] @ waits thold
     @ [ Lbl "idle" ] @ hdr
     (* START only after SCL has been observed high for tsu steps (D8: the environment may
        hold SCL low at reset or after a STOP; G4 measures the setup from the first high step) *)
     @ [ Lbl "start"; ins (Wtp (2, High)) ] @ waits (tsu - 1)
     @ [ ins (Out 0x04) ] @ waits (thold - 1) @ [ ins (Out 0x00) ]
     @ [ Lbl "addr" ] @ send_bits "ab" @ ack_rx
     @ [ br 2 "addr_nack" ] @ rw_is_write
     @ [ ins (Ldi (L R2, 0)); br 1 "write"; jmp "read" ]
     (* address NACK: status 1; a write discards its N data bytes before the STOP *)
     @ [ Lbl "addr_nack" ] @ rw_is_write
     @ [ ins (Ldi (L R2, 1)); br 2 "stop"; Lbl "an_disc"; ins (Pop Sr); ins (Addi (R0, 0xFF)); br 2 "an_disc"; jmp "stop" ]
     (* write data *)
     @ [ Lbl "write"; ins (Pop Sr) ] @ send_bits "wb" @ ack_rx
     @ [ br 2 "data_nack"; ins (Addi (R0, 0xFF)); br 2 "write"; jmp "end" ]
     @ [ Lbl "data_nack"; ins (Ldi (L R2, 2)); Lbl "dn"; ins (Addi (R0, 0xFF)); br 1 "stop"; ins (Pop Sr); jmp "dn" ]
     (* read data *)
     @ [ Lbl "read"; ins (Ldi (L Lc, 8)) ] @ waits l
     @ [ Lbl "rb"; ins (Out 0x0C); ins (Wtp (2, High)); ins (Pin (3, In_msb)) ] @ waits (h - 2)
     @ [ ins (Out 0x08) ] @ waits (l - 2)
     @ [ I (fun f -> Djnz (f "rb")); ins (Push Sr); ins (Addi (R0, 0xFF)); br 1 "rnack" ]
     @ [ ins (Out 0x00); ins (Out 0x04); ins (Wtp (2, High)) ] @ waits (h - 1)
     @ [ ins (Out 0x00); ins (Out 0x08); ins (Ldi (L Lc, 8)) ] @ waits (l - 4) @ [ jmp "rb" ]
     @ [ Lbl "rnack" ] @ waits l @ [ ins (Out 0x0C); ins (Wtp (2, High)) ] @ waits (h - 1) @ [ ins (Out 0x08) ]
     (* end of a transaction without NACK: Sr if r3 != 0, else STOP *)
     @ [ Lbl "end"; ins (Cmp (C R3, 0)); br 1 "stop" ]
     @ [ ins (Out 0x08) ] @ waits l
     @ [ ins (Out 0x0C); ins (Wtp (2, High)) ] @ waits (tsu - 2)
     @ [ ins (Out 0x04) ] @ waits 2 @ [ ins (Push R2) ] @ hdr @ waits thold @ [ ins (Out 0x00); jmp "addr" ]
     (* STOP from a low phase (SCL pulled, SDA released) *)
     @ [ Lbl "stop"; ins (Out 0x00) ] @ waits l
     @ [ ins (Out 0x04); ins (Wtp (2, High)) ] @ waits (tsu - 2)
     @ [ ins (Out 0x0C) ] @ waits 2 @ [ ins (Push R2) ] @ waits thold @ [ jmp "idle" ])
;;

(* Target with 7-bit address [addr] (the host tool patches the CMP immediates; the popped
   config byte must equal [addr], else HALT). Event-driven on the SCL line, so the program
   does not depend on P. Conditions (START, Sr, STOP) are detected only where B3 allows them:
   from bus idle and in the first cell after an ACK cell. There the program samples SDA in
   the second high step (b), presets sr to b in all 8 bits, then polls:
   PIN SDA (In_lsb, shifting the sample into sr), WTP SCL low with to = 1, BR; SDA differing
   from b while SCL is still high afterwards is a condition (SCL cannot fall and rise again
   within l_min). Period 6 steps; a condition is recognised only if SCL stays high for about
   7 steps after the SDA edge (the hd margin, measured in test_i2c.ml).
   Registers: r0 = config, r1 = saved data (stretch release), sr = data / poll history,
   lc = cell counter. to = 1 only inside poll loops. *)
let i2c_tgt ~addr =
  let br c lbl = I (fun f -> Br (c, f lbl)) and jmp lbl = I (fun f -> Jmp (f lbl)) in
  let djnz lbl = I (fun f -> Djnz (f lbl)) in
  let to1 = ins (Ldi (To_lo, 1)) and to0 = ins (Ldi (To_lo, 0)) in
  (* first cell after an ACK cell (or bus idle): [pre] runs in the low phase; on SCL fall
     goes to [fell1]/[fell0] (bit 7 was 1/0), Sr/START -> "start", STOP -> "stop" *)
  let first_cell p ~pre ~fell1 ~fell0 =
    [ Lbl (p ^ "_first"); ins (Wtp (2, Low)) ]
    @ pre
    @ [ ins (Ldi (L Sr, 0xFF)); ins (Wtp (2, High)); ins (Pin (3, In_lsb)); ins (Cmp (C Sr, 0xFF)); to1
      ; br 1 (p ^ "_q1"); ins (Ldi (L Sr, 0))
      ; Lbl (p ^ "_q0"); ins (Pin (3, In_lsb)); ins (Wtp (2, Low)); br 4 fell0; ins (Cmp (C Sr, 0)); br 1 (p ^ "_q0"); jmp "stop"
      ; Lbl (p ^ "_q1"); ins (Pin (3, In_lsb)); ins (Wtp (2, Low)); br 4 fell1; ins (Cmp (C Sr, 0xFF)); br 1 (p ^ "_q1"); jmp "start" ]
  in
  asm
    ([ ins (Out 0x0C); to0; ins (Pop R0); ins (Cmp (C R0, addr)); br 2 "halt" ]
     (* bus idle: wait for START (SDA falls while SCL high) *)
     @ [ Lbl "idle"; ins (Ldi (L Sr, 0xFF)); to1
       ; Lbl "qi"; ins (Pin (3, In_lsb)); ins (Wtp (2, Low)); br 4 "resync_first"; ins (Cmp (C Sr, 0xFF)); br 1 "qi" ]
     (* START / Sr: address byte *)
     @ [ Lbl "start"; to0; ins (Ldi (L Lc, 8))
       ; Lbl "ab"; ins (Wtp (2, Low)); ins (Wtp (2, High)); ins (Pin (3, In_msb)); djnz "ab"
       ; ins (Cmp (C Sr, addr lsl 1)); br 1 "wr_ack"; ins (Cmp (C Sr, (addr lsl 1) lor 1)); br 1 "rd_ack"
       ; ins (Wtp (2, Low)); ins (Wtp (2, High)); jmp "nad_first" ]
     @ [ Lbl "stop"; to0; jmp "idle" ]
     (* not addressed: passive, byte-aligned until a condition *)
     @ first_cell "nad" ~pre:[] ~fell1:"nad_fell" ~fell0:"nad_fell"
     @ [ Lbl "nad_fell"; to0; ins (Ldi (L Lc, 8)); Lbl "nb"; ins (Wtp (2, High)); ins (Wtp (2, Low)); djnz "nb"; jmp "nad_first" ]
     (* lost alignment (SCL low seen while waiting for START): check every cell for a condition *)
     @ first_cell "resync" ~pre:[] ~fell1:"resync_fell" ~fell0:"resync_fell"
     @ [ Lbl "resync_fell"; to0; jmp "resync_first" ]
     (* write: ACK the address, then bytes *)
     @ [ Lbl "wr_ack"; ins (Wtp (2, Low)); ins (Out 0x04); ins (Wtp (2, High)) ]
     @ first_cell "wr" ~pre:[ ins (Out 0x0C) ] ~fell1:"w_fell1" ~fell0:"w_fell0"
     @ [ Lbl "w_fell0"; to0; ins (Ldi (L Sr, 0)); jmp "w_rest"
       ; Lbl "w_fell1"; to0; ins (Ldi (L Sr, 1))
       ; Lbl "w_rest"; ins (Ldi (L Lc, 7))
       ; Lbl "wb"; ins (Wtp (2, High)); ins (Pin (3, In_msb)); ins (Wtp (2, Low)); djnz "wb"
       ; ins (Out 0x04); ins (Push Sr); ins (Wtp (2, High)); jmp "wr_first" ]
     (* read: ACK the address, then bytes; stretch only when the TX FIFO is empty *)
     @ [ Lbl "rd_ack"; ins (Wtp (2, Low)); ins (Out 0x04); ins (Wtp (2, High))
       ; Lbl "rd_next"; ins (Wtp (2, Low)); br 5 "rd_stretch"; ins (Pop Sr); ins (Pin (3, Out_msb))
       ; Lbl "rd_bits"; ins (Ldi (L Lc, 7))
       ; Lbl "rb"; ins (Wtp (2, High)); ins (Wtp (2, Low)); ins (Pin (3, Out_msb)); djnz "rb"
       ; ins (Wtp (2, High)); ins (Wtp (2, Low)); ins (Out 0x0C)
       ; ins (Wtp (2, High)); ins (Pin (3, In_lsb)); ins (Cmp (C Sr, 0)); br 1 "rd_next"; jmp "nad_first"
       ; Lbl "rd_stretch"; ins (Out 0x00); ins (Pop Sr); ins (Pin (3, Out_msb))
         (* release SCL with PIN 2 on a constant, data saved in r1 (D9: no pin read-back) *)
       ; ins (Mov (M R1, S Sr)); ins (Ldi (L Sr, 0xFF)); ins (Pin (2, Out_msb)); ins (Mov (M Sr, S R1)); jmp "rd_bits" ]
     @ [ Lbl "halt"; ins Halt ])
;;
