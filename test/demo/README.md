# Virtual demo board

The chip (RTL in `src/`, or the final gate-level netlist) on a simulated board: host API over the
SPI host port, independent device models on the uio pins, and fault-injection scenarios. Results
and their interpretation are in `log/demo_v2.md`.

| file | role |
|---|---|
| `pemu_host.py` | board loop (pad resolution, wired-AND I2C, pull-ups) and the host API `Pemu` |
| `peers.py` | UART, SPI, I2C and USB-LS device models, written from `doc/protocols/` |
| `assets.json` | firmware images and ROM package table, from `rtl_v1/bin/export_demo_assets.exe` |
| `test_demo.py` | the 17 scenarios |
| `run_demo.sh` | one simulator run per scenario: `results/<mode>/<scenario>.{json,log,vcd.gz}` |
| `compare_runs.py`, `check_vcd.py` | RTL vs GL: records, and settled pin values at every clock edge |

```
export PDK_ROOT=<repo>/.toolchain/pdk          # gate level only
./run_demo.sh rtl                               # about 70 s
GL_NETLIST=<runs/wokwi/final/nl/*.nl.v> ./run_demo.sh gl   # about 5.5 min
python3 compare_runs.py results/rtl results/gl
python3 check_vcd.py --compare results/rtl results/gl
./run_demo.sh rtl usb_ls_tx                     # a single scenario
```

Regenerate `assets.json` after a library or firmware change:
`dune build && ./_build/default/rtl_v1/bin/export_demo_assets.exe test/demo/assets.json`.
