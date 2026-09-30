`timescale 1 ps/ 1 ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 09-30-2026 16:47:05
// Design Name:
// Module Name: AFDX_TX_MAC
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
//
// Revision:
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module AFDX_TX_MAC #(
    parameter integer MAX_PAYLOAD_BYTES = 1471,
    parameter integer MIN_FRAME_BYTES   = 60,
    parameter integer BAG_CYCLES        = 50000,
    parameter integer IFG_CYCLES        = 12,
    parameter [31:0] DEST_MAC_PREFIX    = 32'h03_00_00_00,
    parameter [15:0] ES1_USER_ID        = 16'h01_01,
    parameter [15:0] ES2_USER_ID        = 16'h01_02,
    parameter [7:0]  PAD_BYTE           = 8'hAA,
    parameter integer VL_COUNT          = 5
)(
    input                                               clk,
    input                                               reset,

    input [7:0]                                         ff_tx_data,
    input                                               tx_valid,
    output                                              tx_ready,
    input                                               ff_tx_tlast,
    input                                               ff_tx_sop,
    input [7:0]                                         tx_port,

    // Application layer signals 
    input [15:0]                                        app_upd_src_port,
    input [15:0]                                        app_upd_dst_port,

    //MACA_GMII_PHY
    output                                              mdc_a,//PHY管理数据时钟
    inout                                               mdio_a, //PHY管理数据I/O
    output                                              phy_rstb0_a,//PHY复位信号
    input                                               p0_txc_a,
    input                                               p0_rxc_a,
    input [7:0]                                         p0_rxd_a,
    input                                               p0_rxdv_a,
    input                                               p0_rxer_a,
    input                                               p0_col_a,
    input                                               p0_crs_a,

    output                                              p0_gtxc_a,//GMII发送时钟 125Mhz
    output [7:0]                                        p0_txd_a, //GMII发送数据
    output                                              p0_txen_a, //GMII发送使能
    output                                              p0_txer_a,//GMII发送错误

    input                                               reg_wr_a,
    input                                               reg_rd_a,
    input [3:0]                                         reg_addr_a,
    input [31:0]                                        reg_data_in_a,
    output [31:0]                                       reg_data_out_a, //GMII寄存器数据输出
    output                                              reg_acc_bsy_a,//GMII寄存器访问忙信号

    //MACB_GMII_PHY
    output                                              mdc_b,//PHY管理数据时钟
    inout                                               mdio_b, //PHY管理数据I/O
    output                                              phy_rstb0_b,//PHY复位信号
    input                                               p0_txc_b,
    input                                               p0_rxc_b,
    input [7:0]                                         p0_rxd_b,
    input                                               p0_rxdv_b,
    input                                               p0_rxer_b,
    input                                               p0_col_b,
    input                                               p0_crs_b,

    output                                              p0_gtxc_b,//GMII发送时钟 125Mhz
    output [7:0]                                        p0_txd_b, //GMII发送数据
    output                                              p0_txen_b, //GMII发送使能
    output                                              p0_txer_b,//GMII发送错误

    input                                               reg_wr_b,
    input                                               reg_rd_b,
    input [3:0]                                         reg_addr_b,
    input [31:0]                                        reg_data_in_b,
    output [31:0]                                       reg_data_out_b, //GMII寄存器数据输出
    output                                              reg_acc_bsy_b //GMII寄存器访问忙信号


    );

    // The first accepted payload byte is SOP; ff_tx_sop is retained for
    // compatibility with the earlier wrapper interface.
    afdx_mac_tx #(
        .MAX_PAYLOAD_BYTES(MAX_PAYLOAD_BYTES),
        .MIN_FRAME_BYTES(MIN_FRAME_BYTES),
        .BAG_CYCLES(BAG_CYCLES),
        .IFG_CYCLES(IFG_CYCLES),
        .DEST_MAC_PREFIX(DEST_MAC_PREFIX),
        .ES1_USER_ID(ES1_USER_ID),
        .ES2_USER_ID(ES2_USER_ID),
        .PAD_BYTE(PAD_BYTE),
        .VL_COUNT(VL_COUNT)
    ) u_afdx_mac_tx (
        .clk(clk), .reset(reset),
        .tx_data(ff_tx_data), .tx_valid(tx_valid),
        .tx_ready(tx_ready), .tx_tlast(ff_tx_tlast), .tx_port(tx_port),
        .app_upd_src_port(app_upd_src_port),
        .app_upd_dst_port(app_upd_dst_port),
        .mdc_a(mdc_a), .mdio_a(mdio_a), .phy_rstb0_a(phy_rstb0_a),
        .p0_txc_a(p0_txc_a), .p0_rxc_a(p0_rxc_a),
        .p0_rxd_a(p0_rxd_a), .p0_rxdv_a(p0_rxdv_a),
        .p0_rxer_a(p0_rxer_a), .p0_col_a(p0_col_a), .p0_crs_a(p0_crs_a),
        .p0_gtxc_a(p0_gtxc_a), .p0_txd_a(p0_txd_a),
        .p0_txen_a(p0_txen_a), .p0_txer_a(p0_txer_a),
        .reg_wr_a(reg_wr_a), .reg_rd_a(reg_rd_a),
        .reg_addr_a(reg_addr_a), .reg_data_in_a(reg_data_in_a),
        .reg_data_out_a(reg_data_out_a), .reg_acc_bsy_a(reg_acc_bsy_a),
        .mdc_b(mdc_b), .mdio_b(mdio_b), .phy_rstb0_b(phy_rstb0_b),
        .p0_txc_b(p0_txc_b), .p0_rxc_b(p0_rxc_b),
        .p0_rxd_b(p0_rxd_b), .p0_rxdv_b(p0_rxdv_b),
        .p0_rxer_b(p0_rxer_b), .p0_col_b(p0_col_b), .p0_crs_b(p0_crs_b),
        .p0_gtxc_b(p0_gtxc_b), .p0_txd_b(p0_txd_b),
        .p0_txen_b(p0_txen_b), .p0_txer_b(p0_txer_b),
        .reg_wr_b(reg_wr_b), .reg_rd_b(reg_rd_b),
        .reg_addr_b(reg_addr_b), .reg_data_in_b(reg_data_in_b),
        .reg_data_out_b(reg_data_out_b), .reg_acc_bsy_b(reg_acc_bsy_b)
    );
endmodule
