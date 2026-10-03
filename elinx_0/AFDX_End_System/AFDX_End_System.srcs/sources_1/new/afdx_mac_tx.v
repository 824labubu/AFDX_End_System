`timescale 1 ps/1 ps

// Hand-written AFDX TX MAC.
//
// The former implementation used the vendor mac_100Mbps IP as a FIFO and
// therefore depended on an undocumented register_acc address map.  This
// module keeps the useful protocol behavior (AFDX partition/VL mapping,
// IPv4/UDP framing, SN and padding) but owns the complete TX path:
//
//   application clk domain: capture -> BAG -> build DA..SN in RAM
//   p0_txc clock domains : 7x55 + D5 -> frame bytes -> FCS -> IFG on GMII A/B
//
// Each p0_txc input is the corresponding GMII TX clock.  PHY MDIO
// configuration is outside this TX-only module.
module afdx_mac_tx #(
    parameter integer MAX_PAYLOAD_BYTES = 1471,
    parameter integer MIN_FRAME_BYTES   = 60,
    parameter integer BAG_CYCLES        = 50000,
    parameter integer IFG_CYCLES        = 12,
    parameter [31:0] DEST_MAC_PREFIX    = 32'h03_00_00_00,
    parameter [15:0] ES1_USER_ID        = 16'h01_01,
    parameter [15:0] ES2_USER_ID        = 16'h01_02,
    parameter [7:0]  PAD_BYTE           = 8'hAA,
    parameter [7:0]  SN_INIT            = 8'h01,
    parameter integer VL_COUNT          = 5,
    // The built-in legacy route table has five entries.  Keep its width
    // independent of VL_COUNT (which may be 128) so zero-extended table bits
    // cannot accidentally turn partition/flow 0 into a valid VL route.
    parameter integer ROUTE_COUNT       = 5,
    // Packed tables are indexed from the least-significant element.
    parameter [ROUTE_COUNT*8-1:0] ROUTE_PARTITION_TABLE = 40'h05_04_03_02_01,
    parameter [ROUTE_COUNT*8-1:0] ROUTE_FLOW_TABLE = {ROUTE_COUNT{8'd0}},
    parameter [ROUTE_COUNT*8-1:0] ROUTE_VL_INDEX_TABLE = 40'h04_03_02_01_00,
    parameter [VL_COUNT*16-1:0] VL_ID_TABLE = 80'h0005_0004_0003_0002_0001,
    parameter [VL_COUNT*32-1:0] VL_BAG_TABLE = {VL_COUNT{BAG_CYCLES}},
    parameter [VL_COUNT*16-1:0] VL_LMAX_TABLE = {VL_COUNT{16'd1518}},
    // A zero address uses the legacy address derived from the VL descriptor.
    parameter [VL_COUNT*48-1:0] VL_DEST_MAC_TABLE = {VL_COUNT{48'd0}},
    parameter [VL_COUNT*32-1:0] VL_DEST_IP_TABLE = {VL_COUNT{32'd0}}
)(
    input                         clk,
    input                         reset,
    input  [7:0]                  tx_data,
    input                         tx_valid,
    output reg                    tx_ready,
    input                         tx_tlast,
    input                         tx_sop,
    input  [15:0]                 tx_len,
    input  [7:0]                  tx_port, // partition ID
    input  [7:0]                  tx_flow,
    input                         tx_vl_index_valid,
    input  [7:0]                  tx_vl_index,
    input  [15:0]                 app_upd_src_port,
    input  [15:0]                 app_upd_dst_port,

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
    // High while the single capture/build/transmit slot is occupied.  This
    // is a status-only addition; legacy named-port instantiations may omit it.
    output                        tx_busy
);

    localparam integer MAX_FRAME_BYTES = MAX_PAYLOAD_BYTES + 64;

    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_CAPTURE    = 4'd1;
    localparam [3:0] ST_DRAIN      = 4'd2;
    localparam [3:0] ST_CHECK      = 4'd3;
    localparam [3:0] ST_WAIT       = 4'd4;
    localparam [3:0] ST_BUILD_DATA = 4'd5;
    localparam [3:0] ST_TX_WAIT    = 4'd6;
    localparam [3:0] ST_PUBLISH_WAIT = 4'd7;

    localparam [3:0] ERR_NONE  = 4'd0;
    localparam [3:0] ERR_PORT  = 4'd1;
    localparam [3:0] ERR_LONG  = 4'd2;
    localparam [3:0] ERR_SHORT = 4'd3;
    localparam [3:0] ERR_SOP   = 4'd4;
    localparam [3:0] ERR_LEN   = 4'd5;
    localparam [3:0] ERR_LMAX  = 4'd6;

    reg [3:0]  state;
    reg [7:0]  payload_mem [0:MAX_PAYLOAD_BYTES-1];
    reg [7:0]  payload_read_data;
    reg [7:0]  frame_mem_a [0:MAX_FRAME_BYTES-1];
    reg [7:0]  frame_mem_b [0:MAX_FRAME_BYTES-1];
    reg [15:0] payload_len;
    reg [15:0] expected_len;
    reg [15:0] tx_base_len;
    reg [15:0] tx_frame_len;
    reg [15:0] build_offset;
    reg [3:0]  frame_error;
    reg [3:0]  last_error;

    reg [7:0]  frame_vl_index;
    reg [47:0] tx_dst_mac;
    reg [15:0] tx_lmax;
    reg [31:0] tx_bag_cycles;
    reg [7:0]  tx_sequence;
    reg [31:0] bag_timer [0:VL_COUNT-1];
    reg [7:0]  sequence_mem [0:VL_COUNT-1];
    // IPv4 Identification is maintained per VL, just like the AFDX SN.  A
    // fragmented QUE datagram would share one ID across its fragments; this
    // non-fragmenting path advances once for each accepted payload frame.
    reg [15:0] ip_id_mem [0:VL_COUNT-1];
    reg [15:0] tx_ip_identification;

    reg [15:0] tx_src_udp;
    reg [15:0] tx_dst_udp;
    reg [15:0] tx_udp_len;
    reg [15:0] tx_ip_total_len;
    reg [15:0] tx_ip_checksum;
    reg [31:0] tx_src_ip;
    reg [31:0] tx_dst_ip;


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
    wire        input_fire;
    wire        payload_write;
    wire [15:0] payload_write_addr;
    wire        payload_prefetch;
    wire [15:0] payload_read_addr;
    reg         route_valid;
    reg [7:0]   route_vl_index;
    wire        selected_vl_valid;
    wire [7:0]  selected_vl_index;
    integer     route_scan;
    wire [15:0] frame_addr_a;
    wire [15:0] frame_addr_b;
    reg  [7:0]  frame_data_a;
    reg  [7:0]  frame_data_b;

    assign input_fire = tx_valid && tx_ready;
    // A synchronous read port lets the capture array infer a block RAM.
    // Read byte zero while the preceding UDP-header byte is being built;
    // thereafter each cycle fetches the payload byte for the next cycle.
    assign payload_write = reset && input_fire &&
                           (((state == ST_IDLE) && tx_sop) ||
                            ((state == ST_CAPTURE) && !tx_sop &&
                             (payload_len < MAX_PAYLOAD_BYTES)));
    assign payload_write_addr = (state == ST_IDLE) ? 16'd0 : payload_len;
    assign payload_prefetch = reset && (state == ST_BUILD_DATA) &&
                              (build_offset >= 16'd41) &&
                              (build_offset < (tx_base_len - 16'd1));
    assign payload_read_addr = build_offset - 16'd41;

    always @(posedge clk) begin
        if (payload_write)
            payload_mem[payload_write_addr] <= tx_data;
        if (payload_prefetch)
            payload_read_data <= payload_mem[payload_read_addr];
    end
    assign selected_vl_valid = tx_vl_index_valid ?
                               (tx_vl_index < VL_COUNT) : route_valid;
    // Keep table/RAM indexes in range even when an invalid explicit VL is
    // presented.  The validity bit still rejects that frame in ST_CHECK.
    assign selected_vl_index = (tx_vl_index_valid && (tx_vl_index < VL_COUNT)) ?
                               tx_vl_index : route_vl_index;

    always @(*) begin
        route_valid = 1'b0;
        route_vl_index = 8'd0;
        for (route_scan = 0; route_scan < ROUTE_COUNT; route_scan = route_scan + 1) begin
            if (!route_valid &&
                (tx_port == ROUTE_PARTITION_TABLE[route_scan*8 +: 8]) &&
                (tx_flow == ROUTE_FLOW_TABLE[route_scan*8 +: 8]) &&
                (ROUTE_VL_INDEX_TABLE[route_scan*8 +: 8] < VL_COUNT)) begin
                route_valid = 1'b1;
                route_vl_index = ROUTE_VL_INDEX_TABLE[route_scan*8 +: 8];
            end
        end
    end

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

    assign p0_gtxc_a = p0_txc_a;
    assign p0_gtxc_b = p0_txc_b;
    assign mdc_a = 1'b0;
    assign mdc_b = 1'b0;
    assign mdio_a = 1'bz;
    assign mdio_b = 1'bz;
    assign phy_rstb0_a = reset;
    assign phy_rstb0_b = reset;

    // The legacy register response outputs are fixed compatibility signals.
    assign reg_data_out_a = 32'h0000_0000;
    assign reg_data_out_b = 32'h0000_0000;
    assign reg_acc_bsy_a  = 1'b0;
    assign reg_acc_bsy_b  = 1'b0;
    assign tx_busy        = (state != ST_IDLE);

    afdx_gmii_tx #(
        .IFG_CYCLES(IFG_CYCLES)
    ) gmii_tx_a (
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

    afdx_gmii_tx #(
        .IFG_CYCLES(IFG_CYCLES)
        ) gmii_tx_b (
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

    // The capture buffer is deliberately single-frame.  It accepts the
    // remaining bytes of an overlength frame in ST_DRAIN so tlast still marks
    // a clean boundary for the next frame.
    always @(*) begin
        tx_ready = 1'b0;
        if (reset && ((state == ST_IDLE) || (state == ST_CAPTURE) ||
                      (state == ST_DRAIN)))
            tx_ready = 1'b1;
    end

    function [31:0] source_ip_for_partition;
        input [7:0] partition_id;
        begin
            source_ip_for_partition = {8'h0A, ES1_USER_ID, partition_id};
        end
    endfunction

    function [31:0] default_destination_ip;
        input [7:0] vl_index;
        input [15:0] vl_id;
        begin
            if (vl_index == 8'd0)
                default_destination_ip = {16'hF4F4, vl_id};
            else
                default_destination_ip = {8'h0A, ES2_USER_ID, (vl_index + 8'd1)};
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
        input [47:0] mac;
        input [2:0]  index;
        begin
            case (index)
                3'd0: destination_byte = mac[47:40];
                3'd1: destination_byte = mac[39:32];
                3'd2: destination_byte = mac[31:24];
                3'd3: destination_byte = mac[23:16];
                3'd4: destination_byte = mac[15:8];
                default: destination_byte = mac[7:0];
            endcase
        end
    endfunction

    function [15:0] ipv4_checksum;
        input [15:0] total_length;
        input [15:0] identification;
        input [31:0] source_ip;
        input [31:0] destination_ip;
        reg [31:0] sum;
        begin
            sum = 32'd0;
            sum = sum + 16'h4500;
            sum = sum + total_length;
            sum = sum + identification;
            sum = sum + 16'h4000;
            sum = sum + 16'h0111;
            sum = sum + source_ip[31:16] + source_ip[15:0];
            sum = sum + destination_ip[31:16] + destination_ip[15:0];
            sum = sum[15:0] + sum[31:16];
            sum = sum[15:0] + sum[31:16];
            ipv4_checksum = ~sum[15:0];
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
                frame_byte_a = destination_byte(tx_dst_mac, build_offset[2:0]);
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
                    5'd4:  frame_byte_a = tx_ip_identification[15:8];
                    5'd5:  frame_byte_a = tx_ip_identification[7:0];
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
                frame_byte_a = payload_read_data;
                frame_byte_b = frame_byte_a;
            end else if (build_offset == (tx_frame_len - 16'd1)) begin
                frame_byte_a = tx_sequence;
                frame_byte_b = tx_sequence;
            end
        end
    end

    integer i;
    always @(posedge clk or negedge reset) begin
        if (!reset) begin
            state              <= ST_IDLE;
            payload_len        <= 16'd0;
            expected_len       <= 16'd0;
            tx_base_len        <= 16'd0;
            tx_frame_len       <= 16'd0;
            build_offset       <= 16'd0;
            frame_error        <= ERR_NONE;
            last_error         <= ERR_NONE;
            frame_vl_index     <= 8'd0;
            tx_dst_mac         <= 48'd0;
            tx_lmax            <= 16'd0;
            tx_bag_cycles      <= 32'd0;
            tx_sequence        <= 8'd0;
            tx_ip_identification <= 16'd0;
            tx_src_udp         <= 16'd0;
            tx_dst_udp         <= 16'd0;
            tx_udp_len         <= 16'd0;
            tx_ip_total_len    <= 16'd0;
            tx_ip_checksum     <= 16'd0;
            tx_src_ip          <= 32'd0;
            tx_dst_ip          <= 32'd0;
            frame_start_toggle <= 1'b0;
            done_a_meta        <= 1'b0;
            done_a_sync        <= 1'b0;
            done_b_meta        <= 1'b0;
            done_b_sync        <= 1'b0;
            done_a_seen        <= 1'b0;
            done_b_seen        <= 1'b0;
            for (i = 0; i < VL_COUNT; i = i + 1) begin
                bag_timer[i]    <= 32'd0;
                sequence_mem[i] <= SN_INIT - 1'b1;
                ip_id_mem[i]    <= 16'd0;
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
                        if (!tx_sop) begin
                            frame_error <= ERR_SOP;
                            state <= tx_tlast ? ST_IDLE : ST_DRAIN;
                        end else begin
                            payload_len     <= 16'd1;
                            expected_len    <= tx_len;
                            frame_vl_index  <= selected_vl_index;
                            tx_dst_mac      <=
                                (VL_DEST_MAC_TABLE[selected_vl_index*48 +: 48] != 0) ?
                                VL_DEST_MAC_TABLE[selected_vl_index*48 +: 48] :
                                {DEST_MAC_PREFIX, VL_ID_TABLE[selected_vl_index*16 +: 16]};
                            tx_dst_ip       <=
                                (VL_DEST_IP_TABLE[selected_vl_index*32 +: 32] != 0) ?
                                VL_DEST_IP_TABLE[selected_vl_index*32 +: 32] :
                                default_destination_ip(selected_vl_index,
                                    VL_ID_TABLE[selected_vl_index*16 +: 16]);
                            tx_bag_cycles   <= VL_BAG_TABLE[selected_vl_index*32 +: 32];
                            tx_lmax         <= VL_LMAX_TABLE[selected_vl_index*16 +: 16];
                            tx_src_udp      <= app_upd_src_port;
                            tx_dst_udp      <= app_upd_dst_port;
                            tx_src_ip       <= source_ip_for_partition(tx_port);
                            if (!selected_vl_valid ||
                                (VL_ID_TABLE[selected_vl_index*16 +: 16] == 0))
                                frame_error <= ERR_PORT;
                            else if ((tx_len == 0) || (tx_len > MAX_PAYLOAD_BYTES))
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
                    end else if (payload_len != expected_len) begin
                        last_error <= ERR_LEN;
                        state <= ST_IDLE;
                    end else if (((((16'd43 + payload_len) < MIN_FRAME_BYTES) ?
                                   MIN_FRAME_BYTES : (16'd43 + payload_len)) + 16'd4)
                                 > tx_lmax) begin
                        last_error <= ERR_LMAX;
                        state <= ST_IDLE;
                    end else begin
                        // SN is outside the IP/UDP lengths.
                        tx_base_len     <= 16'd42 + payload_len;
                        tx_ip_total_len <= 16'd28 + payload_len;
                        tx_udp_len      <= 16'd8 + payload_len;
                        tx_ip_checksum  <= ipv4_checksum(16'd28 + payload_len,
                                                         ip_id_mem[frame_vl_index],
                                                         tx_src_ip, tx_dst_ip);
                        tx_frame_len    <= ((16'd43 + payload_len) < MIN_FRAME_BYTES) ?
                                           MIN_FRAME_BYTES : (16'd43 + payload_len);
                        state <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (bag_timer[frame_vl_index] == 0) begin
                        tx_ip_identification <= ip_id_mem[frame_vl_index];
                        ip_id_mem[frame_vl_index] <=
                            ip_id_mem[frame_vl_index] + 16'd1;
                        tx_sequence <= (sequence_mem[frame_vl_index] == 8'hFF) ?
                                       8'h01 : sequence_mem[frame_vl_index] + 1'b1;
                        sequence_mem[frame_vl_index] <=
                            (sequence_mem[frame_vl_index] == 8'hFF) ?
                            8'h01 : sequence_mem[frame_vl_index] + 1'b1;
                        build_offset <= 16'd0;
                        state <= ST_BUILD_DATA;
                    end
                end

                ST_BUILD_DATA: begin
                    frame_mem_a[build_offset] <= frame_byte_a;
                    frame_mem_b[build_offset] <= frame_byte_b;
                    if (build_offset == (tx_frame_len - 16'd1)) begin
                        // The GMII serializers append their own FCS bytes.
                        state <= ST_PUBLISH_WAIT;
                    end else begin
                        build_offset <= build_offset + 1'b1;
                    end
                end

                ST_PUBLISH_WAIT: begin
                    if (bag_timer[frame_vl_index] == 0) begin
                        frame_start_toggle <= ~frame_start_toggle;
                        if (tx_bag_cycles <= 1)
                            bag_timer[frame_vl_index] <= 32'd0;
                        else
                            bag_timer[frame_vl_index] <= tx_bag_cycles - 1'b1;
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
