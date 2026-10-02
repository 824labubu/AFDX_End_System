`timescale 1ns / 1ps

// 验证夹具只连接真实应用仲裁器和 GMII 回环，不实现协议封装。
module afdx_infrastructure_harness (
    input wire clk,
    input wire reset_n,
    input wire [7:0] app_data,
    input wire app_valid,
    output wire app_ready,
    input wire app_last,
    input wire [15:0] app_src_udp,
    input wire [15:0] app_dst_udp,
    input wire [7:0] app_port,
    output wire [7:0] observed_data,
    output wire observed_valid,
    input wire observed_ready,
    output wire observed_last,
    output wire [15:0] observed_src_udp,
    output wire [15:0] observed_dst_udp,
    output wire [7:0] observed_port,
    input wire gmii_rx_clk_a,
    input wire [7:0] gmii_rxd_a,
    input wire gmii_rx_dv_a,
    input wire gmii_rx_er_a,
    output wire gmii_tx_clk_a,
    output reg [7:0] gmii_txd_a,
    output reg gmii_tx_en_a,
    output reg gmii_tx_er_a,
    input wire gmii_rx_clk_b,
    input wire [7:0] gmii_rxd_b,
    input wire gmii_rx_dv_b,
    input wire gmii_rx_er_b,
    output wire gmii_tx_clk_b,
    output reg [7:0] gmii_txd_b,
    output reg gmii_tx_en_b,
    output reg gmii_tx_er_b
);
    wire [2:0] source_valid;
    wire [2:0] source_ready;

    // 应用类别决定仲裁源，所有源共享外部驱动的数据和元信息。
    assign source_valid[0] = app_valid && app_port == 8'd3;
    assign source_valid[1] = app_valid && app_port == 8'd4;
    assign source_valid[2] = app_valid && app_port == 8'd5;
    assign app_ready = (app_port >= 3 && app_port <= 5) ? source_ready[app_port-3] : 0;

    app_tx_arbiter dut (
        .clk(clk),
        .reset_n(reset_n),
        .s_data({3{app_data}}),
        .s_valid(source_valid),
        .s_ready(source_ready),
        .s_last({3{app_last}}),
        .s_src_udp({3{app_src_udp}}),
        .s_dst_udp({3{app_dst_udp}}),
        .tx_data(observed_data),
        .tx_valid(observed_valid),
        .tx_ready(observed_ready),
        .tx_tlast(observed_last),
        .tx_port(observed_port),
        .app_upd_src_port(observed_src_udp),
        .app_upd_dst_port(observed_dst_udp)
    );

    app_stream_assertions input_check (
        .clk(clk),
        .reset_n(reset_n),
        .data(app_data),
        .valid(app_valid),
        .ready(app_ready),
        .last(app_last),
        .src_udp(app_src_udp),
        .dst_udp(app_dst_udp),
        .application_port(app_port)
    );

    app_stream_assertions output_check (
        .clk(clk),
        .reset_n(reset_n),
        .data(observed_data),
        .valid(observed_valid),
        .ready(observed_ready),
        .last(observed_last),
        .src_udp(observed_src_udp),
        .dst_udp(observed_dst_udp),
        .application_port(observed_port)
    );

    // 逐网寄存一拍的回环只用于验证第三方 Source/Sink 接入。
    assign gmii_tx_clk_a = gmii_rx_clk_a;
    assign gmii_tx_clk_b = gmii_rx_clk_b;

    always @(posedge gmii_rx_clk_a or negedge reset_n) begin
        if (!reset_n) begin
            gmii_txd_a <= 0;
            gmii_tx_en_a <= 0;
            gmii_tx_er_a <= 0;
        end else begin
            gmii_txd_a <= gmii_rxd_a;
            gmii_tx_en_a <= gmii_rx_dv_a;
            gmii_tx_er_a <= gmii_rx_er_a;
        end
    end

    always @(posedge gmii_rx_clk_b or negedge reset_n) begin
        if (!reset_n) begin
            gmii_txd_b <= 0;
            gmii_tx_en_b <= 0;
            gmii_tx_er_b <= 0;
        end else begin
            gmii_txd_b <= gmii_rxd_b;
            gmii_tx_en_b <= gmii_rx_dv_b;
            gmii_tx_er_b <= gmii_rx_er_b;
        end
    end
endmodule
