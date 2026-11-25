###############################################################################
# File: usb3_timing.sdc
# Module: usb3_controller_top
# Target Frequency: 250.0 MHz (4.000 ns Period)
# Technology: SkyWater 130nm HD Standard Cell Library (typical 1.80V, 25C)
###############################################################################

# Primary Core Clock Definition
create_clock -name clk -period 4.000 -waveform {0.000 2.000} [get_ports clk]

# Clock Uncertainty & Jitter
set_clock_uncertainty -setup 0.120 [get_clocks clk]
set_clock_uncertainty -hold  0.040 [get_clocks clk]
set_clock_transition 0.060 [get_clocks clk]

# Input Delays (PIPE Interface & Host Controls)
set_input_delay -clock clk -max 1.200 [get_ports {enable force_* exit_* tx_* dma_* m_axi_*ready m_axi_r* pipe_rx_*}]
set_input_delay -clock clk -min 0.200 [get_ports {enable force_* exit_* tx_* dma_* m_axi_*ready m_axi_r* pipe_rx_*}]

# Output Delays (PIPE Interface & AXI4 Master)
set_output_delay -clock clk -max 1.200 [get_ports {ltssm_* link_* rx_* dma_* m_axi_aw* m_axi_w* m_axi_ar* pipe_tx_*}]
set_output_delay -clock clk -min 0.150 [get_ports {ltssm_* link_* rx_* dma_* m_axi_aw* m_axi_w* m_axi_ar* pipe_tx_*}]

# Environmental Constraints & Driving Cells
set_driving_cell -lib_cell INVX4 [get_ports {enable force_* exit_* tx_* dma_* pipe_rx_*}]
set_load -pin_load 0.020 [get_ports {pipe_tx_* m_axi_*}]
