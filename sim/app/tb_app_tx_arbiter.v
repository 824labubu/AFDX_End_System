`timescale 1ns / 1ps
module tb_app_tx_arbiter;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset_n = 0;
    reg [23:0] s_data = 24'hc0b0a0;
    reg [2:0] s_valid = 3'b111;
    wire [2:0] s_ready;
    reg [2:0] s_last = 0;
    reg [47:0] s_src_udp = {16'd500, 16'd400, 16'd161};
    reg [47:0] s_dst_udp = {16'd69, 16'd401, 16'd900};
    wire [7:0] tx_data;
    wire tx_valid, tx_tlast;
    reg tx_ready = 0;
    wire [7:0] tx_port;
    wire [15:0] app_upd_src_port, app_upd_dst_port;

    app_tx_arbiter dut (
        .clk(clk),
        .reset_n(reset_n),
        .s_data(s_data),
        .s_valid(s_valid),
        .s_ready(s_ready),
        .s_last(s_last),
        .s_src_udp(s_src_udp),
        .s_dst_udp(s_dst_udp),
        .tx_data(tx_data),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_tlast(tx_tlast),
        .tx_port(tx_port),
        .app_upd_src_port(app_upd_src_port),
        .app_upd_dst_port(app_upd_dst_port)
    );

    // 检查当前仲裁输出的数据、末字节和端口信息。
    task check;
        input [7:0] exp_data;
        input [7:0] exp_port;
        input exp_last;
        input [15:0] exp_src;
        input [15:0] exp_dst;
        begin
            #1;
            if (!tx_valid || tx_data !== exp_data || tx_port !== exp_port ||
                tx_tlast !== exp_last || app_upd_src_port !== exp_src ||
                app_upd_dst_port !== exp_dst)
                $fatal(1, "arbiter mismatch data=%h port=%d last=%b", tx_data, tx_port, tx_tlast);
        end
    endtask

    // 执行协议场景并检查结果，失败时立即终止仿真。
    initial begin
        repeat (2) @(negedge clk);
        reset_n = 1;
        tx_ready = 1;
        check(8'ha0, 8'd3, 0, 16'd161, 16'd900);
        @(negedge clk);
        s_data[7:0] = 8'ha1;
        s_last[0] = 1;
        tx_ready = 0;
        check(8'ha1, 8'd3, 1, 16'd161, 16'd900);
        repeat (3) @(negedge clk);
        check(8'ha1, 8'd3, 1, 16'd161, 16'd900);
        tx_ready = 1;
        @(negedge clk);
        s_valid[0] = 0;
        check(8'hb0, 8'd4, 0, 16'd400, 16'd401);
        @(negedge clk);
        s_data[15:8] = 8'hb1;
        s_last[1] = 1;
        check(8'hb1, 8'd4, 1, 16'd400, 16'd401);
        @(negedge clk);
        s_valid[1] = 0;
        check(8'hc0, 8'd5, 0, 16'd500, 16'd69);
        @(negedge clk);
        s_data[23:16] = 8'hc1;
        s_last[2] = 1;
        check(8'hc1, 8'd5, 1, 16'd500, 16'd69);
        @(negedge clk);
        s_valid[2] = 0;
        #1;
        if (tx_valid || s_ready !== 0)
            $fatal(1, "arbiter did not become idle");
        $display("PASS: app_tx_arbiter whole-message grant and backpressure");
        $finish;
    end
endmodule
