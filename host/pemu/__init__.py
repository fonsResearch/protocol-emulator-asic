"""pemu: RP2350 MicroPython host package for the protocol emulator (doc/host.md).

    from machine import Pin
    import pemu
    port = pemu.BitBangPort(Pin(CS, Pin.OUT), Pin(SCK, Pin.OUT), Pin(MOSI, Pin.OUT), Pin(MISO, Pin.IN))
    chip = pemu.Pemu(port)
    chip.check_id()
    lib = pemu.load("assets")            # assets/library.json and assets/programs/*.json
    chip.setup_lane(0, lib.program("uart_tx_d4"), lib.package(0))
    chip.tx_push(0, b"Hi")
    chip.run(1)
    chip.wait_us(2000)
    print(chip.verdict())

Runs unchanged under CPython (tests drive it against the virtual demo board through a simulator
port, test/demo/test_host_pkg.py).
"""

import json

from .device import Pemu, PemuError  # noqa: F401
from .port import BitBangPort  # noqa: F401


class Library:
    """Toolchain outputs on the host filesystem: library.json (`pemu_cc json`), programs/<name>.json
    (`pemu_asm asm -f json`), windows/<name>.json (`pemu_cc retune`, as {"rom": i, "windows": [...]})."""

    def __init__(self, root):
        self.root = root
        with open(root + "/library.json") as f:
            self.lib = json.load(f)

    def package(self, key):
        for p in self.lib["packages"]:
            if p["index"] == key or p["name"] == key:
                return p
        raise PemuError("no ROM package %r" % (key,))

    def program(self, name):
        with open(self.root + "/programs/" + name + ".json") as f:
            return json.load(f)

    def windows(self, name):
        with open(self.root + "/windows/" + name + ".json") as f:
            return json.load(f)


def load(root):
    return Library(root)
