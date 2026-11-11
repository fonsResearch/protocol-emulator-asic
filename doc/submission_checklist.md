# Submission checklist (plan step 12)

Deadline 2027-01-18; target for a complete submission: 2027-01-11 (one week of buffer). Rules
checked 2026-11-11 against the competition page (blog.janestreet.com/protocol-emulator-asic-competition):
the final submission form is not published yet; re-check the page and the organisers' emails before
submitting.

| # | requirement (source: competition page) | artifact | status | owner |
|---|---|---|---|---|
| 1 | IHP CMOS5L via Tiny Tapeout, from the TT IHP Verilog template; max 6x4 tiles | `info.yaml` tiles 6x4, top `tt_um_dean_protocol_emulator`, 30 MHz | done | - |
| 2 | sign-off: a clean run through the TT flow and precheck | CI run 42426292730 on d9d97d2: gds, precheck, gl_test pass (the viewer/docs jobs fail on every branch, a Pages setting) | done for the design commit; **re-run the gds workflow on the final submission commit** (flow inputs unchanged, so the same netlist is expected) | user (pushes, re-runs CI) |
| 3 | open source | repo public; MIT licence, TT template files keep Apache-2.0 | done | - |
| 4 | documentation of architecture and instruction set | `doc/architecture_v2.md`, `doc/isa/isa_v1.md`, `doc/interface_v1.md`, `doc/contracts/*.md`, datasheet `docs/info.md` | done | - |
| 5 | assembler or toolchain with example programs | `toolchain/` (pemu_asm, pemu_cc), `toolchain/examples/*.s`, `flex_v2/firmware/onewire_ctl.s`, `doc/toolchain.md` | done | - |
| 6 | write-up of the verification approach (weighed heavily, readability) | `doc/verification.md`, linked first from `README.md` | draft; review by the user | user review |
| 7 | describe the use of AI tools in the write-up | `doc/verification.md` section 12 | **open**: user decision 2026-11-11, written at submission time | user |
| 8 | submission form | not yet published | **open** | user |
| 9 | citations: papers and official PDK / Tiny Tapeout documentation only (project rule) | scan of all tracked files | clean after removing one notes file (2026-11-11) | done |
| 10 | identity rule: no real name in files | author fields "dean"; commit identity deanblunting | done for files written by the agent; not machine-checkable without the name | user check |
| 11 | reproduction of all results on the frozen tree | `tools/reproduce.sh all` (section 13 of the write-up) | 2026-11-11 (log/freeze_v2.md): freeze identity OK; quick 8/8 and sim 21/21 PASS; R1 6 + 2 negatives and an A2 sample (UART RX/TX, 7 harnesses) as expected; the rest is cited from the logs (user decision); witness tier not run | done (partial by decision) |
| 12 | local commits pushed | v2-inc5-usb steps 9-12 | pushed 2026-11-11 (user approval) | done |

Before submitting (by 2027-01-11):
1. Push the final commits and re-run the gds workflow on the submission commit. Confirm gds,
   precheck and gl_test pass and that the final netlist hash equals the signed-off one
   (b450fe7c...abb0), or record why it differs.
2. Run `tools/reproduce.sh quick` and `sim` on the submission commit.
3. Fill the AI-use section and fill in the form.
