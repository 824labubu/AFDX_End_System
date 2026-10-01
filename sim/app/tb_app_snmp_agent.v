`timescale 1ns / 1ps
module tb_app_snmp_agent;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset_n = 0;
    reg [7:0] rx_data = 0;
    reg rx_valid = 0, rx_last = 0;
    reg [15:0] rx_src_udp = 16'd40000, rx_dst_udp = 16'd161;
    reg [7:0] device_status = 8'd5;
    reg [31:0] rx_packet_count = 32'd42;
    wire enable_cfg;
    wire [7:0] app_tx_data;
    wire app_tx_valid, app_tx_last;
    reg app_tx_ready = 0;
    wire [15:0] app_tx_src_udp, app_tx_dst_udp;
    reg [7:0] request_mem [0:500];
    reg [7:0] response_mem[0:500];
    integer request_len, response_len;
    integer i;
    // TB_ONLY_DEFAULT: these are local test OIDs, not project enterprise OIDs.
    app_snmp_agent #(
        .OID0_LEN(6),
        .OID0_DATA(128'h2b060104010100000000000000000000),
        .OID1_LEN(6),
        .OID1_DATA(128'h2b060104010200000000000000000000),
        .OID2_LEN(6),
        .OID2_DATA(128'h2b060104010300000000000000000000)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .rx_last(rx_last),
        .rx_src_udp(rx_src_udp),
        .rx_dst_udp(rx_dst_udp),
        .device_status(device_status),
        .rx_packet_count(rx_packet_count),
        .enable_cfg(enable_cfg),
        .app_tx_data(app_tx_data),
        .app_tx_valid(app_tx_valid),
        .app_tx_ready(app_tx_ready),
        .app_tx_last(app_tx_last),
        .app_tx_src_udp(app_tx_src_udp),
        .app_tx_dst_udp(app_tx_dst_udp)
    );

    // 构造单个 VarBind 的 SNMP 请求。
    task make_request;
        input [7:0] pdu;
        input [7:0] oid_last;
        input [7:0] value_tag;
        input [7:0] value_len;
        input [7:0] value;
        integer n;
        begin
            n = 0;
            request_mem[n] = 8'h30;
            n = n + 1;
            request_mem[n] = 36 + value_len;
            n = n + 1;
            request_mem[n] = 8'h02;
            n = n + 1;
            request_mem[n] = 8'h01;
            n = n + 1;
            request_mem[n] = 8'h01;
            n = n + 1;
            request_mem[n] = 8'h04;
            n = n + 1;
            request_mem[n] = 8'h06;
            n = n + 1;
            request_mem[n] = "p";
            n = n + 1;
            request_mem[n] = "u";
            n = n + 1;
            request_mem[n] = "b";
            n = n + 1;
            request_mem[n] = "l";
            n = n + 1;
            request_mem[n] = "i";
            n = n + 1;
            request_mem[n] = "c";
            n = n + 1;
            request_mem[n] = pdu;
            n = n + 1;
            request_mem[n] = 23 + value_len;
            n = n + 1;
            request_mem[n] = 8'h02;
            n = n + 1;
            request_mem[n] = 8'h01;
            n = n + 1;
            request_mem[n] = 8'h2a;
            n = n + 1;
            request_mem[n] = 8'h02;
            n = n + 1;
            request_mem[n] = 8'h01;
            n = n + 1;
            request_mem[n] = 0;
            n = n + 1;
            request_mem[n] = 8'h02;
            n = n + 1;
            request_mem[n] = 8'h01;
            n = n + 1;
            request_mem[n] = 0;
            n = n + 1;
            request_mem[n] = 8'h30;
            n = n + 1;
            request_mem[n] = 12 + value_len;
            n = n + 1;
            request_mem[n] = 8'h30;
            n = n + 1;
            request_mem[n] = 10 + value_len;
            n = n + 1;
            request_mem[n] = 8'h06;
            n = n + 1;
            request_mem[n] = 8'h06;
            n = n + 1;
            request_mem[n] = 8'h2b;
            n = n + 1;
            request_mem[n] = 8'h06;
            n = n + 1;
            request_mem[n] = 8'h01;
            n = n + 1;
            request_mem[n] = 8'h04;
            n = n + 1;
            request_mem[n] = 8'h01;
            n = n + 1;
            request_mem[n] = oid_last;
            n = n + 1;
            request_mem[n] = value_tag;
            n = n + 1;
            request_mem[n] = value_len;
            n = n + 1;
            if (value_len != 0) begin
                request_mem[n] = value;
                n = n + 1;
            end
            request_len = n;
        end
    endtask
    // 逐字节发送已构造的 SNMP 请求。
    task send_request;
        integer j;
        begin
            for (j = 0; j < request_len; j = j + 1) begin
                @(negedge clk);
                rx_data = request_mem[j];
                rx_valid = 1;
                rx_last = (j == request_len - 1);
            end
            @(negedge clk);
            rx_valid = 0;
            rx_last = 0;
        end
    endtask
    function integer len_size;
        input integer value;
        begin
            if (value < 128)
                len_size = 1;
            else if (value < 256)
                len_size = 2;
            else
                len_size = 3;
        end
    endfunction
    // 为测试报文编码 BER 长度字段。
    task put_length;
        input integer value;
        inout integer n;
        begin
            if (value < 128) begin
                request_mem[n] = value;
                n = n + 1;
            end else if (value < 256) begin
                request_mem[n] = 8'h81;
                n = n + 1;
                request_mem[n] = value;
                n = n + 1;
            end else begin
                request_mem[n] = 8'h82;
                n = n + 1;
                request_mem[n] = value >> 8;
                n = n + 1;
                request_mem[n] = value;
                n = n + 1;
            end
        end
    endtask
    // 构造含长格式 BER 长度的 SET 请求。
    task make_long_set;
        input integer value_length;
        integer n, j, vb_body, vb_total, vbl_total, pdu_body, pdu_total, msg_body;
        begin
            vb_body = 8 + 1 + len_size(value_length) + value_length;
            vb_total = 1 + len_size(vb_body) + vb_body;
            vbl_total = 1 + len_size(vb_total) + vb_total;
            pdu_body = 9 + vbl_total;
            pdu_total = 1 + len_size(pdu_body) + pdu_body;
            msg_body = 11 + pdu_total;
            n = 0;
            request_mem[n] = 8'h30;
            n = n + 1;
            put_length(msg_body, n);
            request_mem[n] = 8'h02;
            n = n + 1;
            request_mem[n] = 1;
            n = n + 1;
            request_mem[n] = 1;
            n = n + 1;
            request_mem[n] = 8'h04;
            n = n + 1;
            request_mem[n] = 6;
            n = n + 1;
            request_mem[n] = "p";
            n = n + 1;
            request_mem[n] = "u";
            n = n + 1;
            request_mem[n] = "b";
            n = n + 1;
            request_mem[n] = "l";
            n = n + 1;
            request_mem[n] = "i";
            n = n + 1;
            request_mem[n] = "c";
            n = n + 1;
            request_mem[n] = 8'ha3;
            n = n + 1;
            put_length(pdu_body, n);
            request_mem[n] = 8'h02;
            n = n + 1;
            request_mem[n] = 1;
            n = n + 1;
            request_mem[n] = 8'h2a;
            n = n + 1;
            request_mem[n] = 8'h02;
            n = n + 1;
            request_mem[n] = 1;
            n = n + 1;
            request_mem[n] = 0;
            n = n + 1;
            request_mem[n] = 8'h02;
            n = n + 1;
            request_mem[n] = 1;
            n = n + 1;
            request_mem[n] = 0;
            n = n + 1;
            request_mem[n] = 8'h30;
            n = n + 1;
            put_length(vb_total, n);
            request_mem[n] = 8'h30;
            n = n + 1;
            put_length(vb_body, n);
            request_mem[n] = 8'h06;
            n = n + 1;
            request_mem[n] = 6;
            n = n + 1;
            request_mem[n] = 8'h2b;
            n = n + 1;
            request_mem[n] = 6;
            n = n + 1;
            request_mem[n] = 1;
            n = n + 1;
            request_mem[n] = 4;
            n = n + 1;
            request_mem[n] = 1;
            n = n + 1;
            request_mem[n] = 3;
            n = n + 1;
            request_mem[n] = 8'h04;
            n = n + 1;
            put_length(value_length, n);
            for (j = 0; j < value_length; j = j + 1) begin
                request_mem[n] = j;
                n = n + 1;
            end
            request_len = n;
        end
    endtask
    // 在反压下接收 SNMP 响应并检查输出稳定性。
    task collect_response;
        integer j;
        reg done;
        begin
            response_len = 0;
            done = 0;
            wait (app_tx_valid);
            if (app_tx_src_udp != 161 || app_tx_dst_udp != 40000)
                $fatal(1, "SNMP UDP metadata mismatch");
            for (j = 0; j < 500 && !done; j = j + 1) begin
                app_tx_ready = 0;
                #1;
                if (!app_tx_valid)
                    $fatal(1, "SNMP response ended early");
                response_mem[response_len] = app_tx_data;
                repeat (2) @(negedge clk);
                if (app_tx_data !== response_mem[response_len])
                    $fatal(1, "SNMP response changed under backpressure");
                done = app_tx_last;
                response_len = response_len + 1;
                app_tx_ready = 1;
                @(negedge clk);
            end
            app_tx_ready = 0;
            if (!done)
                $fatal(1, "SNMP response too long");
        end
    endtask

    // 执行协议场景并检查结果，失败时立即终止仿真。
    initial begin
        repeat (2) @(negedge clk);
        reset_n = 1;
        make_request(8'ha0, 8'h01, 8'h05, 0, 0);
        send_request;
        collect_response;
        if (response_len!=39 || response_mem[13]!=8'ha2 ||
            response_mem[17]!=8'h2a || response_mem[20]!=0 ||
            response_mem[36]!=8'h02 || response_mem[38]!=5)
            $fatal(1, "SNMP GET response mismatch len=%0d", response_len);
        make_request(8'ha3, 8'h03, 8'h02, 1, 1);
        send_request;
        collect_response;
        if (!enable_cfg || response_mem[20] != 0 || response_mem[38] != 1)
            $fatal(1, "SNMP SET failed");
        make_request(8'ha3, 8'h01, 8'h02, 1, 1);
        send_request;
        collect_response;
        if (response_mem[20] != 17 || response_mem[23] != 1 || device_status != 5)
            $fatal(1, "SNMP readonly SET not rejected");
        make_request(8'ha0, 8'h09, 8'h05, 0, 0);
        send_request;
        collect_response;
        if (response_mem[36] != 8'h80 || response_len != 38)
            $fatal(1, "SNMP missing OID exception mismatch");
        make_request(8'ha0, 8'h01, 8'h05, 0, 0);
        request_mem[1] = request_mem[1] + 1;
        send_request;
        repeat (8) @(negedge clk);
        if (app_tx_valid)
            $fatal(1, "malformed BER produced response");
        make_request(8'ha3, 8'h03, 8'h02, 1, 0);
        request_mem[7] = "x";
        send_request;
        repeat (8) @(negedge clk);
        if (app_tx_valid || enable_cfg !== 1)
            $fatal(1, "wrong SNMP community changed state");
        make_request(8'ha3, 8'h03, 8'h02, 1, 2);
        send_request;
        collect_response;
        if (response_mem[20] != 10 || enable_cfg !== 1)
            $fatal(1, "invalid SNMP SET value changed state");
        make_long_set(128);
        send_request;
        collect_response;
        if (response_len != 171 || response_mem[22] != 7 || enable_cfg !== 1)
            $fatal(
                1,
                "SNMP 0x81 length or wrongType handling failed len=%0d b20=%h b21=%h b22=%h b23=%h",
                response_len,
                response_mem[20],
                response_mem[21],
                response_mem[22],
                response_mem[23]
            );
        make_long_set(436);
        send_request;
        collect_response;
        if (response_len != 484 || response_mem[24] != 7 || enable_cfg !== 1)
            $fatal(1, "SNMP 0x82 / 484-byte boundary failed len=%0d", response_len);
        $display("PASS: SNMP Get, Set, errors, BER 0x81/0x82 and 484-byte boundary");
        $finish;
    end
endmodule
