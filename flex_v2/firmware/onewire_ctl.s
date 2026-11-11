; 1-Wire controller, standard speed, DQ = uio2 open drain (held-out package, plan step 11).
; Written after the contract (flex_v2/src/flex_lib.ml onewire_ctl, doc/protocols/onewire_v1.md).
; P = 29 at 30 MHz: one step = 1 us. OUT in step a takes effect from step a + 1; WAIT k = k + 1 steps.
; A slot starting with OUT 0x00 in step a pulls from s0 = a + 1.
; Host TX framing: 0 = reset (pushes the presence sample in bit 7: 0 = present),
;                  1 b = write byte b (LSB first), 2 = read a byte (pushed, LSB first).
.own 0x04
.od 0x04
.equ DQ 2

        OUT 0x04            ; release DQ
cmd:    POP r0
        CMP r0, 0
        BR z, reset
        CMP r0, 1
        BR z, write
read:   LDI lc, 8
rloop:  OUT 0x00            ; a
        WAIT 1              ; a+1 .. a+2
        OUT 0x04            ; a+3: released from s0+3 (L = 3)
        WAIT 8              ; a+4 .. a+12
        PIN DQ, in_lsb      ; a+13 = s0+12: sample (tRDV 15 us)
        WAIT 52             ; a+14 .. a+66
        DJNZ rloop          ; a+67: next pull at s0+68
        PUSH sr
        JMP cmd
write:  POP sr
        LDI lc, 8
wloop:  OUT 0x00            ; a
        WAIT 4              ; a+1 .. a+5
        PIN DQ, out_lsb     ; a+6: a 1 releases from s0+6 (L = 6), a 0 keeps the pull
        WAIT 58             ; a+7 .. a+65
        OUT 0x04            ; a+66: released from s0+66 (write-0 L = 66)
        WAIT 61             ; a+67 .. a+128
        DJNZ wloop          ; a+129: next pull at s0+130 = r+64 after a write-0
        JMP cmd
reset:  OUT 0x00            ; a
        WAIT 499            ; a+1 .. a+500
        OUT 0x04            ; a+501: released from r = s0+501 (L = 501)
        WAIT 69             ; a+502 .. a+571
        PIN DQ, in_lsb      ; a+572 = r+70: presence sample (tPDHIGH <= 60, tPDLOW >= 60)
        WAIT 409            ; a+573 .. a+982
        PUSH sr             ; a+983: bit 7 = presence sample; next pull at r+487 or later
        JMP cmd
