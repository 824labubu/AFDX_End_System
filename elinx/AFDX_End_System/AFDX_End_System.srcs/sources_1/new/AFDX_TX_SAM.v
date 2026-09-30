`timescale 1 ps/ 1 ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 09-30-2026 12:20:59
// Design Name:
// Module Name: AFDX_TX_SAM
// Project Name:
// Target Devices:
// Tool Versions:
// Description: 采样端口 20 Bytes = Rserved/4 + FSS/4 + 空速/4 + 高度/4 + 工作模式/4
//
// Dependencies:
//
// Revision:
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module AFDX_TX_SAM#(
    parameter                                           MAX_PAYLOAD_LEN = 12'd1471,
    parameter                                           MAX_UDPH_LEN = MAX_PAYLOAD_LEN + 8,
    parameter                                           MAX_IP_LEN = MAX_UDPH_LEN + 20,
    parameter                                           MAX_ETH_LEN = MAX_IP_LEN + 14,
    parameter                                           ES1_USER_ID = 16'h01_01,
    parameter                                           ES2_USER_ID = 16'h01_02,
    parameter                                           PORT_SAM = 8'b0000_0001,
    parameter                                           VLID = 16'h00_01
)
(
    input                                               clk,
    input                                               reset,

    input [7:0]                                         tx_sam_data,
    input                                               tx_sam_valid,
    output reg                                          tx_sam_ready,
    input                                               tx_sam_tlast,//高电平
    input                                               tx_sam_sop,//高电平
    input [15:0]                                        tx_sam_udp_len,

    // Application layer signals 
    input [15:0]                                        sam_app_upd_src_port,
    input [15:0]                                        sam_app_upd_dst_port,

    //MACA_GMII_PHY
    output                                              sam_mdc_a,//PHY管理数据时钟
    inout                                               sam_mdio_a, //PHY管理数据I/O
    output                                              sam_phy_rstb0_a,//PHY复位信号

    output                                              sam_p0_gtxc_a,//GMII发送时钟 125Mhz
    output [7:0]                                        sam_p0_txd_a, //GMII发送数据
    output                                              sam_p0_txen_a, //GMII发送使能
    output                                              sam_p0_txer_a,//GMII发送错误

    output [31:0]                                       sam_reg_data_out_a, //GMII寄存器数据输出
    output                                              sam_reg_acc_bsy_a,//GMII寄存器访问忙信号

    //MACB_GMII_PHY
    output                                              sam_mdc_b,//PHY管理数据时钟
    inout                                               sam_mdio_b, //PHY管理数据I/O
    output                                              sam_phy_rstb0_b,//PHY复位信号

    output                                              sam_p0_gtxc_b,//GMII发送时钟 125Mhz
    output [7:0]                                        sam_p0_txd_b, //GMII发送数据
    output                                              sam_p0_txen_b, //GMII发送使能
    output                                              sam_p0_txer_b,//GMII发送错误

    output [31:0]                                       sam_reg_data_out_b, //GMII寄存器数据输出
    output                                              sam_reg_acc_bsy_b //GMII寄存器访问忙信号

    );

    //payload define
    reg [MAX_PAYLOAD_LEN*8-1:0]                         sam_data;
    reg [1:0]                                           sam_state;
    reg [1:0]                                           sam_state_next;
    reg [15:0]                                          sam_data_cnt; //12'd 1471
    localparam                                          IDLE = 2'd0;
    localparam                                          RECEIVE = 2'd1;
    localparam                                          FULL = 2'd2;

    //udp config
    reg [MAX_UDPH_LEN*8-1:0]                            sam_udp_data;
    reg [15:0]                                          sam_src_udp_port;
    reg [15:0]                                          sam_dst_udp_port;
    reg [15:0]                                          sam_udp_len;

    //ip define
    reg [31:0]                                          sam_src_ip;
    reg [31:0]                                          sam_dst_ip;
    reg [3:0]                                           sam_ip_version;
    reg [3:0]                                           sam_ip_ihl;
    reg [7:0]                                           sam_ip_tos;
    reg [15:0]                                          sam_ip_len;
    reg [15:0]                                          sam_identier;
    reg [2:0]                                           sam_ip_flags;
    reg [12:0]                                          sam_ip_offset;
    reg [15:0]                                          sam_ip_ttl;
    reg [7:0]                                           sam_ip_protocol;
    reg [15:0]                                          sam_ip_checksum;
    reg [MAX_IP_LEN*8-1:0]                              sam_iph_udph_data;

    //ethernet define
    reg [47:0]                                          sam_src_mac_a;
    reg [47:0]                                          sam_src_mac_b;
    reg [47:0]                                          sam_dst_mac_a;
    reg [47:0]                                          sam_dst_mac_b;
    reg [15:0]                                          sam_eth_type;
    reg [MAX_ETH_LEN*8-1:0]                             sam_etha_iph_udph_data;
    reg [MAX_ETH_LEN*8-1:0]                             sam_ethb_iph_udph_data;

    //净荷整合
    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            sam_state <= 'd0;
            sam_state_next <= IDLE;
            sam_data_cnt <= 'd0;
            sam_data <= 'd0;
            tx_sam_ready <= 1'b0;
        end
        else begin
            sam_state <= sam_state_next;
            case(sam_state)
                IDLE: begin
                    if(tx_sam_valid && tx_sam_sop)begin
                        sam_state_next <= RECEIVE;
                        sam_data_cnt <= 'd0;
                        tx_sam_ready <= 1'b1;
                        sam_data <= {sam_data, tx_sam_data};
                    end   
                    else begin
                        sam_state_next <= IDLE;
                        sam_data_cnt <= 'd0;
                        tx_sam_ready <= 1'b1;
                        sam_data <= 'd0;
                    end
                end
                RECEIVE: begin
                    sam_data_cnt <= sam_data_cnt + 1'b1;
                    sam_data <= {sam_data, tx_sam_data};
                    if((sam_data_cnt == MAX_PAYLOAD_LEN - 1) && tx_sam_tlast) begin
                        sam_state_next <= FULL;
                    end 
                    else begin
                        sam_state_next <= RECEIVE;
                    end
                end
                FULL: begin
                    tx_sam_ready <= 1'b0;
                    if(~tx_sam_valid) begin
                        sam_state_next <= IDLE;
                    end 
                    else begin
                        sam_state_next <= FULL;
                    end
                end
                default: sam_state_next <= IDLE;
            endcase
        end
    end


    //udp config
    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            sam_src_udp_port <= 'd0;
            sam_dst_udp_port <= 'd0;
            sam_udp_len <= 'd0;
            sam_udp_data <= 'd0;
        end
        else if(tx_sam_tlast && sam_state == FULL)begin
            sam_src_udp_port <= sam_app_upd_src_port;
            sam_dst_udp_port <= sam_app_upd_dst_port;
            sam_udp_len <= tx_sam_udp_len + 16'd8;
            sam_udp_data <= {sam_src_udp_port,sam_dst_udp_port,sam_udp_len,16'h0000,sam_data};
        end
    end

    //ip config
    function [15:0] ipv4_checksum;
        input [15:0] total_length;
        input [31:0] source_ip;
        input [31:0] destination_ip;
        reg [31:0] sum;
        begin
            // IPv4 words: 4500, total length, ID=0, flags/offset=4000,
            // TTL=1 and UDP protocol=11, followed by both addresses.
            sum = 32'd0;
            sum = sum + 16'h4500;
            sum = sum + total_length;
            sum = sum + 16'h0000;
            sum = sum + 16'h4000;
            sum = sum + 16'h0111;
            sum = sum + source_ip[31:16] + source_ip[15:0];
            sum = sum + destination_ip[31:16] + destination_ip[15:0];
            sum = sum[15:0] + sum[31:16];
            sum = sum[15:0] + sum[31:16];
            ipv4_checksum = ~sum[15:0];
        end
    endfunction
    
    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            sam_src_ip <= 'd0;
            sam_dst_ip <= 'd0;
            sam_ip_version <= 'd0;
            sam_ip_ihl <= 'd0;
            sam_ip_tos <= 'd0;
            sam_ip_len <= 'd0;
            sam_identier <= 'd0;
            sam_ip_flags <= 'd0;
            sam_ip_offset <= 'd0;
            sam_ip_ttl <= 'd0;
            sam_ip_protocol <= 'd0;
            sam_ip_checksum <= 'd0;
            sam_iph_udph_data <= 'd0;
        end
        else if(tx_sam_tlast && sam_state == FULL)begin
            sam_src_ip <= {8'h0A,ES1_USER_ID,PORT_SAM};
            sam_dst_ip <= {24'hF4_F4,VLID};
            sam_ip_version <= 4'h4;
            sam_ip_ihl <= 4'h5;
            sam_ip_tos <= 8'h00;
            sam_ip_len <= sam_udp_len + 16'd20;
            sam_identier <= sam_identier + 1'd1;
            sam_ip_flags <= 3'b010;
            sam_ip_offset <= 13'b000_0000_000_00;
            sam_ip_ttl <= 8'h01;
            sam_ip_protocol <= 8'h11; // UDP protocol 
            sam_ip_checksum <= ipv4_checksum
            sam_ip_checksum <= ipv4_checksum(sam_ip_len, sam_src_ip, sam_dst_ip); // initial checksum
            sam_iph_udph_data <= {sam_ip_version,sam_ip_ihl,sam_ip_tos,sam_ip_len,sam_identier,sam_ip_flags,sam_ip_offset,sam_ip_ttl,sam_ip_protocol,sam_ip_checksum,sam_src_ip,sam_dst_ip,sam_udp_data};
        end
    end 

    //ethernet config
    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            sam_src_mac_a <= 'd0;
            sam_src_mac_b <= 'd0;
            sam_dst_mac_a <= 'd0;
            sam_dst_mac_b <= 'd0;
            sam_eth_type <= 'd0;
            sam_etha_iph_udph_data <= 'd0;
            sam_ethb_iph_udph_data <= 'd0;

        end
        else if(tx_sam_tlast && sam_state == FULL)begin
            sam_src_mac_a <= {24'h02_00_00,ES1_USER_ID,8'h20};
            sam_src_mac_b <= {24'h02_00_00,ES1_USER_ID,8'h40};
            sam_dst_mac_a <= {32'h03_00_00_00,VLID};
            sam_dst_mac_b <= {32'h03_00_00_00,VLID};
            sam_eth_type <= 16'h0800; // IPv4 type
            sam_etha_iph_udph_data <= {sam_src_mac_a,sam_dst_mac_a,sam_eth_type,sam_iph_udph_data};
            sam_ethb_iph_udph_data <= {sam_src_mac_b,sam_dst_mac_b,sam_eth_type,sam_iph_udph_data};
        end
    end

endmodule
