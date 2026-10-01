`timescale 1ns / 1ps
module tb_app_tftp_615a;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset_n = 0;
    // TB_ONLY_DEFAULT: 1 kHz clock and TID 5000 are test-local values.
    reg [15:0] cfg_local_tid = 16'd5000;
    reg [7:0] rx_data = 0;
    reg rx_valid = 0, rx_last = 0;
    reg [15:0] rx_src_udp = 16'd6000, rx_dst_udp = 16'd69;
    wire [7:0] app_tx_data;
    wire app_tx_valid, app_tx_last;
    reg app_tx_ready = 0;
    wire [15:0] app_tx_src_udp, app_tx_dst_udp;
    wire file_wr_en, file_commit, file_rd_req;
    wire [7:0] file_wr_data;
    wire [9:0] file_wr_addr, file_rd_addr;
    wire [31:0] file_written_size;
    reg [7:0] file_rd_data = 0;
    reg file_rd_valid = 0;
    reg [31:0] file_size = 0;
    wire session_valid, timeout_error;
    reg [7:0] file_mem[0:1023];
    integer write_count = 0, commit_count = 0, timeout_count = 0;
    app_tftp_615a #(
        .CLK_FREQ_HZ(1000),
        .TFTP_TIMEOUT_MS(100),
        .TFTP_DALLY_MS(100),
        .TFTP_RETRY_LIMIT(2),
        .FILE_ADDR_WIDTH(10),
        .MAX_FILE_BYTES(1024)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .cfg_local_tid(cfg_local_tid),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .rx_last(rx_last),
        .rx_src_udp(rx_src_udp),
        .rx_dst_udp(rx_dst_udp),
        .app_tx_data(app_tx_data),
        .app_tx_valid(app_tx_valid),
        .app_tx_ready(app_tx_ready),
        .app_tx_last(app_tx_last),
        .app_tx_src_udp(app_tx_src_udp),
        .app_tx_dst_udp(app_tx_dst_udp),
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
        .session_valid(session_valid),
        .timeout_error(timeout_error)
    );
    always @(posedge clk) begin
        if (file_wr_en) begin
            file_mem[file_wr_addr] <= file_wr_data;
            write_count = write_count + 1;
        end
        if (file_commit)
            commit_count = commit_count + 1;
        if (timeout_error)
            timeout_count = timeout_count + 1;
        file_rd_valid <= file_rd_req;
        if (file_rd_req)
            file_rd_data <= file_mem[file_rd_addr];
    end

    // 在时钟下降沿驱动一个接收字节。
    task send_byte;
        input [7:0] b;
        input last;
        begin
            @(negedge clk);
            rx_data = b;
            rx_valid = 1;
            rx_last = last;
        end
    endtask
    // 发送 octet 模式的 TFTP 读请求。
    task send_rrq;
        begin
            rx_dst_udp = 69;
            send_byte(0, 0);
            send_byte(1, 0);
            send_byte("f", 0);
            send_byte(0, 0);
            send_byte("o", 0);
            send_byte("c", 0);
            send_byte("t", 0);
            send_byte("e", 0);
            send_byte("t", 0);
            send_byte(0, 1);
            finish_packet;
        end
    endtask
    // 发送指定块号的 TFTP ACK。
    task send_ack;
        input [7:0] block;
        begin
            rx_dst_udp = 5000;
            send_byte(0, 0);
            send_byte(4, 0);
            send_byte(0, 0);
            send_byte(block, 1);
            finish_packet;
        end
    endtask
    // 接收并校验 TFTP DATA 块及文件内容。
    task drain_data;
        input [7:0] block;
        input integer data_length;
        integer j;
        reg [7:0] expected;
        begin
            if (!app_tx_valid)
                $fatal(1, "RRQ DATA missing");
            for (j = 0; j < data_length + 4; j = j + 1) begin
                if (j == 0 || j == 2)
                    expected = 0;
                else if (j == 1)
                    expected = 3;
                else if (j == 3)
                    expected = block;
                else
                    expected = file_mem[(block-1)*512+j-4];
                #1;
                if (!app_tx_valid || app_tx_data !== expected ||
                    app_tx_last !== (j==data_length+3))
                    $fatal(1, "RRQ DATA block %0d byte %0d mismatch", block, j);
                app_tx_ready = 1;
                @(posedge clk);
                @(negedge clk);
            end
            app_tx_ready = 0;
        end
    endtask
    // 结束当前接收报文。
    task finish_packet;
        begin
            @(negedge clk);
            rx_valid = 0;
            rx_last = 0;
            repeat (2) @(negedge clk);
        end
    endtask
    // 发送 octet 模式的 TFTP 写请求。
    task send_wrq;
        begin
            rx_dst_udp = 69;
            send_byte(0, 0);
            send_byte(2, 0);
            send_byte("f", 0);
            send_byte(0, 0);
            send_byte("o", 0);
            send_byte("c", 0);
            send_byte("t", 0);
            send_byte("e", 0);
            send_byte("t", 0);
            send_byte(0, 1);
            finish_packet;
        end
    endtask
    // 发送首个 TFTP DATA 块。
    task send_data1;
        begin
            rx_dst_udp = 5000;
            send_byte(0, 0);
            send_byte(3, 0);
            send_byte(0, 0);
            send_byte(1, 0);
            send_byte(8'haa, 0);
            send_byte(8'hbb, 0);
            send_byte(8'hcc, 1);
            finish_packet;
        end
    endtask
    // 接收并校验四字节 TFTP 响应。
    task drain_four;
        input [7:0] opcode;
        input [7:0] block;
        integer i;
        reg [7:0] exp;
        begin
            if (!app_tx_valid || app_tx_src_udp != 5000 || app_tx_dst_udp != 6000)
                $fatal(1, "TFTP TX metadata/valid mismatch");
            for (i = 0; i < 4; i = i + 1) begin
                case (i)
                    0, 2: exp = 0;
                    1: exp = opcode;
                    default: exp = block;
                endcase
                app_tx_ready = 0;
                #1;
                if (!app_tx_valid || app_tx_data !== exp || app_tx_last !== (i == 3))
                    $fatal(1, "TFTP TX byte %0d got %02h expected %02h", i, app_tx_data, exp);
                repeat (2) @(negedge clk);
                if (app_tx_data !== exp)
                    $fatal(1, "TFTP byte changed under stall");
                app_tx_ready = 1;
                @(negedge clk);
            end
            app_tx_ready = 0;
        end
    endtask

    // 执行协议场景并检查结果，失败时立即终止仿真。
    initial begin
        repeat (2) @(negedge clk);
        reset_n = 1;
        send_wrq;
        drain_four(4, 0);
        send_data1;
        repeat (8) @(negedge clk);
        if (write_count != 3 || commit_count != 1 || file_written_size != 3 ||
            file_mem[0] !== 8'haa || file_mem[1] !== 8'hbb || file_mem[2] !== 8'hcc)
            $fatal(1, "TFTP DATA was not committed exactly once");
        drain_four(4, 1);
        send_data1;
        if (write_count != 3 || commit_count != 1)
            $fatal(1, "duplicate TFTP DATA rewrote file");
        drain_four(4, 1);
        repeat (110) @(negedge clk);
        if (session_valid)
            $fatal(1, "TFTP dally did not expire");
        send_wrq;
        drain_four(4, 0);
        repeat (102) @(negedge clk);
        drain_four(4, 0);
        repeat (102) @(negedge clk);
        drain_four(4, 0);
        repeat (105) @(negedge clk);
        if (timeout_count != 1 || session_valid)
            $fatal(1, "TFTP retry limit did not abort session");
        file_size = 513;
        for (integer j = 0; j < 513; j = j + 1) file_mem[j] = j[7:0];
            send_rrq;
        wait (app_tx_valid);
        drain_data(1, 512);
        rx_src_udp = 6001;
        send_ack(1);
        if (app_tx_valid)
            $fatal(1, "wrong TID advanced RRQ");
        rx_src_udp = 6000;
        send_ack(1);
        wait (app_tx_valid);
        drain_data(2, 1);
        send_ack(2);
        if (session_valid)
            $fatal(1, "RRQ did not complete");
        file_size = 512;
        send_rrq;
        wait (app_tx_valid);
        drain_data(1, 512);
        send_ack(0);
        if (app_tx_valid)
            $fatal(1, "old ACK advanced block");
        send_ack(1);
        wait (app_tx_valid);
        drain_data(2, 0);
        send_ack(2);
        if (session_valid)
            $fatal(1, "exact-multiple RRQ did not terminate");
        $display("PASS: TFTP WRQ, DATA, duplicate, RRQ, TID, retry and timeout");
        $finish;
    end
endmodule
