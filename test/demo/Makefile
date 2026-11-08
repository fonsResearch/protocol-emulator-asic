# Virtual demo board (plan step 8). Same build as test/Makefile, scenario module test_demo.
#   make                      RTL (src/), all scenarios
#   make GATES=yes GL_NETLIST=<final/nl netlist>   gate-level
#   COCOTB_TEST_FILTER=<scenario> make ...          one scenario (run_demo.sh does this per FST)
SIM ?= icarus
FST ?= -fst
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../../src
PROJECT_SOURCES = tt_um_dean_protocol_emulator.v pemu_core_v1m.v
SRAM_MODELS = $(PWD)/../../rtl/macros/RM_IHPSG13_1P_256x16_c2_bm_bist/RM_IHPSG13_1P_256x16_c2_bm_bist.v \
              $(PWD)/../../rtl/macros/RM_IHPSG13_1P_256x16_c2_bm_bist/RM_IHPSG13_1P_core_behavioral_bm_bist.v
GL_NETLIST ?= $(PWD)/../gate_level_netlist.v

ifneq ($(GATES),yes)
SIM_BUILD        = sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
VERILOG_SOURCES += $(SRAM_MODELS)
COMPILE_ARGS    += -DSIM -DFUNCTIONAL
else
SIM_BUILD        = sim_build/gl
COMPILE_ARGS    += -DGL_TEST -DFUNCTIONAL -DSIM
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/verilog/sg13cmos5l_io.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_stdcell.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_udp.v
VERILOG_SOURCES += $(GL_NETLIST)
VERILOG_SOURCES += $(SRAM_MODELS)
endif

COMPILE_ARGS    += -I$(SRC_DIR)
VERILOG_SOURCES += $(PWD)/../tb.v
TOPLEVEL = tb
COCOTB_TEST_MODULES = test_demo
include $(shell cocotb-config --makefiles)/Makefile.sim
