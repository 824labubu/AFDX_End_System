`timescale 1 ps/ 1 ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 09-26-2026 17:02:10
// Design Name:
// Module Name: AFDX_TX
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


module AFDX_TX(
    input                                               clk,
    input                                               reset,

    input [7:0]                                         rx_data,
    input                                               rx_valid,
    input                                               rx_ready,

    //MACA_GMII_PHY
    output                                              mdc_a,//PHY管理数据时钟
    inout                                               mdio_a, //PHY管理数据I/O
    output                                              phy_rstb0_a,//PHY复位信号

    output                                              p0_gtxc_a,//GMII发送时钟 125Mhz
    output [7:0]                                        p0_txd_a, //GMII发送数据
    output                                              p0_txen_a, //GMII发送使能
    output                                              p0_txer_a,//GMII发送错误

    output [31:0]                                       reg_data_out_a, //GMII寄存器数据输出
    output                                              reg_acc_bsy_a,//GMII寄存器访问忙信号

    //MACB_GMII_PHY
    output                                              mdc_b,//PHY管理数据时钟
    inout                                               mdio_b, //PHY管理数据I/O
    output                                              phy_rstb0_b,//PHY复位信号

    output                                              p0_gtxc_b,//GMII发送时钟 125Mhz
    output [7:0]                                        p0_txd_b, //GMII发送数据
    output                                              p0_txen_b, //GMII发送使能
    output                                              p0_txer_b,//GMII发送错误

    output [31:0]                                       reg_data_out_b, //GMII寄存器数据输出
    output                                              reg_acc_bsy_b //GMII寄存器访问忙信号

    );

    parameter                                         SAM = 8'b0000_0001;
    parameter                                         QUE = 8'b0000_0010;
    parameter                                         SAP_SNMP = 8'b0000_0011;
    parameter                                         SAP_RTC = 8'b0000_0100;
    parameter                                         SAP_615A = 8'b0000_0101;

    reg [15:0]                                        src_udp;
    reg [15:0]                                        dst_udp;
    reg [31:0]                                        src_ip;
    reg [31:0]                                        dst_ip;
    reg [47:0]                                        src_mac_a;
    reg [47:0]                                        dst_mac_a;
    reg [47:0]                                        src_mac_b;
    reg [47:0]                                        dst_mac_b;

    //fifo_que define
    wire                                              almost_full;
    wire                                              almost_empty;
    wire                                              empty;
    wire                                              full; 
    wire [7:0]                                        q;
    //pad_bits
    reg [127:0]                                       pad_bits;
    
    //udp define
    reg [135:0]                                       udp_data; 
    reg [15:0]                                        udp_payload_len;
    reg [15:0]                                        udp_checksum;
    reg [199:0]                                       udph_data;

    //ip define
    reg [3:0]                                         ip_version;
    reg [3:0]                                         ip_header_len;
    reg [7:0]                                         ip_tos;
    reg [15:0]                                        ip_total_len;
    wire [15:0]                                       ip_identier;//标识符（分片重组）
    reg [2:0]                                         ip_flags;//标志位
    reg [12:0]                                        ip_framented_offset;
    reg [7:0]                                         ip_ttl;
    reg [7:0]                                         ip_protocol;
    reg [15:0]                                        ip_checksum;

    reg [15:0]                                        ip_id_cnt;
    reg [3:0]                                         ip_offest;// 8200/1500=5
    reg [159:0]                                       iph_data;    
    reg [15:0]                                        ip_packet[0:9];//ipv4分组
    reg [16:0]                                        iph_checksum;   
    reg [359:0]                                       iph_udph_data;

    //ethernet define
    reg [15:0]                                        eth_type;
    reg [471:0]                                       eth_iph_udph_data;

    wire [255:0]                                      afdx0_data;
    wire                                              afdx0_almost_full;
    wire                                              afdx0_almost_empty;
    wire                                              afdx0_empty;
    wire                                              afdx0_full;
    wire [255:0]                                      afdx1_data;
    wire                                              afdx1_almost_full;
    wire                                              afdx1_almost_empty;
    wire                                              afdx1_empty;
    wire                                              afdx1_full;
   
    wire [7:0]                                        port_sel;
    assign port_sel = src_ip[7:0];

    //PORT Selection
    always@(*)
    begin
        case (port_sel)
            8'b0000_0001:   port = SAM;
            8'b0000_0010:   port = QUE;
            8'b0000_0011:   port = SAP_SNMP;
            8'b0000_0100:   port = SAP_RTC;
            8'b0000_0101:   port = SAP_615A;
            default:   port = 8'b0000_0000; // Default port assignment
        endcase

    end

    //-----------------------------------QUE PORT--------------------------------------
    //fifo_que
    FIFO_QUE fifo_que_inst (
		.clock (clk),          //input    clock
		.data (tx_data),            //input    [7:0]    data
		.rdreq (~empty)
		.wrreq (~full),          //input    wrreq
		.almost_empty (almost_empty),//output    almost_empty
		.almost_full (almost_full),//output    almost_full
		.empty (empty),          //output    empty
		.full (full),            //output    full
		.q (q)                   //output    [7:0]    q
    );

    //pad_bits function
    function pad_afdx_bits;
        input [4:0]                  pad_bytes_len;
    
        for(int i = 0; i < pad_bytes_len; i++) begin
            pad_afdx_bits[i*8 +: 8] <= 8'hAA;
        end
        
    endfunction


    //udp config
    always@(*)
    begin
        case(port)
            SAM:
            begin
                src_udp = 16'h2710;
                dst_udp = 16'h2710;//10000    
            end
            QUE:
            begin
                src_udp = 16'h2AF8;
                dst_udp = 16'h2AF8;//11000
            end
            SAP_SNMP:
            begin
                src_udp = 16'h00A1;//161
                dst_udp = 16'h00A1;
            end
            SAP_RTC:
            begin
                src_udp = 16'h4E20;//20000
                dst_udp = 16'h4E20;
            end
            SAP_615A://问题一：请求一次 数据一次
            begin
                src_udp = 16'hAFC8;//45000
                dst_udp = 16'h0045;//69
            end
        endcase

    end

    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            udp_data <= 'd0;
            pad_bits <= 'd0;
            udp_payload_len <= 'd0;
            udp_checksum <= 'd0;

        end
        else begin
            pad_bits <= pad_afdx_bits(16);
            udp_data <= {q,pad_bits};
            udp_payload_len <= 1 /*payload_len*/ + 8;
            udp_checksum <= 16'h0;

        end
    end

    always@(posedge clk or negedge reset)begin
        if(~reset)
            udph_data <= 'd0;
        else
            udph_data <= {src_udp,dst_udp,udp_payload_len,udp_checksum,udp_data};
    end

    //ip config
    always@(*)begin//问题二：判断目的IP是单播还是多播
        case(port)
            SAM:
            begin
                src_ip = 32'h0A_01_01_01;//设备ID: ES1 0X_0101 ES2: 0X_0102
                dst_ip = 32'hF4_F4_00_01;//多播IP 标识VL
            end
            QUE:
            begin
                src_ip = 32'h0A_01_01_02;
                dst_ip = 32'h0A_01_02_02;
            end
            SAP_SNMP:
            begin
                src_ip = 32'h0A_01_01_03;
                dst_ip = 32'h0A_01_02_03;
            end
            SAP_RTC:
            begin
                src_ip = 32'h0A_01_01_04;
                dst_ip = 32'h0A_01_02_04;
            end
            SAP_615A:
            begin
                src_ip = 32'h0A_01_01_05;
                dst_ip = 32'h0A_01_02_05;//问题三：可能会出现VL标识 ip地址可能为多播
            end
        endcase
    end
    
    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            ip_version <= 'd0;
            ip_header_len <= 'd0;
            ip_tos <= 'd0;
            ip_total_len <= 'd0;
            ip_ttl <= 'd0;
            ip_protocol <= 'd0;
            ip_checksum <= 'd0;
        end
        else begin
            ip_version <= 4'h4;
            ip_header_len <= 4'h5;
            ip_tos <= 16'h0000;
            ip_total_len <= udp_payload_len + 20;
            ip_ttl <= 8'h01;
            ip_protocol <= 8'h11; //udp
            ip_checksum <= 16'h0;
        end
    end

    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            ip_flags <= 'd0;
            ip_id_cnt <= 'd0;
            ip_frament_offset <= 'd0;
            ip_offest <= 'd0;
        end
        else if(ip_total_len > 1500)begin

            for(integer i = ip_total_len; i > 1500; i = i - 1500)begin
                ip_id_cnt <= ip_id_cnt + 1;
                ip_flags <= 3'b001;//可分片
                ip_frament_offset <= 184 * ip_offest;
                ip_offest <= ip_offest + 1;
            end
            
            ip_offest <= ip_offest + 1;
            ip_id_cnt <= ip_id_cnt + 1;
            ip_flags <= 3'b000;//IP分片中的最后一片
            ip_frament_offset <= ip_offest * 184;
        end
        else begin
            ip_offest <= 'd0;
            ip_flags <= 3'b010;//不分片
            ip_id_cnt <= ip_id_cnt;
            ip_frament_offset <= 'd0;
            
        end
    end

    assign ip_identier = ip_id_cnt;

    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            iph_data <= 'd0;
        end
        else begin
            iph_data <= {ip_version,ip_header_len,ip_tos,ip_total_len,ip_identier,ip_flags,ip_frament_offset,ip_ttl,ip_protocol,ip_checksum,src_ip,dst_ip};
        end
    end


    //iph_checksum
    //ipv4首部按16位划分存储
    always@(*)begin
        ip_packet[0] = iph_data[15:0];
        ip_packet[1] = iph_data[31:16];
        ip_packet[2] = iph_data[47:32];
        ip_packet[3] = iph_data[63:48];
        ip_packet[4] = iph_data[79:64];
        ip_packet[5] = iph_data[95:80];
        ip_packet[6] = iph_data[111:96];
        ip_packet[7] = iph_data[127:112];
        ip_packet[8] = iph_data[143:128];
        ip_packet[9] = iph_data[159:144];
    end
    //反码求和
    always@(*)begin
        iph_checksum = 0;
        for(integer i = 0; i < 10; i = i + 1)begin
            iph_checksum = iph_checksum + (~ip_packet[i]);
        end
    end
    //将产生的进位回卷到低16位
    always@(*)begin
        if(iph_checksum[16] == 1'b1)begin
            iph_checksum = iph_checksum[15:0] + 1;
        end
    end

    always@(posedge clk or negedge reset)begin
        if(~reset)
            iph_udph_data <= 'd0;
        else
            iph_udph_data <= {iph_data[159:80],iph_checksum,iph_data[63:0],udph_data};
    end

    //ethernet_config
    always@(*)begin
        case (src_ip[23:8])
            16'h0101:
                    begin
                        src_mac_a = 48'h02_00_00_01_01_20;
                        src_mac_b = 48'h02_00_00_01_01_40;
                        dst_mac_a = 48'h03_00_00_00_00_01;
                        dst_mac_b = 48'h03_00_00_00_00_01;
                    end 
            16'h0102:
                    begin
                        src_mac_a = 48'h02_00_00_01_02_20;
                        src_mac_b = 48'h02_00_00_01_02_40;
                        dst_mac_a = 48'h03_00_00_00_00_01;
                        dst_mac_b = 48'h03_00_00_00_00_01;
                    end 
            default: begin
                        src_mac_a = 48'h02_00_00_00_00_20;
                        src_mac_b = 48'h02_00_00_00_00_40;
                        dst_mac_a = 48'h03_00_00_00_00_00;
                        dst_mac_b = 48'h03_00_00_00_00_00;
            end
        endcase
    end

    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            eth_iph_udph_data <= 'd0;
            eth_type <= 'd0;
        end
        else begin
            eth_type <= 16'h0800; // Set the Ethernet type to IPv4
            eth_iph_udph_data <= {src_mac_a,dst_mac_a,eth_type,iph_udph_data};
        end

    end


    FIFO_AFDX fifo_que_afdx0_inst(
		.clock (clk),          //input    clock
		.data (eth_iph_udph_data[255:0]),            //input    [255:0]    data
		.rdreq (~afdx0_empty),          //input    rdreq
		.wrreq (~afdx0_full),          //input    wrreq
		.almost_empty (afdx0_almost_empty),
		.almost_full (afdx0_almost_full),//output    almost_full
		.empty (afdx0_empty),          //output    empty
		.full (afdx0_full),            //output    full
		.q (afdx0_data)
    );

    FIFO_AFDX fifo_que_afdx1(
		.clock (clk),          //input    clock
		.data (eth_iph_udph_data[472:256]),            //input    [255:0]    data
		.rdreq (~afdx1_empty),          //input    rdreq
		.wrreq (~afdx1_full),          //input    wrreq
		.almost_empty (afdx1_almost_empty),
		.almost_full (afdx1_almost_full),//output    almost_full
		.empty (afdx1_empty),          //output    empty
		.full (afdx1_full),            //output    full
        .q (afdx1_data)
    );

    





endmodule
