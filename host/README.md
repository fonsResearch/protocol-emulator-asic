# pemu host package (RP2350, MicroPython)

Copy `host/pemu/` and `host/assets/` to the board's filesystem. Then:

```python
from machine import Pin
import pemu
port = pemu.BitBangPort(Pin(CS, Pin.OUT), Pin(SCK, Pin.OUT), Pin(MOSI, Pin.OUT), Pin(MISO, Pin.IN))
chip = pemu.Pemu(port)
chip.check_id()
lib = pemu.load("assets")
chip.setup_lane(0, lib.program("uart_tx_d4"), lib.package(0))
chip.tx_push(0, b"Hi\n")
chip.run(1)
chip.wait_us(2000)
print(chip.verdict())   # fail/blame, codes, stamps, host_valid
```

The pin numbers (CS, SCK, MOSI, MISO -> ui_in[0..2], uo_out[0]) depend on the demo board and are
not fixed here. API, the host-stream guard (`host_valid`) and verification: `doc/host.md`.
Rebuild `assets/` after a toolchain change: `python3 host/tools/build_assets.py` (`--check` to
compare).
