`timescale 1 ps/ 1 ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 10-03-2026 14:34:10
// Design Name:
// Module Name: afdx_gmii_tx
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

module afdx_gmii_tx #(
    parameter integer IFG_CYCLES = 12
)(
    input                                               tx_clk,
    input                                               reset,
    input                                               frame_start_toggle,//识别新帧
    input  [15:0]                                       frame_len,
    output [15:0]                                       frame_addr,
    input  [7:0]                                        frame_data,
    output reg                                          gmii_tx_en,
    output reg  [7:0]                                   gmii_txd,
    output reg                                          gmii_tx_er,
    output reg                                          done_toggle//指示帧发送完成
);

    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_PREAMBLE = 3'd1;
    localparam [2:0] ST_DATA     = 3'd2;
    localparam [2:0] ST_FCS      = 3'd3;
    localparam [2:0] ST_IFG      = 3'd4;

    reg [2:0]                                           state;
    reg [2:0]                                           preamble_count;//控制帧头发送 7*0x55
    reg [15:0]                                          frame_addr_reg;
    reg [15:0]                                          frame_len_reg;
    reg [31:0]                                          ifg_count;
    reg [1:0]                                           fcs_index;
    wire [31:0]                                         fcs;
    // Keep the event synchronizer flops together in implementation.
    (* ASYNC_REG = "TRUE" *) reg start_meta;
    (* ASYNC_REG = "TRUE" *) reg start_sync;
    reg                                                 start_seen;//记录帧起始事件是否已 seen

    assign frame_addr = frame_addr_reg;

    afdx_fcs_tx fcs_tx (
        .clk(tx_clk),
        .reset(reset),
        .start((state == ST_DATA) && (frame_addr_reg == 16'd0)),
        .data_valid(state == ST_DATA),
        .data(frame_data),
        .data_last((state == ST_DATA) &&
                   (frame_addr_reg == (frame_len_reg - 1'b1))),
        .fcs(fcs),
        .fcs_valid()
    );

    always @(posedge tx_clk or negedge reset) begin
        if (!reset) begin
            state          <= ST_IDLE;
            preamble_count <= 3'd0;
            frame_addr_reg <= 16'd0;
            frame_len_reg  <= 16'd0;
            ifg_count      <= 32'd0;
            fcs_index      <= 2'd0;
            start_meta     <= 1'b0;
            start_sync     <= 1'b0;
            start_seen     <= 1'b0;
            gmii_tx_en     <= 1'b0;
            gmii_txd       <= 8'h00;
            gmii_tx_er     <= 1'b0;
            done_toggle    <= 1'b0;
        end else begin
            // The frame buffer and its length are stable before the toggle
            // reaches this clock domain.  Two flops provide the event CDC.
            start_meta <= frame_start_toggle;
            start_sync <= start_meta;

            case (state)
                ST_IDLE: begin
                    gmii_tx_en <= 1'b0;
                    gmii_txd   <= 8'h00;
                    gmii_tx_er <= 1'b0;
                    if ((start_sync != start_seen) && (frame_len != 0)) begin
                        start_seen     <= start_sync;
                        frame_len_reg  <= frame_len;
                        frame_addr_reg <= 16'd0;
                        preamble_count <= 3'd1;
                        gmii_tx_en     <= 1'b1;
                        gmii_txd       <= 8'h55;
                        gmii_tx_er     <= 1'b0;
                        state          <= ST_PREAMBLE;
                    end
                end

                ST_PREAMBLE: begin
                    gmii_tx_en <= 1'b1;
                    gmii_tx_er <= 1'b0;
                    // One 0x55 was emitted when the event was accepted.
                    // Counts 1..6 emit the remaining six 0x55 bytes; count 7
                    // emits the SFD, giving the standard 7x55 + D5.
                    if (preamble_count < 3'd7) begin
                        gmii_txd       <= 8'h55;
                        preamble_count <= preamble_count + 1'b1;
                    end else begin
                        gmii_txd       <= 8'hD5;
                        frame_addr_reg <= 16'd0;
                        state          <= ST_DATA;
                    end
                end

                ST_DATA: begin
                    gmii_tx_en <= 1'b1;
                    gmii_txd   <= frame_data;
                    gmii_tx_er <= 1'b0;
                    if (frame_addr_reg >= (frame_len_reg - 1'b1)) begin
                        fcs_index <= 2'd0;
                        state     <= ST_FCS;
                    end else begin
                        frame_addr_reg <= frame_addr_reg + 1'b1;
                    end
                end

                ST_FCS: begin
                    gmii_tx_en <= 1'b1;
                    gmii_tx_er <= 1'b0;
                    case (fcs_index)
                        2'd0: gmii_txd <= fcs[7:0];
                        2'd1: gmii_txd <= fcs[15:8];
                        2'd2: gmii_txd <= fcs[23:16];
                        default: gmii_txd <= fcs[31:24];
                    endcase
                    if (fcs_index == 2'd3) begin
                        ifg_count <= 32'd0;
                        state     <= ST_IFG;
                    end else begin
                        fcs_index <= fcs_index + 1'b1;
                    end
                end

                ST_IFG: begin
                    gmii_tx_en <= 1'b0;
                    gmii_txd   <= 8'h00;
                    gmii_tx_er <= 1'b0;
                    if ((IFG_CYCLES <= 1) ||
                        (ifg_count >= (IFG_CYCLES - 1))) begin
                        done_toggle <= ~done_toggle;
                        state       <= ST_IDLE;
                    end else begin
                        ifg_count <= ifg_count + 1'b1;
                    end
                end

                default: begin
                    state      <= ST_IDLE;
                    gmii_tx_en <= 1'b0;
                    gmii_txd   <= 8'h00;
                    gmii_tx_er <= 1'b0;
                end
            endcase
        end
    end
endmodule

