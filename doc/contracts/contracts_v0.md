# Paper contracts v0

Status: DRAFT v0 (2026-10-17), for review. These contracts are written against `doc/contracts/language_v0.md` to test whether the language can express UART, SPI and I2C before any monitor RTL exists. They are not yet compiled or proved. Section 7 summarises what fits and what does not.

Notation:
- Λ = 2: synchroniser latency (`doc/interface.md` section 3).
- Codes are written relative to the watcher's base.
- `fail` = chip at fault; `blame` = environment at fault.
- Parameters in ns are converted per language section 6: strict for `fail`, lenient for `blame`.

## 0. Spike target: UART TX on the v0.1 core

Program: `doc/isa/isa_v0.md` section 6 (bit period D ≥ 3). TX = `uo_out[0]`; RUN = `ui_in[7]`.

v0.1 has no host data stream: data enters through `IN` from `uio_in`. This contract therefore covers framing and timing only, as the slice A2 did. Data correctness stays with deferred decision 3.

```
contract uart_tx_v01 clock 50_000_000
  out tx  = uo[0]
  in  run = ui[7]
  param D = 4 cycles

  watcher host_run base 0x80 {
    await run idle                 -- first running cycle c0 (running == s2(RUN), interface 3)
    await !run idle
    raise blame 1                  -- v0.1 drives 0 on halt (known v0 issue, decision 6), so any halt is blamed
  }

  watcher frame base 0x10 {
    await run idle                 -- anchor c0; OUT 0x01 executes in c0, tx high from c0+1
    hold tx for 1 else fail 1      -- idle high after prologue
    loop {
      await !tx idle               -- start bit: first low cycle a (unbounded idle allowed, WF4)
      hold !tx for D-1 else fail 2 -- start bit lasts exactly D cycles (exact form, Q2(b))
      repeat 8 {
        hold stable tx for D-1 else fail 3   -- each data bit constant for D cycles ...
        skip 1                               -- ... changes only on the D-grid
      }
      hold tx for D else fail 4    -- stop bit high for D cycles
    }
  }
end
```

Theorem to prove in the spike:
- **U:** for all `ui_in`, `uio_in` and `rst_n` sequences, `F -> B`.
- **N1:** under R_P = "RUN rises once and stays high", B never fires, and a new frame starts within 10D+5 cycles of the previous one. That is the slice's A2 bound, written as an extra `fail` watcher with a finite window.

What this exercises: the halt rule, the RUN synchroniser timing (the blame must fire no later than the first wrong tx cycle), and the free environment.

Caveat: the `repeat 8` block above checks bit constancy within each bit but not alignment of the first data bit. It is a first draft; the spike replaces it with the exact form from the UART monitor document (`doc/protocols/uart.md`) and checks both forms against each other.

## 1. UART TX (v1, with host stream)

Parameters:
- B: bit period in cycles;
- m: receiver sampling margin in cycles (tolerance form);
- L_start: policy, maximum cycles from a pending byte to its start bit.

```
contract uart_tx clock F
  io  tx = uio[k]                       -- idle by pull-up when oe = 0 (v1 pin model, decision 6)
  stream txq : host_write(0, 8)
  let line_tx = tx.oe && !tx.out        -- chip drives the line low

  watcher frame base 0x10 {             -- tolerance form, Q2(a): what a receiver samples
    reg d[8]
    loop {
      await rise line_tx idle           -- start bit begins
      take d <- txq else fail 1         -- no frame without a host byte
      skip B/2 - m
      hold line_tx for 2m+1 else fail 2              -- start bit seen low around its middle
      for i in 0..7 {
        skip B - 2m - 1
        hold (line_tx == !d[i]) for 2m+1 else fail 3 -- bit i around its middle, LSB first
      }
      skip B - 2m - 1
      hold !line_tx for 2m+1 else fail 4             -- stop bit
    }
  }

  watcher progress base 0x18 {
    loop {
      await txq.pending idle
      await rise line_tx within [1, L_start] else fail 1
      skip 10*B
    }
  }
end
```

There are no `blame` checks: UART TX has no peer input. A host that writes no bytes is not a violation.

