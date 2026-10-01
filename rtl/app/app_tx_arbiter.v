// Three complete UDP-payload streams: 0=SNMP, 1=RTC, 2=TFTP/615A.
// The selected source retains the grant until its final byte is accepted.
module app_tx_arbiter (
    input wire clk,
    input wire reset_n,
    input wire [23:0] s_data,
    input wire [2:0] s_valid,
    output reg [2:0] s_ready,
    input wire [2:0] s_last,
    input wire [47:0] s_src_udp,
    input wire [47:0] s_dst_udp,
    output reg [7:0] tx_data,
    output reg tx_valid,
    input wire tx_ready,
    output reg tx_tlast,
    output reg [7:0] tx_port,
    output reg [15:0] app_upd_src_port,
    output reg [15:0] app_upd_dst_port
);
    reg active;
    reg [1:0] grant;
    reg [1:0] next_priority;
    reg [1:0] chosen;
    reg found;
    integer probe_idx;
    integer i;

    // 按轮询优先级选择有效源，并在报文期间保留已锁定的源。
    always @* begin
        found = 1'b0;
        chosen = 2'd0;
        probe_idx = 0;
        for (i = 0; i < 3; i = i + 1) begin
            probe_idx = next_priority + i;
            if (probe_idx >= 3)
                probe_idx = probe_idx - 3;
            if (!found && s_valid[probe_idx]) begin
                found = 1'b1;
                chosen = probe_idx;
            end
        end
        if (active) begin
            found = 1'b1;
            chosen = grant;
        end

        tx_data = 8'd0;
        tx_valid = 1'b0;
        tx_tlast = 1'b0;
        tx_port = 8'd0;
        app_upd_src_port = 16'd0;
        app_upd_dst_port = 16'd0;
        s_ready = 3'b000;
        // 同步转发所选源的数据和端口信息，仅向该源反馈 ready。
        if (found) begin
            tx_data = s_data[chosen*8+:8];
            tx_valid = s_valid[chosen];
            tx_tlast = s_last[chosen];
            app_upd_src_port = s_src_udp[chosen*16+:16];
            app_upd_dst_port = s_dst_udp[chosen*16+:16];
            case (chosen)
                2'd0: tx_port = 8'd3;
                2'd1: tx_port = 8'd4;
                default: tx_port = 8'd5;
            endcase
            s_ready[chosen] = tx_ready;
        end
    end

    // 首字节有效即锁定仲裁，末字节握手后释放并轮换优先级。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            active <= 1'b0;
            grant <= 2'd0;
            next_priority <= 2'd0;
        end else if (tx_valid) begin
            if (tx_ready && tx_tlast) begin
                active <= 1'b0;
                next_priority <= (chosen == 2'd2) ? 2'd0 : chosen + 1'b1;
            end else begin
                active <= 1'b1;
                grant <= chosen;
            end
        end
    end
endmodule
