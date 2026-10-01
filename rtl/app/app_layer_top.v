// Application-only integration. No AFDX RX/TX or network-layer logic here.
module app_layer_top #(
    parameter integer CLK_FREQ_HZ = 0,  // TBD
    parameter integer RTC_TICK_NS = 0,  // TBD
    parameter integer FILE_ADDR_WIDTH = 1,  // TBD
    parameter integer MAX_FILE_BYTES = 0,  // TBD
    parameter integer OID0_LEN = 0,
    parameter [127:0] OID0_DATA = 0,
    parameter integer OID1_LEN = 0,
    parameter [127:0] OID1_DATA = 0,
    parameter integer OID2_LEN = 0,
    parameter [127:0] OID2_DATA = 0
) (
    input wire clk,
    input wire reset_n,
    input wire [7:0] app_rx_data,
    input wire app_rx_valid,
    input wire app_rx_last,
    input wire [7:0] app_rx_port,
    input wire [15:0] app_rx_src_udp,
    input wire [15:0] app_rx_dst_udp,
    input wire [15:0] cfg_rtc_local_udp,
    input wire [15:0] cfg_rtc_remote_udp,
    input wire [15:0] cfg_tftp_local_tid,
    input wire [7:0] device_status,
    input wire [31:0] rx_packet_count,
    output wire snmp_enable_cfg,
    output wire [63:0] rtc_local_time,
    output wire rtc_sync_valid,
    output wire file_wr_en,
    output wire [FILE_ADDR_WIDTH-1:0] file_wr_addr,
    output wire [7:0] file_wr_data,
    output wire file_commit,
    output wire [31:0] file_written_size,
    output wire file_rd_req,
    output wire [FILE_ADDR_WIDTH-1:0] file_rd_addr,
    input wire [7:0] file_rd_data,
    input wire file_rd_valid,
    input wire [31:0] file_size,
    output wire tftp_session_valid,
    output wire tftp_timeout_error,
    output wire [7:0] tx_data,
    output wire tx_valid,
    input wire tx_ready,
    output wire tx_tlast,
    output wire [7:0] tx_port,
    output wire [15:0] app_upd_src_port,
    output wire [15:0] app_upd_dst_port
);
    wire [23:0] s_data;
    wire [2:0] s_valid, s_ready, s_last;
    wire [47:0] s_src_udp, s_dst_udp;

    // port 3 的接收载荷交给 SNMP，发送流接入仲裁源 0。
    app_snmp_agent #(
        .OID0_LEN(OID0_LEN),
        .OID0_DATA(OID0_DATA),
        .OID1_LEN(OID1_LEN),
        .OID1_DATA(OID1_DATA),
        .OID2_LEN(OID2_LEN),
        .OID2_DATA(OID2_DATA)
    ) snmp (
        .clk(clk),
        .reset_n(reset_n),
        .rx_data(app_rx_data),
        .rx_valid(app_rx_valid && app_rx_port == 8'd3),
        .rx_last(app_rx_last),
        .rx_src_udp(app_rx_src_udp),
        .rx_dst_udp(app_rx_dst_udp),
        .device_status(device_status),
        .rx_packet_count(rx_packet_count),
        .enable_cfg(snmp_enable_cfg),
        .app_tx_data(s_data[7:0]),
        .app_tx_valid(s_valid[0]),
        .app_tx_ready(s_ready[0]),
        .app_tx_last(s_last[0]),
        .app_tx_src_udp(s_src_udp[15:0]),
        .app_tx_dst_udp(s_dst_udp[15:0])
    );
    // port 4 的接收载荷交给 RTC，发送流接入仲裁源 1。
    app_rtc_sync #(
        .RTC_TICK_NS(RTC_TICK_NS)
    ) rtc (
        .clk(clk),
        .reset_n(reset_n),
        .cfg_local_udp(cfg_rtc_local_udp),
        .cfg_remote_udp(cfg_rtc_remote_udp),
        .rx_data(app_rx_data),
        .rx_valid(app_rx_valid && app_rx_port == 8'd4),
        .rx_last(app_rx_last),
        .local_time(rtc_local_time),
        .rtc_sync_valid(rtc_sync_valid),
        .app_tx_data(s_data[15:8]),
        .app_tx_valid(s_valid[1]),
        .app_tx_ready(s_ready[1]),
        .app_tx_last(s_last[1]),
        .app_tx_src_udp(s_src_udp[31:16]),
        .app_tx_dst_udp(s_dst_udp[31:16])
    );
    // port 5 的接收载荷交给 TFTP，发送流接入仲裁源 2。
    app_tftp_615a #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .FILE_ADDR_WIDTH(FILE_ADDR_WIDTH),
        .MAX_FILE_BYTES(MAX_FILE_BYTES)
    ) tftp (
        .clk(clk),
        .reset_n(reset_n),
        .cfg_local_tid(cfg_tftp_local_tid),
        .rx_data(app_rx_data),
        .rx_valid(app_rx_valid && app_rx_port == 8'd5),
        .rx_last(app_rx_last),
        .rx_src_udp(app_rx_src_udp),
        .rx_dst_udp(app_rx_dst_udp),
        .app_tx_data(s_data[23:16]),
        .app_tx_valid(s_valid[2]),
        .app_tx_ready(s_ready[2]),
        .app_tx_last(s_last[2]),
        .app_tx_src_udp(s_src_udp[47:32]),
        .app_tx_dst_udp(s_dst_udp[47:32]),
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
        .session_valid(tftp_session_valid),
        .timeout_error(tftp_timeout_error)
    );
    // 将三个应用发送流按完整报文仲裁到公共 TX 接口。
    app_tx_arbiter arbiter (
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
endmodule
