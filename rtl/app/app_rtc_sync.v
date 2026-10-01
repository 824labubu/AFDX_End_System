// Project-defined 16-byte RTC payload; timestamp unit is ns.
module app_rtc_sync #(
    parameter integer RTC_TICK_NS  = 0,  // TBD: set from the final system clock
    parameter integer RTC_SEND_ACK = 1
) (
    input wire clk,
    input wire reset_n,
    input wire [15:0] cfg_local_udp,
    input wire [15:0] cfg_remote_udp,
    input wire [7:0] rx_data,
    input wire rx_valid,
    input wire rx_last,
    output reg [63:0] local_time,
    output reg rtc_sync_valid,
    output reg [7:0] app_tx_data,
    output wire app_tx_valid,
    input wire app_tx_ready,
    output wire app_tx_last,
    output reg [15:0] app_tx_src_udp,
    output reg [15:0] app_tx_dst_udp
);
    localparam [7:0] TYPE_SYNC = 8'h01;
    localparam [7:0] TYPE_ACK = 8'h02;
    localparam [7:0] VERSION = 8'h01;
    localparam integer MSG_BYTES = 16;

    reg [4:0] rx_count;
    reg rx_overflow;
    reg [7:0] rx_type, rx_version;
    reg [31:0] rx_sequence;
    reg [63:0] rx_timestamp;
    reg [31:0] last_sequence;
    reg sequence_seen;
    reg ack_pending;
    reg [4:0] tx_count;
    reg [31:0] ack_sequence;
    reg [63:0] ack_time;

    wire [31:0] sequence_next = {rx_sequence[23:0], rx_data};
    wire [63:0] timestamp_next = {rx_timestamp[55:0], rx_data};
    assign app_tx_valid = ack_pending;
    assign app_tx_last = ack_pending && (tx_count == MSG_BYTES - 1);

    // 按网络字节序输出 ACK 的类型、序号和时间快照。
    always @* begin
        case (tx_count)
            0: app_tx_data = TYPE_ACK;
            1: app_tx_data = VERSION;
            2, 3: app_tx_data = 8'd0;
            4: app_tx_data = ack_sequence[31:24];
            5: app_tx_data = ack_sequence[23:16];
            6: app_tx_data = ack_sequence[15:8];
            7: app_tx_data = ack_sequence[7:0];
            8: app_tx_data = ack_time[63:56];
            9: app_tx_data = ack_time[55:48];
            10: app_tx_data = ack_time[47:40];
            11: app_tx_data = ack_time[39:32];
            12: app_tx_data = ack_time[31:24];
            13: app_tx_data = ack_time[23:16];
            14: app_tx_data = ack_time[15:8];
            default: app_tx_data = ack_time[7:0];
        endcase
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rx_count <= 0;
            rx_overflow <= 0;
            rx_type <= 0;
            rx_version <= 0;
            rx_sequence <= 0;
            rx_timestamp <= 0;
            last_sequence <= 0;
            sequence_seen <= 0;
            local_time <= 0;
            rtc_sync_valid <= 0;
            ack_pending <= 0;
            tx_count <= 0;
            ack_sequence <= 0;
            ack_time <= 0;
            app_tx_src_udp <= 0;
            app_tx_dst_udp <= 0;
        end else begin
            rtc_sync_valid <= 0;
            // 每拍按配置步长推进本地时间。
            local_time <= local_time + RTC_TICK_NS;
            // 仅在握手时推进 ACK 字节索引。
            if (app_tx_valid && app_tx_ready) begin
                if (app_tx_last) begin
                    ack_pending <= 0;
                    tx_count <= 0;
                end else
                    tx_count <= tx_count + 1'b1;
            end
            // 收集 SYNC 字段并记录超长报文。
            if (rx_valid) begin
                if (rx_count == 0)
                    rx_type <= rx_data;
                if (rx_count == 1)
                    rx_version <= rx_data;
                if (rx_count >= 4 && rx_count <= 7)
                    rx_sequence <= sequence_next;
                if (rx_count >= 8 && rx_count <= 15)
                    rx_timestamp <= timestamp_next;
                if (rx_count >= MSG_BYTES)
                    rx_overflow <= 1;

                // 完整且格式有效的 SYNC 才进入序号检查。
                if (rx_last) begin
                    if (!rx_overflow && rx_count == MSG_BYTES-1 &&
                        rx_type == TYPE_SYNC && rx_version == VERSION) begin
                        if (!sequence_seen || rx_sequence > last_sequence) begin
                            // 新序号提交包含当前末字节的时间戳。
                            local_time <= timestamp_next;
                            rtc_sync_valid <= 1;
                            last_sequence <= rx_sequence;
                            sequence_seen <= 1;
                        end
                        // 新序号或重复序号可生成 ACK，旧序号不响应。
                        if (RTC_SEND_ACK && !ack_pending &&
                            (!sequence_seen || rx_sequence >= last_sequence)) begin
                            ack_pending <= 1;
                            ack_sequence <= rx_sequence;
                            ack_time <= (!sequence_seen || rx_sequence > last_sequence) ?
                                        timestamp_next : local_time;
                            app_tx_src_udp <= cfg_local_udp;
                            app_tx_dst_udp <= cfg_remote_udp;
                        end
                    end
                    rx_count <= 0;
                    rx_overflow <= 0;
                    rx_sequence <= 0;
                    rx_timestamp <= 0;
                end else if (rx_count < MSG_BYTES) rx_count <= rx_count + 1'b1;
            end
        end
    end
endmodule
