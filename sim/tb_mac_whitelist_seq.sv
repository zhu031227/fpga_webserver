`timescale 1ns/1ps
//==============================================================================
// tb_mac_whitelist_seq — mac_whitelist_seq L1 单元仿真（8 用例）
//
// 验证模式 0（BRAM 顺序查找）：
//   1. 写 3 条（idx0/7/15）→ 全命中
//   2. 未添加 MAC → miss
//   3. DEL idx7 → idx7 miss、idx0 仍 hit
//   4. CLEAR → 任意 miss + USED_CNT=0
//   5. 加满 16 条 → free_idx=0xF（表满）
//   6. en=0 + default_pass 0/1 → match 恒 = default_pass
//   7. 周期数 ==18 强断言
//   8. 连续两笔查找不丢
//
// 计数约定：FSM 采样到 req 的上升沿记 0，此后每拍 +1，lookup_done=1 停。
// 正确实现 cyc == 18。
//==============================================================================

module tb_mac_whitelist_seq;
    reg clk = 1'b0, cfg_clk = 1'b0;
    reg reset_l = 1'b0, cfg_reset_l = 1'b0;           // 两域复位，低有效
    reg         cfg_rlwh   = 1'b0;
    reg  [11:0] cfg_addr  = 12'b0;
    reg  [31:0] cfg_wdata = 32'b0;
    wire [31:0] cfg_rdata;
    reg         lookup_req = 1'b0;
    reg  [47:0] lookup_mac = 48'b0;
    wire        lookup_match, lookup_done, lookup_busy;
    reg         whitelist_en = 1'b1, default_pass = 1'b0;

    mac_whitelist_seq dut (
        .clk(clk), .reset_l(reset_l),
        .lookup_req(lookup_req), .lookup_mac(lookup_mac),
        .lookup_match(lookup_match), .lookup_done(lookup_done), .lookup_busy(lookup_busy),
        .cfg_clk(cfg_clk), .cfg_reset_l(cfg_reset_l),
        .cfg_rlwh(cfg_rlwh), .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata), .cfg_rdata(cfg_rdata),
        .whitelist_en(whitelist_en), .default_pass(default_pass)
    );

    initial begin forever #4  clk     = ~clk;     end   // 125MHz → 半周期 4ns
    initial begin forever #10 cfg_clk = ~cfg_clk; end   // 50MHz  → 半周期 10ns

    // MAC 常量（下标即目标槽位，便于对号）
    localparam [47:0] M0    = 48'h11_22_33_44_55_01;
    localparam [47:0] M7    = 48'h11_22_33_44_55_07;
    localparam [47:0] M15   = 48'h11_22_33_44_55_0F;
    localparam [47:0] MISS  = 48'hAA_BB_CC_DD_EE_EE;
    localparam [47:0] FULL0 = 48'hAA_00_00_00_00_00;   // 用例 5 第一条

    integer errors = 0;

    // ---- 复位：两域同拉低再同释放 ----
    task automatic do_reset;
        begin
            reset_l = 1'b0; cfg_reset_l = 1'b0;
            #100; reset_l = 1'b1; cfg_reset_l = 1'b1; #100;
        end
    endtask

    // ---- SubBus 写（电平敏感、多拍，幂等）----
    task automatic subbus_wr(input [11:0] addr, input [31:0] data);
        begin
            cfg_rlwh = 1'b1; cfg_addr = addr; cfg_wdata = data;
            #30;                          // 多拍电平（模拟 3 拍写事务）
            cfg_rlwh = 1'b0;
            #20;
        end
    endtask

    // ---- SubBus 读（组合读，零延迟）----
    task automatic subbus_rd(input [11:0] addr, output [31:0] data);
        begin
            cfg_rlwh = 1'b0; cfg_addr = addr;
            #5;
            data = cfg_rdata;
        end
    endtask

    // ---- 写一条 MAC：INDEX → MAC_H → MAC_L → WR ----
    task automatic wr_mac(input [3:0] idx, input [47:0] mac);
        begin
            subbus_wr(12'h0, {28'b0, idx});
            subbus_wr(12'h1, mac[47:16]);
            subbus_wr(12'h2, {16'b0, mac[15:0]});
            subbus_wr(12'h3, 32'b0);
            #100;                          // 等 BRAM 写稳定（跨 cfg_clk/clk 域）
        end
    endtask

    // ---- 查找任务：发 req、等 done、采 match、数周期 ----
    task automatic do_lookup(input [47:0] mac, output reg hit, output integer cyc);
        begin
            lookup_mac = mac;
            lookup_req = 1'b1;
            @(posedge clk);                        // FSM 采样到 req 的边沿 = 计数起点（记 0）
            lookup_req = 1'b0;
            cyc = 0;
            while (lookup_done !== 1'b1 && cyc < 1000) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            if (cyc >= 1000) $fatal(1, "lookup_done timeout, mac=%h", mac);
            hit = lookup_match;                    // done 拍采样 match
        end
    endtask

    // ---- 断言 helper ----
    task automatic check_hit(input [47:0] mac, input [0:0] exp, input integer tag);
        reg hit;
        integer cyc;
        begin
            do_lookup(mac, hit, cyc);
            if (hit !== exp) begin
                $display("  [FAIL] case%0d: mac=%h hit=%b exp=%b", tag, mac, hit, exp);
                errors = errors + 1;
            end else begin
                $display("  [PASS] case%0d: mac=%h hit=%b (cyc=%0d)", tag, mac, hit, cyc);
            end
        end
    endtask

    integer i;
    reg [31:0] rd;
    reg hit;
    integer n_cyc;

    initial begin
        errors = 0;
        do_reset();

        //----------------------------------------------------------------------
        $display("=== Test 1: 写 3 条 idx0/7/15 → 全命中 ===");
        wr_mac(4'd0, M0);
        wr_mac(4'd7, M7);
        wr_mac(4'd15, M15);
        check_hit(M0, 1'b1, 101);
        check_hit(M7, 1'b1, 102);
        check_hit(M15, 1'b1, 103);

        //----------------------------------------------------------------------
        $display("=== Test 2: 未添加 MAC → miss ===");
        check_hit(MISS, 1'b0, 200);

        //----------------------------------------------------------------------
        $display("=== Test 3: DEL idx7 ===");
        subbus_wr(12'h0, {28'b0, 4'd7});   // INDEX=7
        subbus_wr(12'h4, 32'b1);           // DEL
        #100;
        check_hit(M7, 1'b0, 301);
        check_hit(M0, 1'b1, 302);

        //----------------------------------------------------------------------
        $display("=== Test 4: CLEAR ===");
        subbus_wr(12'h5, 32'b1);           // CLEAR
        #400;                              // clear sequencer 16 拍 + 余量
        check_hit(M0, 1'b0, 400);
        subbus_rd(12'hB, rd);              // USED_CNT
        if (rd !== 32'd0) begin
            $display("  [FAIL] T4 USED_CNT=0x%h expect 0", rd);
            errors = errors + 1;
        end else $display("  [PASS] T4 USED_CNT=0");

        //----------------------------------------------------------------------
        $display("=== Test 5: 加满 16 条 ===");
        for (i = 0; i < 16; i = i + 1)
            wr_mac(i[3:0], 48'hAA_00_00_00_00_00 + i);
        subbus_rd(12'h9, rd);              // FREE_IDX
        if (rd[3:0] !== 4'hF) begin
            $display("  [FAIL] T5 free_idx=0x%h expect 0xF", rd[3:0]);
            errors = errors + 1;
        end else $display("  [PASS] T5 free_idx=0xF (表满)");

        //----------------------------------------------------------------------
        $display("=== Test 6: en=0 + default_pass 两态 ===");
        whitelist_en = 1'b0; default_pass = 1'b1;
        check_hit(MISS, 1'b1, 601);
        default_pass = 1'b0;
        check_hit(MISS, 1'b0, 602);
        whitelist_en = 1'b1; default_pass = 1'b1;

        //----------------------------------------------------------------------
        $display("=== Test 7: 周期数 ==18 ===");
        do_lookup(FULL0, hit, n_cyc);
        if (n_cyc !== 18) begin
            $display("  [FAIL] T7 cyc=%0d expect 18", n_cyc);
            errors = errors + 1;
        end else $display("  [PASS] T7 cyc=18");

        //----------------------------------------------------------------------
        $display("=== Test 8: 连续两笔查找 ===");
        check_hit(FULL0, 1'b1, 801);
        check_hit(FULL0, 1'b1, 802);

        //----------------------------------------------------------------------
        if (errors == 0) $display("\n========== ALL 8 TESTS PASSED ==========");
        else             $display("\n========== FAILURES: %0d ==========", errors);
        #100;
        $finish;
    end
endmodule
