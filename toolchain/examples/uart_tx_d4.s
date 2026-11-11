; UART 8N1 transmitter on uio0, D lane steps per bit, bytes from the host TX FIFO.
; Checked on chip by ROM package 0 (uart_tx_v1_d4_p0) at P = 64:
;   30 MHz / ((64 + 1) * 4) = 115385 baud (+0.16 % from 115200).
; Timing: every bit lasts exactly D steps (start, 8 data LSB first); stop >= D steps.
.own 0x01
.equ D 4

        OUT 1               ; idle high from the first step
        OEN 1               ; drive uio0 (push-pull)
next:   POP sr              ; blocks until the host writes a byte
        LDI lc, 8
        OUT 0               ; start bit: 1 + (D-1) steps
        WAIT D-2
bit:    PIN 0, out_lsb      ; data bit: 1 + (D-2) + 1 steps
        WAIT D-3
        DJNZ bit
        OUT 1               ; stop bit
        WAIT D-2
        JMP next
