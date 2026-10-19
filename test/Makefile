# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# defaults
SIM ?= icarus
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = tt_um_dean_protocol_emulator.v pemu_core_v1m.v
# IHP SRAM behavioural model (vendored, IHP-Open-PDK 2bbec755; see flow/pdk/pdk_manifest.md).
# The gate-level netlist keeps the three macros as black boxes, so both builds need it.
SRAM_MODELS = $(PWD)/../rtl/macros/RM_IHPSG13_1P_256x16_c2_bm_bist/RM_IHPSG13_1P_256x16_c2_bm_bist.v \
              $(PWD)/../rtl/macros/RM_IHPSG13_1P_256x16_c2_bm_bist/RM_IHPSG13_1P_core_behavioral_bm_bist.v

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD				= sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
VERILOG_SOURCES += $(SRAM_MODELS)
COMPILE_ARGS    += -DSIM -DFUNCTIONAL

else

# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DSIM
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/verilog/sg13cmos5l_io.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_stdcell.v
# Not in the template (b86a2a7): the stdcell models instantiate UDPs (ihp_dff_r, ihp_mux2, ...)
# that are defined only in sg13cmos5l_udp.v; without it Icarus cannot elaborate any flop or mux2.
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_udp.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v
VERILOG_SOURCES += $(SRAM_MODELS)

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)

# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
