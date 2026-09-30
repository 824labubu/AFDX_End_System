`timescale 1 ps/1 ps

// Hand-written AFDX TX MAC.
//
// The former implementation used the vendor mac_100Mbps IP as a FIFO and
// therefore depended on an undocumented register_acc address map.  This
// module keeps the useful protocol behavior (AFDX partition/VL mapping,
// IPv4/UDP framing, SN, padding and FCS) but owns the complete TX path:
//
//   application clk domain: capture -> BAG -> build DA..FCS in RAM
//   p0_rxc clock domains : 7x55 + D5 -> frame bytes -> IFG on GMII A/B
//
// The p0_rxc inputs are used as the GMII TX clock because that is the clock
// path used by the reference IP (p0_gtxc = p0_rxc).  The RX data/status pins
// and the old register access pins remain as compatibility ports; they are
// not used by this TX-only MAC.  PHY MDIO configuration is intentionally
// outside this module.
module afdx_mac_tx #(
    parameter integer MAX_PAYLOAD_BYTES = 1471,
    parameter integer MIN_FRAME_BYTES   = 60,
    parameter integer BAG_CYCLES        = 50000,
    parameter integer IFG_CYCLES        = 12,
    parameter [31:0] DEST_MAC_PREFIX    = 32'h03_00_00_00,
    parameter [15:0] ES1_USER_ID        = 16'h01_01,
    parameter [15:0] ES2_USER_ID        = 16'h01_02,
    parameter [7:0]  PAD_BYTE           = 8'hAA,
    parameter integer VL_COUNT          = 5
)(
    input                         clk,
    input                         reset,
    input  [7:0]                  tx_data,
    input                         tx_valid,
    output reg                    tx_ready,
    input                         tx_tlast,
    input  [7:0]                  tx_port,
    input  [15:0]                 app_upd_src_port,
    input  [15:0]                 app_upd_dst_port,

    // PHY/GMII A.  p0_rxc_a is the TX serializer clock in this interface.
    output                        mdc_a,
    inout                         mdio_a,
    output                        phy_rstb0_a,
    input                         p0_txc_a,
    input                         p0_rxc_a,
    input  [7:0]                  p0_rxd_a,
    input                         p0_rxdv_a,
    input                         p0_rxer_a,
    input                         p0_col_a,
    input                         p0_crs_a,
    output                        p0_gtxc_a,
    output [7:0]                  p0_txd_a,
    output                        p0_txen_a,
    output                        p0_txer_a,
    input                         reg_wr_a,
    input                         reg_rd_a,
    input  [3:0]                  reg_addr_a,
    input  [31:0]                 reg_data_in_a,
    output [31:0]                 reg_data_out_a,
    output                        reg_acc_bsy_a,

    // PHY/GMII B.  The B frame differs only in source MAC byte 5 and FCS.
    output                        mdc_b,
    inout                         mdio_b,
    output                        phy_rstb0_b,
    input                         p0_txc_b,
    input                         p0_rxc_b,
    input  [7:0]                  p0_rxd_b,
    input                         p0_rxdv_b,
    input                         p0_rxer_b,
    input                         p0_col_b,
    input                         p0_crs_b,
    output                        p0_gtxc_b,
    output [7:0]                  p0_txd_b,
    output                        p0_txen_b,
    output                        p0_txer_b,
    input                         reg_wr_b,
    input                         reg_rd_b,
    input  [3:0]                  reg_addr_b,
    input  [31:0]                 reg_data_in_b,
    output [31:0]                 reg_data_out_b,
    output                        reg_acc_bsy_b
);

    localparam integer MAX_FRAME_BYTES = MAX_PAYLOAD_BYTES + 64;

    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_CAPTURE    = 4'd1;
    localparam [3:0] ST_DRAIN      = 4'd2;
    localparam [3:0] ST_CHECK      = 4'd3;
    localparam [3:0] ST_WAIT       = 4'd4;
    localparam [3:0] ST_BUILD_DATA = 4'd5;
    localparam [3:0] ST_BUILD_FCS  = 4'd6;
    localparam [3:0] ST_TX_WAIT    = 4'd7;
    localparam [3:0] ST_PUBLISH_WAIT = 4'd8;

    localparam [3:0] ERR_NONE  = 4'd0;
    localparam [3:0] ERR_PORT  = 4'd1;
    localparam [3:0] ERR_LONG  = 4'd2;
    localparam [3:0] ERR_SHORT = 4'd3;

    localparam [7:0] PORT_SAM      = 8'd1;
    localparam [7:0] PORT_QUE      = 8'd2;
    localparam [7:0] PORT_SAP_SNMP = 8'd3;
    localparam [7:0] PORT_SAP_RTC  = 8'd4;
    localparam [7:0] PORT_SAP_615A = 8'd5;

    reg [3:0]  state;
    reg [7:0]  payload_mem [0:MAX_PAYLOAD_BYTES-1];
    reg [7:0]  frame_mem_a [0:MAX_FRAME_BYTES-1];
    reg [7:0]  frame_mem_b [0:MAX_FRAME_BYTES-1];
    reg [15:0] payload_len;
    reg [15:0] tx_base_len;
    reg [15:0] tx_frame_len;
    reg [15:0] build_offset;
    reg [15:0] frame_len_with_fcs;
    reg [3:0]  frame_error;
    reg [3:0]  last_error;

    reg [7:0]  tx_vl_index;
    reg [15:0] tx_vl_id;
    reg [7:0]  tx_sequence;
    reg [31:0] bag_timer [0:VL_COUNT-1];
    reg [7:0]  sequence_mem [0:VL_COUNT-1];

    reg [15:0] tx_src_udp;
    reg [15:0] tx_dst_udp;
    reg [15:0] tx_udp_len;
    reg [15:0] tx_ip_total_len;
    reg [15:0] tx_ip_checksum;
    reg [31:0] tx_src_ip;
    reg [31:0] tx_dst_ip;

    reg [1:0]  fcs_count;
    reg [31:0] crc_a;
    reg [31:0] crc_b;
    reg [31:0] fcs_a;
    reg [31:0] fcs_b;

    reg        frame_start_toggle;
    wire       done_toggle_a;
    wire       done_toggle_b;
    // Keep the return-event synchronizer flops together in implementation.
    (* ASYNC_REG = "TRUE" *) reg done_a_meta;
    (* ASYNC_REG = "TRUE" *) reg done_a_sync;
    (* ASYNC_REG = "TRUE" *) reg done_b_meta;
    (* ASYNC_REG = "TRUE" *) reg done_b_sync;
    reg        done_a_seen;
    reg        done_b_seen;

    reg  [7:0] frame_byte_a;
    reg  [7:0] frame_byte_b;
    reg  [7:0] fcs_byte_a;
    reg  [7:0] fcs_byte_b;
    wire [31:0] crc_a_next;
    wire [31:0] crc_b_next;
    wire        input_fire;
    wire        port_valid;
    wire [7:0]  port_index;
    wire [15:0] frame_addr_a;
    wire [15:0] frame_addr_b;
    reg  [7:0]  frame_data_a;
    reg  [7:0]  frame_data_b;

    assign input_fire = tx_valid && tx_ready;
    assign port_valid = (tx_port >= 8'd1) && (tx_port <= VL_COUNT);
    assign port_index = port_valid ? (tx_port - 8'd1) : 8'd0;

    // The arrays are written in clk and read by the two independent GMII
    // clock domains after frame_start_toggle.  They remain unchanged until
    // both done toggles have returned.
    // Procedural bounds checks treat an unknown address as false during
    // time-zero/reset, avoiding an out-of-range array read before the GMII
    // serializer has received its first frame event.
    always @(*) begin
        frame_data_a = 8'h00;
        frame_data_b = 8'h00;
        if (frame_addr_a < MAX_FRAME_BYTES)
            frame_data_a = frame_mem_a[frame_addr_a];
        if (frame_addr_b < MAX_FRAME_BYTES)
            frame_data_b = frame_mem_b[frame_addr_b];
    end

    // Keep the reference IP's clock relationship: GMII TX clock follows the
    // PHY-side p0_rxc input.  p0_txc and all RX pins are intentionally unused
    // by this TX-only implementation.
    assign p0_gtxc_a = p0_rxc_a;
    assign p0_gtxc_b = p0_rxc_b;
    assign mdc_a = 1'b0;
    assign mdc_b = 1'b0;
    assign mdio_a = 1'bz;
    assign mdio_b = 1'bz;
    assign phy_rstb0_a = reset;
    assign phy_rstb0_b = reset;

    // The old IP register bus is retained only for source compatibility.  It
    // is not a MAC control plane and has no effect on the handwritten TX.
    assign reg_data_out_a = 32'h0000_0000;
    assign reg_data_out_b = 32'h0000_0000;
    assign reg_acc_bsy_a  = 1'b0;
    assign reg_acc_bsy_b  = 1'b0;

    afdx_gmii_tx #(.IFG_CYCLES(IFG_CYCLES)) gmii_tx_a (
        .tx_clk(p0_rxc_a), .reset(reset),
        .frame_start_toggle(frame_start_toggle),
        .frame_len(frame_len_with_fcs), .frame_addr(frame_addr_a),
        .frame_data(frame_data_a),
        .gmii_tx_en(p0_txen_a), .gmii_txd(p0_txd_a),
        .gmii_tx_er(p0_txer_a), .done_toggle(done_toggle_a)
    );

    afdx_gmii_tx #(.IFG_CYCLES(IFG_CYCLES)) gmii_tx_b (
        .tx_clk(p0_rxc_b), .reset(reset),
        .frame_start_toggle(frame_start_toggle),
        .frame_len(frame_len_with_fcs), .frame_addr(frame_addr_b),
        .frame_data(frame_data_b),
        .gmii_tx_en(p0_txen_b), .gmii_txd(p0_txd_b),
        .gmii_tx_er(p0_txer_b), .done_toggle(done_toggle_b)
    );

    // The capture buffer is deliberately single-frame.  It accepts the
    // remaining bytes of an overlength frame in ST_DRAIN so tlast still marks
    // a clean boundary for the next frame.
    always @(*) begin
        tx_ready = 1'b0;
        if (reset && ((state == ST_IDLE) || (state == ST_CAPTURE) ||
                      (state == ST_DRAIN)))
            tx_ready = 1'b1;
    end

    function [15:0] vl_id_for_port;
        input [7:0] port_number;
        begin
            if ((port_number >= 8'd1) && (port_number <= VL_COUNT))
                vl_id_for_port = {8'h00, port_number};
            else
                vl_id_for_port = 16'h0000;
        end
    endfunction

    function [31:0] source_ip_for_port;
        input [7:0] port_number;
        begin
            source_ip_for_port = {8'h0A, ES1_USER_ID, port_number};
        end
    endfunction

    function [31:0] destination_ip_for_port;
        input [7:0] port_number;
        begin
            case (port_number)
                PORT_SAM:      destination_ip_for_port = 32'hF4F4_0001;
                PORT_QUE:      destination_ip_for_port = {8'h0A, ES2_USER_ID, PORT_QUE};
                PORT_SAP_SNMP: destination_ip_for_port = {8'h0A, ES2_USER_ID, PORT_SAP_SNMP};
                PORT_SAP_RTC:  destination_ip_for_port = {8'h0A, ES2_USER_ID, PORT_SAP_RTC};
                PORT_SAP_615A: destination_ip_for_port = {8'h0A, ES2_USER_ID, PORT_SAP_615A};
                default:       destination_ip_for_port = {8'h0A, ES2_USER_ID, port_number};
            endcase
        end
    endfunction

    function [7:0] mac_byte;
        input [47:0] mac;
        input [2:0]  index;
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

    function [7:0] destination_byte;
        input [15:0] vl_id;
        input [2:0]  index;
        begin
            case (index)
                3'd0: destination_byte = DEST_MAC_PREFIX[31:24];
                3'd1: destination_byte = DEST_MAC_PREFIX[23:16];
                3'd2: destination_byte = DEST_MAC_PREFIX[15:8];
                3'd3: destination_byte = DEST_MAC_PREFIX[7:0];
                3'd4: destination_byte = vl_id[15:8];
                default: destination_byte = vl_id[7:0];
            endcase
        end
    endfunction

    function [15:0] ipv4_checksum;
        input [15:0] total_length;
        input [31:0] source_ip;
        input [31:0] destination_ip;
        reg [31:0] sum;
        begin
            sum = 32'd0;
            sum = sum + 16'h4500;
            sum = sum + total_length;
            sum = sum + 16'h0000;
            sum = sum + 16'h4000;
            sum = sum + 16'h0111;
            sum = sum + source_ip[31:16] + source_ip[15:0];
            sum = sum + destination_ip[31:16] + destination_ip[15:0];
            sum = sum[15:0] + sum[31:16];
            sum = sum[15:0] + sum[31:16];
            ipv4_checksum = ~sum[15:0];
        end
    endfunction

    function [31:0] crc32_next;
        input [31:0] crc;
        input [7:0]  data;
        integer bit_index;
        reg [31:0] c;
        begin
            c = crc;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (c[0] ^ data[bit_index])
                    c = (c >> 1) ^ 32'hEDB8_8320;
                else
                    c = c >> 1;
            end
            crc32_next = c;
        end
    endfunction

    wire [47:0] src_mac_a = {24'h02_00_00, ES1_USER_ID, 8'h20};
    wire [47:0] src_mac_b = {24'h02_00_00, ES1_USER_ID, 8'h40};

    // Ethernet frame bytes before FCS.  The one-byte AFDX SN is the final
    // byte of the minimum Ethernet data field and is excluded from IP/UDP
    // lengths, matching the existing project framing convention.
    always @(*) begin
        frame_byte_a = PAD_BYTE;
        frame_byte_b = PAD_BYTE;
        if (build_offset < tx_frame_len) begin
            if (build_offset < 16'd6) begin
                frame_byte_a = destination_byte(tx_vl_id, build_offset[2:0]);
                frame_byte_b = frame_byte_a;
            end else if (build_offset < 16'd12) begin
                frame_byte_a = mac_byte(src_mac_a, build_offset - 16'd6);
                frame_byte_b = mac_byte(src_mac_b, build_offset - 16'd6);
            end else if (build_offset < 16'd14) begin
                frame_byte_a = (build_offset == 16'd12) ? 8'h08 : 8'h00;
                frame_byte_b = frame_byte_a;
            end else if (build_offset < 16'd34) begin
                case (build_offset - 16'd14)
                    5'd0:  frame_byte_a = 8'h45;
                    5'd1:  frame_byte_a = 8'h00;
                    5'd2:  frame_byte_a = tx_ip_total_len[15:8];
                    5'd3:  frame_byte_a = tx_ip_total_len[7:0];
                    5'd4:  frame_byte_a = 8'h00;
                    5'd5:  frame_byte_a = 8'h00;
                    5'd6:  frame_byte_a = 8'h40;
                    5'd7:  frame_byte_a = 8'h00;
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
            end else if (build_offset < 16'd42) begin
                case (build_offset - 16'd34)
                    3'd0: frame_byte_a = tx_src_udp[15:8];
                    3'd1: frame_byte_a = tx_src_udp[7:0];
                    3'd2: frame_byte_a = tx_dst_udp[15:8];
                    3'd3: frame_byte_a = tx_dst_udp[7:0];
                    3'd4: frame_byte_a = tx_udp_len[15:8];
                    3'd5: frame_byte_a = tx_udp_len[7:0];
                    3'd6: frame_byte_a = 8'h00;
                    default: frame_byte_a = 8'h00;
                endcase
                frame_byte_b = frame_byte_a;
            end else if (build_offset < tx_base_len) begin
                frame_byte_a = payload_mem[build_offset - 16'd42];
                frame_byte_b = frame_byte_a;
            end else if (build_offset == (tx_frame_len - 16'd1)) begin
                frame_byte_a = tx_sequence;
                frame_byte_b = tx_sequence;
            end
        end
    end

    always @(*) begin
        case (fcs_count)
            2'd0: begin
                fcs_byte_a = fcs_a[7:0];
                fcs_byte_b = fcs_b[7:0];
            end
            2'd1: begin
                fcs_byte_a = fcs_a[15:8];
                fcs_byte_b = fcs_b[15:8];
            end
            2'd2: begin
                fcs_byte_a = fcs_a[23:16];
                fcs_byte_b = fcs_b[23:16];
            end
            default: begin
                fcs_byte_a = fcs_a[31:24];
                fcs_byte_b = fcs_b[31:24];
            end
        endcase
    end

    assign crc_a_next = crc32_next(crc_a, frame_byte_a);
    assign crc_b_next = crc32_next(crc_b, frame_byte_b);

    integer i;
    always @(posedge clk or negedge reset) begin
        if (!reset) begin
            state              <= ST_IDLE;
            payload_len        <= 16'd0;
            tx_base_len        <= 16'd0;
            tx_frame_len       <= 16'd0;
            build_offset       <= 16'd0;
            frame_len_with_fcs <= 16'd0;
            frame_error        <= ERR_NONE;
            last_error         <= ERR_NONE;
            tx_vl_index        <= 8'd0;
            tx_vl_id           <= 16'd0;
            tx_sequence        <= 8'd0;
            tx_src_udp         <= 16'd0;
            tx_dst_udp         <= 16'd0;
            tx_udp_len         <= 16'd0;
            tx_ip_total_len    <= 16'd0;
            tx_ip_checksum     <= 16'd0;
            tx_src_ip          <= 32'd0;
            tx_dst_ip          <= 32'd0;
            fcs_count          <= 2'd0;
            crc_a              <= 32'hFFFF_FFFF;
            crc_b              <= 32'hFFFF_FFFF;
            fcs_a              <= 32'd0;
            fcs_b              <= 32'd0;
            frame_start_toggle <= 1'b0;
            done_a_meta        <= 1'b0;
            done_a_sync        <= 1'b0;
            done_b_meta        <= 1'b0;
            done_b_sync        <= 1'b0;
            done_a_seen        <= 1'b0;
            done_b_seen        <= 1'b0;
            for (i = 0; i < VL_COUNT; i = i + 1) begin
                bag_timer[i]    <= 32'd0;
                sequence_mem[i] <= 8'd0;
            end
        end else begin
            // Return events from the two GMII clock domains.
            done_a_meta <= done_toggle_a;
            done_a_sync <= done_a_meta;
            done_b_meta <= done_toggle_b;
            done_b_sync <= done_b_meta;

            for (i = 0; i < VL_COUNT; i = i + 1)
                if (bag_timer[i] != 0)
                    bag_timer[i] <= bag_timer[i] - 1'b1;

            case (state)
                ST_IDLE: begin
                    if (input_fire) begin
                        payload_len     <= 16'd1;
                        payload_mem[0]  <= tx_data;
                        tx_vl_index     <= port_index;
                        tx_vl_id        <= vl_id_for_port(tx_port);
                        tx_src_udp      <= app_upd_src_port;
                        tx_dst_udp      <= app_upd_dst_port;
                        tx_src_ip       <= source_ip_for_port(tx_port);
                        tx_dst_ip       <= destination_ip_for_port(tx_port);
                        frame_error     <= port_valid ? ERR_NONE : ERR_PORT;
                        state           <= tx_tlast ? ST_CHECK : ST_CAPTURE;
                    end
                end

                ST_CAPTURE: begin
                    if (input_fire) begin
                        if (payload_len < MAX_PAYLOAD_BYTES) begin
                            payload_mem[payload_len] <= tx_data;
                            payload_len <= payload_len + 1'b1;
                            if (tx_tlast) begin
                                state <= ST_CHECK;
                            end else if (payload_len == (MAX_PAYLOAD_BYTES - 1)) begin
                                state <= ST_DRAIN;
                            end
                        end else begin
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
                        state <= ST_IDLE;
                    end else if (payload_len == 0) begin
                        last_error <= ERR_SHORT;
                        state <= ST_IDLE;
                    end else begin
                        // SN is outside the IP/UDP lengths.
                        tx_base_len     <= 16'd42 + payload_len;
                        tx_ip_total_len <= 16'd28 + payload_len;
                        tx_udp_len      <= 16'd8 + payload_len;
                        tx_ip_checksum  <= ipv4_checksum(16'd28 + payload_len,
                                                         tx_src_ip, tx_dst_ip);
                        tx_frame_len    <= ((16'd43 + payload_len) < MIN_FRAME_BYTES) ?
                                           MIN_FRAME_BYTES : (16'd43 + payload_len);
                        state <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (bag_timer[tx_vl_index] == 0) begin
                        tx_sequence <= (sequence_mem[tx_vl_index] == 8'hFF) ?
                                       8'h01 : sequence_mem[tx_vl_index] + 1'b1;
                        sequence_mem[tx_vl_index] <=
                            (sequence_mem[tx_vl_index] == 8'hFF) ?
                            8'h01 : sequence_mem[tx_vl_index] + 1'b1;
                        build_offset <= 16'd0;
                        crc_a <= 32'hFFFF_FFFF;
                        crc_b <= 32'hFFFF_FFFF;
                        state <= ST_BUILD_DATA;
                    end
                end

                ST_BUILD_DATA: begin
                    frame_mem_a[build_offset] <= frame_byte_a;
                    frame_mem_b[build_offset] <= frame_byte_b;
                    crc_a <= crc_a_next;
                    crc_b <= crc_b_next;
                    if (build_offset == (tx_frame_len - 16'd1)) begin
                        fcs_a <= ~crc_a_next;
                        fcs_b <= ~crc_b_next;
                        fcs_count <= 2'd0;
                        state <= ST_BUILD_FCS;
                    end else begin
                        build_offset <= build_offset + 1'b1;
                    end
                end

                ST_BUILD_FCS: begin
                    frame_mem_a[tx_frame_len + fcs_count] <= fcs_byte_a;
                    frame_mem_b[tx_frame_len + fcs_count] <= fcs_byte_b;
                    if (fcs_count == 2'd3) begin
                        frame_len_with_fcs <= tx_frame_len + 16'd4;
                        // Do not publish before the previous frame's BAG has
                        // elapsed.  Building a long frame may consume the
                        // timer, while a short frame must wait here.
                        state <= ST_PUBLISH_WAIT;
                    end else begin
                        fcs_count <= fcs_count + 1'b1;
                    end
                end

                ST_PUBLISH_WAIT: begin
                    if (bag_timer[tx_vl_index] == 0) begin
                        frame_start_toggle <= ~frame_start_toggle;
                        if (BAG_CYCLES <= 1)
                            bag_timer[tx_vl_index] <= 32'd0;
                        else
                            bag_timer[tx_vl_index] <= BAG_CYCLES - 1;
                        state <= ST_TX_WAIT;
                    end
                end

                ST_TX_WAIT: begin
                    if ((done_a_sync != done_a_seen) &&
                        (done_b_sync != done_b_seen)) begin
                        done_a_seen <= done_a_sync;
                        done_b_seen <= done_b_sync;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