## 2. UART RX (chip receives, reports bytes to the host)

```
contract uart_rx clock F
  in rx = uio[k]
  stream rxq : host_read(0, 8)
  param B, m, L_report (policy)

  watcher frame base 0x20 {
    reg d[8]
    loop {
      await fall rx idle
      hold !rx for B/2 + m else blame 1            -- start bit stable through mid + margin
      for i in 0..7 {
        skip B - 2m - 1
        hold stable rx for 2m else blame 2         -- peer: no edge near bit middle
        sample d[i] <- rx
      }
      skip B - 2m - 1
      hold rx for 2m+1 else blame 3                -- framing: stop bit high near its middle
      await rxq.push within [0, L_report] else fail 1
      match d == rxq.last else fail 2              -- chip reports exactly the sampled byte
    }
  }
end
```

Proof obligation hidden in this contract: the chip's own sampling instant must lie inside the [mid-m, mid+m] window that the `blame` checks keep stable. That is a property of program P, discharged by U.

## 3. SPI controller, mode (CPOL, CPHA)

SPI has no standard timing; parameters come from the target's datasheet:
- t_css: CS setup;
- t_csh: CS hold;
- t_su, t_h: MOSI setup and hold around the target's sampling edge;
- t_v: target MISO valid after shift edge;
- T_hi, T_lo: minimum SCK high and low.

`samp` and `shft` denote the sampling and shifting SCK edges for the mode:
- leading edge = `rise sck` if CPOL = 0, else `fall sck`;
- `samp` = leading if CPHA = 0, else trailing.

```
contract spi_ctrl clock F
  out sck = uo[a]   out mosi = uo[b]   out cs_n = uo[c]   in miso = uio[d]
  stream txq : host_write(0, 8)   stream rxq : host_read(0, 8)

  watcher idle_pol base 0x30 {          -- SCK idles at CPOL whenever CS is high
    loop { hold (!cs_n || sck == CPOL) for 1 else fail 1 }
  }
  watcher sck_low  base 0x31 { loop { await fall sck idle  hold !sck for T_lo-1 else fail 1 } }
  watcher sck_high base 0x32 { loop { await rise sck idle  hold  sck for T_hi-1 else fail 1 } }
  watcher mosi_su  base 0x33 { loop { await changed mosi idle  hold !samp for t_su else fail 1 } }
  watcher mosi_h   base 0x34 { loop { await samp idle  hold stable mosi for t_h else fail 1 } }

  watcher frame base 0x38 {
    reg d[8]  reg q[8]
    loop {
      await fall cs_n idle
      take d <- txq else fail 1
      hold !changed sck for t_css else fail 2
      for i in 0..7 {                                  -- MSB first
        await samp within [1, T_bit_max] else fail 3
        expect mosi == d[7-i] else fail 4
        skip Λ                                         -- align to the pad time of this edge
        sample q[7-i] <- miso
      }
      await rise cs_n within [t_csh, T_end_max] else fail 5
      await rxq.push within [0, L_report] else fail 6
      match q == rxq.last else fail 7
    }
  }

  watcher miso_valid base 0x3C {        -- target holds MISO stable around our sampling edge
    loop {
      await samp idle
      skip Λ - 1
      hold stable miso for 2 else blame 1   -- 1-cycle uncertainty on each side, widened per 6
    }
  }
end
```

Note: the `skip Λ` alignment is error-prone to write by hand. A compiler helper (`sample_at samp`) should generate it.

## 4. SPI target, mode (CPOL, CPHA)

Here the peer drives SCK. The chip's response latency, Λ+1 cycles from a pad edge to its own output change, turns into assumptions on the controller's speed.

