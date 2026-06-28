`timescale 1ns / 1ps

module lcpu_bfm #(
    parameter read_time_out = 2000,
    parameter delay_time = 1000,
    parameter string script_file = "../ref/script.tcl"
) (
    input logic clk,
    input logic reset_l,

    input  logic        OP_DONE,
    input  logic [31:0] RD_DATA,
    output logic [31:0] ADDRESS,
    output logic [31:0] WR_DATA,
    output logic        RH_WL,
    output logic        EXEC
);

  integer file;
  int temp_addr, temp_data, dly_t;
  int have_expect = 0;
  int expect_data;
  int read_time_out_cnt = 0;
  int cmd_count = 0;
  int ret;

  initial begin
    file = $fopen("../tcl/InstructRAM.tcl", "r");
    if (file == 0) begin
      $display("BFM Error: Failed to open ../tcl/InstructRAM.tcl");
    end else begin
      $display("BFM: Opened ../tcl/InstructRAM.tcl");
    end

    ADDRESS = 0;
    WR_DATA = 0;
    RH_WL   = 1;
    EXEC    = 0;
    #delay_time;
    $display("BFM: Starting TCL command loop (delay done)");

    // Use $fscanf to read directly from file (avoids $sscanf/wide-reg issues)
    while (!$feof(
        file
    )) begin
      read_time_out_cnt = 0;

      // Try jwrite: "jwrite 0xADDR 0xDATA"
      ret = $fscanf(file, " jwrite 0x%h 0x%h\n", temp_addr, temp_data);
      if (ret == 2) begin
        @(posedge clk);
        ADDRESS = temp_addr;
        WR_DATA = temp_data;
        RH_WL   = 0;
        EXEC    = 1;
        @(posedge clk);
        EXEC = 0;
        wait (OP_DONE);
        have_expect = 0;
        cmd_count   = cmd_count + 1;
      end else begin
        // Try jread: "jread 0xADDR"
        ret = $fscanf(file, " jread 0x%h\n", temp_addr);
        if (ret == 1) begin
          @(posedge clk);
          ADDRESS = temp_addr;
          RH_WL   = 1;
          EXEC    = 1;
          @(posedge clk);
          EXEC = 0;
          wait (OP_DONE);
          if (have_expect == 1) begin
            if (RD_DATA == expect_data) begin
              $display("Read 0x%h: 0x%h", ADDRESS, RD_DATA);
              have_expect = 0;
            end else begin
              while ((RD_DATA != expect_data) && (read_time_out_cnt < read_time_out)) begin
                @(posedge clk);
                read_time_out_cnt = read_time_out_cnt + 1;
                ADDRESS = temp_addr;
                RH_WL   = 1;
                EXEC    = 1;
                @(posedge clk);
                EXEC = 0;
                wait (OP_DONE);
              end
              $display("Read 0x%h: 0x%h", ADDRESS, RD_DATA);
              have_expect = 0;
            end
          end
          cmd_count = cmd_count + 1;
        end else begin
          // Try after: "after DELAY"
          ret = $fscanf(file, " after %d\n", dly_t);
          if (ret == 1) begin
            have_expect = 0;
            #(dly_t);
            cmd_count = cmd_count + 1;
          end else begin
            // Try #expect: "#expect 0xVALUE"
            ret = $fscanf(file, " #expect 0x%h\n", expect_data);
            if (ret == 1) begin
              have_expect = 1;
              cmd_count   = cmd_count + 1;
            end else begin
              // Skip unknown line
              ret = $fscanf(file, " %*s\n");
              $display("BFM: Skipped unknown line (cmd %0d)", cmd_count);
            end
          end
        end
      end
    end

    $display("BFM: Execution complete. %0d commands processed.", cmd_count);
    $fclose(file);
  end
endmodule
