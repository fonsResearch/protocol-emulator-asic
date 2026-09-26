# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
#
# Placeholder test for the wrapper-only skeleton: with no core instantiated,
# every output and output-enable must be 0 during and after reset. This is
# replaced by trace replay (S2) once the core exists.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_wrapper_outputs_idle(dut):
    clock = Clock(dut.clk, 20, unit="ns")  # 50 MHz, matches template CLOCK_PERIOD
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    assert dut.uo_out.value == 0
    assert dut.uio_oe.value == 0

    dut.rst_n.value = 1
    for pattern in (0x00, 0xFF, 0xA5, 0x5A):
        dut.ui_in.value = pattern
        dut.uio_in.value = pattern ^ 0xFF
        await ClockCycles(dut.clk, 3)
        assert dut.uo_out.value == 0
        assert dut.uio_out.value == 0
        assert dut.uio_oe.value == 0
