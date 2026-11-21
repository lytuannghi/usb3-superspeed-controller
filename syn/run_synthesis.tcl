# =============================================================================
# Synthesis Script: run_synthesis.tcl
# Tool: Synopsys Design Compiler / Cadence Genus
# =============================================================================

set TOP_MODULE usb3_controller_top

set RTL_FILES [list \
    ../rtl/phy/usb3_pipe_if.v \
    ../rtl/phy/usb3_ltssm.v \
    ../rtl/link/usb3_scrambler.v \
    ../rtl/link/usb3_crc.v \
    ../rtl/proto/usb3_packet_engine.v \
    ../rtl/dma/usb3_dma_engine.v \
    ../rtl/usb3_controller_top.v \
]

read_verilog $RTL_FILES
current_design $TOP_MODULE
link

source usb3_timing.sdc

compile_ultra -gate_clock -no_autoungroup

report_timing -delay max -max_paths 10 > reports/timing_report.txt
report_area -hierarchy > reports/area_report.txt
report_power > reports/power_report.txt

write -format verilog -hierarchy -output netlist/${TOP_MODULE}_syn.v
