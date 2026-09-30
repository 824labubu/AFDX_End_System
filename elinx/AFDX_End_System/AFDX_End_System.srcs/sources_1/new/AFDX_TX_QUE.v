`timescale 1 ps/ 1 ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 09-30-2026 12:21:27
// Design Name:
// Module Name: AFDX_TX_QUE
// Project Name:
// Target Devices:
// Tool Versions:
// Description:队列端口 可处理8KB数据包
//
// Dependencies:
//
// Revision:
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module AFDX_TX_QUE#(
    parameter                                           MAX_PAYLOAD_LEN = 16'd1471,
    parameter                                           MAX_UDPH_LEN = MAX_PAYLOAD_LEN + 8,
    parameter                                           MAX_IP_LEN = MAX_UDPH_LEN + 20,
    parameter                                           MAX_ETH_LEN = MAX_IP_LEN + 14,
    parameter                                           ES1_USER_ID = 16'h01_01,
    parameter                                           ES2_USER_ID = 16'h01_02,
    parameter                                           PORT_QUE = 8'b0000_0010,
    parameter                                           VLID = 16'h00_02
)
(
    input                                               clk,
    input                                               reset,

    input [7:0]                                         tx_que_data,
    input                                               tx_que_valid,
    output reg                                          tx_que_ready,
    input                                               tx_que_sop,//高电平
    input                                               tx_que_tlast
    input                                               tx_que_sop,//高电平
    input [15:0]                                        tx_que_udp_len,

    // Application layer signals 
    input [15:0]                                        que_app_upd_src_port,
    input [15:0]                                        que_app_upd_dst_port,

    //MACA_GMII_PHY
    output                                              que_mdc_a,//PHY管理数据时钟
    inout                                               que_mdio_a, //PHY管理数据I/O
    output                                              que_phy_rstb0_a,//PHY复位信号

    output                                              que_p0_gtxc_a,//GMII发送时钟 125Mhz
    output [7:0]                                        que_p0_txd_a, //GMII发送数据
    output                                              que_p0_txen_a, //GMII发送使能
    output                                              que_p0_txer_a,//GMII发送错误

    output [31:0]                                       que_reg_data_out_a, //GMII寄存器数据输出
    output                                              que_reg_acc_bsy_a,//GMII寄存器访问忙信号

    //MACB_GMII_PHY
    output                                              que_mdc_b,//PHY管理数据时钟
    inout                                               que_mdio_b, //PHY管理数据I/O
    output                                              que_phy_rstb0_b,//PHY复位信号

    output                                              que_p0_gtxc_b,//GMII发送时钟 125Mhz
    output [7:0]                                        que_p0_txd_b, //GMII发送数据
    output                                              que_p0_txen_b, //GMII发送使能
    output                                              que_p0_txer_b,//GMII发送错误

    output [31:0]                                       que_reg_data_out_b, //GMII寄存器数据输出
    output                                              que_reg_acc_bsy_b //GMII寄存器访问忙信号

    );

    //payload define
    reg [MAX_PAYLOAD_LEN*8-1:0]                         que_data;
    reg [1:0]                                           que_state;
    reg [1:0]                                           que_state_next;
    reg [15:0]                                          que_data_cnt; //12'd 1471
    localparam                                          IDLE = 2'd0;
    localparam                                          RECEIVE = 2'd1;
    localparam                                          FULL = 2'd2;

    //udp config
    reg [MAX_UDPH_LEN*8-1:0]                            que_udp_data;
    reg [15:0]                                          que_src_udp_port;
    reg [15:0]                                          que_dst_udp_port;
    reg [15:0]                                          que_udp_len;

    //ip define
    reg [31:0]                                          que_src_ip;
    reg [31:0]                                          que_dst_ip;
    reg [3:0]                                           que_ip_version;
    reg [3:0]                                           que_ip_ihl;
    reg [7:0]                                           que_ip_tos;
    reg [15:0]                                          que_ip_len;
    reg [15:0]                                          que_identier;
    reg [2:0]                                           que_ip_flags;
    reg [12:0]                                          que_ip_offset;
    reg [15:0]                                          que_ip_ttl;
    reg [7:0]                                           que_ip_protocol;
    reg [15:0]                                          que_ip_checksum;
    reg [MAX_IP_LEN*8-1:0]                              que_iph_udph_data;

    reg [3:0]                                           ip_offset_cnt;

    //ethernet define
    reg [47:0]                                          que_src_mac_a;
    reg [47:0]                                          que_src_mac_b;
    reg [47:0]                                          que_dst_mac_a;
    reg [47:0]                                          que_dst_mac_b;
    reg [15:0]                                          que_eth_type;
    reg [MAX_ETH_LEN*8-1:0]                             que_etha_iph_udph_data;
    reg [MAX_ETH_LEN*8-1:0]                             que_ethb_iph_udph_data;


    //净荷整合
    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            que_state <= 'd0;
            que_state_next <= IDLE;
            que_data_cnt <= 'd0;
            que_data <= 'd0;
            tx_que_ready <= 1'b0;
        end
        else begin
            que_state <= que_state_next;
            case(que_state)
                IDLE: begin
                    if(tx_sam_valid && tx_sam_sop)begin
                        que_state_next <= RECEIVE;
                        que_data_cnt <= 'd0;
                        tx_que_ready <= 1'b1;
                        que_data <= {que_data, tx_que_data};
                    end   
                    else begin
                        que_state_next <= IDLE;
                        que_data_cnt <= 'd0;
                        tx_que_ready <= 1'b1;
                        que_data <= 'd0;
                    end
                end
                RECEIVE: begin
                    que_data_cnt <= que_data_cnt + 1'b1;
                    que_data <= {que_data, tx_que_data};
                    if((que_data_cnt == MAX_PAYLOAD_LEN - 1) && tx_que_tlast) begin
                        que_state_next <= FULL;
                    end 
                    else begin
                        que_state_next <= RECEIVE;
                    end
                end
                FULL: begin
                    tx_que_ready <= 1'b0;
                    if(~tx_que_valid) begin
                        que_state_next <= IDLE;
                    end 
                    else begin
                        que_state_next <= FULL;
                    end
                end
                default: que_state_next <= IDLE;
            endcase
        end
    end

    //udp config
    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            que_src_udp_port <= 'd0;
            que_dst_udp_port <= 'd0;
            que_udp_len <= 'd0;
            que_udp_data <= 'd0;
        end
        else if(tx_que_tlast && que_state == FULL)begin
            que_src_udp_port <= que_app_upd_src_port;
            que_dst_udp_port <= que_app_upd_dst_port;
            que_udp_len <= tx_que_udp_len + 16'd8;
            que_udp_data <= {que_src_udp_port,que_dst_udp_port,que_udp_len,16'h0000,que_data};
        end
    end

    //ip config
    function [15:0] ipv4_checksum;
    input [15:0] total_length;            // 当前分片的总长度
    input [15:0] identification;          // 同一原始报文的所有分片相同
    input [15:0] flags_fragment_offset;   // DF/MF/片偏移
    input [31:0] source_ip;
    input [31:0] destination_ip;

    reg [31:0] sum;

    begin
        sum = 32'd0;

        sum = sum + 32'h00004500;
        sum = sum + {16'd0, total_length};
        sum = sum + {16'd0, identification};
        sum = sum + {16'd0, flags_fragment_offset};
        sum = sum + 32'h00000111;  // TTL=1，UDP=17
        sum = sum + {16'd0, source_ip[31:16]};
        sum = sum + {16'd0, source_ip[15:0]};
        sum = sum + {16'd0, destination_ip[31:16]};
        sum = sum + {16'd0, destination_ip[15:0]};

        // 回卷进位，显式扩展避免丢失进位
        sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};
        sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};

        ipv4_checksum = ~sum[15:0];
    end
    endfunction
    
    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            que_src_ip <= 'd0;
            que_dst_ip <= 'd0;
            que_ip_version <= 'd0;
            que_ip_ihl <= 'd0;
            que_ip_tos <= 'd0;
            que_ip_len <= 'd0;
            que_identier <= 'd0;
            que_ip_flags <= 'd0;
            que_ip_offset <= 'd0;
            que_ip_ttl <= 'd0;
            que_ip_protocol <= 'd0;
            que_ip_checksum <= 'd0;
            ip_offset_cnt <= 'd0;
            que_iph_udph_data <= 'd0;
        end
        else if(tx_sam_tlast && sam_state == FULL)begin
            que_src_ip <= {8'h0A,ES1_USER_ID,PORT_QUE};
            que_dst_ip <= {8'h0A,ES2_USER_ID,PORT_QUE};
            que_ip_version <= 4'h4;
            que_ip_ihl <= 4'h5;
            que_ip_tos <= 8'h00;
            que_ip_len <= que_udp_len + 16'd20;
            que_identier <= que_identier + 1'd1;//更新标识符
            que_ip_ttl <= 8'h01;
            que_ip_protocol <= 8'h11; // UDP protocol 
            ip_offset_cnt <= 'd0;

            //分片处理
            if(que_ip_len >= 16'd1500)begin
                for(integer i = 0; i < que_ip_len; i = i + 1500)begin
                    que_ip_len <= 16'h1499;//分片 总长度要进行更新
                    que_identier <= que_identier;//分片标识符保持不变
                    que_ip_flags <= 3'b001;//可分片
                    que_ip_offset <= ip_offset_cnt * 184;
                    ip_offset_cnt <= ip_offset_cnt + 1'd1;
                    que_ip_checksum <= ipv4_checksum(que_ip_len, que_identier, {que_ip_flags,que_ip_offset},que_src_ip, que_dst_ip);
                    que_iph_udph_data <= {que_ip_version,que_ip_ihl,que_ip_tos,que_ip_len,que_identier,que_ip_flags,que_ip_offset,que_ip_ttl,que_ip_protocol,que_ip_checksum,que_src_ip,que_dst_ip,que_udp_data};
                end
            end
            //不分片
            else begin
                que_ip_flags <= 3'b010;
                que_ip_offset <= 13'b000_0000_000_00;
                que_ip_checksum <= ipv4_checksum(que_ip_len, que_identier, {que_ip_flags,que_ip_offset},que_src_ip, que_dst_ip); // initial checksum
                que_iph_udph_data <= {que_ip_version,que_ip_ihl,que_ip_tos,que_ip_len,que_identier,que_ip_flags,que_ip_offset,que_ip_ttl,que_ip_protocol,que_ip_checksum,que_src_ip,que_dst_ip,que_udp_data};
                
            end
            //最后一个分片处理
                que_ip_len <= que_ip_len - (ip_offset_cnt * 16'h1471);
                que_identier <= que_identier;
                que_ip_flags <= 3'b000;
                que_ip_offset <= 13'b000_0000_000_00;
                que_ip_checksum <= ipv4_checksum(que_ip_len, que_identier, {que_ip_flags,que_ip_offset},que_src_ip, que_dst_ip); 
                que_iph_udph_data <= {que_ip_version,que_ip_ihl,que_ip_tos,que_ip_len,que_identier,que_ip_flags,que_ip_offset,que_ip_ttl,que_ip_protocol,que_ip_checksum,que_src_ip,que_dst_ip,que_udp_data};
                
        end
    end 

     //ethernet config
    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            que_src_mac_a <= 'd0;
            que_src_mac_b <= 'd0;
            que_dst_mac_a <= 'd0;
            que_dst_mac_b <= 'd0;
            que_eth_type <= 'd0;
            que_etha_iph_udph_data <= 'd0;
            que_ethb_iph_udph_data <= 'd0;
        end
        else if(tx_que_tlast && que_state == FULL)begin
            que_src_mac_a <= {24'h02_00_00,ES1_USER_ID,8'h20};
            que_src_mac_b <= {24'h02_00_00,ES1_USER_ID,8'h40};
            que_dst_mac_a <= {32'h03_00_00_00,VLID};
            que_dst_mac_b <= {32'h03_00_00_00,VLID};
            que_eth_type <= 16'h0800; // IPv4 type
            que_etha_iph_udph_data <= {que_src_mac_a,que_dst_mac_a,que_eth_type,que_iph_udph_data};
            que_ethb_iph_udph_data <= {que_src_mac_b,que_dst_mac_b,que_eth_type,que_iph_udph_data};
        end
    end





endmodule
