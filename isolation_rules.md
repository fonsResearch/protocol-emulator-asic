# Agent-independence protocol (process layer E)

The reference semantics (S1), the RTL, and the protocol monitors (S3) are cross-checked against each other. The checks only mean something if these artifacts are written independently. Each is produced by a separate agent context, from a different source document. Every disagreement between them is logged and triaged.

## Contexts and permissions

| Context | May read | May write | Must not read |
|---|---|---|---|
| Doc (human-approved) | anything | `doc/` | — |
| Spec (S1) | `doc/isa/`, `doc/interface.md` | `spec/` | `rtl/`, `src/` generated core, `monitors/`, `formal/` |
| RTL | `doc/isa/`, `doc/interface.md` | `rtl/`, generated Verilog in `src/` | `spec/`, `monitors/`, `formal/` |
| Monitor (S3) | `doc/protocols/`, `trace/` interface | `monitors/` | `doc/isa/`, `spec/`, `rtl/` |
| Trace (S2) | `doc/interface.md` | `trace/` | `spec/`, `rtl/`, `monitors/` internals |
| Integrator (formal, mutation, flow) | everything, through library interfaces | `formal/`, `mutation/`, `flow/`, `log/` | — (writes nothing in `spec/`, `rtl/`, `monitors/`) |

`doc/interface.md` is the only shared contract between spec and RTL. It defines the pin interface and the instruction-memory load port.

## Fix routing

When the integrator finds a mismatch, it records it in `log/disagreements.md` before anyone fixes anything. Each entry has an ID, the date, the failing check, and the counterexample trace in S2 format.

The fix goes back to the owning context. That context receives only the counterexample trace and the relevant section of `doc/`, never the other artifact's code.

Each entry is triaged as exactly one of:
- `spec-bug`
- `rtl-bug`
- `monitor-bug`
- `doc-ambiguity`, which is fixed in `doc/` and requires user approval.

## Enforcement and its limits

- **Enforced by:** separate agent sessions with briefs that list the allowed paths.
- **Not enforced:** the filesystem does not block reads. Independence is procedural and cannot be proven cryptographically.
- **Also recorded:** the commit history of each directory, so authorship per context is auditable.
- **What is measured:** mutation cross-kill (spec mutants against RTL checks and the reverse), plus the triage counts in `log/disagreements.md`.
- **Known limitation:** every context uses the same model family, so correlated errors are expected to be higher than between independent human teams. The measurement is there to quantify that correlation, not to assume independence.
