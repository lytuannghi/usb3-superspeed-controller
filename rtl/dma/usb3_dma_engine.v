// =============================================================================
// File: usb3_dma_engine.v
// Module: usb3_dma_engine
// Project: USB 3.0 SuperSpeed (5 Gbps) Controller ASIC
// Description: Scatter-Gather AXI4 Master DMA Engine for USB 3.0 SuperSpeed
//              bulk data endpoints. Supports burst reads (Bulk IN) and burst
//              writes (Bulk OUT) with 32-bit streaming packet interfaces.
// =============================================================================

`timescale 1ns / 1ps

module usb3_dma_engine (
    input  wire        clk,
    input  wire        rst_n,

    // Software Control & Status
    input  wire        dma_start,
    input  wire        dma_dir,          // 0: OUT (USB -> Memory), 1: IN (Memory -> USB)
    input  wire [31:0] dma_addr,
    input  wire [15:0] dma_len,          // Length in bytes
    output reg         dma_busy,
    output reg         dma_done,

    // USB Packet Interface (IN Path: Memory -> USB)
    output reg         tx_dpp_valid,
    output reg  [31:0] tx_dpp_data,
    output reg         tx_dpp_last,
    input  wire        tx_dpp_ready,

    // USB Packet Interface (OUT Path: USB -> Memory)
    input  wire        rx_dpp_valid,
    input  wire [31:0] rx_dpp_data,
    input  wire        rx_dpp_last,

    // AXI4 Master Interface
    // Write Address Channel
    output reg  [31:0] m_axi_awaddr,
    output reg  [7:0]  m_axi_awlen,
    output reg  [2:0]  m_axi_awsize,
    output reg  [1:0]  m_axi_awburst,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,

    // Write Data Channel
    output reg  [31:0] m_axi_wdata,
    output reg  [3:0]  m_axi_wstrb,
    output reg         m_axi_wlast,
    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,

    // Write Response Channel
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output reg         m_axi_bready,

    // Read Address Channel
    output reg  [31:0] m_axi_araddr,
    output reg  [7:0]  m_axi_arlen,
    output reg  [2:0]  m_axi_arsize,
    output reg  [1:0]  m_axi_arburst,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,

    // Read Data Channel
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output reg         m_axi_rready
);

    localparam DMA_IDLE      = 3'd0;
    localparam DMA_AR_START  = 3'd1;
    localparam DMA_R_BURST   = 3'd2;
    localparam DMA_AW_START  = 3'd3;
    localparam DMA_W_BURST   = 3'd4;
    localparam DMA_B_WAIT    = 3'd5;
    localparam DMA_FINISH    = 3'd6;

    reg [2:0] state;
    reg [15:0] bytes_transferred;
    reg [15:0] target_len;
    reg [31:0] cur_addr;

    // FIFO for OUT packets (USB -> Memory)
    reg [31:0] out_fifo [0:15];
    reg [3:0]  fifo_wr_ptr;
    reg [3:0]  fifo_rd_ptr;
    reg [4:0]  fifo_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= DMA_IDLE;
            dma_busy          <= 1'b0;
            dma_done          <= 1'b0;
            bytes_transferred <= 16'd0;
            target_len        <= 16'd0;
            cur_addr          <= 32'd0;

            tx_dpp_valid      <= 1'b0;
            tx_dpp_data       <= 32'd0;
            tx_dpp_last       <= 1'b0;

            m_axi_awaddr      <= 32'd0;
            m_axi_awlen       <= 8'd0;
            m_axi_awsize      <= 3'b010; // 4 bytes (32-bit)
            m_axi_awburst     <= 2'b01;  // INCR
            m_axi_awvalid     <= 1'b0;

            m_axi_wdata       <= 32'd0;
            m_axi_wstrb       <= 4'b1111;
            m_axi_wlast       <= 1'b0;
            m_axi_wvalid      <= 1'b0;
            m_axi_bready      <= 1'b0;

            m_axi_araddr      <= 32'd0;
            m_axi_arlen       <= 8'd0;
            m_axi_arsize      <= 3'b010; // 4 bytes
            m_axi_arburst     <= 2'b01;  // INCR
            m_axi_arvalid     <= 1'b0;
            m_axi_rready      <= 1'b0;

            fifo_wr_ptr       <= 4'd0;
            fifo_rd_ptr       <= 4'd0;
            fifo_count        <= 5'd0;
        end else begin
            dma_done <= 1'b0;

            // FIFO writes on USB RX data
            if (rx_dpp_valid && fifo_count < 5'd16) begin
                out_fifo[fifo_wr_ptr] <= rx_dpp_data;
                fifo_wr_ptr <= fifo_wr_ptr + 4'd1;
                fifo_count  <= fifo_count + 5'd1;
            end

            case (state)
                DMA_IDLE: begin
                    dma_busy <= 1'b0;
                    if (dma_start) begin
                        dma_busy          <= 1'b1;
                        target_len        <= dma_len;
                        cur_addr          <= dma_addr;
                        bytes_transferred <= 16'd0;
                        fifo_wr_ptr       <= 4'd0;
                        fifo_rd_ptr       <= 4'd0;
                        fifo_count        <= 5'd0;

                        if (dma_dir) begin // IN transfer (Read from memory, stream to USB)
                            state <= DMA_AR_START;
                        end else begin     // OUT transfer (Wait for USB data, write to memory)
                            state <= DMA_AW_START;
                        end
                    end
                end

                DMA_AR_START: begin
                    m_axi_araddr  <= cur_addr;
                    m_axi_arlen   <= (target_len >> 2) - 1; // Number of 32-bit words
                    m_axi_arvalid <= 1'b1;
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        state         <= DMA_R_BURST;
                    end
                end

                DMA_R_BURST: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        tx_dpp_valid <= 1'b1;
                        tx_dpp_data  <= m_axi_rdata;
                        tx_dpp_last  <= (bytes_transferred + 16'd4 >= target_len);
                        bytes_transferred <= bytes_transferred + 16'd4;
                        if (m_axi_rlast || (bytes_transferred + 16'd4 >= target_len)) begin
                            m_axi_rready <= 1'b0;
                            state        <= DMA_FINISH;
                        end
                    end else if (tx_dpp_ready) begin
                        tx_dpp_valid <= 1'b0;
                    end
                end

                DMA_AW_START: begin
                    if (fifo_count > 0 || rx_dpp_last) begin
                        m_axi_awaddr  <= cur_addr;
                        m_axi_awlen   <= (target_len >> 2) - 1;
                        m_axi_awvalid <= 1'b1;
                        if (m_axi_awvalid && m_axi_awready) begin
                            m_axi_awvalid <= 1'b0;
                            state         <= DMA_W_BURST;
                        end
                    end
                end

                DMA_W_BURST: begin
                    if (fifo_count > 0) begin
                        m_axi_wdata   <= out_fifo[fifo_rd_ptr];
                        m_axi_wvalid  <= 1'b1;
                        m_axi_wlast   <= (bytes_transferred + 16'd4 >= target_len);
                        if (m_axi_wready) begin
                            fifo_rd_ptr <= fifo_rd_ptr + 4'd1;
                            fifo_count  <= fifo_count - 5'd1;
                            bytes_transferred <= bytes_transferred + 16'd4;
                            if (bytes_transferred + 16'd4 >= target_len) begin
                                m_axi_wvalid <= 1'b0;
                                m_axi_bready <= 1'b1;
                                state        <= DMA_B_WAIT;
                            end
                        end
                    end else begin
                        m_axi_wvalid <= 1'b0;
                    end
                end

                DMA_B_WAIT: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        state        <= DMA_FINISH;
                    end
                end

                DMA_FINISH: begin
                    dma_done <= 1'b1;
                    dma_busy <= 1'b0;
                    state    <= DMA_IDLE;
                end
            endcase
        end
    end

endmodule
