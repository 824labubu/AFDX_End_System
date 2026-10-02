`timescale 1ns / 1ps

// 无 cocotb 依赖的兜底测试只检查应用握手和双网回环连线。
module tb_afdx_v1_smoke;
    reg clk = 0;
    reg reset_n = 0;
    reg [7:0] app_data = 0;
    reg app_valid = 0;
    wire app_ready;
    reg app_last = 0;
    reg [15:0] app_src_udp = 40000;
    reg [15:0] app_dst_udp = 161;
    reg [7:0] app_port = 3;
    wire [7:0] observed_data;
    wire observed_valid;
    reg observed_ready = 0;
    wire observed_last;
    wire [15:0] observed_src_udp;
    wire [15:0] observed_dst_udp;
    wire [7:0] observed_port;
    reg gmii_rx_clk_a = 0;
    reg [7:0] gmii_rxd_a = 0;
    reg gmii_rx_dv_a = 0;
    reg gmii_rx_er_a = 0;
    wire gmii_tx_clk_a;
    wire [7:0] gmii_txd_a;
    wire gmii_tx_en_a;
    wire gmii_tx_er_a;
    reg gmii_rx_clk_b = 0;
    reg [7:0] gmii_rxd_b = 0;
    reg gmii_rx_dv_b = 0;
    reg gmii_rx_er_b = 0;
    wire gmii_tx_clk_b;
    wire [7:0] gmii_txd_b;
    wire gmii_tx_en_b;
    wire gmii_tx_er_b;
    integer accepted = 0;
    integer i;

    always #10 clk = ~clk;
    always #4 gmii_rx_clk_a = ~gmii_rx_clk_a;
    always #4 gmii_rx_clk_b = ~gmii_rx_clk_b;

    afdx_infrastructure_harness fixture (
        .clk(clk),
        .reset_n(reset_n),
        .app_data(app_data),
        .app_valid(app_valid),
        .app_ready(app_ready),
        .app_last(app_last),
        .app_src_udp(app_src_udp),
        .app_dst_udp(app_dst_udp),
        .app_port(app_port),
        .observed_data(observed_data),
        .observed_valid(observed_valid),
        .observed_ready(observed_ready),
        .observed_last(observed_last),
        .observed_src_udp(observed_src_udp),
        .observed_dst_udp(observed_dst_udp),
        .observed_port(observed_port),
        .gmii_rx_clk_a(gmii_rx_clk_a),
        .gmii_rxd_a(gmii_rxd_a),
        .gmii_rx_dv_a(gmii_rx_dv_a),
        .gmii_rx_er_a(gmii_rx_er_a),
        .gmii_tx_clk_a(gmii_tx_clk_a),
        .gmii_txd_a(gmii_txd_a),
        .gmii_tx_en_a(gmii_tx_en_a),
        .gmii_tx_er_a(gmii_tx_er_a),
        .gmii_rx_clk_b(gmii_rx_clk_b),
        .gmii_rxd_b(gmii_rxd_b),
        .gmii_rx_dv_b(gmii_rx_dv_b),
        .gmii_rx_er_b(gmii_rx_er_b),
        .gmii_tx_clk_b(gmii_tx_clk_b),
        .gmii_txd_b(gmii_txd_b),
        .gmii_tx_en_b(gmii_tx_en_b),
        .gmii_tx_er_b(gmii_tx_er_b)
    );

    // 比较被接收字节和元信息，末字节只能出现在第四拍。
    always @(posedge clk) begin
        if (reset_n && observed_valid && observed_ready) begin
            if (observed_data !== accepted || observed_port !== 3 ||
                observed_src_udp !== 40000 || observed_dst_udp !== 161 ||
                observed_last !== (accepted == 3))
                $fatal(1, "SV smoke application mismatch at byte %0d", accepted);
            accepted = accepted + 1;
        end
    end

    initial begin
        repeat (3) @(negedge clk);
        reset_n = 1;
        app_valid = 1;
        repeat (3) @(negedge clk);
        if (accepted != 0)
            $fatal(1, "accepted data during backpressure");
        observed_ready = 1;
        for (i = 0; i < 4; i = i + 1) begin
            app_data = i;
            app_last = (i == 3);
            if (i == 3) begin
                observed_ready = 0;
                repeat (2) @(negedge clk);
                observed_ready = 1;
            end
            @(negedge clk);
        end
        app_valid = 0;
        app_last = 0;
        if (accepted != 4)
            $fatal(1, "SV smoke missing application bytes");
        gmii_rxd_a = 8'h55;
        gmii_rxd_b = 8'hd5;
        gmii_rx_dv_a = 1;
        gmii_rx_dv_b = 1;
        @(posedge gmii_rx_clk_a);
        #1;
        if (gmii_txd_a !== 8'h55 || gmii_txd_b !== 8'hd5 ||
            !gmii_tx_en_a || !gmii_tx_en_b || gmii_tx_er_a || gmii_tx_er_b)
            $fatal(1, "SV smoke GMII loopback mismatch");
        $display("PASS: independent AFDX V1 infrastructure smoke");
        $finish;
    end

    // 超过测试期限则自动失败。
    initial begin
        #10000;
        $fatal(1, "TIMEOUT: independent SV smoke");
    end
endmodule
