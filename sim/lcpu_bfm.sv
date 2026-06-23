`timescale 1ns / 1ps

module lcpu_bfm #(
    parameter read_time_out = 2000,
    parameter delay_time = 1000,
    parameter string script_file = "../ref/script.tcl") (
    input  logic        clk,
    input  logic        reset_l,

    input  logic        OP_DONE,
    input  logic [31:0] RD_DATA,
    output logic [31:0] ADDRESS,
    output logic [31:0] WR_DATA,
    output logic        RH_WL,
    output logic        EXEC
);

    integer file;
    reg [63:0] cmd_word;          // first word of each line
    int temp_addr, temp_data, dly_t;
    int have_expect = 0;
    int expect_data;
    int read_time_out_cnt = 0;
    int cmd_count = 0;
    int ret;

    initial begin
        file = $fopen(script_file, "r");
        if (file == 0) begin
            $display("BFM Error: Failed to open %s", script_file);
        end
        else begin
            $display("BFM: Opened %s", script_file);
        end

        ADDRESS <= 0;
        WR_DATA <= 0;
        RH_WL   <= 1;
        EXEC    <= 0;
        # delay_time;

        while (!$feof(file)) begin
            cmd_word = 0;
            ret = $fscanf(file, "%s", cmd_word);

            if (ret != 1) begin
                // Blank line or EOF, skip rest of line
                void'($fscanf(file, "%*c"));
            end
            // --- jwrite: reversed in reg as "etirwj" ---
            // byte0='e'(0x65), byte1='t'(0x74)
            else if (cmd_word[7:0] == 8'h65 && cmd_word[15:8] == 8'h74) begin
                ret = $fscanf(file, " 0x%h 0x%h", temp_addr, temp_data);
                if (ret == 2) begin
                    @(posedge clk);
                    ADDRESS <= temp_addr;
                    WR_DATA <= temp_data;
                    RH_WL   <= 0;
                    EXEC    <= 1;
                    @(posedge clk);
                    EXEC    <= 0;
                    wait (OP_DONE);
                    have_expect = 0;
                    cmd_count = cmd_count + 1;
                end
                else begin
                    $display("BFM WARN: jwrite parse fail (ret=%0d)", ret);
                end
            end
            // --- jread: reversed in reg as "daerj" ---
            // byte0='d'(0x64), byte1='a'(0x61)
            else if (cmd_word[7:0] == 8'h64 && cmd_word[15:8] == 8'h61) begin
                ret = $fscanf(file, " 0x%h", temp_addr);
                if (ret == 1) begin
                    @(posedge clk);
                    ADDRESS <= temp_addr;
                    RH_WL   <= 1;
                    EXEC    <= 1;
                    @(posedge clk);
                    EXEC    <= 0;
                    wait (OP_DONE);
                    if (have_expect == 1) begin
                        if (RD_DATA == expect_data) begin
                            $display("Read 0x%h: 0x%h", ADDRESS, RD_DATA);
                            have_expect = 0;
                        end
                        else begin
                            while ((RD_DATA != expect_data) && (read_time_out_cnt < read_time_out)) begin
                                @(posedge clk);
                                read_time_out_cnt = read_time_out_cnt + 1;
                                ADDRESS <= temp_addr;
                                RH_WL   <= 1;
                                EXEC    <= 1;
                                @(posedge clk);
                                EXEC    <= 0;
                                wait (OP_DONE);
                            end
                            $display("Read 0x%h: 0x%h", ADDRESS, RD_DATA);
                            have_expect = 0;
                        end
                    end
                    cmd_count = cmd_count + 1;
                end
                else begin
                    $display("BFM WARN: jread parse fail (ret=%0d)", ret);
                end
            end
            // --- after: reversed in reg as "retfa" ---
            // byte0='r'(0x72), byte1='e'(0x65)
            else if (cmd_word[7:0] == 8'h72 && cmd_word[15:8] == 8'h65) begin
                ret = $fscanf(file, " %d", dly_t);
                if (ret == 1) begin
                    have_expect = 0;
                    # dly_t;
                    cmd_count = cmd_count + 1;
                end
                else begin
                    $display("BFM WARN: after parse fail (ret=%0d)", ret);
                end
            end
            // --- #expect: reversed in reg as "tcepxe#" ---
            // byte0='t'(0x74), byte1='c'(0x63)
            else if (cmd_word[7:0] == 8'h74 && cmd_word[15:8] == 8'h63) begin
                ret = $fscanf(file, " 0x%h", temp_data);
                if (ret == 1) begin
                    have_expect = 1;
                    cmd_count = cmd_count + 1;
                end
                else begin
                    $display("BFM WARN: #expect parse fail (ret=%0d)", ret);
                end
            end
            else begin
                // Unknown command, skip rest of line
                $display("BFM WARN: unknown cmd, byte0=0x%h byte1=0x%h", cmd_word[7:0], cmd_word[15:8]);
                void'($fscanf(file, "%*c"));
            end
        end

        $display("BFM: Execution complete. %0d commands processed.", cmd_count);
        $fclose(file);
    end

endmodule
