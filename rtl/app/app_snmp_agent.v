// Bounded SNMPv2c Agent: one VarBind, GetRequest and SetRequest.
// OID bytes are configured through the separate lookup module parameters.
module app_snmp_agent #(
    parameter integer OID0_LEN = 0,
    parameter [127:0] OID0_DATA = 0,
    parameter integer OID1_LEN = 0,
    parameter [127:0] OID1_DATA = 0,
    parameter integer OID2_LEN = 0,
    parameter [127:0] OID2_DATA = 0,
    parameter integer COMMUNITY_LEN = 6,
    parameter [127:0] COMMUNITY_DATA = 128'h7075626c696300000000000000000000
) (
    input wire clk,
    input wire reset_n,
    input wire [7:0] rx_data,
    input wire rx_valid,
    input wire rx_last,
    input wire [15:0] rx_src_udp,
    input wire [15:0] rx_dst_udp,
    input wire [7:0] device_status,
    input wire [31:0] rx_packet_count,
    output reg enable_cfg,
    output wire [7:0] app_tx_data,
    output wire app_tx_valid,
    input wire app_tx_ready,
    output wire app_tx_last,
    output wire [15:0] app_tx_src_udp,
    output reg [15:0] app_tx_dst_udp
);
    localparam integer MAX_MSG = 484;
    localparam [15:0] SNMP_PORT = 16'd161;
    localparam [2:0] S_IDLE = 0, S_CHECK = 1, S_LOOKUP = 2, S_LAYOUT = 3, S_BUILD = 4, S_TX = 5;
    reg [2:0] state;
    reg [7:0] rx_mem[0:MAX_MSG-1];
    reg [7:0] tx_mem[0:MAX_MSG-1];
    reg [9:0] rx_count, rx_length, tx_length, tx_index;
    reg rx_overflow, rx_complete;
    reg [15:0] request_src_udp, request_dst_udp;
    reg [7:0] pdu_tag, request_value_tag;
    reg [127:0] oid_packed;
    reg [  7:0] oid_length;
    wire oid_found, oid_writable;
    wire [1:0] object_id;
    wire [7:0] object_value_tag;
    reg [9:0] version_at, version_bytes, community_at, community_bytes;
    reg [9:0] reqid_at, reqid_bytes, oid_at, oid_bytes;
    reg [9:0] request_value_at, request_value_bytes;
    reg [9:0] request_content_len;
    reg [7:0] response_tag, response_error, response_index;
    reg [ 9:0] response_value_len;
    reg [31:0] response_value;
    reg echo_request_value, pending_write;
    integer p, body_len, pdu_body_len, vb_body_len;
    integer vbl_total, vb_total, pdu_total, msg_total;
    integer i;
    reg [7:0] tag_tmp;
    integer start_tmp, len_tmp, next_tmp;
    reg ok_tmp, valid_msg;
    integer outer_end, pdu_end, vbl_end, vb_end;
    integer ver_s, ver_l, ver_n, com_s, com_l, com_n;
    integer req_s, req_l, req_n, oid_s, oid_l, oid_n;
    integer val_s, val_l, val_n;
    reg [7:0] parsed_pdu, parsed_value_tag;
    reg [9:0] build_index;
    reg [9:0] msg_body_size, pdu_body_size, vb_body_size, vb_total_size;
    reg [9:0] off_version, off_community, off_pdu, off_reqid, off_error;
    reg [9:0] off_vbl, off_vb, off_oid, off_value, off_content;
    reg [7:0] build_byte;
    integer delta;

    app_snmp_oid_lookup #(
        .OID0_LEN(OID0_LEN),
        .OID0_DATA(OID0_DATA),
        .OID1_LEN(OID1_LEN),
        .OID1_DATA(OID1_DATA),
        .OID2_LEN(OID2_LEN),
        .OID2_DATA(OID2_DATA)
    ) oid_lookup (
        .oid_len(oid_length),
        .oid_data(oid_packed),
        .found(oid_found),
        .object_id(object_id),
        .writable(oid_writable),
        .value_tag(object_value_tag)
    );
    assign app_tx_valid = state == S_TX;
    assign app_tx_data = tx_mem[tx_index];
    assign app_tx_last = app_tx_valid && (tx_index == tx_length - 1'b1);
    assign app_tx_src_udp = SNMP_PORT;

    // 根据内容长度计算 BER 长度字段的字节数。
    function integer len_bytes;
        input integer value;
        begin
            if (value < 128)
                len_bytes = 1;
            else if (value < 256)
                len_bytes = 2;
            else
                len_bytes = 3;
        end
    endfunction

    // Read a definite-length BER TLV; caller checks nesting and tag.
    task read_tlv;
        input integer at;
        output reg [7:0] tag;
        output integer content_at;
        output integer content_len;
        output integer after;
        output reg valid;
        reg [7:0] length_byte;
        integer q;
        begin
            tag = 0;
            content_at = 0;
            content_len = 0;
            after = 0;
            valid = 0;
            q = at;
            if (q + 1 < rx_length) begin
                tag = rx_mem[q];
                length_byte = rx_mem[q+1];
                q = q + 2;
                if (length_byte < 128)
                    content_len = length_byte;
                else if (length_byte == 8'h81 && q < rx_length) begin
                    content_len = rx_mem[q];
                    q = q + 1;
                    if (content_len < 128)
                        q = MAX_MSG + 1;
                end else if (length_byte == 8'h82 && q + 1 < rx_length) begin
                    content_len = {rx_mem[q], rx_mem[q+1]};
                    q = q + 2;
                    if (content_len < 256)
                        q = MAX_MSG + 1;
                end else
                    q = MAX_MSG + 1;
                content_at = q;
                after = q + content_len;
                valid = (q <= rx_length && after <= rx_length);
            end
        end
    endtask

    // 输出短格式或 0x81/0x82 格式的 BER 长度字节。
    function [7:0] length_byte;
        input [9:0] value;
        input integer index;
        begin
            if (value < 128)
                length_byte = value[7:0];
            else if (value < 256)
                length_byte = (index == 0) ? 8'h81 : value[7:0];
            else
                case (index)
                    0: length_byte = 8'h82;
                    1: length_byte = {6'd0, value[9:8]};
                    default: length_byte = value[7:0];
                endcase
        end
    endfunction

    // 根据预先计算的字段偏移选择当前响应字节。
    always @* begin
        build_byte = 0;
        delta = 0;
        if (build_index == 0)
            build_byte = 8'h30;
        else if (build_index < off_version)
            build_byte = length_byte(msg_body_size, build_index - 1);
        else if (build_index < off_community)
            build_byte = rx_mem[version_at+build_index-off_version];
        else if (build_index < off_pdu)
            build_byte = rx_mem[community_at+build_index-off_community];
        else if (build_index == off_pdu)
            build_byte = 8'ha2;
        else if (build_index < off_reqid)
            build_byte = length_byte(pdu_body_size, build_index - off_pdu - 1);
        else if (build_index < off_error)
            build_byte = rx_mem[reqid_at+build_index-off_reqid];
        else if (build_index < off_vbl) begin
            delta = build_index - off_error;
            case (delta)
                0, 3: build_byte = 8'h02;
                1, 4: build_byte = 8'h01;
                2: build_byte = response_error;
                default: build_byte = response_index;
            endcase
        end else if (build_index == off_vbl) build_byte = 8'h30;
        else if (build_index < off_vb)
            build_byte = length_byte(vb_total_size, build_index - off_vbl - 1);
        else if (build_index == off_vb)
            build_byte = 8'h30;
        else if (build_index < off_oid)
            build_byte = length_byte(vb_body_size, build_index - off_vb - 1);
        else if (build_index < off_value)
            build_byte = rx_mem[oid_at+build_index-off_oid];
        else if (build_index == off_value)
            build_byte = response_tag;
        else if (build_index < off_content)
            build_byte = length_byte(response_value_len, build_index - off_value - 1);
        else if (echo_request_value)
            build_byte=rx_mem[request_value_at+request_value_bytes-request_content_len+
                              build_index-off_content];
        else begin
            delta = build_index - off_content;
            build_byte = response_value >> ((response_value_len - delta - 1) * 8);
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= S_IDLE;
            rx_count <= 0;
            rx_length <= 0;
            rx_overflow <= 0;
            rx_complete <= 0;
            request_src_udp <= 0;
            request_dst_udp <= 0;
            tx_length <= 0;
            tx_index <= 0;
            app_tx_dst_udp <= 0;
            enable_cfg <= 0;
            pdu_tag <= 0;
            request_value_tag <= 0;
            oid_packed <= 0;
            oid_length <= 0;
            version_at <= 0;
            version_bytes <= 0;
            community_at <= 0;
            community_bytes <= 0;
            reqid_at <= 0;
            reqid_bytes <= 0;
            oid_at <= 0;
            oid_bytes <= 0;
            request_value_at <= 0;
            request_value_bytes <= 0;
            request_content_len <= 0;
            response_tag <= 0;
            response_error <= 0;
            response_index <= 0;
            response_value_len <= 0;
            response_value <= 0;
            echo_request_value <= 0;
            pending_write <= 0;
            build_index <= 0;
            msg_body_size <= 0;
            pdu_body_size <= 0;
            vb_body_size <= 0;
            vb_total_size <= 0;
            off_version <= 0;
            off_community <= 0;
            off_pdu <= 0;
            off_reqid <= 0;
            off_error <= 0;
            off_vbl <= 0;
            off_vb <= 0;
            off_oid <= 0;
            off_value <= 0;
            off_content <= 0;
        end else begin
            // 缓存接收载荷，并在末字节锁存长度和 UDP 端口。
            if (rx_valid) begin
                if (rx_count < MAX_MSG)
                    rx_mem[rx_count] <= rx_data;
                else
                    rx_overflow <= 1;
                if (rx_count < MAX_MSG + 1)
                    rx_count <= rx_count + 1'b1;
                if (rx_last) begin
                    rx_length <= rx_count + 1'b1;
                    request_src_udp <= rx_src_udp;
                    request_dst_udp <= rx_dst_udp;
                    rx_complete <= !rx_overflow && rx_count < MAX_MSG;
                    rx_count <= 0;
                    rx_overflow <= 0;
                end
            end

            case (state)
                S_IDLE:
                if (rx_complete) begin
                    rx_complete <= 0;
                    state <= S_CHECK;
                end
                // 校验 BER 嵌套、版本、community 和单个 VarBind。
                S_CHECK: begin
                    valid_msg = 1;
                    read_tlv(0, tag_tmp, start_tmp, len_tmp, next_tmp, ok_tmp);
                    if (!ok_tmp || tag_tmp != 8'h30 || next_tmp != rx_length)
                        valid_msg = 0;
                    outer_end = next_tmp;
                    p = start_tmp;

                    if (valid_msg) begin
                        ver_s = p;
                        read_tlv(p, tag_tmp, start_tmp, len_tmp, next_tmp, ok_tmp);
                        if (!ok_tmp || tag_tmp!=8'h02 || len_tmp!=1 ||
                            rx_mem[start_tmp]!=8'h01 || next_tmp>outer_end)
                            valid_msg = 0;
                        ver_l = len_tmp;
                        ver_n = next_tmp;
                        p = next_tmp;
                    end
                    if (valid_msg) begin
                        com_s = p;
                        read_tlv(p, tag_tmp, start_tmp, len_tmp, next_tmp, ok_tmp);
                        if (!ok_tmp || tag_tmp!=8'h04 || len_tmp!=COMMUNITY_LEN ||
                            len_tmp>16 || next_tmp>outer_end)
                            valid_msg = 0;
                        for (i = 0; i < 16; i = i + 1)
                            if (i < len_tmp && rx_mem[start_tmp+i] !== COMMUNITY_DATA[127-i*8-:8])
                                valid_msg = 0;
                        com_l = len_tmp;
                        com_n = next_tmp;
                        p = next_tmp;
                    end
                    if (valid_msg) begin
                        read_tlv(p, tag_tmp, start_tmp, len_tmp, next_tmp, ok_tmp);
                        if (!ok_tmp || (tag_tmp!=8'ha0 && tag_tmp!=8'ha3) ||
                            next_tmp!=outer_end)
                            valid_msg = 0;
                        parsed_pdu = tag_tmp;
                        p = start_tmp;
                        pdu_end = next_tmp;
                    end
                    if (valid_msg) begin
                        req_s = p;
                        read_tlv(p, tag_tmp, start_tmp, len_tmp, next_tmp, ok_tmp);
                        if (!ok_tmp || tag_tmp!=8'h02 || len_tmp<1 || len_tmp>4 ||
                            next_tmp>pdu_end)
                            valid_msg = 0;
                        req_l = len_tmp;
                        req_n = next_tmp;
                        p = next_tmp;
                    end
                    for (i = 0; i < 2; i = i + 1) begin
                        if (valid_msg) begin
                            read_tlv(p, tag_tmp, start_tmp, len_tmp, next_tmp, ok_tmp);
                            if (!ok_tmp || tag_tmp!=8'h02 || len_tmp!=1 ||
                                rx_mem[start_tmp]!=0 || next_tmp>pdu_end)
                                valid_msg = 0;
                            p = next_tmp;
                        end
                    end
                    if (valid_msg) begin
                        read_tlv(p, tag_tmp, start_tmp, len_tmp, next_tmp, ok_tmp);
                        if (!ok_tmp || tag_tmp != 8'h30 || next_tmp != pdu_end)
                            valid_msg = 0;
                        p = start_tmp;
                        vbl_end = next_tmp;
                    end
                    if (valid_msg) begin
                        read_tlv(p, tag_tmp, start_tmp, len_tmp, next_tmp, ok_tmp);
                        if (!ok_tmp || tag_tmp != 8'h30 || next_tmp != vbl_end)
                            valid_msg = 0;
                        p = start_tmp;
                        vb_end = next_tmp;
                    end
                    if (valid_msg) begin
                        oid_s = p;
                        read_tlv(p, tag_tmp, start_tmp, len_tmp, next_tmp, ok_tmp);
                        if (!ok_tmp || tag_tmp!=8'h06 || len_tmp<1 || len_tmp>16 ||
                            next_tmp>vb_end)
                            valid_msg = 0;
                        oid_l = len_tmp;
                        oid_n = next_tmp;
                        p = next_tmp;
                    end
                    if (valid_msg) begin
                        val_s = p;
                        read_tlv(p, tag_tmp, start_tmp, len_tmp, next_tmp, ok_tmp);
                        if (!ok_tmp || next_tmp != vb_end)
                            valid_msg = 0;
                        if (parsed_pdu == 8'ha0 && (tag_tmp != 8'h05 || len_tmp != 0))
                            valid_msg = 0;
                        parsed_value_tag = tag_tmp;
                        val_l = len_tmp;
                        val_n = next_tmp;
                    end
                    if (valid_msg && request_dst_udp == SNMP_PORT) begin
                        pdu_tag <= parsed_pdu;
                        version_at <= ver_s;
                        version_bytes <= ver_n - ver_s;
                        community_at <= com_s;
                        community_bytes <= com_n - com_s;
                        reqid_at <= req_s;
                        reqid_bytes <= req_n - req_s;
                        oid_at <= oid_s;
                        oid_bytes <= oid_n - oid_s;
                        request_value_at <= val_s;
                        request_value_bytes <= val_n - val_s;
                        request_content_len <= val_l;
                        request_value_tag <= parsed_value_tag;
                        oid_length <= oid_l;
                        oid_packed <= 0;
                        for (i = 0; i < 16; i = i + 1)
                            if (i < oid_l)
                                oid_packed[127-i*8-:8] <= rx_mem[oid_n-oid_l+i];
                        state <= S_LOOKUP;
                    end else
                        state <= S_IDLE;
                end
                // GET 读取对象值，SET 检查权限和类型后暂存写入。
                S_LOOKUP: begin
                    response_error <= 0;
                    response_index <= 0;
                    pending_write <= 0;
                    echo_request_value <= 0;
                    if (pdu_tag == 8'ha0) begin
                        if (!oid_found) begin
                            response_tag <= 8'h80;  // noSuchObject
                            response_value_len <= 0;
                            response_value <= 0;
                        end else begin
                            response_tag <= object_value_tag;
                            if (object_id == 0) begin
                                response_value <= device_status;
                                response_value_len <= device_status[7] ? 2 : 1;
                            end else if (object_id == 1) begin
                                response_value <= rx_packet_count;
                                response_value_len <= 4;
                            end else begin
                                response_value <= enable_cfg;
                                response_value_len <= 1;
                            end
                        end
                    end else begin
                        echo_request_value <= 1;
                        response_tag <= request_value_tag;
                        if (!oid_found)
                            response_error <= 8'd11;  // noCreation
                        else if (!oid_writable)
                            response_error <= 8'd17;  // notWritable
                        else if (request_value_tag != 8'h02 || request_value_bytes != 3)
                            response_error <= 8'd7;  // wrongType
                        else if (rx_mem[request_value_at+2] > 1)
                            response_error <= 8'd10;  // wrongValue
                        else begin
                            pending_write <= 1;
                            response_value <= rx_mem[request_value_at+2];
                        end
                        if (!oid_found || !oid_writable || request_value_tag!=8'h02 ||
                            request_value_bytes!=3 || rx_mem[request_value_at+2]>1)
                            response_index <= 1;
                        response_value_len <= request_content_len;
                    end
                    state <= S_LAYOUT;
                end
                // 计算响应各层长度和字段偏移，并拒绝超长响应。
                S_LAYOUT: begin
                    vb_body_len = oid_bytes + 1 + len_bytes(response_value_len) +
                        response_value_len;
                    vb_total = 1 + len_bytes(vb_body_len) + vb_body_len;
                    vbl_total = 1 + len_bytes(vb_total) + vb_total;
                    pdu_body_len = reqid_bytes + 6 + vbl_total;
                    pdu_total = 1 + len_bytes(pdu_body_len) + pdu_body_len;
                    body_len = version_bytes + community_bytes + pdu_total;
                    msg_total = 1 + len_bytes(body_len) + body_len;
                    if (msg_total > MAX_MSG)
                        state <= S_IDLE;
                    else begin
                        msg_body_size <= body_len;
                        pdu_body_size <= pdu_body_len;
                        vb_body_size <= vb_body_len;
                        vb_total_size <= vb_total;
                        p = 1 + len_bytes(body_len);
                        off_version <= p;
                        p = p + version_bytes;
                        off_community <= p;
                        p = p + community_bytes;
                        off_pdu <= p;
                        p = p + 1 + len_bytes(pdu_body_len);
                        off_reqid <= p;
                        p = p + reqid_bytes;
                        off_error <= p;
                        p = p + 6;
                        off_vbl <= p;
                        p = p + 1 + len_bytes(vb_total);
                        off_vb <= p;
                        p = p + 1 + len_bytes(vb_body_len);
                        off_oid <= p;
                        p = p + oid_bytes;
                        off_value <= p;
                        p = p + 1 + len_bytes(response_value_len);
                        off_content <= p;
                        tx_length <= msg_total;
                        build_index <= 0;
                        tx_index <= 0;
                        app_tx_dst_udp <= request_src_udp;
                        state <= S_BUILD;
                    end
                end
                // 每拍写入一个响应字节，构建完成后提交有效 SET。
                S_BUILD: begin
                    tx_mem[build_index] <= build_byte;
                    if (build_index == tx_length - 1'b1) begin
                        if (pending_write)
                            enable_cfg <= response_value[0];
                        state <= S_TX;
                    end else
                        build_index <= build_index + 1'b1;
                end
                // 发送索引仅在握手时推进，反压期间保持当前字节。
                S_TX:
                if (app_tx_ready) begin
                    if (app_tx_last) begin
                        tx_index <= 0;
                        state <= S_IDLE;
                    end else
                        tx_index <= tx_index + 1'b1;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
