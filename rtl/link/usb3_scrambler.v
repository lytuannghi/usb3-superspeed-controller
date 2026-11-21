// =============================================================================
// File: usb3_scrambler.v
// Module: usb3_scrambler
// Project: USB 3.0 SuperSpeed (5 Gbps) Controller ASIC
// Description: Parallel 32-bit Scrambler / Descrambler conforming to USB 3.0
//              Chapter 7.3 with characteristic polynomial:
//              G(X) = X^16 + X^15 + X^13 + X^4 + 1
//              Resets LFSR state to 16'hFFFF on COM (K28.5) character.
// =============================================================================

`timescale 1ns / 1ps

module usb3_scrambler (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bypass,

    input  wire [31:0] data_in,
    input  wire [3:0]  datak_in,

    output reg  [31:0] data_out,
    output reg  [3:0]  datak_out
);

    reg [15:0] lfsr;

    // Single-bit LFSR advance function
    function [15:0] next_lfsr_1b(input [15:0] state);
        reg fb;
        begin
            fb = state[15] ^ state[14] ^ state[12] ^ state[3];
            next_lfsr_1b = {state[14:0], fb};
        end
    endfunction

    // 8-bit LFSR advance function
    function [23:0] next_lfsr_8b(input [15:0] state);
        integer i;
        reg [15:0] cur;
        reg [7:0]  mask;
        begin
            cur = state;
            for (i = 0; i < 8; i = i + 1) begin
                mask[i] = cur[15];
                cur = next_lfsr_1b(cur);
            end
            next_lfsr_8b = {cur, mask};
        end
    endfunction

    integer b;
    reg [15:0] state_pipe;
    reg [7:0]  mask_byte [0:3];
    reg [23:0] step_res;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr      <= 16'hFFFF;
            data_out  <= 32'd0;
            datak_out <= 4'd0;
        end else begin
            datak_out <= datak_in;

            if (bypass) begin
                data_out <= data_in;
            end else begin
                // Process 4 bytes
                state_pipe = lfsr;

                // Byte 0
                if (datak_in[0] && data_in[7:0] == 8'hBC) begin // COM resets LFSR
                    state_pipe = 16'hFFFF;
                    data_out[7:0] <= data_in[7:0];
                end else if (datak_in[0]) begin
                    data_out[7:0] <= data_in[7:0]; // Bypass control K-code
                end else begin
                    step_res = next_lfsr_8b(state_pipe);
                    state_pipe = step_res[23:8];
                    data_out[7:0] <= data_in[7:0] ^ step_res[7:0];
                end

                // Byte 1
                if (datak_in[1] && data_in[15:8] == 8'hBC) begin
                    state_pipe = 16'hFFFF;
                    data_out[15:8] <= data_in[15:8];
                end else if (datak_in[1]) begin
                    data_out[15:8] <= data_in[15:8];
                end else begin
                    step_res = next_lfsr_8b(state_pipe);
                    state_pipe = step_res[23:8];
                    data_out[15:8] <= data_in[15:8] ^ step_res[7:0];
                end

                // Byte 2
                if (datak_in[2] && data_in[23:16] == 8'hBC) begin
                    state_pipe = 16'hFFFF;
                    data_out[23:16] <= data_in[23:16];
                end else if (datak_in[2]) begin
                    data_out[23:16] <= data_in[23:16];
                end else begin
                    step_res = next_lfsr_8b(state_pipe);
                    state_pipe = step_res[23:8];
                    data_out[23:16] <= data_in[23:16] ^ step_res[7:0];
                end

                // Byte 3
                if (datak_in[3] && data_in[31:24] == 8'hBC) begin
                    state_pipe = 16'hFFFF;
                    data_out[31:24] <= data_in[31:24];
                end else if (datak_in[3]) begin
                    data_out[31:24] <= data_in[31:24];
                end else begin
                    step_res = next_lfsr_8b(state_pipe);
                    state_pipe = step_res[23:8];
                    data_out[31:24] <= data_in[31:24] ^ step_res[7:0];
                end

                lfsr <= state_pipe;
            end
        end
    end

endmodule
