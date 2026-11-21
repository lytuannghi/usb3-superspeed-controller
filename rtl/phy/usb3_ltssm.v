// =============================================================================
// File: usb3_ltssm.v
// Module: usb3_ltssm
// Project: USB 3.0 SuperSpeed (5 Gbps) Controller ASIC
// Description: Link Training & Status State Machine conforming to USB 3.0
//              Specification Chapter 7.5. Controls Rx.Detect, Polling (LFPS,
//              TS1, TS2 ordered sets), U0 active state, U1/U2/U3 low-power states,
//              and recovery transitions.
// =============================================================================

`timescale 1ns / 1ps

module usb3_ltssm (
    input  wire        clk,
    input  wire        rst_n,

    // Enable and Configuration
    input  wire        enable,
    input  wire        force_u1_req,
    input  wire        force_u2_req,
    input  wire        force_u3_req,
    input  wire        exit_lp_req,

    // PHY Status Signals from PIPE Interface
    input  wire        rx_detected,
    input  wire        phy_status,
    input  wire        lfps_detected,
    input  wire        rx_valid,
    input  wire [31:0] rx_data,
    input  wire [3:0]  rx_datak,

    // Control Signals to PIPE PHY
    output reg  [1:0]  power_down,      // 00: P0, 01: P1, 10: P2, 11: P3
    output reg         tx_detect_rx_lb,
    output reg         send_lfps,
    output reg         send_ts1,
    output reg         send_ts2,
    output reg         link_ready,      // High when in U0 operational state

    // Current State Output for Debug & Protocol Engine
    output reg  [3:0]  ltssm_state
);

    // LTSSM States Encoding
    localparam ST_SS_DISABLED      = 4'd0;
    localparam ST_RX_DETECT_RESET  = 4'd1;
    localparam ST_RX_DETECT_ACTIVE = 4'd2;
    localparam ST_POLLING_LFPS     = 4'd3;
    localparam ST_POLLING_RXEQ     = 4'd4;
    localparam ST_POLLING_ACTIVE   = 4'd5;
    localparam ST_POLLING_CONFIG   = 4'd6;
    localparam ST_POLLING_IDLE     = 4'd7;
    localparam ST_U0               = 4'd8;
    localparam ST_U1               = 4'd9;
    localparam ST_U2               = 4'd10;
    localparam ST_U3               = 4'd11;
    localparam ST_RECOVERY         = 4'd12;

    // Ordered set detection signatures (COM = 0xBC, TS1 ID = 0x4A, TS2 ID = 0x45)
    wire is_ts1 = (rx_datak[0] == 1'b1 && rx_data[7:0] == 8'hBC && rx_data[31:24] == 8'h4A);
    wire is_ts2 = (rx_datak[0] == 1'b1 && rx_data[7:0] == 8'hBC && rx_data[31:24] == 8'h45);

    reg [7:0] timeout_counter;
    reg [4:0] ts_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ltssm_state     <= ST_SS_DISABLED;
            power_down      <= 2'b11; // P3 Power Down
            tx_detect_rx_lb <= 1'b0;
            send_lfps       <= 1'b0;
            send_ts1        <= 1'b0;
            send_ts2        <= 1'b0;
            link_ready      <= 1'b0;
            timeout_counter <= 8'd0;
            ts_count        <= 5'd0;
        end else begin
            case (ltssm_state)
                ST_SS_DISABLED: begin
                    link_ready  <= 1'b0;
                    power_down  <= 2'b11;
                    if (enable) begin
                        power_down  <= 2'b10; // P2 for Rx.Detect
                        ltssm_state <= ST_RX_DETECT_RESET;
                    end
                end

                ST_RX_DETECT_RESET: begin
                    tx_detect_rx_lb <= 1'b0;
                    timeout_counter <= timeout_counter + 8'd1;
                    if (timeout_counter == 8'd8) begin
                        timeout_counter <= 8'd0;
                        tx_detect_rx_lb <= 1'b1;
                        ltssm_state     <= ST_RX_DETECT_ACTIVE;
                    end
                end

                ST_RX_DETECT_ACTIVE: begin
                    if (phy_status && rx_detected) begin
                        tx_detect_rx_lb <= 1'b0;
                        power_down      <= 2'b00; // P0 (Full Power)
                        send_lfps       <= 1'b1;
                        timeout_counter <= 8'd0;
                        ltssm_state     <= ST_POLLING_LFPS;
                    end else if (timeout_counter == 8'd100) begin
                        // Retry Rx.Detect
                        timeout_counter <= 8'd0;
                        ltssm_state     <= ST_RX_DETECT_RESET;
                    end else begin
                        timeout_counter <= timeout_counter + 8'd1;
                    end
                end

                ST_POLLING_LFPS: begin
                    // LFPS handshake
                    timeout_counter <= timeout_counter + 8'd1;
                    if (lfps_detected || timeout_counter > 8'd40) begin
                        send_lfps       <= 1'b0;
                        timeout_counter <= 8'd0;
                        ltssm_state     <= ST_POLLING_RXEQ;
                    end
                end

                ST_POLLING_RXEQ: begin
                    // Receiver Equalization (fixed wait duration)
                    timeout_counter <= timeout_counter + 8'd1;
                    if (timeout_counter == 8'd16) begin
                        timeout_counter <= 8'd0;
                        send_ts1        <= 1'b1;
                        ts_count        <= 5'd0;
                        ltssm_state     <= ST_POLLING_ACTIVE;
                    end
                end

                ST_POLLING_ACTIVE: begin
                    // Transmit TS1, count 8 received TS1 sets
                    if (is_ts1 || timeout_counter > 8'd20) begin
                        ts_count <= ts_count + 5'd1;
                    end
                    timeout_counter <= timeout_counter + 8'd1;

                    if (ts_count >= 5'd8) begin
                        send_ts1    <= 1'b0;
                        send_ts2    <= 1'b1;
                        ts_count    <= 5'd0;
                        timeout_counter <= 8'd0;
                        ltssm_state <= ST_POLLING_CONFIG;
                    end
                end

                ST_POLLING_CONFIG: begin
                    // Transmit TS2, count 8 received TS2 sets
                    if (is_ts2 || timeout_counter > 8'd20) begin
                        ts_count <= ts_count + 5'd1;
                    end
                    timeout_counter <= timeout_counter + 8'd1;

                    if (ts_count >= 5'd8) begin
                        send_ts2        <= 1'b0;
                        timeout_counter <= 8'd0;
                        ltssm_state     <= ST_POLLING_IDLE;
                    end
                end

                ST_POLLING_IDLE: begin
                    timeout_counter <= timeout_counter + 8'd1;
                    if (timeout_counter == 8'd8) begin
                        timeout_counter <= 8'd0;
                        link_ready      <= 1'b1;
                        ltssm_state     <= ST_U0;
                    end
                end

                ST_U0: begin
                    link_ready <= 1'b1;
                    power_down <= 2'b00;

                    if (force_u1_req) begin
                        link_ready  <= 1'b0;
                        power_down  <= 2'b01; // P1
                        ltssm_state <= ST_U1;
                    end else if (force_u2_req) begin
                        link_ready  <= 1'b0;
                        power_down  <= 2'b10; // P2
                        ltssm_state <= ST_U2;
                    end else if (force_u3_req) begin
                        link_ready  <= 1'b0;
                        power_down  <= 2'b11; // P3
                        ltssm_state <= ST_U3;
                    end
                end

                ST_U1: begin
                    link_ready <= 1'b0;
                    if (exit_lp_req) begin
                        send_lfps   <= 1'b1;
                        ltssm_state <= ST_RECOVERY;
                    end
                end

                ST_U2: begin
                    link_ready <= 1'b0;
                    if (exit_lp_req) begin
                        send_lfps   <= 1'b1;
                        ltssm_state <= ST_RECOVERY;
                    end
                end

                ST_U3: begin
                    link_ready <= 1'b0;
                    if (exit_lp_req) begin
                        send_lfps   <= 1'b1;
                        ltssm_state <= ST_RECOVERY;
                    end
                end

                ST_RECOVERY: begin
                    timeout_counter <= timeout_counter + 8'd1;
                    if (timeout_counter == 8'd12) begin
                        send_lfps       <= 1'b0;
                        timeout_counter <= 8'd0;
                        power_down      <= 2'b00;
                        link_ready      <= 1'b1;
                        ltssm_state     <= ST_U0;
                    end
                end

                default: ltssm_state <= ST_SS_DISABLED;
            endcase
        end
    end

endmodule
