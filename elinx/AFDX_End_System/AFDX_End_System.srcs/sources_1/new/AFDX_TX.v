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
// Description:五分区 每个分区用于一条VL，暂不涉及sub_VL
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

    input [7:0]                                         tx_data,
    input                                               tx_valid,
    output reg                                          tx_ready,
    input                                               tx_tlast,
    input [7:0]                                         tx_port,
    
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
    parameter                                         BAG = 1;//1ms = 20ns * 50_000
    parameter                                         LMAX = 8'd64;
    parameter                                         JITTER_MAX = 40 * 1000 + (20 + LMAX) * 8 * 10;//64  ----->  2336
    parameter                                         JITTER_TIME_CIRCLE = JITTER_MAX / 20;
    parameter                                         SEND_START_TIME = (20 + LMAX) * 8 * 1000;//ns
    parameter                                         SEND_START_TIME_CIRCLE = SEND_START_TIME / 20;    

    reg [15:0]                                        src_udp;
    reg [15:0]                                        dst_udp;
    reg [31:0]                                        src_ip;
    reg [31:0]                                        dst_ip;
    reg [47:0]                                        src_mac_a;
    reg [47:0]                                        dst_mac_a;
    reg [47:0]                                        src_mac_b;
    reg [47:0]                                        dst_mac_b;

    //fifo_que define
    wire                                              que_almost_full;
    wire                                              que_almost_empty;
    wire                                              que_empty;
    wire                                              que_full; 
    wire [7:0]                                        que_q;
    wire [7:0]                                        que_data;
    
    //sam port define
    wire [7:0]                                        sam_data;
    wire                                              sam_almost_full;
    wire                                              sam_almost_empty;
    wire                                              sam_empty;
    wire                                              sam_full;
    wire [7:0]                                        sam_q;


    //sap_snmp define
    wire [7:0]                                        sap_snmp_data;
    wire [7:0]                                        snmp_q;
    wire                                              snmp_almost_full;
    wire                                              snmp_almost_empty;
    wire                                              snmp_empty;
    wire                                              snmp_full;

    //sap_rtc define
    wire [7:0]                                        sap_rtc_data;
    wire [7:0]                                        rtc_q;
    wire                                              rtc_almost_full;
    wire                                              rtc_almost_empty;
    wire                                              rtc_empty;
    wire                                              rtc_full;
    
    //sap_615a define
    wire [7:0]                                        sap_615a_data; 
    wire [7:0]                                        tftp_q;
    wire                                              tftp_almost_full;
    wire                                              tftp_almost_empty;
    wire                                              tftp_empty;
    wire                                              tftp_full;


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

    //VL_LUT define
    reg [4:0]                                         wraddress;
    reg [4:0]                                         rdaddress;
    reg                                               wren;
    reg [7:0]                                         vl_lut_data;
    reg [7:0]                                         vl_lut;
    reg [7:0]                                         vl_config_data;
    reg [7:0]                                         priority;
    reg [15:0]                                         VL_id;

    reg [21:0]                                        send_start_time;
    reg [7:0]                                         sn;
    reg [479:0]                                       data_sn_etherneth_iph_udph;

    wire [7:0]                                        port_sel;
    assign port_sel = tx_port;

    //tx_ready 
    always@(posedge clk or negedge reset)
    begin
        if (!reset)
            tx_ready <= 1'b0;
        else if (~que_full || ~sam_full || ~sap_snmp_full || ~sap_rtc_full || ~sap_615a_full)
            tx_ready <= 1'b1;
        else
            tx_ready <= 1'b0;
    end

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
    assign que_data = (port == QUE) ? tx_data : 8'b0000_0000;

    FIFO_QUE fifo_que_inst (
		.clock (clk),          //input    clock
		.data (que_data),            //input    [7:0]    data
		.rdreq (~que_empty)
		.wrreq (tx_valid && tx_ready && port == QUE),          //input    wrreq
		.almost_empty (que_almost_empty),//output    almost_empty
		.almost_full (que_almost_full),//output    almost_full
		.empty (que_empty),          //output    empty
		.full (que_full),            //output    full
		.q (que_q)                   //output    [7:0]    q
    );

    //-------------------------------------SAM PORT-------------------------------------
    assign sam_data = (port == SAM) ? tx_data : 8'b0000_0000;
    FIFO_SAM fifo_sam_inst (
		.clock (clk),          //input    clock
		.data (sam_data),            //input    [7:0]    data
		.rdreq (~sam_empty)
		.wrreq (tx_valid && tx_ready && port == SAM),          //input    wrreq
		.empty (sam_empty),          //output    empty
		.full (sam_full),            //output    full
		.q (sam_q)                   //output    [7:0]    q
    );

    //-------------------------------------SAP_SNMP PPORT-------------------------------
    assign sap_snmp_data = (port == SAP_SNMP) ? tx_data : 8'b0000_0000;
    assign sap_rtc_data = (port == SAP_RTC) ? tx_data : 8'b0000_0000;
    assign sap_615a_data = (port == SAP_615A) ? tx_data : 8'b0000_0000;

    FIFO_QUE fifo_sap_snmp (
		.clock (clk),          //input    clock
		.data (sap_snmp_data),            //input    [7:0]    data
		.rdreq (~snmp_empty),          //input    rdreq
		.wrreq (tx_valid && tx_ready && port == SAP_SNMP),          //input    wrreq
		.almost_empty (snmp_almost_empty),//output    almost_empty
		.almost_full (snmp_almost_full),//output    almost_full
		.empty (snmp_empty),          //output    empty
		.full (snmp_full),            //output    full
		.q (snmp_q)                   //output    [7:0]    q
    );

    FIFO_QUE fifo_sap_rtc (
		.clock (clk),          //input    clock
		.data (sap_rtc_data),            //input    [7:0]    data
		.rdreq (~rtc_empty),          //input    rdreq
		.wrreq (tx_valid && tx_ready && port == SAP_RTC),          //input    wrreq
		.almost_empty (rtc_almost_empty),//output    almost_empty
		.almost_full (rtc_almost_full),//output    almost_full
		.empty (rtc_empty),          //output    empty
		.full (rtc_full),            //output    full
        .q (rtc_q)                   //output    [7:0]    q
    );

    FIFO_QUE fifo_sap_615a (
		.clock (clk),          //input    clock
		.data (sap_615a_data),            //input    [7:0]    data
		.rdreq (~tftp_empty),          //input    rdreq
		.wrreq (tx_valid && tx_ready && port == SAP_615A),          //input    wrreq
		.almost_empty (tftp_almost_empty),//output    almost_empty
		.almost_full (tftp_almost_full),//output    almost_full
		.empty (tftp_empty),          //output    empty
		.full (tftp_full),            //output    full
        .q (tftp_q)                   //output    [7:0]    q
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
                dst_ip = {16'hF4_F4,VL_id};//多播IP 标识VL
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
            ip_tos <= 8'h00;
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
            iph_checksum = ~iph_checksum[15:0];
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
                        dst_mac_a = {32'h03_00_00_00,VL_id};
                        dst_mac_b = {32'h03_00_00_00,VL_id};
                    end 
            16'h0102:
                    begin
                        src_mac_a = 48'h02_00_00_01_02_20;
                        src_mac_b = 48'h02_00_00_01_02_40;
                        dst_mac_a = {48'h03_00_00_00,VL_id};
                        dst_mac_b = {32'h03_00_00_00,VL_id};
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
		.wrreq (tx_ready && tx_valid),          //input    wrreq
		.almost_empty (afdx0_almost_empty),
		.almost_full (afdx0_almost_full),//output    almost_full
		.empty (afdx0_empty),          //output    empty
		.full (afdx0_full),            //output    full
		.q (afdx0_data)
    );

    FIFO_AFDX fifo_que_afdx1(
		.clock (clk),          //input    clock
		.data ({40'h0,eth_iph_udph_data[471:256]}),            //input    [255:0]    data
		.rdreq (~afdx1_empty),          //input    rdreq
		.wrreq (tx_ready && tx_valid),          //input    wrreq
		.almost_empty (afdx1_almost_empty),
		.almost_full (afdx1_almost_full),//output    almost_full
		.empty (afdx1_empty),          //output    empty
		.full (afdx1_full),            //output    full
        .q (afdx1_data)
    );


    //VL_BAG_config
    always@(*)begin
        case(dst_mac_a[15:0])
            16'h0001:VL_id = 16'h00_01;
            16'h0002:VL_id = 16'h00_02;
            16'h0003:VL_id = 16'h00_03;
            16'h0004:VL_id = 16'h00_04;
            16'h0005:VL_id = 16'h00_05;
            16'h0006:VL_id = 16'h00_06;
            16'h0007:VL_id = 16'h00_07;
            16'h0008:VL_id = 16'h00_08;
            16'h0009:VL_id = 16'h00_09;
            16'h000a:VL_id = 16'h00_0a;
            16'h000b:VL_id = 16'h00_0b;
            16'h000c:VL_id = 16'h00_0c;
            16'h000d:VL_id = 16'h00_0d;
            16'h000e:VL_id = 16'h00_0e;
            16'h000f:VL_id = 16'h00_0f;
            16'h0010:VL_id = 16'h00_10;
            16'h0011:VL_id = 16'h00_11;
            16'h0012:VL_id = 16'h00_12;
            16'h0013:VL_id = 16'h00_13;
            16'h0015:VL_id = 16'h00_15;
            16'h0016:VL_id = 16'h00_16;
            16'h0017:VL_id = 16'h00_17;
            16'h0018:VL_id = 16'h00_18;
            16'h0019:VL_id = 16'h00_19;
            16'h001a:VL_id = 16'h00_1a;
            16'h001b:VL_id = 16'h00_1b;
            16'h001c:VL_id = 16'h00_1c;
            16'h001e:VL_id = 16'h00_1e;
            16'h001f:VL_id = 16'h00_1f;
            16'h0020:VL_id = 16'h00_20;
            16'h0021:VL_id = 16'h00_21;
            16'h0022:VL_id = 16'h00_22;
            16'h0023:VL_id = 16'h00_23;
            16'h0024:VL_id = 16'h00_24;
            16'h0025:VL_id = 16'h00_25;
            16'h0026:VL_id = 16'h00_26;
            16'h0027:VL_id = 16'h00_27;
            16'h0028:VL_id = 16'h00_28;
            16'h0029:VL_id = 16'h00_29;
            16'h002a:VL_id = 16'h00_2a;
            16'h002c:VL_id = 16'h00_2c;
            16'h002d:VL_id = 16'h00_2d;
            16'h002e:VL_id = 16'h00_2e;
            16'h002f:VL_id = 16'h00_2f;
            16'h0030:VL_id = 16'h00_30;
            16'h0031:VL_id = 16'h00_31;
            16'h0032:VL_id = 16'h00_32;
            16'h0033:VL_id = 16'h00_33;
            16'h0034:VL_id = 16'h00_34;
            16'h0035:VL_id = 16'h00_35;
            16'h0036:VL_id = 16'h00_36;
            16'h0037:VL_id = 16'h00_37;
            16'h0038:VL_id = 16'h00_38;
            16'h0039:VL_id = 16'h00_39;
            16'h003a:VL_id = 16'h00_3a;
            16'h003b:VL_id = 16'h00_3b;
            16'h003c:VL_id = 16'h00_3c;
            16'h003d:VL_id = 16'h00_3d;
            16'h003e:VL_id = 16'h00_3e;
            16'h003f:VL_id = 16'h00_3f;
            16'h0040:VL_id = 16'h00_40;
            16'h0041:VL_id = 16'h00_41;
            16'h0042:VL_id = 16'h00_42;
            16'h0043:VL_id = 16'h00_43;
            16'h0044:VL_id = 16'h00_44;
            16'h0045:VL_id = 16'h00_45;
            16'h0046:VL_id = 16'h00_46;
            16'h0047:VL_id = 16'h00_47;
            16'h0048:VL_id = 16'h00_48;
            16'h0049:VL_id = 16'h00_49;
            16'h004a:VL_id = 16'h00_4a;
            16'h004b:VL_id = 16'h00_4b;
            16'h004c:VL_id = 16'h00_4c;
            16'h004d:VL_id = 16'h00_4d;
            16'h004e:VL_id = 16'h00_4e;
            16'h004f:VL_id = 16'h00_4f;
            16'h0050:VL_id = 16'h00_50;
            16'h0051:VL_id = 16'h00_51;
            16'h0052:VL_id = 16'h00_52;
            16'h0053:VL_id = 16'h00_53;
            16'h0054:VL_id = 16'h00_54;
            16'h0055:VL_id = 16'h00_55;
            16'h0056:VL_id = 16'h00_56;
            16'h0057:VL_id = 16'h00_57;
            16'h0058:VL_id = 16'h00_58;
            16'h0059:VL_id = 16'h00_59;
            16'h005a:VL_id = 16'h00_5a;
            16'h005b:VL_id = 16'h00_5b;
            16'h005c:VL_id = 16'h00_5c;
            16'h005d:VL_id = 16'h00_5d;
            16'h005e:VL_id = 16'h00_5e;
            16'h005f:VL_id = 16'h00_5f;
            16'h0060:VL_id = 16'h00_60;
            16'h0061:VL_id = 16'h00_61;
            16'h0062:VL_id = 16'h00_62;
            16'h0063:VL_id = 16'h00_63;
            16'h0064:VL_id = 16'h00_64;
            16'h0065:VL_id = 16'h00_65;
            16'h0066:VL_id = 16'h00_66;
            16'h0067:VL_id = 16'h00_67;
            16'h0068:VL_id = 16'h00_68;
            16'h0069:VL_id = 16'h00_69;
            16'h006a:VL_id = 16'h00_6a;
            16'h006b:VL_id = 16'h00_6b;
            16'h006c:VL_id = 16'h00_6c;
            16'h006d:VL_id = 16'h00_6d;
            16'h006e:VL_id = 16'h00_6e;
            16'h006f:VL_id = 16'h00_6f;
            16'h0070:VL_id = 16'h00_70;
            16'h0071:VL_id = 16'h00_71;
            16'h0072:VL_id = 16'h00_72;
            16'h0073:VL_id = 16'h00_73;
            16'h0074:VL_id = 16'h00_74;
            16'h0075:VL_id = 16'h00_75;
            16'h0076:VL_id = 16'h00_76;
            16'h0077:VL_id = 16'h00_77;
            16'h0078:VL_id = 16'h00_78;
            16'h0079:VL_id = 16'h00_79;
            16'h007a:VL_id = 16'h00_7a;
            16'h007b:VL_id = 16'h00_7b;
            16'h007c:VL_id = 16'h00_7c;
            16'h007d:VL_id = 16'h00_7d;
            16'h007e:VL_id = 16'h00_7e;
            16'h007f:VL_id = 16'h00_7f;
            16'h0080:VL_id = 16'h00_80;
            default: VL_id = 16'h00_00;
        endcase
    end

    //VL_LUT配置
    VL_LUT VL_LUT_inst(
	.clock(clk)					,//input clock
	.data(vl_lut_data)						,//input [7:0] data
	.rdaddress(rdaddress)				,//input [4:0] rdaddress
	.wraddress(wraddress)				,//input [4:0] wraddress
	.wren(wren)					,//input wren
	.q(vl_config_data)							//output	[7:0] q
    );

    always@(posedge clk or negedge reset)begin
        if(~reset)
            wren <= 'd0;
        else if(wraddress >= 5'd31)
            wren <= 'd0;
        else
            wren <= 'd1;
    end


    always@(*)
    begin
        case (wraddress)
                5'd1: vl_lut = BAG;
                5'd2: vl_lut = LMAX;
                5'd3: vl_lut = priority;
                5'd4: vl_lut = JITTER_MAX;
            default: 
                vl_lut = 8'h00;
        endcase
    end

    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            wraddress <= 'd0;
            vl_lut_data <= 'd0;
        end
        else begin
            wraddress <= wraddress + 1;
            vl_lut_data <= vl_lut;
        end
    end

    //sub_VL_config  
    always@(*)
    begin
        case (src_ip[7:0])
            8'h01: priority = 8'h01;
            8'h02: priority = 8'h02;
            8'h03: priority = 8'h03;
            8'h04: priority = 8'h04;
            8'h05: priority = 8'h05;
            default: priority = 8'h00;
        endcase
    end



    //VL_RP
    //vl_priority_adjust
    always@(*)begin
        case(priority)
            8'h01:
                begin
                    send_start_time = 'd0;           
                end
            8'h02:
                begin
                    send_start_time = SEND_START_TIME;
                end
            8'h03:
                begin
                    send_start_time = SEND_START_TIME * 2;
                end
            8'h04:
                begin
                    send_start_time = SEND_START_TIME * 3;
                end
            8'h05:
                begin
                    send_start_time = SEND_START_TIME * 4;
                end
            default:
                    send_start_time = 'd0;
        endcase
    end

    //vl_sn_config
   
    always@(posedge clk or negedge reset)begin
        if(~reset)begin
            sn <= 'd0;
            data_sn_etherneth_iph_udph <= 'd0;
        end
        else if((~afdx1_empty)||(~afdx0_empty))begin 
            if(sn >= 8'd255)begin
                sn <= 1'd1;
                data_sn_etherneth_iph_udph <= {afdx1_data[215:0],afdx0_data,sn};
            end
            else begin
                sn <= sn + 1'd1;
                data_sn_etherneth_iph_udph <= {afdx1_data[215:0],afdx0_data,sn};
            end
        end
    end 

    
    




endmodule
