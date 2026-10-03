`timescale 1 ps/1 ps

// Unified AFDX transmit descriptor scheduler.
//
// tx_port/tx_flow select one of ten enabled VL slots in the 128-VL index
// space. Each slot has one completed-packet buffer in a shared, synchronous
// payload RAM. The scheduler considers all ten slots together, using strict
// priority (smaller number wins), round robin within a priority, and per-VL
// BAG eligibility. A QUE datagram owns the GMII outputs through all of its
// fragments; fragment-level preemption is not implemented in this version.
module AFDX_TX #(
    parameter [15:0] ES1_USER_ID = 16'h01_01,
    parameter [15:0] ES2_USER_ID = 16'h01_02,
    parameter integer MAX_PAYLOAD_BYTES = 1471,
    parameter integer QUE_MAX_PAYLOAD_BYTES = 8192,
    parameter integer MIN_FRAME_BYTES = 60,
    parameter integer BAG_CYCLES = 50000,
    parameter integer QUE_BAG_CYCLES = BAG_CYCLES,
    parameter integer IFG_CYCLES = 12,
    parameter [7:0] PAD_BYTE = 8'hAA,
    parameter [7:0] SN_INIT = 8'h01,
    // Packed table index 0 occupies the least significant slice.
    parameter [79:0] VL_PRIORITY_TABLE = {10{8'd0}},
    parameter [319:0] VL_BAG_TABLE = {
        {6{BAG_CYCLES}}, {2{QUE_BAG_CYCLES}}, {2{BAG_CYCLES}}
    },
    parameter [159:0] VL_LMAX_TABLE = {10{16'd1518}}
) (
    input                         clk,
    input                         reset,       // active-low
    input  [7:0]                  tx_data,
    input                         tx_valid,
    output reg                    tx_ready,
    input                         tx_tlast,
    input  [7:0]                  tx_port,
    input                         tx_sop,
    input  [15:0]                 tx_len,
    input  [15:0]                 app_upd_src_port,
    input  [15:0]                 app_upd_dst_port,

    output                        mdc_a,
    inout                         mdio_a,
    output                        phy_rstb0_a,
    output                        p0_gtxc_a,
    output [7:0]                  p0_txd_a,
    output                        p0_txen_a,
    output                        p0_txer_a,
    output [31:0]                 reg_data_out_a,
    output                        reg_acc_bsy_a,
    output                        mdc_b,
    inout                         mdio_b,
    output                        phy_rstb0_b,
    output                        p0_gtxc_b,
    output [7:0]                  p0_txd_b,
    output                        p0_txen_b,
    output                        p0_txer_b,
    output [31:0]                 reg_data_out_b,
    output                        reg_acc_bsy_b,
    output                        queue_overflow,
    output                        queue_error_valid,
    output [3:0]                  queue_error_code,
    output                        queue_busy,
    input  [7:0]                  tx_flow
);
    localparam [1:0] ING_IDLE = 2'd0;
    localparam [1:0] ING_CAPTURE = 2'd1;
    localparam [1:0] ING_DRAIN = 2'd2;
    localparam [1:0] SCH_IDLE = 2'd0;
    localparam [1:0] SCH_STREAM = 2'd1;
    localparam [1:0] SCH_WAIT_ENGINE = 2'd2;
    // Match afdx_mac_que_tx's externally visible error encoding.
    localparam [3:0] ERR_LONG = 4'd1;
    localparam [3:0] ERR_SOP = 4'd3;
    localparam [3:0] ERR_LEN = 4'd4;
    localparam [3:0] ERR_LMAX = 4'd5;
    localparam [3:0] ERR_PORT = 4'd7;
    localparam integer TOTAL_PAYLOAD_BYTES =
        8*MAX_PAYLOAD_BYTES + 2*QUE_MAX_PAYLOAD_BYTES;

    // Logical indices 0..9 are enabled; 10..127 remain reserved. There is
    // one physical slot per enabled VL, rather than 128 maximum-size slots.
    localparam [127:0] LINK_STATUS =
        {{118{1'b0}}, {10{1'b1}}};
    wire [7:0] tx_flow_eff =
        ((^tx_flow) === 1'bx) ? 8'd0 : tx_flow;
    reg route_valid;
    reg [3:0] route_slot;
    always @(*) begin
        route_valid = 1'b1;
        route_slot = 4'd0;
        if (tx_flow_eff > 8'd1) begin
            route_valid = 1'b0;
        end else begin
            case (tx_port)
                8'd1: route_slot = {3'd0, tx_flow_eff[0]};
                8'd2: route_slot = {3'd1, tx_flow_eff[0]};
                8'd3: route_slot = {3'd2, tx_flow_eff[0]};
                8'd4: route_slot = {3'd3, tx_flow_eff[0]};
                8'd5: route_slot = {3'd4, tx_flow_eff[0]};
                default: route_valid = 1'b0;
            endcase
        end
    end

    function [16:0] slot_base;
        input [3:0] slot;
        begin
            case (slot)
                4'd0: slot_base = 0;
                4'd1: slot_base = MAX_PAYLOAD_BYTES;
                4'd2: slot_base = 2*MAX_PAYLOAD_BYTES;
                4'd3: slot_base = 2*MAX_PAYLOAD_BYTES +
                                   QUE_MAX_PAYLOAD_BYTES;
                default: slot_base = 2*MAX_PAYLOAD_BYTES +
                    2*QUE_MAX_PAYLOAD_BYTES +
                    (slot - 4'd4)*MAX_PAYLOAD_BYTES;
            endcase
        end
    endfunction

    function [15:0] slot_capacity;
        input [3:0] slot;
        begin
            if ((slot == 4'd2) || (slot == 4'd3))
                slot_capacity = QUE_MAX_PAYLOAD_BYTES;
            else
                slot_capacity = MAX_PAYLOAD_BYTES;
        end
    endfunction

    function [7:0] slot_port;
        input [3:0] slot;
        begin
            slot_port = (slot >> 1) + 8'd1;
        end
    endfunction

    // LMAX counts Ethernet destination MAC through FCS. Each QUE fragment
    // is checked separately, with its non-final IP payload aligned to 8 B.
    function frame_fits_lmax;
        input [15:0] payload_bytes;
        input [3:0] slot;
        reg [31:0] remaining;
        reg [31:0] fragment_bytes;
        reg [31:0] frame_bytes;
        reg [31:0] maximum_frame;
        integer f;
        begin
            maximum_frame = 0;
            if ((slot == 4'd2) || (slot == 4'd3)) begin
                remaining = payload_bytes + 32'd8; // UDP header
                for (f = 0;
                     f < ((QUE_MAX_PAYLOAD_BYTES + 8 + 1471)/1472 + 1);
                     f = f + 1) begin
                    if (remaining != 0) begin
                        if (remaining > 32'd1479) begin
                            fragment_bytes = 32'd1472;
                            remaining = remaining - 32'd1472;
                        end else begin
                            fragment_bytes = remaining;
                            remaining = 0;
                        end
                        frame_bytes = 32'd35 + fragment_bytes;
                        if (frame_bytes < MIN_FRAME_BYTES)
                            frame_bytes = MIN_FRAME_BYTES;
                        frame_bytes = frame_bytes + 32'd4;
                        if (frame_bytes > maximum_frame)
                            maximum_frame = frame_bytes;
                    end
                end
            end else begin
                maximum_frame = 32'd43 + payload_bytes;
                if (maximum_frame < MIN_FRAME_BYTES)
                    maximum_frame = MIN_FRAME_BYTES;
                maximum_frame = maximum_frame + 32'd4;
            end
            frame_fits_lmax =
                maximum_frame <= VL_LMAX_TABLE[slot*16 +: 16];
        end
    endfunction

    // A one-write, one-registered-read payload memory. Every beat is written
    // once into its VL slot; no single-cycle whole-frame copy is required.
    reg [7:0] payload_mem [0:TOTAL_PAYLOAD_BYTES-1];
    reg [7:0] read_byte;
    reg        mem_write_enable;
    reg [16:0] mem_write_addr;
    reg        mem_read_enable;
    reg [16:0] mem_read_addr;
    always @(posedge clk) begin
        if (mem_write_enable)
            payload_mem[mem_write_addr] <= tx_data;
        if (mem_read_enable)
            read_byte <= payload_mem[mem_read_addr];
    end

    reg [1:0] ingress_state;
    reg [3:0] ingress_slot;
    reg [15:0] ingress_count;
    reg [15:0] ingress_expected_len;
    reg [15:0] ingress_src_udp;
    reg [15:0] ingress_dst_udp;
    reg [15:0] slot_len [0:9];
    reg [15:0] slot_src_udp [0:9];
    reg [15:0] slot_dst_udp [0:9];
    reg [9:0] pending;
    reg [9:0] active_slot_mask;
    reg [31:0] bag_timer [0:9];
    reg [3:0] rr_next;
    reg queue_overflow_reg;
    reg queue_error_pulse;
    reg [3:0] queue_error_reg;
    wire input_fire = tx_valid && tx_ready;
    wire ingress_queue_route = route_valid &&
        ((route_slot == 4'd2) || (route_slot == 4'd3));
    wire ingress_queue_request = (tx_port == 8'd2);
    wire ingress_que_active =
        (ingress_state != ING_IDLE) &&
        ((ingress_slot == 4'd2) || (ingress_slot == 4'd3));

    always @(*) begin
        tx_ready = 1'b0;
        if (reset) begin
            case (ingress_state)
                ING_IDLE:
                    tx_ready = !route_valid ||
                        (!pending[route_slot] &&
                         !active_slot_mask[route_slot]);
                ING_CAPTURE, ING_DRAIN: tx_ready = 1'b1;
                default: tx_ready = 1'b0;
            endcase
        end
    end

    always @(*) begin
        mem_write_enable = 1'b0;
        mem_write_addr = 17'd0;
        if (reset && input_fire) begin
            if ((ingress_state == ING_IDLE) && route_valid && tx_sop &&
                (tx_len != 0) && (tx_len <= slot_capacity(route_slot))) begin
                mem_write_enable = 1'b1;
                mem_write_addr = slot_base(route_slot);
            end else if ((ingress_state == ING_CAPTURE) && !tx_sop &&
                         (ingress_count < slot_capacity(ingress_slot))) begin
                mem_write_enable = 1'b1;
                mem_write_addr = slot_base(ingress_slot) + ingress_count;
            end
        end
    end

    // One scan over ten enabled descriptors. The cyclic scan order supplies
    // round robin tie breaking; a lower priority number always wins.
    reg select_valid;
    reg [3:0] select_slot;
    reg [7:0] select_priority;
    integer scan;
    integer candidate;
    reg candidate_ready;
    wire [1:0] que_vl_bag_ready;
    always @(*) begin
        select_valid = 1'b0;
        select_slot = 4'd0;
        select_priority = 8'hFF;
        candidate = 0;
        candidate_ready = 1'b0;
        for (scan = 0; scan < 10; scan = scan + 1) begin
            candidate = rr_next + scan;
            if (candidate >= 10)
                candidate = candidate - 10;
            candidate_ready = pending[candidate] &&
                LINK_STATUS[candidate] &&
                (bag_timer[candidate] == 0);
            if (candidate == 2)
                candidate_ready = candidate_ready &&
                                  que_vl_bag_ready[0];
            if (candidate == 3)
                candidate_ready = candidate_ready &&
                                  que_vl_bag_ready[1];
            if (candidate_ready &&
                (!select_valid ||
                 (VL_PRIORITY_TABLE[candidate*8 +: 8] <
                  select_priority))) begin
                select_valid = 1'b1;
                select_slot = candidate[3:0];
                select_priority =
                    VL_PRIORITY_TABLE[candidate*8 +: 8];
            end
        end
    end

    reg [1:0] sched_state;
    reg [3:0] dispatch_slot;
    reg dispatch_queue;
    reg [15:0] dispatch_len;
    reg [15:0] dispatch_index;
    reg [15:0] dispatch_src_udp;
    reg [15:0] dispatch_dst_udp;
    wire stream_valid = (sched_state == SCH_STREAM);
    wire stream_sop = stream_valid && (dispatch_index == 0);
    wire stream_last = stream_valid &&
        (dispatch_index == (dispatch_len - 1'b1));
    wire nonq_valid = stream_valid && !dispatch_queue;
    // The QUE MAC treats valid while not ready as an overflow attempt.
    // Its input sees a beat only when the scheduler has a real handshake.
    wire que_valid = stream_valid && dispatch_queue && que_ready;
    wire nonq_ready;
    wire que_ready;
    wire nonq_busy;
    wire que_busy_i;
    wire dispatch_ready = dispatch_queue ? que_ready : nonq_ready;
    wire dispatch_busy = dispatch_queue ? que_busy_i : nonq_busy;
    wire stream_fire = stream_valid && dispatch_ready;

    always @(*) begin
        mem_read_enable = 1'b0;
        mem_read_addr = 17'd0;
        if (reset) begin
            if ((sched_state == SCH_IDLE) && select_valid) begin
                mem_read_enable = 1'b1;
                mem_read_addr = slot_base(select_slot);
            end else if ((sched_state == SCH_STREAM) && stream_fire &&
                         !stream_last) begin
                mem_read_enable = 1'b1;
                mem_read_addr =
                    slot_base(dispatch_slot) + dispatch_index + 17'd1;
            end
        end
    end

    wire nonq_mdc_a, nonq_phy_a, nonq_gtxc_a, nonq_txen_a, nonq_txer_a;
    wire [7:0] nonq_txd_a;
    wire [31:0] nonq_reg_a;
    wire nonq_acc_a, nonq_mdio_a;
    wire nonq_mdc_b, nonq_phy_b, nonq_gtxc_b, nonq_txen_b, nonq_txer_b;
    wire [7:0] nonq_txd_b;
    wire [31:0] nonq_reg_b;
    wire nonq_acc_b, nonq_mdio_b;
    wire que_mdc_a, que_phy_a, que_gtxc_a, que_txen_a, que_txer_a;
    wire [7:0] que_txd_a;
    wire [31:0] que_reg_a;
    wire que_acc_a, que_mdio_a;
    wire que_mdc_b, que_phy_b, que_gtxc_b, que_txen_b, que_txer_b;
    wire [7:0] que_txd_b;
    wire [31:0] que_reg_b;
    wire que_acc_b, que_mdio_b;
    wire que_overflow_i, que_error_valid_i;
    wire [3:0] que_error_code_i;

    // Disable the non-QUE MAC's private BAG gate: the scheduler owns its
    // per-VL eligibility. The QUE engine retains BAG between IP fragments;
    // its readiness bits are included in the scheduler's eligibility check.
    afdx_mac_tx #(
        .MAX_PAYLOAD_BYTES(MAX_PAYLOAD_BYTES),
        .MIN_FRAME_BYTES(MIN_FRAME_BYTES),
        .BAG_CYCLES(1),
        .IFG_CYCLES(IFG_CYCLES),
        .PAD_BYTE(PAD_BYTE),
        .SN_INIT(SN_INIT),
        .ES1_USER_ID(ES1_USER_ID),
        .ES2_USER_ID(ES2_USER_ID),
        .VL_COUNT(10),
        .ROUTE_COUNT(10),
        .ROUTE_PARTITION_TABLE(
            {8'd5,8'd5,8'd4,8'd4,8'd3,8'd3,8'd2,8'd2,8'd1,8'd1}),
        .ROUTE_FLOW_TABLE(
            {8'd1,8'd0,8'd1,8'd0,8'd1,8'd0,8'd1,8'd0,8'd1,8'd0}),
        .ROUTE_VL_INDEX_TABLE(
            {8'd9,8'd8,8'd7,8'd6,8'd5,8'd4,8'd3,8'd2,8'd1,8'd0}),
        .VL_ID_TABLE(
            {16'd10,16'd9,16'd8,16'd7,16'd6,
             16'd5,16'd4,16'd3,16'd2,16'd1}),
        .VL_BAG_TABLE({10{32'd1}}),
        .VL_LMAX_TABLE(VL_LMAX_TABLE),
        .VL_DEST_MAC_TABLE(
            {48'h03000000000A,48'h030000000009,
             48'h030000000008,48'h030000000007,
             48'h030000000006,48'h030000000005,
             48'h030000000004,48'h030000000003,
             48'h030000000002,48'h030000000001}),
        .VL_DEST_IP_TABLE(
            {32'h0A010205,32'h0A010205,
             32'h0A010204,32'h0A010204,
             32'h0A010203,32'h0A010203,
             32'h0A010202,32'h0A010202,
             32'hF4F40002,32'hF4F40001})
    ) u_non_queue_mac (
        .clk(clk), .reset(reset),
        .tx_data(read_byte), .tx_valid(nonq_valid),
        .tx_ready(nonq_ready), .tx_tlast(stream_last),
        .tx_sop(stream_sop), .tx_len(dispatch_len),
        .tx_port(slot_port(dispatch_slot)),
        .tx_flow({7'd0, dispatch_slot[0]}),
        .tx_vl_index_valid(1'b1),
        .tx_vl_index({4'd0, dispatch_slot}),
        .app_upd_src_port(dispatch_src_udp),
        .app_upd_dst_port(dispatch_dst_udp),
        .mdc_a(nonq_mdc_a), .mdio_a(nonq_mdio_a),
        .phy_rstb0_a(nonq_phy_a), .p0_txc_a(clk),
        .p0_gtxc_a(nonq_gtxc_a), .p0_txd_a(nonq_txd_a),
        .p0_txen_a(nonq_txen_a), .p0_txer_a(nonq_txer_a),
        .reg_data_out_a(nonq_reg_a), .reg_acc_bsy_a(nonq_acc_a),
        .mdc_b(nonq_mdc_b), .mdio_b(nonq_mdio_b),
        .phy_rstb0_b(nonq_phy_b), .p0_txc_b(clk),
        .p0_gtxc_b(nonq_gtxc_b), .p0_txd_b(nonq_txd_b),
        .p0_txen_b(nonq_txen_b), .p0_txer_b(nonq_txer_b),
        .reg_data_out_b(nonq_reg_b), .reg_acc_bsy_b(nonq_acc_b),
        .tx_busy(nonq_busy)
    );

    localparam [31:0] QUE_SRC_IP = {8'h0A, ES1_USER_ID, 8'd2};
    localparam [31:0] QUE_DST_IP = {8'h0A, ES2_USER_ID, 8'd2};
    localparam [47:0] QUE_SRC_MAC_A =
        {24'h02_00_00, ES1_USER_ID, 8'h20};
    localparam [47:0] QUE_SRC_MAC_B =
        {24'h02_00_00, ES1_USER_ID, 8'h40};
    wire [47:0] que_dst_mac =
        (dispatch_slot == 4'd3) ?
        48'h030000000004 : 48'h030000000003;
    afdx_mac_que_tx #(
        .MAX_PAYLOAD_BYTES(QUE_MAX_PAYLOAD_BYTES),
        .MIN_FRAME_BYTES(MIN_FRAME_BYTES),
        .IFG_CYCLES(IFG_CYCLES),
        .ES1_USER_ID(ES1_USER_ID),
        .ES2_USER_ID(ES2_USER_ID),
        .PAD_BYTE(PAD_BYTE),
        .SN_INIT(SN_INIT)
    ) u_queue_mac (
        .clk(clk), .reset(reset),
        .tx_data(read_byte), .tx_valid(que_valid),
        .tx_ready(que_ready), .tx_tlast(stream_last),
        .tx_sop(stream_sop), .tx_len(dispatch_len),
        .tx_vl_index({4'd0, dispatch_slot}),
        .app_upd_src_port(dispatch_src_udp),
        .app_upd_dst_port(dispatch_dst_udp),
        .src_ip(QUE_SRC_IP), .dst_ip(QUE_DST_IP),
        .src_mac_a(QUE_SRC_MAC_A), .dst_mac(que_dst_mac),
        .src_mac_b(QUE_SRC_MAC_B),
        .bag_cycles_timer(VL_BAG_TABLE[dispatch_slot*32 +: 24]),
        .vl_lmax(VL_LMAX_TABLE[dispatch_slot*16 +: 16]),
        .mdc_a(que_mdc_a), .mdio_a(que_mdio_a),
        .phy_rstb0_a(que_phy_a), .p0_txc_a(clk),
        .p0_gtxc_a(que_gtxc_a), .p0_txd_a(que_txd_a),
        .p0_txen_a(que_txen_a), .p0_txer_a(que_txer_a),
        .reg_data_out_a(que_reg_a), .reg_acc_bsy_a(que_acc_a),
        .mdc_b(que_mdc_b), .mdio_b(que_mdio_b),
        .phy_rstb0_b(que_phy_b), .p0_txc_b(clk),
        .p0_gtxc_b(que_gtxc_b), .p0_txd_b(que_txd_b),
        .p0_txen_b(que_txen_b), .p0_txer_b(que_txer_b),
        .reg_data_out_b(que_reg_b), .reg_acc_bsy_b(que_acc_b),
        .tx_overflow(que_overflow_i),
        .tx_error_valid(que_error_valid_i),
        .tx_error_code(que_error_code_i),
        .tx_busy(que_busy_i),
        .vl_bag_ready(que_vl_bag_ready)
    );

    // Ownership starts when a complete descriptor is selected, and is held
    // until the selected engine has finished both redundant transmissions.
    wire owner_queue = (sched_state != SCH_IDLE) && dispatch_queue;
    assign mdc_a = owner_queue ? que_mdc_a : nonq_mdc_a;
    assign mdio_a = owner_queue ? que_mdio_a : nonq_mdio_a;
    assign phy_rstb0_a = owner_queue ? que_phy_a : nonq_phy_a;
    assign p0_gtxc_a = owner_queue ? que_gtxc_a : nonq_gtxc_a;
    assign p0_txd_a = owner_queue ? que_txd_a : nonq_txd_a;
    assign p0_txen_a = owner_queue ? que_txen_a : nonq_txen_a;
    assign p0_txer_a = owner_queue ? que_txer_a : nonq_txer_a;
    assign reg_data_out_a = owner_queue ? que_reg_a : nonq_reg_a;
    assign reg_acc_bsy_a = owner_queue ? que_acc_a : nonq_acc_a;
    assign mdc_b = owner_queue ? que_mdc_b : nonq_mdc_b;
    assign mdio_b = owner_queue ? que_mdio_b : nonq_mdio_b;
    assign phy_rstb0_b = owner_queue ? que_phy_b : nonq_phy_b;
    assign p0_gtxc_b = owner_queue ? que_gtxc_b : nonq_gtxc_b;
    assign p0_txd_b = owner_queue ? que_txd_b : nonq_txd_b;
    assign p0_txen_b = owner_queue ? que_txen_b : nonq_txen_b;
    assign p0_txer_b = owner_queue ? que_txer_b : nonq_txer_b;
    assign reg_data_out_b = owner_queue ? que_reg_b : nonq_reg_b;
    assign reg_acc_bsy_b = owner_queue ? que_acc_b : nonq_acc_b;

    assign queue_overflow = queue_overflow_reg | que_overflow_i;
    assign queue_error_valid = queue_error_pulse | que_error_valid_i;
    assign queue_error_code =
        queue_error_pulse ? queue_error_reg : que_error_code_i;
    assign queue_busy = pending[2] | pending[3] |
                        active_slot_mask[2] | active_slot_mask[3] |
                        ingress_que_active | que_busy_i;

    reg previous_txen_a;
    wire frame_wire_start =
        (sched_state != SCH_IDLE) &&
        p0_txen_a && !previous_txen_a;
    integer i;
    always @(posedge clk or negedge reset) begin
        if (!reset) begin
            ingress_state <= ING_IDLE;
            ingress_slot <= 4'd0;
            ingress_count <= 16'd0;
            ingress_expected_len <= 16'd0;
            ingress_src_udp <= 16'd0;
            ingress_dst_udp <= 16'd0;
            sched_state <= SCH_IDLE;
            dispatch_slot <= 4'd0;
            dispatch_queue <= 1'b0;
            dispatch_len <= 16'd0;
            dispatch_index <= 16'd0;
            dispatch_src_udp <= 16'd0;
            dispatch_dst_udp <= 16'd0;
            pending <= 10'd0;
            active_slot_mask <= 10'd0;
            rr_next <= 4'd0;
            previous_txen_a <= 1'b0;
            queue_overflow_reg <= 1'b0;
            queue_error_pulse <= 1'b0;
            queue_error_reg <= 4'd0;
            for (i = 0; i < 10; i = i + 1) begin
                slot_len[i] <= 16'd0;
                slot_src_udp[i] <= 16'd0;
                slot_dst_udp[i] <= 16'd0;
                bag_timer[i] <= 32'd0;
            end
        end else begin
            queue_error_pulse <= 1'b0;
            previous_txen_a <= p0_txen_a;
            for (i = 0; i < 10; i = i + 1)
                if (bag_timer[i] != 0)
                    bag_timer[i] <= bag_timer[i] - 1'b1;
            if (frame_wire_start) begin
                if (VL_BAG_TABLE[dispatch_slot*32 +: 32] <= 32'd1)
                    bag_timer[dispatch_slot] <= 32'd0;
                else
                    bag_timer[dispatch_slot] <=
                        VL_BAG_TABLE[dispatch_slot*32 +: 32] - 1'b1;
            end

            case (ingress_state)
                ING_IDLE: begin
                    if (input_fire) begin
                        ingress_slot <= route_slot;
                        ingress_count <= 16'd1;
                        ingress_expected_len <= tx_len;
                        ingress_src_udp <= app_upd_src_port;
                        ingress_dst_udp <= app_upd_dst_port;
                        if (!route_valid || !tx_sop || (tx_len == 0) ||
                            (tx_len > slot_capacity(route_slot))) begin
                            if (ingress_queue_request) begin
                                queue_error_pulse <= 1'b1;
                                if (!route_valid)
                                    queue_error_reg <= ERR_PORT;
                                else if (!tx_sop)
                                    queue_error_reg <= ERR_SOP;
                                else if (tx_len >
                                         slot_capacity(route_slot)) begin
                                    queue_error_reg <= ERR_LONG;
                                    queue_overflow_reg <= 1'b1;
                                end else
                                    queue_error_reg <= ERR_LEN;
                            end
                            ingress_state <=
                                tx_tlast ? ING_IDLE : ING_DRAIN;
                        end else if (tx_tlast) begin
                            if (tx_len != 16'd1) begin
                                if (ingress_queue_route) begin
                                    queue_error_pulse <= 1'b1;
                                    queue_error_reg <= ERR_LEN;
                                end
                            end else if (!frame_fits_lmax(16'd1,
                                                          route_slot)) begin
                                if (ingress_queue_route) begin
                                    queue_error_pulse <= 1'b1;
                                    queue_error_reg <= ERR_LMAX;
                                end
                            end else begin
                                slot_len[route_slot] <= 16'd1;
                                slot_src_udp[route_slot] <=
                                    app_upd_src_port;
                                slot_dst_udp[route_slot] <=
                                    app_upd_dst_port;
                                pending[route_slot] <= 1'b1;
                            end
                        end else begin
                            ingress_state <= ING_CAPTURE;
                        end
                    end
                end
                ING_CAPTURE: begin
                    if (input_fire) begin
                        if (tx_sop) begin
                            if ((ingress_slot == 4'd2) ||
                                (ingress_slot == 4'd3)) begin
                                queue_error_pulse <= 1'b1;
                                queue_error_reg <= ERR_SOP;
                            end
                            ingress_state <=
                                tx_tlast ? ING_IDLE : ING_DRAIN;
                        end else if (ingress_count >=
                                     slot_capacity(ingress_slot)) begin
                            if ((ingress_slot == 4'd2) ||
                                (ingress_slot == 4'd3)) begin
                                queue_error_pulse <= 1'b1;
                                queue_error_reg <= ERR_LONG;
                                queue_overflow_reg <= 1'b1;
                            end
                            ingress_state <=
                                tx_tlast ? ING_IDLE : ING_DRAIN;
                        end else if (tx_tlast) begin
                            if ((ingress_count + 16'd1) !=
                                ingress_expected_len) begin
                                if ((ingress_slot == 4'd2) ||
                                    (ingress_slot == 4'd3)) begin
                                    queue_error_pulse <= 1'b1;
                                    queue_error_reg <= ERR_LEN;
                                end
                            end else if (!frame_fits_lmax(
                                ingress_count + 16'd1,
                                ingress_slot)) begin
                                if ((ingress_slot == 4'd2) ||
                                    (ingress_slot == 4'd3)) begin
                                    queue_error_pulse <= 1'b1;
                                    queue_error_reg <= ERR_LMAX;
                                end
                            end else begin
                                slot_len[ingress_slot] <=
                                    ingress_count + 16'd1;
                                slot_src_udp[ingress_slot] <=
                                    ingress_src_udp;
                                slot_dst_udp[ingress_slot] <=
                                    ingress_dst_udp;
                                pending[ingress_slot] <= 1'b1;
                            end
                            ingress_state <= ING_IDLE;
                        end else begin
                            ingress_count <= ingress_count + 1'b1;
                        end
                    end
                end
                ING_DRAIN: begin
                    if (input_fire && tx_tlast)
                        ingress_state <= ING_IDLE;
                end
                default: ingress_state <= ING_IDLE;
            endcase

            case (sched_state)
                SCH_IDLE: begin
                    if (select_valid && !nonq_busy && !que_busy_i) begin
                        dispatch_slot <= select_slot;
                        dispatch_queue <=
                            (select_slot == 4'd2) ||
                            (select_slot == 4'd3);
                        dispatch_len <= slot_len[select_slot];
                        dispatch_index <= 16'd0;
                        dispatch_src_udp <=
                            slot_src_udp[select_slot];
                        dispatch_dst_udp <=
                            slot_dst_udp[select_slot];
                        pending[select_slot] <= 1'b0;
                        active_slot_mask[select_slot] <= 1'b1;
                        sched_state <= SCH_STREAM;
                    end
                end
                SCH_STREAM: begin
                    if (stream_fire) begin
                        if (stream_last) begin
                            // The selected MAC now owns a complete copy of
                            // the payload; its input slot can accept the
                            // next datagram while the old one is on the wire.
                            active_slot_mask[dispatch_slot] <= 1'b0;
                            sched_state <= SCH_WAIT_ENGINE;
                        end else
                            dispatch_index <= dispatch_index + 1'b1;
                    end
                end
                SCH_WAIT_ENGINE: begin
                    if (!dispatch_busy) begin
                        rr_next <=
                            (dispatch_slot == 4'd9) ?
                            4'd0 : dispatch_slot + 1'b1;
                        sched_state <= SCH_IDLE;
                    end
                end
                default: sched_state <= SCH_IDLE;
            endcase
        end
    end
endmodule