```
contract spi_tgt clock F
  in sck = ui[a]   in mosi = ui[b]   in cs_n = ui[c]   io miso = uio[d]
  stream txq : host_write(0, 8)   stream rxq : host_read(0, 8)
  param T_half_min = <derived: Λ + 1 + t_su_peer + margin> cycles

  watcher bus_speed base 0x40 {          -- the peer must not clock faster than we can answer
    loop {
      await changed sck && !cs_n idle
      hold stable sck for T_half_min - 1 else blame 1
    }
  }
  watcher cs_setup base 0x41 { loop { await fall cs_n idle  hold stable sck for t_css_min else blame 1 } }
  watcher mosi_stab base 0x42 {          -- both are inputs: same latency, no Λ shift
    loop { await samp && !cs_n idle  hold stable mosi for t_h_min else blame 1 }
  }
  watcher miso_drive base 0x44 {         -- MISO driven only while selected (within Λ+1 cycles)
    loop { hold (miso.oe == !cs_n_delayed) for 1 else fail 1 }   -- cs_n_delayed: see section 7
  }
  watcher frame base 0x48 {
    reg d[8]  reg q[8]
    loop {
      await fall cs_n idle
      take d <- txq else fail 1          -- underrun policy: open (could also be a blame on the host)
      for i in 0..7 {
        await shft idle                  -- (CPHA = 0 drives bit 7 before the first edge; elided)
        mark e
        hold stable miso.out for T_half_min - 1 else fail 2   -- valid until the next sampling edge
        expect miso.out == d[7-i] else fail 3
        sample q[7-i] <- mosi
      }
      await rxq.push within [0, L_report] else fail 4
      match q == rxq.last else fail 5
    }
  }
end
```

## 5. I2C controller, write transaction (UM10204 Rev. 7, Standard and Fast mode)

UM10204 parameters (Sm / Fm):

| parameter | Sm | Fm |
|---|---|---|
| tLOW | ≥ 4.7 µs | ≥ 1.3 µs |
| tHIGH | ≥ 4.0 µs | ≥ 0.6 µs |
| tHD;STA, tSU;STO | ≥ 4.0 µs | ≥ 0.6 µs |
| tSU;STA | ≥ 4.7 µs | ≥ 0.6 µs |
| tBUF | ≥ 4.7 µs | ≥ 1.3 µs |
| tSU;DAT | ≥ 250 ns | ≥ 100 ns |
| tr | ≤ 1000 ns | ≤ 300 ns |
| tVD;DAT | ≤ 3.45 µs | ≤ 0.9 µs |

Policy parameter: T_stretch, the maximum clock stretch accepted from a target. The standard sets no bound.

```
contract i2c_ctrl_wr clock F
  od scl = uio[2]   od sda = uio[3]
  stream txq : host_write(0, 8)          -- first byte: address<<1 | 0; then data bytes
  stream ackq : host_read(0, 1)          -- one ACK bit per byte, reported to the host

  watcher scl_low  base 0x50 {           -- chip holds SCL low for at least tLOW
    loop { await rise scl.drive idle  hold scl.drive for tLOW - 1 else fail 1 }
  }
  watcher scl_high base 0x51 {           -- tHIGH counted from the observed line-high, not the release
    loop {
      await fall scl.drive idle
      await scl.line within [0, T_stretch] else blame 1      -- stretch bound (policy) + rise time
      mark h
      await rise scl.drive idle
      expect elapsed(h) >= tHIGH else fail 1                 -- strict, Λ-shifted per language 6
    }
  }
  watcher scl_held base 0x52 {           -- nobody else pulls SCL low during our high phase
    loop {
      await scl.line && !scl.drive idle
      hold scl.line until scl.drive idle else blame 1   -- single-controller assumption (Q4)
    }
  }
  watcher sda_setup base 0x53 {          -- data changes only while we hold SCL low, with setup
    loop {
      await changed sda.drive && scl.drive idle
      mark ch
      await fall scl.drive idle
      expect elapsed(ch) >= tSU_DAT else fail 1    -- plus tr when the change is a release (if-branch, elided)
    }
  }
  watcher sda_line base 0x54 {           -- when we pull SDA low, the line follows within Λ+1
    loop {
      await rise sda.drive idle
      skip Λ + 1
      hold !sda.line until fall sda.drive idle else blame 1  -- contention / pad fault
    }
  }

  watcher transaction base 0x58 {
    reg d[8]  reg a[1]
    mark stop                                         -- reset release treated as bus free (open: should be a blame-checked tBUF)
    loop {
      await rise sda.drive && !scl.drive idle         -- START: SDA pulled low while SCL released
      expect scl.line else fail 1                     -- line was observed high
      expect elapsed(stop) >= tBUF else fail 2        -- bus free time since our last STOP
      take d <- txq else fail 3
      hold !scl.drive for tHD_STA else fail 4
      loop {                                          -- bytes until STOP
        for i in 0..7 {
          await fall scl.drive idle                   -- release SCL: data must be on SDA
          expect sda.drive == !d[7-i] else fail 5     -- MSB first; 0 means pull low
          if !d[7-i] {
            hold sda.line until rise scl.drive idle else blame 2   -- we sent 1: nobody pulls SDA
          }
        }
        await fall scl.drive idle                     -- 9th clock: ACK slot
        expect !sda.drive else fail 6                 -- we release SDA for the ACK
        await scl.line within [0, T_stretch] else blame 3
        skip Λ
        sample a[0] <- !sda.line                      -- ACK = line low
        await ackq.push within [0, L_report] else fail 7
        match a == ackq.last else fail 8
        if txq.pending { take d <- txq else fail 3 } else {
          await fall sda.drive && !scl.drive idle     -- STOP: SDA released while SCL high
          mark stop
          -- tSU;STO check: elapsed since SCL line high >= tSU_STO (fail), elided for brevity
        }
      }
    }
  }
end
```

