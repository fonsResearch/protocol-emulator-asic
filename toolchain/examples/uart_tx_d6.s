; The same transmitter at D = 6 steps per bit. It runs under ROM package 0 with the window
; override from `pemu_cc retune 0 uart_tx:d=6,pin=0` (windows 0 2 6 62 0 0 0 0); the
; retuned contract is not covered by the shipped A2 proof (doc/toolchain.md section 3.3).
; At P = 42: 30 MHz / (43 * 6) = 116279 baud (+0.94 % from 115200).
.own 0x01
.equ D 6

        OUT 1
        OEN 1
next:   POP sr
        LDI lc, 8
        OUT 0
        WAIT D-2
bit:    PIN 0, out_lsb
        WAIT D-3
        DJNZ bit
        OUT 1
        WAIT D-2
        JMP next
