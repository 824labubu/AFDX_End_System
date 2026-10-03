`timescale 1 ps/1 ps

// Unified DUT boundary: UDP payload streams <-> two GMII networks.
// Port directions are relative to the end system, not the application.
// TX is implemented by AFDX_TX_MAC. RX ports reserve the future receive path;
// no received frame is delivered until a real RX implementation is connected.
// See doc/AFDX_End_System_Top_Interface.md for the interface contract.
module AFDX_End_System_top #(
    parameter integer MAX_PAYLOAD_BYTES = 1471,
    parameter integer MIN_FRAME_BYTES   = 60,
    parameter integer BAG_CYCLES        = 50000,
    parameter integer IFG_CYCLES        = 12,
    parameter [31:0] DEST_MAC_PREFIX    = 32'h03_00_00_00,
    parameter [15:0] ES1_USER_ID        = 16'h01_01,
    parameter [15:0] ES2_USER_ID        = 16'h01_02,
    parameter [7:0] PAD_BYTE            = 8'hAA,
    parameter integer VL_COUNT         = 5
)(
    input  wire        clk,
    input  wire        reset_n,

    // Application -> end system: complete UDP payload, one byte per handshake.
    input  wire [7:0]  app_tx_data,
    input  wire        app_tx_valid,
    output wire        app_tx_ready,
    input  wire        app_tx_last,
    input  wire [7:0]  app_tx_port,
    input  wire [15:0] app_tx_src_udp,
    input  wire [15:0] app_tx_dst_udp,

    // End system -> application: same handshake and metadata contract as TX.
    output wire [7:0]  app_rx_data,
    output wire        app_rx_valid,
    input  wire        app_rx_ready,
    output wire        app_rx_last,
    output wire [7:0]  app_rx_port,
    output wire [15:0] app_rx_src_udp,
    output wire [15:0] app_rx_dst_udp,

    // Both RX clocks must run for the current TX implementation to complete.
    // The legacy TX serializer also uses gmii_rx_clk_* as its transmit clock.
    input  wire        gmii_rx_clk_a,
    input  wire [7:0]  gmii_rxd_a,
    input  wire        gmii_rx_dv_a,
    input  wire        gmii_rx_er_a,
    output wire        gmii_tx_clk_a,
    output wire [7:0]  gmii_txd_a,
    output wire        gmii_tx_en_a,
    output wire        gmii_tx_er_a,
    output wire        phy_reset_n_a,

    input  wire        gmii_rx_clk_b,
    input  wire [7:0]  gmii_rxd_b,
    input  wire        gmii_rx_dv_b,
    input  wire        gmii_rx_er_b,
    output wire        gmii_tx_clk_b,
    output wire [7:0]  gmii_txd_b,
    output wire        gmii_tx_en_b,
    output wire        gmii_tx_er_b,
    output wire        phy_reset_n_b
);
    AFDX_TX_MAC #(
        .MAX_PAYLOAD_BYTES(MAX_PAYLOAD_BYTES),
        .MIN_FRAME_BYTES(MIN_FRAME_BYTES),
        .BAG_CYCLES(BAG_CYCLES),
        .IFG_CYCLES(IFG_CYCLES),
        .DEST_MAC_PREFIX(DEST_MAC_PREFIX),
        .ES1_USER_ID(ES1_USER_ID),
        .ES2_USER_ID(ES2_USER_ID),
        .PAD_BYTE(PAD_BYTE),
        .VL_COUNT(VL_COUNT)
    ) u_tx (
        .clk(clk),
        .reset(reset_n),
        .ff_tx_data(app_tx_data),
        .tx_valid(app_tx_valid),
        .tx_ready(app_tx_ready),
        .ff_tx_tlast(app_tx_last),
        .ff_tx_sop(1'b0), // First accepted byte is implicitly SOP.
        .tx_port(app_tx_port),
        .app_upd_src_port(app_tx_src_udp),
        .app_upd_dst_port(app_tx_dst_udp),

        .mdc_a(), .mdio_a(), .phy_rstb0_a(phy_reset_n_a),
        .p0_txc_a(1'b0), .p0_rxc_a(gmii_rx_clk_a),
        .p0_rxd_a(gmii_rxd_a), .p0_rxdv_a(gmii_rx_dv_a),
        .p0_rxer_a(gmii_rx_er_a), .p0_col_a(1'b0), .p0_crs_a(1'b0),
        .p0_gtxc_a(gmii_tx_clk_a), .p0_txd_a(gmii_txd_a),
        .p0_txen_a(gmii_tx_en_a), .p0_txer_a(gmii_tx_er_a),
        .reg_wr_a(1'b0), .reg_rd_a(1'b0), .reg_addr_a(4'd0),
        .reg_data_in_a(32'd0), .reg_data_out_a(), .reg_acc_bsy_a(),

        .mdc_b(), .mdio_b(), .phy_rstb0_b(phy_reset_n_b),
        .p0_txc_b(1'b0), .p0_rxc_b(gmii_rx_clk_b),
        .p0_rxd_b(gmii_rxd_b), .p0_rxdv_b(gmii_rx_dv_b),
        .p0_rxer_b(gmii_rx_er_b), .p0_col_b(1'b0), .p0_crs_b(1'b0),
        .p0_gtxc_b(gmii_tx_clk_b), .p0_txd_b(gmii_txd_b),
        .p0_txen_b(gmii_tx_en_b), .p0_txer_b(gmii_tx_er_b),
        .reg_wr_b(1'b0), .reg_rd_b(1'b0), .reg_addr_b(4'd0),
        .reg_data_in_b(32'd0), .reg_data_out_b(), .reg_acc_bsy_b()
    );

    // RX reservation: deterministic idle, including during reset. This is not
    // a GMII loopback or an application payload decoder. app_rx_ready will be
    // consumed by the future RX buffer/replay logic in the clk domain.
    assign app_rx_data    = 8'd0;
    assign app_rx_valid   = 1'b0;
    assign app_rx_last    = 1'b0;
    assign app_rx_port    = 8'd0;
    assign app_rx_src_udp = 16'd0;
    assign app_rx_dst_udp = 16'd0;
endmodule
