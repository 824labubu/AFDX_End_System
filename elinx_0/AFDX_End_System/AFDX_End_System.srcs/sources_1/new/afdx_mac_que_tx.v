`timescale 1 ps/ 1 ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 10-03-2026 15:23:03
// Design Name:
// Module Name: afdx_mac_que_tx
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:8 KiB
//
// Revision:
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////

module afdx_mac_que_tx #(
    parameter integer MAX_PAYLOAD_BYTES = 8192,
    parameter integer MIN_FRAME_BYTES   = 60,
    parameter integer IFG_CYCLES        = 12,
    parameter [15:0] ES1_USER_ID        = 16'h01_01,
    parameter [15:0] ES2_USER_ID        = 16'h01_02,
    parameter [7:0]  PAD_BYTE           = 8'hAA,
    parameter [7:0]  SN_INIT            = 8'h01,
    parameter [7:0]  QUE_VL0_INDEX      = 8'd2,
    parameter [7:0]  QUE_VL1_INDEX      = 8'd3
)(
    input                         clk,
    input                         reset,
    input  [7:0]                  tx_data,
    input                         tx_valid,
    output reg                    tx_ready,
    input                         tx_tlast,
    input                         tx_sop,
    input  [15:0]                 tx_len,

    input  [15:0]                 app_upd_src_port,
    input  [15:0]                 app_upd_dst_port,

    input  [31:0]                 src_ip,
    input  [31:0]                 dst_ip,
    input  [47:0]                 src_mac_a,
    input  [47:0]                 dst_mac,
    input  [47:0]                 src_mac_b,

    input  [23:0]                 bag_cycles_timer,
    input  [15:0]                 vl_lmax,

    // PHY/GMII A
    output                        mdc_a,
    inout                         mdio_a,
    output                        phy_rstb0_a,
    input                         p0_txc_a,
    output                        p0_gtxc_a,
    output [7:0]                  p0_txd_a,
    output                        p0_txen_a,
    output                        p0_txer_a,
    output [31:0]                 reg_data_out_a,
    output                        reg_acc_bsy_a,

    // PHY/GMII B
    output                        mdc_b,
    inout                         mdio_b,
    output                        phy_rstb0_b,
    input                         p0_txc_b,
    output                        p0_gtxc_b,
    output [7:0]                  p0_txd_b,
    output                        p0_txen_b,
    output                        p0_txer_b,
    output [31:0]                 reg_data_out_b,
    output                        reg_acc_bsy_b,

    // Input status.  tx_ready is the admission handshake; tx_busy mirrors
    // the one-datagram capture/transmit engine being occupied.  A producer
    // that asserts tx_valid while tx_ready is low loses that beat and sets
    // tx_overflow (sticky until reset).  tx_error_valid is a one-cycle event
    // for a rejected datagram or an overflow attempt, and tx_error_code holds
    // the most recent error code.
    output reg                    tx_overflow,
    output reg                    tx_error_valid,
    output reg [3:0]              tx_error_code,
    output                        tx_busy,
    // Absolute route index, sampled on the accepted SOP byte.  An omitted
    // input selects QUE_VL0_INDEX for legacy single-VL instantiations.
    input  [7:0]                  tx_vl_index,
    // bit 0 is QUE_VL0_INDEX, bit 1 is QUE_VL1_INDEX.  A shared scheduler
    // filters candidates with this before granting the one capture engine.
    output [1:0]                  vl_bag_ready
);

    // UDP length is the IP payload length (UDP header plus application bytes).
    // Keep non-final fragments on an eight-byte boundary and every IPv4
    // packet at or below the project's 1499-byte IP length limit.
    localparam integer UDP_HEADER_BYTES = 8;
    localparam integer IP_HEADER_BYTES  = 20;
    localparam integer MAX_UDP_BYTES    = MAX_PAYLOAD_BYTES + UDP_HEADER_BYTES;
    localparam integer IP_FRAGMENT_PAYLOAD_MAX =
        (MAX_UDP_BYTES < 1479) ? MAX_UDP_BYTES : 1479;
    localparam integer FRAG_PAYLOAD_BYTES =
        (IP_FRAGMENT_PAYLOAD_MAX < 8) ? IP_FRAGMENT_PAYLOAD_MAX :
        ((IP_FRAGMENT_PAYLOAD_MAX / 8) * 8);
    // Frame RAM only holds one Ethernet fragment.  Its size is independent
    // of how many application bytes the input payload slot can hold.
    localparam integer MAX_FRAGMENT_FRAME_BYTES =
        14 + IP_HEADER_BYTES + IP_FRAGMENT_PAYLOAD_MAX + 1;
    localparam integer MAX_FRAME_BYTES =
        (MAX_FRAGMENT_FRAME_BYTES > MIN_FRAME_BYTES) ?
        MAX_FRAGMENT_FRAME_BYTES : MIN_FRAME_BYTES;
    // Sized aliases keep the arithmetic feeding 16-bit frame registers
    // explicit for older Quartus/Verilog-2001 elaborators.
    localparam [15:0] UDP_HEADER_BYTES_W          = UDP_HEADER_BYTES;
    localparam [15:0] IP_HEADER_BYTES_W           = IP_HEADER_BYTES;
    localparam [15:0] IP_FRAGMENT_PAYLOAD_MAX_W   = IP_FRAGMENT_PAYLOAD_MAX;
    localparam [15:0] FRAG_PAYLOAD_BYTES_W        = FRAG_PAYLOAD_BYTES;
    localparam [15:0] MIN_FRAME_BYTES_W           = MIN_FRAME_BYTES;

    localparam [3:0] ST_IDLE         = 4'd0;
    localparam [3:0] ST_CAPTURE      = 4'd1;
    localparam [3:0] ST_DRAIN        = 4'd2;
    localparam [3:0] ST_CHECK        = 4'd3;
    localparam [3:0] ST_WAIT_BAG     = 4'd4;
    localparam [3:0] ST_BUILD_DATA   = 4'd5;
    localparam [3:0] ST_PUBLISH_WAIT = 4'd6;
    localparam [3:0] ST_TX_WAIT      = 4'd7;

    localparam [3:0] ERR_NONE  = 4'd0;
    localparam [3:0] ERR_LONG  = 4'd1;
    localparam [3:0] ERR_SHORT = 4'd2;
    localparam [3:0] ERR_SOP   = 4'd3;
    localparam [3:0] ERR_LEN   = 4'd4;
    localparam [3:0] ERR_LMAX  = 4'd5;
    localparam [3:0] ERR_BUSY  = 4'd6;

    reg [3:0] state;
    reg [7:0] payload_mem [0:MAX_PAYLOAD_BYTES-1];
    reg [7:0] payload_read_data;
    reg [15:0] payload_read_addr;
    reg payload_read_enable;
    wire payload_write_enable;
    wire [15:0] payload_write_addr;
    reg [7:0] frame_mem_a [0:MAX_FRAME_BYTES-1];
    reg [7:0] frame_mem_b [0:MAX_FRAME_BYTES-1];

    reg [15:0] payload_len;
    reg [15:0] expected_len;
    reg [15:0] build_offset;
    reg [15:0] tx_base_len;
    reg [15:0] tx_frame_len;
    reg [3:0]  frame_error;
    reg [3:0]  last_error;

    // Metadata is captured with the first accepted payload byte.
    reg [15:0] tx_src_udp;
    reg [15:0] tx_dst_udp;
    reg [15:0] tx_udp_len;
    reg [31:0] tx_src_ip;
    reg [31:0] tx_dst_ip;
    reg [47:0] tx_src_mac_a;
    reg [47:0] tx_src_mac_b;
    reg [47:0] tx_dst_mac;
    reg [15:0] tx_lmax;
    reg [31:0] tx_bag_cycles;

    // Current fragment header/context.
    reg [15:0] tx_frag_offset_bytes;
    reg [15:0] tx_frag_remaining_bytes;
    reg [15:0] tx_ip_total_len;
    reg [15:0] tx_ip_checksum;
    reg [15:0] tx_ip_flags_offset;
    reg [15:0] tx_ip_identification;
    reg        tx_fragment_last;

    // AFDX SN is advanced once for every emitted fragment.  IP identification
    // is advanced once for every original datagram.
    reg [7:0]  tx_sequence;
    reg [7:0]  sequence_counter [0:1];
    reg [15:0] ip_id_counter [0:1];
    reg        active_vl_slot;
    wire [7:0] input_vl_index;
    wire       input_vl_valid;
    wire       input_vl_slot;

    // BAG is applied between completed Ethernet frames, including fragments.
    reg [31:0] bag_timer [0:1];
    integer vl_state_i;

    reg        frame_start_toggle;
    wire       done_toggle_a;
    wire       done_toggle_b;
    (* ASYNC_REG = "TRUE" *) reg done_a_meta;
    (* ASYNC_REG = "TRUE" *) reg done_a_sync;
    (* ASYNC_REG = "TRUE" *) reg done_b_meta;
    (* ASYNC_REG = "TRUE" *) reg done_b_sync;
    reg done_a_seen;
    reg done_b_seen;

    reg [7:0] frame_byte_a;
    reg [7:0] frame_byte_b;
    reg [7:0] frame_data_a;
    reg [7:0] frame_data_b;
    wire [15:0] frame_addr_a;
    wire [15:0] frame_addr_b;
    wire input_fire;

    // This is deliberately a level indication; the engine has no second
    // datagram slot while it is checking, building, or transmitting the
    // current one.  tx_ready remains the authoritative transfer handshake.
    assign tx_busy = (state != ST_IDLE);

    assign input_vl_index = ((^tx_vl_index) === 1'bx) ?
                            QUE_VL0_INDEX : tx_vl_index;
    assign input_vl_valid = (input_vl_index == QUE_VL0_INDEX) ||
                            (input_vl_index == QUE_VL1_INDEX);
    assign input_vl_slot = (input_vl_index == QUE_VL1_INDEX);
    assign vl_bag_ready[0] = reset && (bag_timer[0] == 32'd0);
    assign vl_bag_ready[1] = reset && (bag_timer[1] == 32'd0);
    assign input_fire = tx_valid && tx_ready;
    assign payload_write_enable = input_fire &&
        (((state == ST_IDLE) && tx_sop) ||
         ((state == ST_CAPTURE) && !tx_sop &&
          (payload_len < MAX_PAYLOAD_BYTES)));
    assign payload_write_addr = (state == ST_IDLE) ? 16'd0 : payload_len;
    assign p0_gtxc_a = p0_txc_a;
    assign p0_gtxc_b = p0_txc_b;
    assign mdc_a = 1'b0;
    assign mdc_b = 1'b0;
    assign mdio_a = 1'bz;
    assign mdio_b = 1'bz;
    assign phy_rstb0_a = reset;
    assign phy_rstb0_b = reset;
    assign reg_data_out_a = 32'h0000_0000;
    assign reg_data_out_b = 32'h0000_0000;
    assign reg_acc_bsy_a = 1'b0;
    assign reg_acc_bsy_b = 1'b0;

    afdx_gmii_tx #(.IFG_CYCLES(IFG_CYCLES)) gmii_tx_a (
        .tx_clk(p0_txc_a),
        .reset(reset),
        .frame_start_toggle(frame_start_toggle),
        .frame_len(tx_frame_len),
        .frame_addr(frame_addr_a),
        .frame_data(frame_data_a),
        .gmii_tx_en(p0_txen_a),
        .gmii_txd(p0_txd_a),
        .gmii_tx_er(p0_txer_a),
        .done_toggle(done_toggle_a)
    );

    afdx_gmii_tx #(.IFG_CYCLES(IFG_CYCLES)) gmii_tx_b (
        .tx_clk(p0_txc_b),
        .reset(reset),
        .frame_start_toggle(frame_start_toggle),
        .frame_len(tx_frame_len),
        .frame_addr(frame_addr_b),
        .frame_data(frame_data_b),
        .gmii_tx_en(p0_txen_b),
        .gmii_txd(p0_txd_b),
        .gmii_tx_er(p0_txer_b),
        .done_toggle(done_toggle_b)
    );

    always @(*) begin
        frame_data_a = 8'h00;
        frame_data_b = 8'h00;
        if (frame_addr_a < MAX_FRAME_BYTES)
            frame_data_a = frame_mem_a[frame_addr_a];
        if (frame_addr_b < MAX_FRAME_BYTES)
            frame_data_b = frame_mem_b[frame_addr_b];
    end

    always @(*) begin
        tx_ready = 1'b0;
        if (reset && (((state == ST_IDLE) && input_vl_valid) ||
                      (state == ST_CAPTURE) || (state == ST_DRAIN)))
            tx_ready = 1'b1;
    end

    function [7:0] mac_byte;
        input [47:0] mac;
        input [2:0] index;
        begin
            case (index)
                3'd0: mac_byte = mac[47:40];
                3'd1: mac_byte = mac[39:32];
                3'd2: mac_byte = mac[31:24];
                3'd3: mac_byte = mac[23:16];
                3'd4: mac_byte = mac[15:8];
                default: mac_byte = mac[7:0];
            endcase
        end
    endfunction

    function [15:0] ipv4_checksum;
        input [15:0] total_length;
        input [15:0] identification;
        input [15:0] flags_fragment_offset;
        input [31:0] source_ip;
        input [31:0] destination_ip;
        reg [31:0] sum;
        begin
            sum = 32'd0;
            sum = sum + 32'h0000_4500;
            sum = sum + {16'd0, total_length};
            sum = sum + {16'd0, identification};
            sum = sum + {16'd0, flags_fragment_offset};
            sum = sum + 32'h0000_0111; // TTL=1, UDP=17
            sum = sum + {16'd0, source_ip[31:16]};
            sum = sum + {16'd0, source_ip[15:0]};
            sum = sum + {16'd0, destination_ip[31:16]};
            sum = sum + {16'd0, destination_ip[15:0]};
            sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};
            sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};
            ipv4_checksum = ~sum[15:0];
        end
    endfunction

    // Combinational description of the fragment selected by the context
    // registers.  The offset is in the original IP payload (UDP header is
    // included at offset zero).
    reg [15:0] frag_payload_len_comb;
    reg [15:0] frag_ip_total_len_comb;
    reg [15:0] frag_base_len_comb;
    reg [15:0] frag_frame_len_comb;
    reg [15:0] frag_flags_offset_comb;
    reg [15:0] frag_checksum_comb;
    reg        frag_last_comb;

    always @(*) begin
        if (tx_frag_remaining_bytes > IP_FRAGMENT_PAYLOAD_MAX_W)
            frag_payload_len_comb = FRAG_PAYLOAD_BYTES_W;
        else
            frag_payload_len_comb = tx_frag_remaining_bytes;
        frag_last_comb = (tx_frag_remaining_bytes <= IP_FRAGMENT_PAYLOAD_MAX_W);
        frag_ip_total_len_comb = IP_HEADER_BYTES_W + frag_payload_len_comb;
        frag_base_len_comb = 16'd14 + frag_ip_total_len_comb;
        frag_frame_len_comb = ((frag_base_len_comb + 16'd1) < MIN_FRAME_BYTES_W) ?
                              MIN_FRAME_BYTES_W : (frag_base_len_comb + 16'd1);
        if (tx_udp_len <= IP_FRAGMENT_PAYLOAD_MAX_W)
            frag_flags_offset_comb = 16'h4000 | (tx_frag_offset_bytes >> 3);
        else if (frag_last_comb)
            frag_flags_offset_comb = (tx_frag_offset_bytes >> 3);
        else
            frag_flags_offset_comb = 16'h2000 | (tx_frag_offset_bytes >> 3);
        frag_checksum_comb = ipv4_checksum(
            frag_ip_total_len_comb,
            tx_ip_identification,
            frag_flags_offset_comb,
            tx_src_ip,
            tx_dst_ip);
    end

    // Header, UDP payload, padding, and final AFDX SN byte for the current
    // fragment.  `tx_base_len` excludes the SN and any minimum-frame pad.
    // The next payload byte is fetched one build clock before it is placed
    // into the Ethernet fragment.  A clocked read lets synthesis implement
    // the 8 KiB datagram slot as a block RAM instead of a register mux.
    // First-fragment bytes begin at Ethernet offset 42; later fragments
    // begin at offset 34 because the UDP header occurs only once.
    always @(*) begin
        payload_read_enable = 1'b0;
        payload_read_addr = 16'd0;
        if (state == ST_BUILD_DATA &&
            (build_offset + 16'd1 < tx_base_len)) begin
            if (tx_frag_offset_bytes == 0) begin
                if (build_offset >= 16'd41) begin
                    payload_read_addr = build_offset - 16'd41;
                    if (payload_read_addr < MAX_PAYLOAD_BYTES)
                        payload_read_enable = 1'b1;
                end
            end else if (build_offset >= 16'd33) begin
                payload_read_addr = tx_frag_offset_bytes -
                                    UDP_HEADER_BYTES_W +
                                    (build_offset - 16'd33);
                if (payload_read_addr < MAX_PAYLOAD_BYTES)
                    payload_read_enable = 1'b1;
            end
        end
    end

    // One write port and one registered read port.  Neither port has a reset,
    // so an FPGA block RAM can implement the entire payload slot.
    always @(posedge clk) begin
        if (payload_write_enable)
            payload_mem[payload_write_addr] <= tx_data;
        if (payload_read_enable)
            payload_read_data <= payload_mem[payload_read_addr];
    end

    always @(*) begin
        frame_byte_a = PAD_BYTE;
        frame_byte_b = PAD_BYTE;
        if (build_offset < tx_frame_len) begin
            if (build_offset < 16'd6) begin
                frame_byte_a = mac_byte(tx_dst_mac, build_offset[2:0]);
                frame_byte_b = frame_byte_a;
            end else if (build_offset < 16'd12) begin
                frame_byte_a = mac_byte(tx_src_mac_a, build_offset - 16'd6);
                frame_byte_b = mac_byte(tx_src_mac_b, build_offset - 16'd6);
            end else if (build_offset < 16'd14) begin
                frame_byte_a = (build_offset == 16'd12) ? 8'h08 : 8'h00;
                frame_byte_b = frame_byte_a;
            end else if (build_offset < 16'd34) begin
                case (build_offset - 16'd14)
                    5'd0:  frame_byte_a = 8'h45;
                    5'd1:  frame_byte_a = 8'h00;
                    5'd2:  frame_byte_a = tx_ip_total_len[15:8];
                    5'd3:  frame_byte_a = tx_ip_total_len[7:0];
                    5'd4:  frame_byte_a = tx_ip_identification[15:8];
                    5'd5:  frame_byte_a = tx_ip_identification[7:0];
                    5'd6:  frame_byte_a = tx_ip_flags_offset[15:8];
                    5'd7:  frame_byte_a = tx_ip_flags_offset[7:0];
                    5'd8:  frame_byte_a = 8'h01;
                    5'd9:  frame_byte_a = 8'h11;
                    5'd10: frame_byte_a = tx_ip_checksum[15:8];
                    5'd11: frame_byte_a = tx_ip_checksum[7:0];
                    5'd12: frame_byte_a = tx_src_ip[31:24];
                    5'd13: frame_byte_a = tx_src_ip[23:16];
                    5'd14: frame_byte_a = tx_src_ip[15:8];
                    5'd15: frame_byte_a = tx_src_ip[7:0];
                    5'd16: frame_byte_a = tx_dst_ip[31:24];
                    5'd17: frame_byte_a = tx_dst_ip[23:16];
                    5'd18: frame_byte_a = tx_dst_ip[15:8];
                    default: frame_byte_a = tx_dst_ip[7:0];
                endcase
                frame_byte_b = frame_byte_a;
            end else if (build_offset < tx_base_len) begin
                if (tx_frag_offset_bytes == 0) begin
                    case (build_offset - 16'd34)
                        4'd0: frame_byte_a = tx_src_udp[15:8];
                        4'd1: frame_byte_a = tx_src_udp[7:0];
                        4'd2: frame_byte_a = tx_dst_udp[15:8];
                        4'd3: frame_byte_a = tx_dst_udp[7:0];
                        4'd4: frame_byte_a = tx_udp_len[15:8];
                        4'd5: frame_byte_a = tx_udp_len[7:0];
                        4'd6: frame_byte_a = 8'h00;
                        default: frame_byte_a = 8'h00;
                    endcase
                    if (build_offset >= 16'd42)
                        frame_byte_a = payload_read_data;
                end else begin
                    frame_byte_a = payload_read_data;
                end
                frame_byte_b = frame_byte_a;
            end else if (build_offset == (tx_frame_len - 16'd1)) begin
                frame_byte_a = tx_sequence;
                frame_byte_b = tx_sequence;
            end
        end
    end

    // A final fragment may be up to seven bytes larger than a non-final
    // fragment.  Check the largest fragment before releasing any of them.
    // LMAX includes SN and FCS, but excludes preamble and IFG.
    reg [15:0] check_udp_len;
    reg [15:0] check_frag_payload_len;
    reg [15:0] check_remainder;
    reg [15:0] check_frame_len;
    always @(*) begin
        check_udp_len = payload_len + UDP_HEADER_BYTES_W;
        check_remainder = 16'd0;
        if (check_udp_len > IP_FRAGMENT_PAYLOAD_MAX_W) begin
            check_remainder = check_udp_len % FRAG_PAYLOAD_BYTES_W;
            check_frag_payload_len = FRAG_PAYLOAD_BYTES_W;
            if (check_remainder <=
                (IP_FRAGMENT_PAYLOAD_MAX_W - FRAG_PAYLOAD_BYTES_W))
                check_frag_payload_len = FRAG_PAYLOAD_BYTES_W + check_remainder;
        end else begin
            check_frag_payload_len = check_udp_len;
        end
        check_frame_len = 16'd14 + IP_HEADER_BYTES_W + check_frag_payload_len + 16'd1;
        if (check_frame_len < MIN_FRAME_BYTES_W)
            check_frame_len = MIN_FRAME_BYTES_W;
    end

    always @(posedge clk or negedge reset) begin
        if (!reset) begin
            state <= ST_IDLE;
            payload_len <= 16'd0;
            expected_len <= 16'd0;
            build_offset <= 16'd0;
            tx_base_len <= 16'd0;
            tx_frame_len <= 16'd0;
            frame_error <= ERR_NONE;
            last_error <= ERR_NONE;
            tx_overflow <= 1'b0;
            tx_error_valid <= 1'b0;
            tx_error_code <= ERR_NONE;
            tx_src_udp <= 16'd0;
            tx_dst_udp <= 16'd0;
            tx_udp_len <= 16'd0;
            tx_src_ip <= 32'd0;
            tx_dst_ip <= 32'd0;
            tx_src_mac_a <= 48'd0;
            tx_src_mac_b <= 48'd0;
            tx_dst_mac <= 48'd0;
            tx_lmax <= 16'd0;
            tx_bag_cycles <= 32'd0;
            tx_frag_offset_bytes <= 16'd0;
            tx_frag_remaining_bytes <= 16'd0;
            tx_ip_total_len <= 16'd0;
            tx_ip_checksum <= 16'd0;
            tx_ip_flags_offset <= 16'd0;
            tx_ip_identification <= 16'd0;
            tx_fragment_last <= 1'b0;
            tx_sequence <= SN_INIT;
            active_vl_slot <= 1'b0;
            for (vl_state_i = 0; vl_state_i < 2; vl_state_i = vl_state_i + 1) begin
                sequence_counter[vl_state_i] <= (SN_INIT == 8'h01) ?
                                                8'hFF : (SN_INIT - 1'b1);
                ip_id_counter[vl_state_i] <= 16'd0;
                bag_timer[vl_state_i] <= 32'd0;
            end
            frame_start_toggle <= 1'b0;
            done_a_meta <= 1'b0;
            done_a_sync <= 1'b0;
            done_b_meta <= 1'b0;
            done_b_sync <= 1'b0;
            done_a_seen <= 1'b0;
            done_b_seen <= 1'b0;
        end else begin
            // Status events are pulses, while tx_overflow and
            // tx_error_code retain the information for software/logic that
            // samples them after the packet has been rejected.
            tx_error_valid <= 1'b0;
            if (tx_valid && !tx_ready) begin
                tx_overflow <= 1'b1;
                tx_error_valid <= 1'b1;
                tx_error_code <= ERR_BUSY;
            end

            done_a_meta <= done_toggle_a;
            done_a_sync <= done_a_meta;
            done_b_meta <= done_toggle_b;
            done_b_sync <= done_b_meta;
            for (vl_state_i = 0; vl_state_i < 2; vl_state_i = vl_state_i + 1)
                if (bag_timer[vl_state_i] != 0)
                    bag_timer[vl_state_i] <= bag_timer[vl_state_i] - 1'b1;

            case (state)
                ST_IDLE: begin
                    if (input_fire) begin
                        if (!tx_sop) begin
                            frame_error <= ERR_SOP;
                            // Even a one-byte malformed packet must pass
                            // through ST_CHECK so the external error event
                            // and last_error are generated.
                            state <= tx_tlast ? ST_CHECK : ST_DRAIN;
                        end else begin
                            active_vl_slot <= input_vl_slot;
                            payload_len <= 16'd1;
                            expected_len <= tx_len;
                            tx_src_udp <= app_upd_src_port;
                            tx_dst_udp <= app_upd_dst_port;
                            tx_src_ip <= src_ip;
                            tx_dst_ip <= dst_ip;
                            tx_src_mac_a <= src_mac_a;
                            tx_src_mac_b <= src_mac_b;
                            tx_dst_mac <= dst_mac;
                            tx_lmax <= vl_lmax;
                            tx_bag_cycles <= bag_cycles_timer;
                            if ((tx_len == 0) || (tx_len > MAX_PAYLOAD_BYTES))
                                frame_error <= ERR_LEN;
                            else
                                frame_error <= ERR_NONE;
                            state <= tx_tlast ? ST_CHECK : ST_CAPTURE;
                        end
                    end
                end

                ST_CAPTURE: begin
                    if (input_fire) begin
                        if (tx_sop) begin
                            frame_error <= ERR_SOP;
                            state <= tx_tlast ? ST_CHECK : ST_DRAIN;
                        end else if (payload_len < MAX_PAYLOAD_BYTES) begin
                            payload_len <= payload_len + 1'b1;
                            if (tx_tlast)
                                state <= ST_CHECK;
                            else if (payload_len == MAX_PAYLOAD_BYTES - 1)
                                state <= ST_DRAIN;
                        end else begin
                            // The capture RAM is full.  The byte is consumed
                            // only to drain the rest of this malformed
                            // datagram; report the capacity overrun in the
                            // same sticky status used for a busy violation.
                            tx_overflow <= 1'b1;
                            if (frame_error == ERR_NONE)
                                frame_error <= ERR_LONG;
                            state <= tx_tlast ? ST_CHECK : ST_DRAIN;
                        end
                    end
                end

                ST_DRAIN: begin
                    if (input_fire) begin
                        if (frame_error == ERR_NONE)
                            frame_error <= ERR_LONG;
                        if (tx_tlast)
                            state <= ST_CHECK;
                    end
                end

                ST_CHECK: begin
                    if (frame_error != ERR_NONE) begin
                        last_error <= frame_error;
                        tx_error_code <= frame_error;
                        tx_error_valid <= 1'b1;
                        state <= ST_IDLE;
                    end else if (payload_len == 0) begin
                        last_error <= ERR_SHORT;
                        tx_error_code <= ERR_SHORT;
                        tx_error_valid <= 1'b1;
                        state <= ST_IDLE;
                    end else if (payload_len != expected_len) begin
                        last_error <= ERR_LEN;
                        tx_error_code <= ERR_LEN;
                        tx_error_valid <= 1'b1;
                        state <= ST_IDLE;
                    end else if ((check_frame_len + 16'd4) > tx_lmax) begin
                        last_error <= ERR_LMAX;
                        tx_error_code <= ERR_LMAX;
                        tx_error_valid <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        tx_udp_len <= check_udp_len;
                        tx_frag_offset_bytes <= 16'd0;
                        tx_frag_remaining_bytes <= check_udp_len;
                        tx_ip_identification <= ip_id_counter[active_vl_slot];
                        ip_id_counter[active_vl_slot] <=
                            ip_id_counter[active_vl_slot] + 1'b1;
                        state <= ST_WAIT_BAG;
                    end
                end

                ST_WAIT_BAG: begin
                    if (bag_timer[active_vl_slot] == 0) begin
                        tx_ip_total_len <= frag_ip_total_len_comb;
                        tx_base_len <= frag_base_len_comb;
                        tx_frame_len <= frag_frame_len_comb;
                        tx_ip_flags_offset <= frag_flags_offset_comb;
                        tx_ip_checksum <= frag_checksum_comb;
                        tx_fragment_last <= frag_last_comb;
                        tx_sequence <= (sequence_counter[active_vl_slot] == 8'hFF) ?
                                       8'h01 : (sequence_counter[active_vl_slot] + 1'b1);
                        sequence_counter[active_vl_slot] <=
                            (sequence_counter[active_vl_slot] == 8'hFF) ?
                            8'h01 : (sequence_counter[active_vl_slot] + 1'b1);
                        build_offset <= 16'd0;
                        state <= ST_BUILD_DATA;
                    end
                end

                ST_BUILD_DATA: begin
                    frame_mem_a[build_offset] <= frame_byte_a;
                    frame_mem_b[build_offset] <= frame_byte_b;
                    if (build_offset == (tx_frame_len - 16'd1))
                        state <= ST_PUBLISH_WAIT;
                    else
                        build_offset <= build_offset + 1'b1;
                end

                ST_PUBLISH_WAIT: begin
                    frame_start_toggle <= ~frame_start_toggle;
                    state <= ST_TX_WAIT;
                end

                ST_TX_WAIT: begin
                    if ((done_a_sync != done_a_seen) &&
                        (done_b_sync != done_b_seen)) begin
                        done_a_seen <= done_a_sync;
                        done_b_seen <= done_b_sync;
                        if (tx_bag_cycles <= 1)
                            bag_timer[active_vl_slot] <= 32'd0;
                        else
                            bag_timer[active_vl_slot] <= tx_bag_cycles - 1'b1;
                        if (tx_fragment_last) begin
                            state <= ST_IDLE;
                        end else begin
                            tx_frag_offset_bytes <= tx_frag_offset_bytes +
                                                    FRAG_PAYLOAD_BYTES_W;
                            tx_frag_remaining_bytes <= tx_frag_remaining_bytes -
                                                       FRAG_PAYLOAD_BYTES_W;
                            state <= ST_WAIT_BAG;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule


