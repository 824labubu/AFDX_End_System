`timescale 1ns / 1ps
module tb_app_layer_top;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset_n = 0;
    reg [7:0] app_rx_data = 0, app_rx_port = 0;
    reg app_rx_valid = 0, app_rx_last = 0;
    reg [15:0] app_rx_src_udp = 0, app_rx_dst_udp = 0;
    // TB_ONLY_DEFAULT: UDP ports, TID, clock and OID are local test values.
    reg [15:0] cfg_rtc_local_udp = 4000, cfg_rtc_remote_udp = 4001;
    reg [15:0] cfg_tftp_local_tid = 5000;
    reg [7:0] device_status = 5;
    reg [31:0] rx_packet_count = 42;
    wire snmp_enable_cfg;
    wire [63:0] rtc_local_time;
    wire rtc_sync_valid;
    wire file_wr_en, file_commit, file_rd_req;
    wire [9:0] file_wr_addr, file_rd_addr;
    wire [7:0] file_wr_data;
    wire [31:0] file_written_size;
    reg [7:0] file_rd_data = 0;
    reg file_rd_valid = 0;
    reg [31:0] file_size = 0;
    wire tftp_session_valid, tftp_timeout_error;
    wire [7:0] tx_data, tx_port;
    wire tx_valid, tx_tlast;
    reg tx_ready = 0;
    wire [15:0] app_upd_src_port, app_upd_dst_port;
    app_layer_top #(
        .CLK_FREQ_HZ(1000000),
        .RTC_TICK_NS(0),
        .FILE_ADDR_WIDTH(10),
        .MAX_FILE_BYTES(1024),
        .OID0_LEN(6),
        .OID0_DATA(128'h2b060104010100000000000000000000)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .app_rx_data(app_rx_data),
        .app_rx_valid(app_rx_valid),
        .app_rx_last(app_rx_last),
        .app_rx_port(app_rx_port),
        .app_rx_src_udp(app_rx_src_udp),
        .app_rx_dst_udp(app_rx_dst_udp),
        .cfg_rtc_local_udp(cfg_rtc_local_udp),
        .cfg_rtc_remote_udp(cfg_rtc_remote_udp),
        .cfg_tftp_local_tid(cfg_tftp_local_tid),
        .device_status(device_status),
        .rx_packet_count(rx_packet_count),
        .snmp_enable_cfg(snmp_enable_cfg),
        .rtc_local_time(rtc_local_time),
        .rtc_sync_valid(rtc_sync_valid),
        .file_wr_en(file_wr_en),
        .file_wr_addr(file_wr_addr),
        .file_wr_data(file_wr_data),
        .file_commit(file_commit),
        .file_written_size(file_written_size),
        .file_rd_req(file_rd_req),
        .file_rd_addr(file_rd_addr),
        .file_rd_data(file_rd_data),
        .file_rd_valid(file_rd_valid),
        .file_size(file_size),
        .tftp_session_valid(tftp_session_valid),
        .tftp_timeout_error(tftp_timeout_error),
        .tx_data(tx_data),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_tlast(tx_tlast),
        .tx_port(tx_port),
        .app_upd_src_port(app_upd_src_port),
        .app_upd_dst_port(app_upd_dst_port)
    );

    // 在时钟下降沿驱动一个接收字节。
    task send_byte;
        input [7:0] b;
        input last;
        begin
            @(negedge clk);
            app_rx_data = b;
            app_rx_valid = 1;
            app_rx_last = last;
        end
    endtask
    // 撤销接收有效和末字节标志。
    task end_packet;
        begin
            @(negedge clk);
            app_rx_valid = 0;
            app_rx_last = 0;
        end
    endtask
    // 发送一个 SNMP GET 请求。
    task send_snmp_get;
        begin
            app_rx_port = 3;
            app_rx_src_udp = 40000;
            app_rx_dst_udp = 161;
            send_byte('h30, 0);
            send_byte('h24, 0);
            send_byte('h02, 0);
            send_byte(1, 0);
            send_byte(1, 0);
            send_byte('h04, 0);
            send_byte(6, 0);
            send_byte("p", 0);
            send_byte("u", 0);
            send_byte("b", 0);
            send_byte("l", 0);
            send_byte("i", 0);
            send_byte("c", 0);
            send_byte('ha0, 0);
            send_byte('h17, 0);
            send_byte(2, 0);
            send_byte(1, 0);
            send_byte('h2a, 0);
            send_byte(2, 0);
            send_byte(1, 0);
            send_byte(0, 0);
            send_byte(2, 0);
            send_byte(1, 0);
            send_byte(0, 0);
            send_byte('h30, 0);
            send_byte('h0c, 0);
            send_byte('h30, 0);
            send_byte('h0a, 0);
            send_byte(6, 0);
            send_byte(6, 0);
            send_byte('h2b, 0);
            send_byte(6, 0);
            send_byte(1, 0);
            send_byte(4, 0);
            send_byte(1, 0);
            send_byte(1, 0);
            send_byte(5, 0);
            send_byte(0, 1);
            end_packet;
        end
    endtask
    // 发送一个完整 RTC SYNC 报文。
    task send_rtc;
        integer j;
        begin
            app_rx_port = 4;
            app_rx_src_udp = 4001;
            app_rx_dst_udp = 4000;
            for (j = 0; j < 16; j = j + 1) begin
                if (j == 0 || j == 1)
                    send_byte(1, j == 15);
                else if (j == 7)
                    send_byte(7, 0);
                else if (j == 15)
                    send_byte(8, 1);
                else
                    send_byte(0, 0);
            end
            end_packet;
        end
    endtask
    // 发送 octet 模式的 TFTP 写请求。
    task send_wrq;
        begin
            app_rx_port = 5;
            app_rx_src_udp = 6000;
            app_rx_dst_udp = 69;
            send_byte(0, 0);
            send_byte(2, 0);
            send_byte("f", 0);
            send_byte(0, 0);
            send_byte("o", 0);
            send_byte("c", 0);
            send_byte("t", 0);
            send_byte("e", 0);
            send_byte("t", 0);
            send_byte(0, 1);
            end_packet;
        end
    endtask

    integer cycles, frames, bytes_in_frame;
    reg [7:0] frame_port;
    reg [2:0] seen_ports;
    // 执行协议场景并检查结果，失败时立即终止仿真。
    initial begin
        repeat (2) @(negedge clk);
        reset_n = 1;
        send_snmp_get;
        send_rtc;
        send_wrq;
        repeat (5) @(negedge clk);
        if (!tx_valid)
            $fatal(1, "integrated application request missing");
        frames = 0;
        bytes_in_frame = 0;
        frame_port = 0;
        seen_ports = 0;
        for (cycles = 0; cycles < 500 && frames < 3; cycles = cycles + 1) begin
            @(negedge clk);
            tx_ready = (cycles % 3 != 0);
            #1;
            if (tx_valid && !tx_ready) begin
                // Check the held beat on the next clock when still stalled.
                if (frame_port != 0 && tx_port != frame_port)
                    $fatal(1, "arbiter switched message under backpressure");
            end
            @(posedge clk);
            if (tx_valid && tx_ready) begin
                if (frame_port == 0)
                    frame_port = tx_port;
                if (tx_port != frame_port)
                    $fatal(1, "interleaved application messages");
                bytes_in_frame = bytes_in_frame + 1;
                if (tx_tlast) begin
                    if ((frame_port==3 && (bytes_in_frame!=39 ||
                                         app_upd_src_port!=161 || app_upd_dst_port!=40000)) ||
                        (frame_port==4 && (bytes_in_frame!=16 ||
                                         app_upd_src_port!=4000 || app_upd_dst_port!=4001)) ||
                        (frame_port==5 && (bytes_in_frame!=4 ||
                                         app_upd_src_port!=5000 || app_upd_dst_port!=6000)) ||
                        frame_port<3 || frame_port>5 || seen_ports[frame_port-3])
                        $fatal(
                            1, "frame %0d port=%0d bytes=%0d", frames, frame_port, bytes_in_frame
                        );
                    seen_ports[frame_port-3] = 1;
                    frames = frames + 1;
                    bytes_in_frame = 0;
                    frame_port = 0;
                end
            end
        end
        if (frames != 3 || seen_ports != 3'b111 || !tftp_session_valid || rtc_local_time != 8)
            $fatal(1, "three-application integration failed");
        $display("PASS: integrated SNMP/RTC/TFTP simultaneous TX and backpressure");
        $finish;
    end
endmodule
