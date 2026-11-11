; Square wave on uio2, HALF steps high and HALF steps low (unmonitored: run the lane with its
; package disabled). At P = 29 one step is 30 cycles = 1 us at 30 MHz, so HALF = 250 is 2 kHz.
; An OUT takes effect at the end of its step; WAIT k lasts k + 1 steps.
.own 0x04
.equ HALF 250

        OUT 0x04
        OEN 0x04
loop:   OUT 0x04            ; high from the next step
        WAIT HALF-2         ; HALF - 1 steps
        OUT 0x00            ; high lasted (HALF - 1) + 1 = HALF steps
        WAIT HALF-3         ; HALF - 2 steps
        JMP loop            ; low lasts (HALF - 2) + 1 (JMP) + 1 (OUT) = HALF steps
