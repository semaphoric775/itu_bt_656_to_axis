SIM           = verilator
TOPLEVEL_LANG = verilog

WAVES ?= 1
EXTRA_ARGS += --trace --trace-fst --trace-structs

COMMON_SOURCES  = $(abspath ../src/itu_bt_656_if.sv)
COMMON_SOURCES += $(abspath ../src/taxi_axis_if.sv)
COMMON_SOURCES += $(abspath ../src/itu_bt_656_to_axis.sv)

COMPILE_ARGS += --sv --timing

# Select testbench with TB=main (default) or TB=anc
TB ?= anc

ifeq ($(TB),anc)
  TOPLEVEL        = tb_itu_bt_656_to_axis_anc
  MODULE          = test_itu_bt_656_to_axis_anc
  SIM_BUILD       = sim_build_anc
  VERILOG_SOURCES = $(COMMON_SOURCES) $(abspath tb_itu_bt_656_to_axis_anc.sv)
else
  TOPLEVEL        = tb_itu_bt_656_to_axis
  MODULE          = test_itu_bt_656_to_axis
  SIM_BUILD       = sim_build_main
  VERILOG_SOURCES = $(COMMON_SOURCES) $(abspath tb_itu_bt_656_to_axis.sv)
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