## 6. I2C target (sketch)

- **Guarantees on the chip:**
  - ACK pulled low in the 9th clock when addressed;
  - SDA changes only while SCL is low, valid within tVD;DAT of the observed SCL fall;
  - if the chip stretches, the stretch is bounded by its own policy;
  - no SDA drive when not addressed;
  - received bytes reported to the host exactly.
- **Assumptions on the controller:** tLOW, tHIGH, START/STOP set-up and hold, tSU;DAT, tBUF, all measured between observed inputs, so there is no Λ shift and the conversion is lenient.
- The chip's own Λ+1-cycle response must fit inside tLOW and tHIGH. At 50 MHz, Λ+1 = 3 cycles = 60 ns against tHIGH ≥ 600 ns (Fm) [arithmetic].

## 7. Expressiveness findings

| requirement | status | note |
|---|---|---|
| UART framing, exact or tolerance form | fits | |
| UART data correctness from a host stream | fits | `take` and `match` |
| UART RX sampling-window assumption | fits | |
| SPI setup and hold as forward invariants | fits | written as change-then-no-edge watchers, no lookback |
| SPI sampling aligned to pad time | fits, error-prone | needs a compiler helper (`sample_at`) |
| SPI target: MISO valid until the peer's next sampling edge | fits | `elapsed` against a mark |
| SPI target: "MISO driven only while selected" with latency | **gap** | needs a delayed observable (`x@k`, the value k cycles ago); proposed for v1 |
| I2C wired-AND: drive vs line, contention, ACK sampling | fits | |
| I2C tHIGH counted from the observed line-high (stretching) | fits | |
| I2C clock stretching, unbounded in the standard | fits as a policy `blame` | language section 7 |
| I2C arbitration (multi-controller) | **open** | Q4: blame or a guarded branch |
| I2C repeated START, read transactions | not written yet | expected to fit; adds branches |
| Phase-dependent assumptions (I2C ACK slot vs data 1) | fits | because roles attach to checks, not watchers |
| Concurrent invariants alongside a sequential frame watcher | fits | uses N_w; I2C controller needs 6 watchers |
| USB-LS: J/K/SE0 pairs, bit-stuffing count, EOP | expected to fit | pair predicates and counters; not written |
| 10BASE-T Manchester RX with recovered timing | fits with effort | windows relative to the last transition (`elapsed`); not written |
| `take` semantics: monitor-side cursor over host writes | **implementation open** | a monitor copy of the queue costs area; tapping the FIFO read port with sequence numbers is cheaper but must stay outside lane state |

The two gaps (delayed observable, arbitration) and the open `take` implementation are inputs to language v1 at plan step 4.
