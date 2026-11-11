; UART 8N1 receiver on uio1 (input), D = 8 steps per bit, bytes pushed to the host RX FIFO.
; Checked on chip by ROM package 1 (uart_rx_v1_d8_m2_p1) at P = 32:
;   30 MHz / (33 * 8) = 113636 baud (-1.36 % from 115200; the contract tolerates m = 2 steps).
; s0 = the step WTP sees the falling edge; data bit i is sampled in step s0 + (i+1)D + D/2.
.equ PIN_RX 1
.equ D 8
.equ C 4                    ; D / 2

start:  WTP PIN_RX, falling ; s0
        LDI lc, 8
        WAIT D+C-3          ; first sample in step s0 + D + C
bit:    PIN PIN_RX, in_lsb
        WAIT D-3
        DJNZ bit
        PUSH sr             ; step s0 + 9D + C
        JMP start
