// =============================================================================
// File: usb3_controller_top.v
// Module: usb3_controller_top
// Project: USB 3.0 SuperSpeed (5 Gbps) Controller ASIC
// Description: Full-Flow Synthesizable Top-Level ASIC Controller integrating:
//              - PIPE 3.0 PHY interface adapter with LFPS generation & receiver detection
//              - 13-state Link Training and Status State Machine (LTSSM)
//              - Dual-path Galois LFSR Scrambler / Descrambler (X^16+X^15+X^13+X^4+1)
//              - Parallel CRC-5 (Header) and CRC-16 (Payload) engines
//              - Protocol packet engine (Header Packets, TP ACK/NRDY, DPP framing)
//              - Scatter-Gather AXI4 Master DMA engine for Bulk Streaming
// =============================================================================

`timescale 1ns / 1ps

module usb3_controller_top (
    input  wire        clk,          // Internal Core Clock (125 MHz - 250 MHz)
    input  wire        rst_n,

    // Host / Device Management Interface
    input  wire        enable,
    input  wire        force_u1_req,
    input  wire        force_u2_req,
    input  wire        force_u3_req,
    input  wire        exit_lp_req,
    output wire [3:0]  ltssm_state,
    output wire        link_ready,

    // Packet Generation Controls
    input  wire        tx_tp_req,
    input  wire [3:0]  tx_tp_subtype,
    input  wire [6:0]  tx_dev_addr,
    input  wire [3:0]  tx_ep_num,
    input  wire [4:0]  tx_seq_num,

    // Packet Reception Status
    output wire        rx_tp_ack,
    output wire        rx_tp_nrdy,
    output wire [3:0]  rx_ep_num,
    output wire [4:0]  rx_seq_num,

    // Software DMA Initiation Interface
    input  wire        dma_start,
    input  wire        dma_dir,
    input  wire [31:0] dma_addr,
    input  wire [15:0] dma_len,
    output wire        dma_busy,
    output wire        dma_done,

    // AXI4 Master Interface (Memory Bus)
    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,

    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,

    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,

    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,

    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    // PIPE 3.0 External Physical Interface (to High-Speed SerDes PMA)
    output wire [31:0] pipe_tx_data,
    output wire [3:0]  pipe_tx_datak,
    output wire        pipe_tx_elec_idle,
    input  wire [31:0] pipe_rx_data,
    input  wire [3:0]  pipe_rx_datak,
    input  wire        pipe_rx_elec_idle,
    input  wire [2:0]  pipe_rx_status,
    input  wire        pipe_phy_status
);

    // Internal Connections
    wire [1:0]  power_down;
    wire        tx_detect_rx_lb;
    wire        phy_status;
    wire        rx_detected;
    wire        send_lfps;
    wire        lfps_detected;
    wire        send_ts1;
    wire        send_ts2;

    wire [31:0] link_rx_data;
    wire [3:0]  link_rx_datak;
    wire        link_rx_valid;
    wire        link_rx_elec_idle;
    wire [2:0]  link_rx_status;

    // Ordered set codes (COM = 0xBC, TS1 ID = 0x4A, TS2 ID = 0x45)
    wire [31:0] ts1_word = {8'h4A, 8'h00, 8'h00, 8'hBC};
    wire [31:0] ts2_word = {8'h45, 8'h00, 8'h00, 8'hBC};

    // Protocol layer TX signals
    wire [31:0] proto_tx_data;
    wire [3:0]  proto_tx_datak;
    wire        proto_tx_valid;

    // Link Layer MUX for TX
    reg [31:0] raw_tx_data;
    reg [3:0]  raw_tx_datak;
    reg        raw_tx_idle;

    always @(*) begin
        if (send_ts1) begin
            raw_tx_data  = ts1_word;
            raw_tx_datak = 4'b0001;
            raw_tx_idle  = 1'b0;
        end else if (send_ts2) begin
            raw_tx_data  = ts2_word;
            raw_tx_datak = 4'b0001;
            raw_tx_idle  = 1'b0;
        end else if (proto_tx_valid) begin
            raw_tx_data  = proto_tx_data;
            raw_tx_datak = proto_tx_datak;
            raw_tx_idle  = 1'b0;
        end else begin
            raw_tx_data  = 32'h00000000;
            raw_tx_datak = 4'b0000;
            raw_tx_idle  = (power_down != 2'b00);
        end
    end

    // TX Scrambler
    wire [31:0] scrambled_tx_data;
    wire [3:0]  scrambled_tx_datak;

    usb3_scrambler u_tx_scrambler (
        .clk       (clk),
        .rst_n     (rst_n),
        .bypass    (!link_ready), // Bypass scrambling during LTSSM Polling
        .data_in   (raw_tx_data),
        .datak_in  (raw_tx_datak),
        .data_out  (scrambled_tx_data),
        .datak_out (scrambled_tx_datak)
    );

    // RX Descrambler
    wire [31:0] descrambled_rx_data;
    wire [3:0]  descrambled_rx_datak;

    usb3_scrambler u_rx_descrambler (
        .clk       (clk),
        .rst_n     (rst_n),
        .bypass    (!link_ready),
        .data_in   (link_rx_data),
        .datak_in  (link_rx_datak),
        .data_out  (descrambled_rx_data),
        .datak_out (descrambled_rx_datak)
    );

    // PIPE 3.0 Adapter
    usb3_pipe_if u_pipe_if (
        .pipe_clk             (clk),
        .rst_n                (rst_n),
        .link_tx_data         (scrambled_tx_data),
        .link_tx_datak        (scrambled_tx_datak),
        .link_tx_elec_idle    (raw_tx_idle),
        .link_rx_data         (link_rx_data),
        .link_rx_datak        (link_rx_datak),
        .link_rx_valid        (link_rx_valid),
        .link_rx_elec_idle    (link_rx_elec_idle),
        .link_rx_status       (link_rx_status),
        .power_down           (power_down),
        .tx_detect_rx_lb      (tx_detect_rx_lb),
        .phy_status           (phy_status),
        .rx_detected          (rx_detected),
        .send_lfps            (send_lfps),
        .lfps_detected        (lfps_detected),
        .pipe_tx_data         (pipe_tx_data),
        .pipe_tx_datak        (pipe_tx_datak),
        .pipe_tx_elec_idle    (pipe_tx_elec_idle),
        .pipe_rx_data_in      (pipe_rx_data),
        .pipe_rx_datak_in     (pipe_rx_datak),
        .pipe_rx_elec_idle_in (pipe_rx_elec_idle),
        .pipe_rx_status_in    (pipe_rx_status),
        .pipe_phy_status_in   (pipe_phy_status)
    );

    // Link Training and Status State Machine (LTSSM)
    usb3_ltssm u_ltssm (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable          (enable),
        .force_u1_req    (force_u1_req),
        .force_u2_req    (force_u2_req),
        .force_u3_req    (force_u3_req),
        .exit_lp_req     (exit_lp_req),
        .rx_detected     (rx_detected),
        .phy_status      (phy_status),
        .lfps_detected   (lfps_detected),
        .rx_valid        (link_rx_valid),
        .rx_data         (link_rx_data),
        .rx_datak        (link_rx_datak),
        .power_down      (power_down),
        .tx_detect_rx_lb (tx_detect_rx_lb),
        .send_lfps       (send_lfps),
        .send_ts1        (send_ts1),
        .send_ts2        (send_ts2),
        .link_ready      (link_ready),
        .ltssm_state     (ltssm_state)
    );

    // DMA Data Streaming Signals
    wire        tx_dpp_valid;
    wire [31:0] tx_dpp_data;
    wire        tx_dpp_last;
    wire        tx_dpp_ready;

    wire        rx_dpp_valid;
    wire [31:0] rx_dpp_data;
    wire        rx_dpp_last;

    // Protocol Packet Engine
    usb3_packet_engine u_packet_engine (
        .clk           (clk),
        .rst_n         (rst_n),
        .link_ready    (link_ready),
        .tx_tp_req     (tx_tp_req),
        .tx_tp_subtype (tx_tp_subtype),
        .tx_dev_addr   (tx_dev_addr),
        .tx_ep_num     (tx_ep_num),
        .tx_seq_num    (tx_seq_num),
        .tx_dph_req    (1'b0),
        .tx_data_len   (16'd0),
        .tx_dpp_valid  (tx_dpp_valid),
        .tx_dpp_data   (tx_dpp_data),
        .tx_dpp_last   (tx_dpp_last),
        .tx_dpp_ready  (tx_dpp_ready),
        .tx_data       (proto_tx_data),
        .tx_datak      (proto_tx_datak),
        .tx_valid      (proto_tx_valid),
        .rx_data       (descrambled_rx_data),
        .rx_datak      (descrambled_rx_datak),
        .rx_valid      (link_rx_valid),
        .rx_tp_ack     (rx_tp_ack),
        .rx_tp_nrdy    (rx_tp_nrdy),
        .rx_ep_num     (rx_ep_num),
        .rx_seq_num    (rx_seq_num),
        .rx_dpp_valid  (rx_dpp_valid),
        .rx_dpp_data   (rx_dpp_data),
        .rx_dpp_last   (rx_dpp_last)
    );

    // Scatter-Gather AXI4 Master DMA Engine
    usb3_dma_engine u_dma_engine (
        .clk           (clk),
        .rst_n         (rst_n),
        .dma_start     (dma_start),
        .dma_dir       (dma_dir),
        .dma_addr      (dma_addr),
        .dma_len       (dma_len),
        .dma_busy      (dma_busy),
        .dma_done      (dma_done),
        .tx_dpp_valid  (tx_dpp_valid),
        .tx_dpp_data   (tx_dpp_data),
        .tx_dpp_last   (tx_dpp_last),
        .tx_dpp_ready  (tx_dpp_ready),
        .rx_dpp_valid  (rx_dpp_valid),
        .rx_dpp_data   (rx_dpp_data),
        .rx_dpp_last   (rx_dpp_last),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),
        .m_axi_bresp   (m_axi_bresp),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rresp   (m_axi_rresp),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready)
    );

endmodule
