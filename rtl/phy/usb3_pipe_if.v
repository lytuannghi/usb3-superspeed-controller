// =============================================================================
// File: usb3_pipe_if.v
// Module: usb3_pipe_if
// Project: USB 3.0 SuperSpeed (5 Gbps) Controller ASIC
// Description: Intel PIPE 3.0 (PHY Interface for PCI Express and USB SuperSpeed)
//              32-bit parallel bus interface @ 125 MHz with LFPS transmission,
//              receiver detection, power management, and elastic buffer monitoring.
// =============================================================================

`timescale 1ns / 1ps

module usb3_pipe_if (
    input  wire        pipe_clk,
    input  wire        rst_n,

    // Internal Link Layer Transmit Interface
    input  wire [31:0] link_tx_data,
    input  wire [3:0]  link_tx_datak,
    input  wire        link_tx_elec_idle,

    // Internal Link Layer Receive Interface
    output reg  [31:0] link_rx_data,
    output reg  [3:0]  link_rx_datak,
    output reg         link_rx_valid,
    output reg         link_rx_elec_idle,
    output reg  [2:0]  link_rx_status,

    // LTSSM Control & Status Signals
    input  wire [1:0]  power_down,       // 00: P0 (U0), 01: P1 (U1), 10: P2 (U2), 11: P3 (U3/Reset)
    input  wire        tx_detect_rx_lb,  // Receiver detection request
    output reg         phy_status,       // PHY handshake completion strobe
    output reg         rx_detected,      // Receiver present indication

    // LFPS Signaling Interface
    input  wire        send_lfps,
    output reg         lfps_detected,

    // Physical PIPE 3.0 External Signals to High-Speed SerDes PMA
    output reg  [31:0] pipe_tx_data,
    output reg  [3:0]  pipe_tx_datak,
    output reg         pipe_tx_elec_idle,
    input  wire [31:0] pipe_rx_data_in,
    input  wire [3:0]  pipe_rx_datak_in,
    input  wire        pipe_rx_elec_idle_in,
    input  wire [2:0]  pipe_rx_status_in,
    input  wire        pipe_phy_status_in
);

    // LFPS generation counter (~50 MHz LFPS burst frequency)
    reg [3:0] lfps_timer;
    reg       lfps_pulse;

    always @(posedge pipe_clk or negedge rst_n) begin
        if (!rst_n) begin
            lfps_timer <= 4'd0;
            lfps_pulse <= 1'b0;
        end else begin
            if (send_lfps) begin
                lfps_timer <= lfps_timer + 4'd1;
                lfps_pulse <= (lfps_timer < 4'd8);
            end else begin
                lfps_timer <= 4'd0;
                lfps_pulse <= 1'b0;
            end
        end
    end

    // Receiver Detection Emulation & Pipeline Staging
    reg [2:0] rx_detect_cnt;
    always @(posedge pipe_clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_detect_cnt <= 3'd0;
            rx_detected   <= 1'b0;
            phy_status    <= 1'b0;
        end else begin
            phy_status <= pipe_phy_status_in;
            if (tx_detect_rx_lb && power_down == 2'b10) begin
                if (rx_detect_cnt == 3'd4) begin
                    rx_detected <= 1'b1;
                    phy_status  <= 1'b1;
                end else begin
                    rx_detect_cnt <= rx_detect_cnt + 3'd1;
                end
            end else begin
                rx_detect_cnt <= 3'd0;
            end
        end
    end

    // TX Staging
    always @(posedge pipe_clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_tx_data      <= 32'h00000000;
            pipe_tx_datak     <= 4'b0000;
            pipe_tx_elec_idle <= 1'b1;
        end else begin
            if (send_lfps) begin
                pipe_tx_elec_idle <= ~lfps_pulse;
                pipe_tx_data      <= 32'hAAAAAAAA;
                pipe_tx_datak     <= 4'b0000;
            end else begin
                pipe_tx_data      <= link_tx_data;
                pipe_tx_datak     <= link_tx_datak;
                pipe_tx_elec_idle <= link_tx_elec_idle;
            end
        end
    end

    // RX Staging & LFPS Detection Filter
    reg [3:0] lfps_rx_filter;
    always @(posedge pipe_clk or negedge rst_n) begin
        if (!rst_n) begin
            link_rx_data      <= 32'd0;
            link_rx_datak     <= 4'd0;
            link_rx_valid     <= 1'b0;
            link_rx_elec_idle <= 1'b1;
            link_rx_status    <= 3'd0;
            lfps_detected     <= 1'b0;
            lfps_rx_filter    <= 4'd0;
        end else begin
            link_rx_data      <= pipe_rx_data_in;
            link_rx_datak     <= pipe_rx_datak_in;
            link_rx_valid     <= ~pipe_rx_elec_idle_in;
            link_rx_elec_idle <= pipe_rx_elec_idle_in;
            link_rx_status    <= pipe_rx_status_in;

            // Simple LFPS activity detector when electrical idle is toggling
            if (!pipe_rx_elec_idle_in && (pipe_rx_data_in == 32'hAAAAAAAA || pipe_rx_data_in == 32'h55555555)) begin
                if (lfps_rx_filter == 4'd6)
                    lfps_detected <= 1'b1;
                else
                    lfps_rx_filter <= lfps_rx_filter + 4'd1;
            end else begin
                if (pipe_rx_elec_idle_in) begin
                    lfps_rx_filter <= 4'd0;
                    lfps_detected  <= 1'b0;
                end
            end
        end
    end

endmodule
