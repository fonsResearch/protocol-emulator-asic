# Mutation kill matrix

Source: formal/work/mut_v5 (campaign), 446 mutants, 0 missing results.
Codes: K killed (formal cex replayed in cyclesim), S survived (formal: proved), U undecided (timeout), E error.
A1 = S: mutant proven pin-equivalent to the partner model from reset; excluded from kill-rate denominators.

## target = rtl

mutants 216; proven pin-equivalent (A1 = S) 47; not proven equivalent 169

| oracle | K | S | U | E | kill rate (of not proven equivalent) |
|---|---|---|---|---|---|
| SIM | 133 | 83 | 0 | 0 | 133/169 |
| A1 | 134 | 47 | 35 | 0 | 134/169 |
| A2 | 55 | 161 | 0 | 0 | 55/169 |
| B1 | 38 | 177 | 1 | 0 | 38/169 |

Kill sets (mutants not proven equivalent): oracles that kill each mutant

| kill set | mutants |
|---|---|
| SIM+A1 | 82 |
| SIM+A1+A2+B1 | 22 |
| SIM+A1+A2 | 21 |
| none | 19 |
| A1 | 8 |
| A2+B1 | 7 |
| SIM+A2+B1 | 5 |
| B1 | 2 |
| SIM | 1 |
| SIM+A1+B1 | 1 |
| SIM+B1 | 1 |

killed by a spec-free oracle (A2 or B1): 59/169; killed only by spec-based oracles (SIM or A1): 91/169

Survivors (no oracle kills, not proven equivalent): 19

| index | op | desc | SIM | A1 | A2 | B1 |
|---|---|---|---|---|---|---|
| 49 | const_invert | const 0x0 w=12 | S | U | S | S |
| 58 | const_invert | const 0x0 w=1 | S | U | S | S |
| 82 | clear_drop | reg w=8 sr | S | U | S | S |
| 111 | const_invert | const 0x0 w=1 | S | U | S | S |
| 114 | const_invert | const 0x0 w=8 | S | U | S | S |
| 144 | op_swap | Signal_or w=1 | S | U | S | S |
| 166 | clear_drop | reg w=6 pc | S | U | S | S |
| 172 | const_invert | const 0x0 w=6 | S | U | S | S |
| 173 | off_by_one | const 0x0 w=6 | S | U | S | S |
| 183 | clear_drop | reg w=8 lc | S | U | S | S |
| 185 | const_invert | const 0x0 w=8 | S | U | S | S |
| 199 | const_invert | const 0x0 w=8 | S | U | S | S |
| 200 | off_by_one | const 0x0 w=8 | S | U | S | S |
| 206 | clear_drop | reg w=8 load_lo | S | U | S | S |
| 209 | op_swap | Signal_and w=1 | S | U | S | S |
| 210 | const_invert | const 0x0 w=8 | S | U | S | S |
| 211 | off_by_one | const 0x0 w=8 | S | U | S | S |
| 214 | const_invert | const 0x0 w=8 | S | U | S | S |
| 215 | off_by_one | const 0x0 w=8 | S | U | S | S |

Per operator (not proven equivalent / proven equivalent):

| op | not proven equiv | proven equiv |
|---|---|---|
| clear_drop | 11 | 5 |
| const_invert | 46 | 22 |
| mux_swap | 30 | 0 |
| off_by_one | 34 | 17 |
| op_swap | 48 | 3 |

## target = spec

mutants 230; proven pin-equivalent (A1 = S) 40; not proven equivalent 190

| oracle | K | S | U | E | kill rate (of not proven equivalent) |
|---|---|---|---|---|---|
| SIM | 153 | 77 | 0 | 0 | 153/190 |
| A1 | 158 | 40 | 32 | 0 | 158/190 |
| A2 | 79 | 151 | 0 | 0 | 79/190 |
| B1 | 48 | 181 | 1 | 0 | 48/190 |

Kill sets (mutants not proven equivalent): oracles that kill each mutant

| kill set | mutants |
|---|---|
| SIM+A1 | 87 |
| SIM+A1+A2 | 33 |
| SIM+A1+A2+B1 | 30 |
| none | 15 |
| A2+B1 | 14 |
| A1 | 7 |
| SIM+A2+B1 | 2 |
| SIM+A1+B1 | 1 |
| B1 | 1 |

killed by a spec-free oracle (A2 or B1): 81/190; killed only by spec-based oracles (SIM or A1): 94/190

Survivors (no oracle kills, not proven equivalent): 15

| index | op | desc | SIM | A1 | A2 | B1 |
|---|---|---|---|---|---|---|
| 46 | clear_drop | reg w=12 | S | U | S | S |
| 64 | off_by_one | const 0x0 w=12 | S | U | S | S |
| 67 | const_invert | const 0x0 w=12 | S | U | S | S |
| 168 | clear_drop | reg w=8 | S | U | S | S |
| 170 | const_invert | const 0x0 w=8 | S | U | S | S |
| 171 | off_by_one | const 0x0 w=8 | S | U | S | S |
| 176 | const_invert | const 0x0 w=8 | S | U | S | S |
| 177 | off_by_one | const 0x0 w=8 | S | U | S | S |
| 178 | clear_drop | reg w=6 | S | U | S | S |
| 201 | clear_drop | reg w=8 | S | U | S | S |
| 212 | const_invert | const 0x0 w=8 | S | U | S | S |
| 216 | const_invert | const 0x0 w=8 | S | U | S | S |
| 217 | off_by_one | const 0x0 w=8 | S | U | S | S |
| 228 | const_invert | const 0x0 w=6 | S | U | S | S |
| 229 | off_by_one | const 0x0 w=6 | S | U | S | S |

Per operator (not proven equivalent / proven equivalent):

| op | not proven equiv | proven equiv |
|---|---|---|
| clear_drop | 11 | 5 |
| const_invert | 47 | 22 |
| mux_swap | 65 | 0 |
| off_by_one | 31 | 13 |
| op_swap | 36 | 0 |

## Triage (2026-09-27)

Campaign: formal/work/mut_v5, flow commit ba4f4f1. Wall time 1393 s, 8 jobs, 120 s wall-clock
limit per oracle call. 0 error cells.

- **Oracle reach, not oracle power.** On RTL mutants, A1 covers every program, so in principle
  it subsumes A2 and B1. Each mutant killed by A2/B1 but not by A1 (9 RTL, 15 spec) has
  A1 = U (timeout). Behaviour that the spec-free oracles reach from frame 0 (program in ROM,
  RUN high) is hundreds of cycles deep for A1, which must first load a program through the
  pins. On spec mutants, A1 only shows that spec and RTL disagree. A2 and B1 show that the
  spec itself violates the protocol or its self-consistency: 81 of 190 spec mutants.
- **Unresolved class.** All 34 mutants that no oracle kills (19 RTL, 15 spec) are reset-value
  mutants: clear_drop on pc, lc, sr, load_lo (and the spec's wait_cnt and others), or
  const_invert / off_by_one on zero constants (register clear values). Hypothesis, not
  verified: they are equivalent, because the core is halted after reset and RUN needs 2
  synchroniser cycles, so halted-state logic re-initialises these registers before they are
  read.
- **Follow-up** (`resolve_undecided.sh`, A1 at 900 s, stopped after 14 of 34). rtl_82
  (clear_drop sr) and rtl_114 (const_invert) are now proven equivalent. The other 12 are
  TIMEOUT at 900 s. The remaining 20 are untested (resumable).
