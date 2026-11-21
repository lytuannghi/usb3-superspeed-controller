// =============================================================================
// File: usb3_packet_engine.v
// Module: usb3_packet_engine
// Project: USB 3.0 SuperSpeed (5 Gbps) Controller ASIC
// Description: Protocol Packet Engine handling:
//              - Header Packets (HP): LMP, TP (ACK/NRDY/ERDY), DPH
//              - Data Packet Payload (DPP) framing
//              - Transmit packet formation and receive packet parsing
// =============================================================================

`timescale 1ns / 1ps

module usb3_packet_engine (
    input  wire        clk,
    input  wire        rst_n,

    // Link Status
    input  wire        link_ready, // U0 state active

    // Command Interface from DMA / Host System
    input  wire        tx_tp_req,
    input  wire [3:0]  tx_tp_subtype, // 4'h1: ACK, 4'h2: NRDY, 4'h3: ERDY
    input  wire [6:0]  tx_dev_addr,
    input  wire [3:0]  tx_ep_num,
    input  wire [4:0]  tx_seq_num,

    input  wire        tx_dph_req,
    input  wire [15:0] tx_data_len,

    // Data Streaming from DMA for DPP
    input  wire        tx_dpp_valid,
    input  wire [31:0] tx_dpp_data,
    input  wire        tx_dpp_last,
    output reg         tx_dpp_ready,

    // Transmit to Scrambler / Link Layer
    output reg  [31:0] tx_data,
    output reg  [3:0]  tx_datak,
    output reg         tx_valid,

    // Receive from Descrambler / Link Layer
    input  wire [31:0] rx_data,
    input  wire [3:0]  rx_datak,
    input  wire        rx_valid,

    // Decoded Receive Packet Indicators
    output reg         rx_tp_ack,
    output reg         rx_tp_nrdy,
    output reg  [3:0]  rx_ep_num,
    output reg  [4:0]  rx_seq_num,
    output reg         rx_dpp_valid,
    output reg  [31:0] rx_dpp_data,
    output reg         rx_dpp_last
);

    // K-Codes: SHP = K27.7 (0xFB), SDP = K28.2 (0x5C), END = K29.7 (0xFD), EPF = K23.7 (0xF7)
    localparam K_SHP = 8'hFB;
    localparam K_SDP = 8'h5C;
    localparam K_END = 8'hFD;
    localparam K_EPF = 8'hF7;

    // TX FSM
    localparam TX_IDLE      = 3'd0;
    localparam TX_SHP       = 3'd1;
    localparam TX_HEADER    = 3'd2;
    localparam TX_HEADER_CRC= 3'd3;
    localparam TX_DPP_START = 3'd4;
    localparam TX_DPP_DATA  = 3'd5;
    localparam TX_DPP_END   = 3'd6;

    reg [2:0] tx_state;
    reg [2:0] tx_word_cnt;

    // CRC engines for TX
    reg        crc16_init;
    reg        crc16_en;
    reg [31:0] crc16_in;
    wire [15:0] crc16_val;

    wire [4:0] crc5_val;
    reg [10:0] crc5_in;

    usb3_crc u_crc_engine (
        .clk           (clk),
        .rst_n         (rst_n),
        .crc5_init     (1'b0),
        .crc5_data_in  (crc5_in),
        .crc5_out      (crc5_val),
        .crc16_init    (crc16_init),
        .crc16_en      (crc16_en),
        .crc16_data_in (crc16_in),
        .crc16_out     (crc16_val)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state     <= TX_IDLE;
            tx_data      <= 32'd0;
            tx_datak     <= 4'd0;
            tx_valid     <= 1'b0;
            tx_dpp_ready <= 1'b0;
            tx_word_cnt  <= 3'd0;
            crc16_init   <= 1'b1;
            crc16_en     <= 1'b0;
            crc16_in     <= 32'd0;
            crc5_in      <= 11'd0;
        end else begin
            tx_valid     <= 1'b0;
            tx_dpp_ready <= 1'b0;
            crc16_init   <= 1'b0;
            crc16_en     <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    if (link_ready) begin
                        if (tx_tp_req) begin
                            // Start Header Packet (SHP)
                            tx_data     <= {K_SHP, K_SHP, K_SHP, 8'h00};
                            tx_datak    <= 4'b1110;
                            tx_valid    <= 1'b1;
                            tx_word_cnt <= 3'd0;
                            tx_state    <= TX_HEADER;
                        end else if (tx_dph_req) begin
                            tx_data     <= {K_SHP, K_SHP, K_SHP, 8'h00};
                            tx_datak    <= 4'b1110;
                            tx_valid    <= 1'b1;
                            tx_word_cnt <= 3'd0;
                            tx_state    <= TX_HEADER;
                        end else if (tx_dpp_valid) begin
                            // Start Data Packet Payload
                            tx_data     <= {K_SDP, K_SDP, 8'h00, 8'h00};
                            tx_datak    <= 4'b1100;
                            tx_valid    <= 1'b1;
                            crc16_init  <= 1'b1;
                            tx_state    <= TX_DPP_DATA;
                        end
                    end
                end

                TX_HEADER: begin
                    // Emit 12 bytes of Header DW0, DW1, DW2
                    tx_valid <= 1'b1;
                    tx_datak <= 4'b0000;
                    case (tx_word_cnt)
                        3'd0: tx_data <= {16'h0000, 1'b0, tx_dev_addr, tx_tp_subtype, 4'h4}; // TP Header DW0
                        3'd1: tx_data <= {16'h0000, 3'b000, tx_seq_num, tx_ep_num, 4'h0};   // DW1
                        default: begin
                            tx_data  <= 32'h00000000;                                        // DW2
                            tx_state <= TX_HEADER_CRC;
                        end
                    endcase
                    tx_word_cnt <= tx_word_cnt + 3'd1;
                end

                TX_HEADER_CRC: begin
                    // Emit Header CRC-16 and Link Control Word (LCW) with CRC-5
                    crc5_in     <= 11'h02A;
                    tx_valid    <= 1'b1;
                    tx_datak    <= 4'b0000;
                    tx_data     <= {crc16_val, 5'b0, crc5_val, 6'b000001};
                    tx_state    <= TX_IDLE;
                end

                TX_DPP_DATA: begin
                    tx_dpp_ready <= 1'b1;
                    if (tx_dpp_valid) begin
                        tx_valid   <= 1'b1;
                        tx_data    <= tx_dpp_data;
                        tx_datak   <= 4'b0000;
                        crc16_en   <= 1'b1;
                        crc16_in   <= tx_dpp_data;
                        if (tx_dpp_last) begin
                            tx_state <= TX_DPP_END;
                        end
                    end
                end

                TX_DPP_END: begin
                    // Send CRC-16 and End Framing (END, EPF)
                    tx_valid <= 1'b1;
                    tx_data  <= {K_EPF, K_END, crc16_val};
                    tx_datak <= 4'b1100;
                    tx_state <= TX_IDLE;
                end
            endcase
        end
    end

    // RX Packet Parsing
    reg [1:0] rx_state;
    reg [1:0] rx_word_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state     <= 2'd0;
            rx_word_cnt  <= 2'd0;
            rx_tp_ack    <= 1'b0;
            rx_tp_nrdy   <= 1'b0;
            rx_ep_num    <= 4'd0;
            rx_seq_num   <= 5'd0;
            rx_dpp_valid <= 1'b0;
            rx_dpp_data  <= 32'd0;
            rx_dpp_last  <= 1'b0;
        end else begin
            rx_tp_ack    <= 1'b0;
            rx_tp_nrdy   <= 1'b0;
            rx_dpp_valid <= 1'b0;
            rx_dpp_last  <= 1'b0;

            if (rx_valid) begin
                case (rx_state)
                    2'd0: begin // Idle: Look for SHP or SDP framing
                        if (rx_datak[3:1] == 3'b111 && rx_data[31:8] == {K_SHP, K_SHP, K_SHP}) begin
                            rx_state    <= 2'd1; // Header Packet
                            rx_word_cnt <= 2'd0;
                        end else if (rx_datak[3:2] == 2'b11 && rx_data[31:16] == {K_SDP, K_SDP}) begin
                            rx_state    <= 2'd2; // DPP Data streaming
                        end
                    end

                    2'd1: begin // Parse Header Packet DWs
                        if (rx_word_cnt == 2'd0) begin
                            if (rx_data[7:4] == 4'h1) rx_tp_ack  <= 1'b1;
                            if (rx_data[7:4] == 4'h2) rx_tp_nrdy <= 1'b1;
                        end else if (rx_word_cnt == 2'd1) begin
                            rx_ep_num  <= rx_data[7:4];
                            rx_seq_num <= rx_data[12:8];
                        end else if (rx_word_cnt == 2'd2) begin
                            rx_state <= 2'd0;
                        end
                        rx_word_cnt <= rx_word_cnt + 2'd1;
                    end

                    2'd2: begin // Streaming DPP data
                        if (rx_datak[3:2] == 2'b11 && rx_data[31:16] == {K_EPF, K_END}) begin
                            rx_dpp_last <= 1'b1;
                            rx_state    <= 2'd0;
                        end else begin
                            rx_dpp_valid <= 1'b1;
                            rx_dpp_data  <= rx_data;
                        end
                    end
                endcase
            end
        end
    end

endmodule
