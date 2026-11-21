// =============================================================================
// File: usb3_crc.v
// Module: usb3_crc
// Project: USB 3.0 SuperSpeed (5 Gbps) Controller ASIC
// Description: Parallel CRC Engines for USB 3.0:
//              - CRC-5: G(X) = X^5 + X^2 + 1 (Header Packet Link Control Word)
//              - CRC-16: G(X) = X^16 + X^15 + X^2 + 1 (Data Packet Payload)
// =============================================================================

`timescale 1ns / 1ps

module usb3_crc (
    input  wire        clk,
    input  wire        rst_n,

    // CRC-5 Interface (for 11-bit Link Control Word)
    input  wire        crc5_init,
    input  wire [10:0] crc5_data_in,
    output wire [4:0]  crc5_out,

    // CRC-16 Interface (for 32-bit streaming Data Packet Payload)
    input  wire        crc16_init,
    input  wire        crc16_en,
    input  wire [31:0] crc16_data_in,
    output reg  [15:0] crc16_out
);

    // Parallel CRC-5 calculation for 11 bits
    // Standard USB 3.0 polynomial: X^5 + X^2 + 1
    function [4:0] calc_crc5_11b(input [10:0] d);
        reg [4:0] c;
        integer i;
        reg fb;
        begin
            c = 5'b11111;
            for (i = 0; i < 11; i = i + 1) begin
                fb = c[4] ^ d[i];
                c[4] = c[3];
                c[3] = c[2];
                c[2] = c[1] ^ fb;
                c[1] = c[0];
                c[0] = fb;
            end
            calc_crc5_11b = ~c; // Inverted output
        end
    endfunction

    assign crc5_out = calc_crc5_11b(crc5_data_in);

    // 32-bit Parallel CRC-16 calculation
    // Polynomial: X^16 + X^15 + X^2 + 1
    function [15:0] step_crc16_32b(input [15:0] cur, input [31:0] d);
        integer i;
        reg [15:0] c;
        reg fb;
        begin
            c = cur;
            for (i = 0; i < 32; i = i + 1) begin
                fb = c[15] ^ d[i];
                c[15] = c[14] ^ fb;
                c[14:3] = c[13:2];
                c[2] = c[1] ^ fb;
                c[1] = c[0];
                c[0] = fb;
            end
            step_crc16_32b = c;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crc16_out <= 16'hFFFF;
        end else begin
            if (crc16_init) begin
                crc16_out <= 16'hFFFF;
            end else if (crc16_en) begin
                crc16_out <= step_crc16_32b(crc16_out, crc16_data_in);
            end
        end
    end

endmodule
