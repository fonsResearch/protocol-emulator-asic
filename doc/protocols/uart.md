# UART 8N1 transmit convention (monitor source document)

Status: APPROVED v0 (2026-09-27). This is the only document the monitor (S3) context reads. It describes the line protocol and deliberately says nothing about the emulator ISA.

## Line format

- The line is a single wire and idles at logic 1 (mark).
- A frame consists of: 1 start bit (logic 0), 8 data bits sent least significant bit first, and 1 stop bit (logic 1).
- There is no parity bit.
- Every bit lasts exactly one bit period of B clock cycles, measured on the monitor's clock. The monitor is parameterised by B.
- Between frames the line may stay idle for any duration of at least 0 cycles beyond the stop bit.

## Monitor requirements

The monitor observes the TX line once per clock cycle and exposes:

- `bad` (safety). Asserted in any cycle where the observed line violates the format. Let cycle 0 be the first cycle in which the line is observed low after being idle; that cycle starts a frame. Within a frame (cycles 0 .. 10B-1):
  - the line may change level only at offsets that are integer multiples of B, where a change at offset k means the value in cycle k differs from the value in cycle k-1;
  - the line must be low during cycles 0 .. B-1 (start bit);
  - the line must be high during cycles 9B .. 10B-1 (stop bit).
  From cycle 10B the line is idle (high) until the next falling edge, which starts a new frame. Once asserted, `bad` stays asserted.

  Consequence: a start bit longer or shorter than B is always detected. The shift moves every later transition off the grid, and every frame contains at least one rising edge because the stop bit is high.
- `frame_done`, pulsed for one cycle when a complete, well-formed frame has been received, together with `frame_data[7:0]`.
- `timeout` (bounded liveness). Asserted if the line stays low for more than 10*B cycles, which a correct 8N1 transmitter can never produce.

## Tolerance and parameters

- Tolerance: 0 cycles by default. The emulator under test is expected to be cycle-exact, so any deviation is a failure.
- A `tolerance` parameter of plus or minus t cycles on bit-boundary timing may be added later for checking real external devices. That is out of scope for the slice.
- Reset/start condition: the monitor starts in the idle state, and the first falling edge it sees begins a frame. A line that is low when monitoring begins is treated as not yet idle. The monitor waits for the line to go high before it looks for a start bit.

## References

The 8N1 asynchronous serial format is the common convention used by UART peripherals: start bit, LSB-first data, and a stop bit at mark level. This document restates it as the monitor's specification. It is not quoted from any one standard.
