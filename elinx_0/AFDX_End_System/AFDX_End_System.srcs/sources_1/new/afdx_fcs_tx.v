`timescale 1 ps/ 1 ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 10-03-2026 14:36:29
// Design Name:
// Module Name: afdx_fcs_tx
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
//
// Revision:
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////

module afdx_fcs_tx (
    input         clk,
    input         reset,
    input         start,
    input         data_valid,
    input  [7:0]  data,
    input         data_last,
    output reg [31:0] fcs,
    output reg    fcs_valid
);

    localparam [31:0] CRC_INIT = 32'hFFFF_FFFF;
    reg [31:0] crc_reg;

    function [31:0] crc32_next;
        input [31:0] crc;
        input [7:0]  value;
        integer bit_index;
        reg [31:0] c;
        begin
            c = crc;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (c[0] ^ value[bit_index])
                    c = (c >> 1) ^ 32'hEDB8_8320;
                else
                    c = c >> 1;
            end
            crc32_next = c;
        end
    endfunction

    wire [31:0] crc_after_data = crc32_next(start ? CRC_INIT : crc_reg, data);

    always @(posedge clk or negedge reset) begin
        if (!reset) begin
            crc_reg   <= CRC_INIT;
            fcs       <= 32'd0;
            fcs_valid <= 1'b0;
        end else begin
            if (start)
                fcs_valid <= 1'b0;
            if (data_valid) begin
                crc_reg <= crc_after_data;
                if (data_last) begin
                    fcs       <= ~crc_after_data;
                    fcs_valid <= 1'b1;
                end
            end else if (start) begin
                crc_reg <= CRC_INIT;
            end
        end
    end
endmodule

