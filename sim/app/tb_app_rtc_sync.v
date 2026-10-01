`timescale 1ns / 1ps
module tb_app_rtc_sync;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset_n = 0;
    // TB_ONLY_DEFAULT: RTC_TICK_NS=0 keeps time stationary for exact checks.
    // TB_ONLY_DEFAULT: UDP ports 4000/4001 are test-local values.
    reg [15:0] cfg_local_udp = 16'd4000, cfg_remote_udp = 16'd4001;
    reg [7:0] rx_data = 0;
    reg rx_valid = 0, rx_last = 0;
    wire [63:0] local_time;
    wire rtc_sync_valid;
    wire [7:0] app_tx_data;
    wire app_tx_valid, app_tx_last;
    reg app_tx_ready = 0;
    wire [15:0] app_tx_src_udp, app_tx_dst_udp;
    integer sync_count = 0;
    app_rtc_sync #(
        .RTC_TICK_NS(0)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .cfg_local_udp(cfg_local_udp),
        .cfg_remote_udp(cfg_remote_udp),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .rx_last(rx_last),
        .local_time(local_time),
        .rtc_sync_valid(rtc_sync_valid),
        .app_tx_data(app_tx_data),
        .app_tx_valid(app_tx_valid),
        .app_tx_ready(app_tx_ready),
        .app_tx_last(app_tx_last),
        .app_tx_src_udp(app_tx_src_udp),
        .app_tx_dst_udp(app_tx_dst_udp)
    );
    always @(posedge clk) if (rtc_sync_valid) sync_count = sync_count + 1;

    // 发送指定序号和时间戳的 RTC 同步报文。
    task send_sync;
        input [31:0] seq_value;
        input [63:0] timestamp;
        input [7:0] version;
        integer i;
        reg [7:0] b;
        begin
            for (i = 0; i < 16; i = i + 1) begin
                case (i)
                    0: b = 8'h01;
                    1: b = version;
                    2, 3: b = 0;
                    4: b = seq_value[31:24];
                    5: b = seq_value[23:16];
                    6: b = seq_value[15:8];
                    7: b = seq_value[7:0];
                    8: b = timestamp[63:56];
                    9: b = timestamp[55:48];
                    10: b = timestamp[47:40];
                    11: b = timestamp[39:32];
                    12: b = timestamp[31:24];
                    13: b = timestamp[23:16];
                    14: b = timestamp[15:8];
                    default: b = timestamp[7:0];
                endcase
                @(negedge clk);
                rx_data = b;
                rx_valid = 1;
                rx_last = (i == 15);
            end
            @(negedge clk);
            rx_valid = 0;
            rx_last = 0;
            @(posedge clk);
            #1;
        end
    endtask

    // 接收 ACK 并检查内容及反压保持行为。
    task drain_ack;
        input [31:0] seq_value;
        integer i;
        reg [7:0] expected;
        begin
            if (!app_tx_valid || app_tx_src_udp != 4000 || app_tx_dst_udp != 4001)
                $fatal(1, "RTC ACK missing or UDP metadata wrong");
            for (i = 0; i < 16; i = i + 1) begin
                case (i)
                    0: expected = 8'h02;
                    1: expected = 8'h01;
                    2, 3: expected = 0;
                    4: expected = seq_value[31:24];
                    5: expected = seq_value[23:16];
                    6: expected = seq_value[15:8];
                    7: expected = seq_value[7:0];
                    8: expected = 8'h01;
                    15: expected = 8'h08;
                    default: expected = 0;
                endcase
                app_tx_ready = 0;
                #1;
                if (!app_tx_valid || app_tx_data !== expected || app_tx_last !== (i == 15))
                    $fatal(1, "RTC ACK byte %0d got %02h expected %02h", i, app_tx_data, expected);
                repeat (2) @(negedge clk);
                if (app_tx_data !== expected)
                    $fatal(1, "RTC ACK changed under backpressure");
                app_tx_ready = 1;
                @(negedge clk);
            end
            app_tx_ready = 0;
        end
    endtask

    // 执行协议场景并检查结果，失败时立即终止仿真。
    initial begin
        repeat (2) @(negedge clk);
        reset_n = 1;
        send_sync(32'd7, 64'h0100000000000008, 8'h01);
        #1;
        if (local_time !== 64'h0100000000000008 || sync_count != 1)
            $fatal(1, "RTC did not commit valid SYNC");
        drain_ack(32'd7);
        send_sync(32'd8, 64'h0100000000000009, 8'h02);
        if (sync_count != 1 || app_tx_valid)
            $fatal(1, "invalid version was accepted");
        send_sync(32'd7, 64'h0100000000000009, 8'h01);
        if (sync_count != 1 || local_time !== 64'h0100000000000008)
            $fatal(1, "duplicate seq_value updated RTC");
        drain_ack(32'd7);
        send_sync(32'd6, 64'h0100000000000009, 8'h01);
        if (sync_count != 1 || app_tx_valid)
            $fatal(1, "old RTC sequence was accepted");
        for (integer j = 0; j < 15; j = j + 1) begin
            @(negedge clk);
            rx_valid = 1;
            rx_last = (j == 14);
            rx_data = (j == 0 || j == 1) ? 8'h01 : 8'h00;
        end
        @(negedge clk);
        rx_valid = 0;
        rx_last = 0;
        @(posedge clk);
        #1;
        if (sync_count != 1 || app_tx_valid)
            $fatal(1, "short RTC payload was accepted");
        $display("PASS: RTC complete SYNC, validation, duplicate, ACK backpressure");
        $finish;
    end
endmodule
