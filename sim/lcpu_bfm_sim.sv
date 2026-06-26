`timescale 1ns / 1ps

module lcpu_bfm #(
    parameter read_time_out = 2000,
    parameter delay_time = 1000,
    parameter script_file = "../ref/script.tcl") (
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
    reg [8191:0] command;
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

        ADDRESS = 0;
        WR_DATA = 0;
        RH_WL   = 1;
        EXEC     = 0;
        # delay_time;

        while (!$feof(file)) begin
            command = 0;
            void'($fgets(command, file));
            read_time_out_cnt = 0;

            // Try jwrite: "jwrite 0xADDR 0xDATA"
            ret = $sscanf(command, "jwrite 0x%h 0x%h", temp_addr, temp_data);
            if (ret == 2) begin
                @(posedge clk);
                ADDRESS = temp_addr;
                WR_DATA = temp_data;
                RH_WL   = 0;
                EXEC     = 1;
                @(posedge clk);
                EXEC     = 0;
                wait (OP_DONE);
                have_expect = 0;
                cmd_count = cmd_count + 1;
            end
            else begin
                // Try jread: "jread 0xADDR"
                ret = $sscanf(command, "jread 0x%h", temp_addr);
                if (ret == 1) begin
                    @(posedge clk);
                    ADDRESS = temp_addr;
                    RH_WL   = 1;
                    EXEC     = 1;
                    @(posedge clk);
                    EXEC     = 0;
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
                                ADDRESS = temp_addr;
                                RH_WL   = 1;
                                EXEC    = 1;
                                @(posedge clk);
                                EXEC    = 0;
                                wait (OP_DONE);
                            end
                            $display("Read 0x%h: 0x%h", ADDRESS, RD_DATA);
                            have_expect = 0;
                        end
                    end
                    cmd_count = cmd_count + 1;
                end
                else begin
                    // Try after: "after DELAY"
                    ret = $sscanf(command, "after %d", dly_t);
                    if (ret == 1) begin
                        have_expect = 0;
                        # dly_t;
                        cmd_count = cmd_count + 1;
                    end
                    else begin
                        // Try #expect: "#expect 0xVALUE"
                        ret = $sscanf(command, "#expect 0x%h", expect_data);
                        if (ret == 1) begin
                            have_expect = 1;
                            cmd_count = cmd_count + 1;
                        end
                    end
                end
            end
        end

        $display("BFM: Execution complete. %0d commands processed.", cmd_count);
        $fclose(file);
    end

endmodule
