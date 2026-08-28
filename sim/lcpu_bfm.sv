//-------------------------------------------------------------------
// lcpu_bfm.sv — Verilator-compatible LCPU bus functional model
//
// Reads a TCL script (jwrite commands) via $fgetc, drives JTAG bus.
// Uses $fgetc parser to avoid $sscanf compatibility issues.
//-------------------------------------------------------------------
`timescale 1ns / 1ps

module lcpu_bfm #(
    parameter read_time_out = 2000,
    parameter delay_time = 1000,
    parameter script_file = "../ref/script.tcl"
) (
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
    integer ch;
    integer cmd_count;
    integer ok;
    integer i;
    reg [31:0] addr, data;
    reg [7:0]  kw_buf [0:9];   // keyword buffer
    integer    kw_len;

    // ---- Hex digit value: returns -1 if not hex ----
    function integer hex_val;
        input [7:0] c;
        begin : hv_func
            if (c >= "0" && c <= "9")      hex_val = c - 48;
            else if (c >= "a" && c <= "f") hex_val = c - 87;
            else if (c >= "A" && c <= "F") hex_val = c - 55;
            else                            hex_val = -1;
        end
    endfunction

    // ---- Read a hex word (stops at first non-hex char) ----
    task read_hex;
        output [31:0] val;
        output integer ok_out;
        integer hv;
        integer cnt;
        begin
            val = 32'h0;
            cnt = 0;
            ok_out = 0;
            // skip whitespace
            while (ch == 32 || ch == 9 || ch == 13) ch = $fgetc(file);
            // skip "0x" prefix if present
            if (ch == 48) begin  // '0'
                ch = $fgetc(file);
                if (ch == 120 || ch == 88) ch = $fgetc(file);  // 'x' or 'X'
            end
            while (cnt < 8) begin
                hv = hex_val(ch[7:0]);
                if (hv == -1) begin  // non-hex character
                    ok_out = (cnt > 0) ? 1 : 0;
                    break;
                end
                val = {val[27:0], hv[3:0]};
                cnt = cnt + 1;
                ch = $fgetc(file);
            end
            if (cnt == 8) ok_out = 1;
        end
    endtask

    // ---- JTAG write operation ----
    task jtag_write;
        input [31:0] waddr;
        input [31:0] wdata;
        begin
            @(posedge clk);
            ADDRESS = waddr;
            WR_DATA = wdata;
            RH_WL   = 0;
            EXEC     = 1;
            @(posedge clk);
            EXEC     = 0;
            wait (OP_DONE);
            cmd_count = cmd_count + 1;
        end
    endtask

    // ---- Skip to end of line ----
    task skip_line;
        begin
            while (ch != -1 && ch != 10) ch = $fgetc(file);
            if (ch != -1) ch = $fgetc(file);  // skip '\n'
        end
    endtask

    initial begin
        file = $fopen(script_file, "r");
        if (file == 0) begin
            $display("BFM Error: Failed to open %s", script_file);
            $stop;
        end
        $display("BFM: Opened %s", script_file);

        ADDRESS = 0;
        WR_DATA = 0;
        RH_WL   = 1;
        EXEC    = 0;
        cmd_count = 0;
        # delay_time;

        ch = $fgetc(file);

        while (ch != -1) begin
            // skip leading whitespace
            while (ch == 32 || ch == 9 || ch == 13 || ch == 10) ch = $fgetc(file);
            if (ch == -1) break;

            // Read keyword until space
            kw_len = 0;
            while (ch != -1 && ch != 32 && ch != 9 && ch != 10 && ch != 13 && kw_len < 10) begin
                kw_buf[kw_len] = ch[7:0];
                kw_len = kw_len + 1;
                ch = $fgetc(file);
            end

            // Check if keyword is "jwrite"
            if (kw_len == 6 &&
                kw_buf[0] == 106 &&  // 'j'
                kw_buf[1] == 119 &&  // 'w'
                kw_buf[2] == 114 &&  // 'r'
                kw_buf[3] == 105 &&  // 'i'
                kw_buf[4] == 116 &&  // 't'
                kw_buf[5] == 101) begin // 'e'

                read_hex(addr, ok);
                if (ok) begin
                    read_hex(data, ok);
                    if (ok) begin
                        jtag_write(addr, data);
                    end
                end
            end

            skip_line();
        end

        $display("BFM: Execution complete. %0d commands processed.", cmd_count);
        $fclose(file);
    end

endmodule
