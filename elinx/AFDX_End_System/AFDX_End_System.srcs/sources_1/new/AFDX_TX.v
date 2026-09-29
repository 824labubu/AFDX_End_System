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
    input                                               tx_ready,

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
    wire                                              almost_full;
    wire                                              almost_empty;
    wire                                              empty;
    wire                                              full; 
    wire [7:0]                                        q;
    wire [7:0]                                        que_data;
    
    //sam port define
    wire [7:0]                                        sam_data;

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
    reg                                               wren;
    reg [7:0]                                         vl_lut_data;
    reg [7:0]                                         vl_lut;
    reg [7:0]                                         vl_config_data;

    reg [19:0]                                        send_start_time;
    reg [7:0]                                         sn;
    reg [479:0]                                       data_sn_etherneth_iph_udph;

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
    assign que_data = (port == QUE) ? tx_data : 8'b0000_0000;

    FIFO_QUE fifo_que_inst (
		.clock (clk),          //input    clock
		.data (que_data),            //input    [7:0]    data
		.rdreq (~empty)
		.wrreq (~full),          //input    wrreq
		.almost_empty (almost_empty),//output    almost_empty
		.almost_full (almost_full),//output    almost_full
		.empty (empty),          //output    empty
		.full (full),            //output    full
		.q (q)                   //output    [7:0]    q
    );

    //-------------------------------------SAM PORT-------------------------------------
    assign sam_data = (port == SAM) ? tx_data : 8'b0000_0000;
    assign q = (port == SAM) ? tx_data : 8'b0000_0000;

    //-------------------------------------SAP_SNMP PPORT-------------------------------
    assign sap_snmp_data = (port == SAP_SNMP) ? tx_data : 8'b0000_0000;
    assign sap_rtc_data = (port == SAP_RTC) ? tx_data : 8'b0000_0000;
    assign sap_615a_data = (port == SAP_615A) ? tx_data : 8'b0000_0000;

    assign q = (port == SAP_SNMP) ? tx_data : 8'b0000_0000;
    assign q = (port == SAP_RTC) ? tx_data : 8'b0000_0000;
    assign q = (port == SAP_615A) ? tx_data : 8'b0000_0000;


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


    //VL_BAG_config
    always@(*)begin
        case(dst_mac_a[15:0])
            16'h0001:VLID = 9'd1;
            16'h0002:VLID = 9'd2;
            16'h0003:VLID = 9'd3;
            16'h0004:VLID = 9'd4;
            16'h0005:VLID = 9'd5;
            16'h0006:VLID = 9'd6;
            16'h0007:VLID = 9'd7;
            16'h0008:VLID = 9'd8;
            16'h0009:VLID = 9'd9;
            16'h000a:VLID = 9'd10;
            16'h000b:VLID = 9'd11;
            16'h000c:VLID = 9'd12;
            16'h000d:VLID = 9'd13;
            16'h000e:VLID = 9'd14;
            16'h000f:VLID = 9'd15;
            16'h0010:VLID = 9'd16;
            16'h0011:VLID = 9'd17;
            16'h0012:VLID = 9'd18;
            16'h0013:VLID = 9'd19;
            16'h0014:VLID = 9'd20;
            16'h0015:VLID = 9'd21;
            16'h0016:VLID = 9'd22;
            16'h0017:VLID = 9'd23;
            16'h0018:VLID = 9'd24;
            16'h0019:VLID = 9'd25;  
            16'h001a:VLID = 9'd26;
            16'h001b:VLID = 9'd27;
            16'h001c:VLID = 9'd28;
            16'h001d:VLID = 9'd29;
            16'h001e:VLID = 9'd30;
            16'h001f:VLID = 9'd31;
            16'h0020:VLID = 9'd32;
            16'h0021:VLID = 9'd33;
            16'h0022:VLID = 9'd34;
            16'h0023:VLID = 9'd35;
            16'h0024:VLID = 9'd36;
            16'h0025:VLID = 9'd37;
            16'h0026:VLID = 9'd38;
            16'h0027:VLID = 9'd39;
            16'h0028:VLID = 9'd40;
            16'h0029:VLID = 9'd41;
            16'h002a:VLID = 9'd42;
            16'h002b:VLID = 9'd43;
            16'h002c:VLID = 9'd44;
            16'h002d:VLID = 9'd45;
            16'h002e:VLID = 9'd46;
            16'h002f:VLID = 9'd47;
            16'h0030:VLID = 9'd48;
            16'h0031:VLID = 9'd49;
            16'h0032:VLID = 9'd50;
            16'h0033:VLID = 9'd51;
            16'h0034:VLID = 9'd52;
            16'h0035:VLID = 9'd53;
            16'h0036:VLID = 9'd54;
            16'h0037:VLID = 9'd55;
            16'h0038:VLID = 9'd56;
            16'h0039:VLID = 9'd57;
            16'h003a:VLID = 9'd58;
            16'h003b:VLID = 9'd59;
            16'h003c:VLID = 9'd60;
            16'h003d:VLID = 9'd61;
            16'h003e:VLID = 9'd62;
            16'h003f:VLID = 9'd63;
            16'h0040:VLID = 9'd64;
            16'h0041:VLID = 9'd65;
            16'h0042:VLID = 9'd66;
            16'h0043:VLID = 9'd67;
            16'h0044:VLID = 9'd68;
            16'h0045:VLID = 9'd69;
            16'h0046:VLID = 9'd70;
            16'h0047:VLID = 9'd71;
            16'h0048:VLID = 9'd72;
            16'h0049:VLID = 9'd73;
            16'h004a:VLID = 9'd74;
            16'h004b:VLID = 9'd75;
            16'h004c:VLID = 9'd76;
            16'h004d:VLID = 9'd77;
            16'h004e:VLID = 9'd78;
            16'h004f:VLID = 9'd79;
            16'h0050:VLID = 9'd80;
            16'h0051:VLID = 9'd81;
            16'h0052:VLID = 9'd82;
            16'h0053:VLID = 9'd83;
            16'h0054:VLID = 9'd84;
            16'h0055:VLID = 9'd85;
            16'h0056:VLID = 9'd86;
            16'h0057:VLID = 9'd87;
            16'h0058:VLID = 9'd88;
            16'h0059:VLID = 9'd89;
            16'h005a:VLID = 9'd90;
            16'h005b:VLID = 9'd91;
            16'h005c:VLID = 9'd92;
            16'h005d:VLID = 9'd93;
            16'h005e:VLID = 9'd94;
            16'h005f:VLID = 9'd95;
            16'h0060:VLID = 9'd96;
            16'h0061:VLID = 9'd97;
            16'h0062:VLID = 9'd98;
            16'h0063:VLID = 9'd99;
            16'h0064:VLID = 9'd100;
            16'h0065:VLID = 9'd101;
            16'h0066:VLID = 9'd102;
            16'h0067:VLID = 9'd103;
            16'h0068:VLID = 9'd104;
            16'h0069:VLID = 9'd105;
            16'h006a:VLID = 9'd106;
            16'h006b:VLID = 9'd107;
            16'h006c:VLID = 9'd108;
            16'h006d:VLID = 9'd109;
            16'h006e:VLID = 9'd110;
            16'h006f:VLID = 9'd111;
            16'h0070:VLID = 9'd112;
            16'h0071:VLID = 9'd113;
            16'h0072:VLID = 9'd114;
            16'h0073:VLID = 9'd115;
            16'h0074:VLID = 9'd116;
            16'h0075:VLID = 9'd117;
            16'h0076:VLID = 9'd118;
            16'h0077:VLID = 9'd119;
            16'h0078:VLID = 9'd120;
            16'h0079:VLID = 9'd121;
            16'h007a:VLID = 9'd122;
            16'h007b:VLID = 9'd123;
            16'h007c:VLID = 9'd124;
            16'h007d:VLID = 9'd125;
            16'h007e:VLID = 9'd126;
            16'h007f:VLID = 9'd127;
            16'h0080:VLID = 9'd128;
            default: VLID = 9'd0;
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
        else if(wraddress > 5'd31)
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
            default: priorty = 8'h00;
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
            if(sn > 8'd256)begin
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
