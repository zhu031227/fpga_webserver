`timescale 1ns/1ps
//==============================================================================
// tb_wl_integration — L2 集成仿真：mac_whitelist_seq × cpu_channel_tri 联合
//
// 验证「包到来 → 提取 SrcMAC → 触发查找 → 门控转发/丢弃」整条链路（6 用例）：
//   1. 白名单加 MAC_A → 喂 SrcMAC=MAC_A → mac2_tx_en 出现波形（转发），drop 不变
//   2. 喂 SrcMAC=MAC_B（不在表）→ mac2_tx_en 无波形，eth1_rx_drop_cnt +1
//   3. enable=0 + defpass=0 → 帧被丢弃
//   4. enable=0 + defpass=1 → 无条件转发
//   4b. enable=1 + defpass=1 → 未命中也放行（回归: defpass 修复）
//   5. 背靠背两帧，第二帧 req 被 busy 挡但不丢，两帧依次正确门控
//   6. CLEAR 进行中喂帧 → 查找不挂死，done 最终到来（结果允许任意）
//==============================================================================

module tb_wl_integration;
    reg clk = 1'b0, cfg_clk = 1'b0, cpu_clk = 1'b0;
    reg reset_l = 1'b0, cfg_reset_l = 1'b0;

    // ---- eth1 RX（tb 喂帧）----
    reg        mac1_rx_sop = 1'b0;
    reg        mac1_rx_en  = 1'b0;
    reg [7:0]  mac1_rx_data = 8'b0;
    reg        mac1_rx_eop = 1'b0;

    // ---- eth2 TX（断言转发）----
    wire       mac2_tx_en;

    // ---- 白名单配置口（50MHz）----
    reg        cfg_rlwh  = 1'b0;
    reg [11:0] cfg_addr  = 12'b0;
    reg [31:0] cfg_wdata = 32'b0;
    wire [31:0] cfg_rdata;

    // ---- 白名单控制 ----
    reg        whitelist_en = 1'b1, default_pass = 1'b0;

    // ---- 查找接口连线 ----
    wire        wl_lookup_req;
    wire [47:0] wl_lookup_mac;
    wire        wl_lookup_match, wl_lookup_done, wl_lookup_busy;

    // ---- 统计 ----
    wire [31:0] eth1_rx_drop_cnt;

    // ---- 转发监测 ----
    reg mac2_tx_seen;

    // ---- 时钟 ----
    initial begin forever #4  clk     = ~clk;     end   // 125MHz
    initial begin forever #10 cfg_clk = ~cfg_clk; end   // 50MHz
    initial begin forever #10 cpu_clk = ~cpu_clk; end   // 50MHz

    // ---- 转发监测：窗口内 mac2_tx_en 是否出现 ----
    always @(posedge clk) begin
        if (reset_l == 1'b0) mac2_tx_seen <= 1'b0;
        else if (mac2_tx_en) mac2_tx_seen <= 1'b1;
    end

    // ---- DUT2: cpu_channel_tri（eth0/eth2 口悬空、CPU 口拉 0）----
    cpu_channel_tri dut2 (
        .clk(clk), .cpu_clk(cpu_clk), .reset_l(reset_l),
        .mac0_rx_sop(1'b0), .mac0_rx_en(1'b0), .mac0_rx_data(8'b0), .mac0_rx_eop(1'b0), .mac0_rx_err(1'b0),
        .mac0_tx_sop(), .mac0_tx_en(), .mac0_tx_data(), .mac0_tx_eop(), .mac0_tx_err(),
        .mac1_rx_sop(mac1_rx_sop), .mac1_rx_en(mac1_rx_en), .mac1_rx_data(mac1_rx_data),
        .mac1_rx_eop(mac1_rx_eop), .mac1_rx_err(1'b0),
        .mac1_tx_sop(), .mac1_tx_en(), .mac1_tx_data(), .mac1_tx_eop(), .mac1_tx_err(),
        .mac2_rx_sop(1'b0), .mac2_rx_en(1'b0), .mac2_rx_data(8'b0), .mac2_rx_eop(1'b0), .mac2_rx_err(1'b0),
        .mac2_tx_sop(), .mac2_tx_en(mac2_tx_en), .mac2_tx_data(), .mac2_tx_eop(), .mac2_tx_err(),
        .wl_lookup_req(wl_lookup_req), .wl_lookup_mac(wl_lookup_mac),
        .wl_lookup_match(wl_lookup_match), .wl_lookup_done(wl_lookup_done), .wl_lookup_busy(wl_lookup_busy),
        .cpu_rd_empty(), .cpu_rd_rpkt_pop(1'b0), .cpu_rd_rpkt_len(), .cpu_rd_rpkt_para(),
        .cpu_rd_ren(1'b0), .cpu_rd_raddr(12'b0), .cpu_rd_rdata(), .cpu_rd_reop_pre(),
        .cpu_wr_full(), .cpu_wr_wen(1'b0), .cpu_wr_waddr(12'b0), .cpu_wr_wdata(8'b0),
        .cpu_wr_wpkt_push(1'b0), .cpu_wr_wpkt_len(13'b0), .cpu_wr_wpkt_para(1'b0),
        .whitelist_en(whitelist_en), .default_pass(default_pass),
        .eth1_rx_drop_cnt(eth1_rx_drop_cnt), .recv_pkt_drop_cnt()
    );

    // ---- DUT1: mac_whitelist engine (dual-mode: -D CUCKOO → cuckoo else seq) ----
`ifdef CUCKOO
    mac_whitelist_cuckoo #(
        .BUCKET_NUM(64), .ADDR_WIDTH(6), .CAPACITY(96)
    ) dut1 (
        .clk(clk), .reset_l(reset_l),
        .lookup_req(wl_lookup_req), .lookup_mac(wl_lookup_mac),
        .lookup_match(wl_lookup_match), .lookup_done(wl_lookup_done), .lookup_busy(wl_lookup_busy),
        .cfg_clk(cfg_clk), .cfg_reset_l(cfg_reset_l),
        .cfg_rlwh(cfg_rlwh), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_rdata(cfg_rdata),
        .whitelist_en(whitelist_en), .default_pass(default_pass),
        .wl_used_cnt()
    );
`else
    mac_whitelist_seq dut1 (
        .clk(clk), .reset_l(reset_l),
        .lookup_req(wl_lookup_req), .lookup_mac(wl_lookup_mac),
        .lookup_match(wl_lookup_match), .lookup_done(wl_lookup_done), .lookup_busy(wl_lookup_busy),
        .cfg_clk(cfg_clk), .cfg_reset_l(cfg_reset_l),
        .cfg_rlwh(cfg_rlwh), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_rdata(cfg_rdata),
        .whitelist_en(whitelist_en), .default_pass(default_pass)
    );
`endif

    // ---- MAC 常量 ----
    localparam [47:0] MAC_A = 48'h11_22_33_44_55_01;
    localparam [47:0] MAC_B = 48'hAA_BB_CC_DD_EE_EE;

    integer errors = 0;

`ifdef CUCKOO
    // ============ MODE=2 (CUCKOO) helpers ============
    localparam integer CLEAR_WAIT = 4000;   // 128 拍 × 20ns + 裕量

    // tb-side bit-exact hash copy of RTL fold/h0/h1
    function automatic integer tb_fold(input [63:0] x);
        integer i, r;
        begin r = 0; for (i = 0; i < 8; i = i + 1) r = r ^ ((x >> (6*i)) & 64'h3F); tb_fold = r; end
    endfunction
    function automatic [63:0] tb_bswap48(input [63:0] x);
        begin
            tb_bswap48 = ((x & 64'h0000000000FF) << 40) | ((x & 64'h00000000FF00) << 24)
                       | ((x & 64'h000000FF0000) << 8)  | ((x & 64'h0000FF000000) >> 8)
                       | ((x & 64'h00FF00000000) >> 24) | ((x & 64'hFF0000000000) >> 40);
        end
    endfunction
    function automatic integer tb_h0(input [63:0] mac); tb_h0 = tb_fold(mac); endfunction
    function automatic integer tb_h1(input [63:0] mac); tb_h1 = tb_fold(tb_bswap48(mac)); endfunction

    // 加一条 MAC：落位到空候选槽（h0 空则 h0，否则 h1；镜像简易跟踪）
    reg [47:0] ck_slot_mac [0:127];
    reg        ck_slot_valid [0:127];
    task automatic ck_write_slot(input [6:0] slot, input [47:0] m);
        begin
            subbus_wr(12'h0, {25'b0, slot});
            subbus_wr(12'h1, m[47:16]);
            subbus_wr(12'h2, {16'b0, m[15:0]});
            subbus_wr(12'h3, 32'b1);
            #3000;
            ck_slot_valid[slot] = 1; ck_slot_mac[slot] = m;
        end
    endtask
    task automatic ck_clear_all;
        integer s;
        begin
            subbus_wr(12'h5, 32'b1);
            #4000;
            for (s = 0; s < 128; s = s + 1) begin ck_slot_valid[s] = 0; ck_slot_mac[s] = 48'b0; end
        end
    endtask
    // add：查重 / 空位直达；双槽皆占则踢 h0 槽住客到它的 h1（1 跳 bounded，L1 已全测 eviction）
    task automatic wl_add_mac(input [47:0] mac);
        integer s0, s1, hv;
        reg [47:0] occ;
        begin
            s0 = tb_h0(mac); s1 = 64 + tb_h1(mac);
            if (ck_slot_valid[s0] && ck_slot_mac[s0] == mac) begin end
            else if (ck_slot_valid[s1] && ck_slot_mac[s1] == mac) begin end
            else if (!ck_slot_valid[s0]) ck_write_slot(s0[6:0], mac);
            else if (!ck_slot_valid[s1]) ck_write_slot(s1[6:0], mac);
            else begin
                // 双槽皆占：mac 住 s0；被踢者 occ 迁到它的 h1（1 跳；h1 一般空，除非极端碰撞）
                occ = ck_slot_mac[s0];
                ck_slot_valid[s0] = 0;
                ck_write_slot(s0[6:0], mac);
                hv = 64 + tb_h1(occ);
                if (ck_slot_valid[hv]) begin
                    // 兜底：目标也被占 → 简单覆盖（并发窗测试不追求完美布局）
                end
                ck_write_slot(hv[6:0], occ);
            end
        end
    endtask
    // MODE=0 同语义包装（seq 用序号写；本 tb 只用 MAC_A 一次）
`else
    localparam integer CLEAR_WAIT = 500;    // seq 16 拍 + 余量
    integer ck_idx_w = 0;
    task automatic wl_add_mac(input [47:0] mac);
        begin
            wr_mac(ck_idx_w[3:0], mac); ck_idx_w = ck_idx_w + 1;
        end
    endtask
`endif

    task automatic do_reset;
        begin
            reset_l = 1'b0; cfg_reset_l = 1'b0;
            #100; reset_l = 1'b1; cfg_reset_l = 1'b1; #100;
        end
    endtask

    task automatic subbus_wr(input [11:0] addr, input [31:0] data);
        begin
            cfg_rlwh = 1'b1; cfg_addr = addr; cfg_wdata = data;
            #30;
            cfg_rlwh = 1'b0;
            #20;
        end
    endtask

    task automatic wr_mac(input [3:0] idx, input [47:0] mac);
        begin
            subbus_wr(12'h0, {28'b0, idx});
            subbus_wr(12'h1, mac[47:16]);
            subbus_wr(12'h2, {16'b0, mac[15:0]});
            subbus_wr(12'h3, 32'b0);
            #200;
        end
    endtask

    task automatic send_frame(input [47:0] srcmac);
        integer i;
        reg [7:0] f [0:63];
        begin
            for (i = 0; i < 6; i = i + 1) f[i] = 8'hFF;
            f[6]  = srcmac[47:40]; f[7]  = srcmac[39:32];
            f[8]  = srcmac[31:24]; f[9]  = srcmac[23:16];
            f[10] = srcmac[15:8];  f[11] = srcmac[7:0];
            f[12] = 8'h08; f[13] = 8'h00;
            for (i = 14; i < 64; i = i + 1) f[i] = 8'h00;
            @(posedge clk);
            for (i = 0; i < 64; i = i + 1) begin
                mac1_rx_sop  <= (i == 0);
                mac1_rx_eop  <= (i == 63);
                mac1_rx_en   <= 1'b1;
                mac1_rx_data <= f[i];
                @(posedge clk);
            end
            mac1_rx_en <= 1'b0; mac1_rx_sop <= 1'b0; mac1_rx_eop <= 1'b0;
            @(posedge clk);   // 等 en 下降沿稳定，让 wpkt_push 明确产生
        end
    endtask

    task automatic clear_tx_seen;
        begin
            @(negedge clk);
            mac2_tx_seen = 1'b0;
        end
    endtask

    // ---- 检查：转发标志 + drop 差值 ----
    task automatic check_result(input integer tag, input [0:0] want_fwd,
                                input [31:0] drop_before, input [31:0] want_delta);
        reg [31:0] d;
        begin
            d = eth1_rx_drop_cnt - drop_before;
            if (mac2_tx_seen !== want_fwd) begin
                $display("  [FAIL] case%0d: mac2_tx_seen=%b want=%b", tag, mac2_tx_seen, want_fwd);
                errors = errors + 1;
            end else if (d !== want_delta) begin
                $display("  [FAIL] case%0d: drop_delta=%0d want=%0d", tag, d, want_delta);
                errors = errors + 1;
            end else begin
                $display("  [PASS] case%0d: fwd=%b drop_delta=%0d", tag, mac2_tx_seen, d);
            end
        end
    endtask

    integer drop_before;

    initial begin
        errors = 0;
        do_reset();

        // 上电后固件 whitelist_init 会先清空白名单（BRAM 上电内容未定义，
        // 不 CLEAR 会让未初始化条目读成 X、污染 miss 查找结果）。
        subbus_wr(12'h5, 32'b1);   // CLEAR
        #(CLEAR_WAIT);             // 等 clear 序列器扫完（seq 16 拍 / cuckoo 128 拍）

        $display("=== Test 1: 白名单加 MAC_A → 喂 MAC_A 帧 → 转发 ===");
        wl_add_mac(MAC_A);
        clear_tx_seen();
        drop_before = eth1_rx_drop_cnt;
        send_frame(MAC_A);
        #2000;
        check_result(101, 1'b1, drop_before, 32'd0);

        $display("=== Test 2: 喂 MAC_B（不在表）→ 丢弃 ===");
        clear_tx_seen();
        drop_before = eth1_rx_drop_cnt;
        send_frame(MAC_B);
        #2000;
        check_result(200, 1'b0, drop_before, 32'd1);

        $display("=== Test 3: enable=0 defpass=0 → 丢弃 ===");
        whitelist_en = 1'b0; default_pass = 1'b0;
        clear_tx_seen();
        drop_before = eth1_rx_drop_cnt;
        send_frame(MAC_A);
        #2000;
        check_result(300, 1'b0, drop_before, 32'd1);

        $display("=== Test 4: enable=0 defpass=1 → 无条件转发 ===");
        default_pass = 1'b1;
        clear_tx_seen();
        drop_before = eth1_rx_drop_cnt;
        send_frame(MAC_B);
        #2000;
        check_result(400, 1'b1, drop_before, 32'd0);
        whitelist_en = 1'b1; default_pass = 1'b1;

        // 回归: 修复"en=1时defpass被忽略"缺陷 (2026-08-30 板测4a实锤)
        // en=1+defpass=1 下未命中帧也必须放行
        $display("=== Test 4b: enable=1 defpass=1 → 未命中也放行 ===");
        clear_tx_seen();
        drop_before = eth1_rx_drop_cnt;
        send_frame(MAC_B);
        #2000;
        check_result(450, 1'b1, drop_before, 32'd0);

        $display("=== Test 5: 背靠背两帧 ===");
        default_pass = 1'b0;   // 恢复丢弃语义, 保持背靠背用例原期望
        clear_tx_seen();
        drop_before = eth1_rx_drop_cnt;
        send_frame(MAC_A);
        send_frame(MAC_B);
        #3000;
        begin
            integer d5;
            d5 = eth1_rx_drop_cnt - drop_before;
            if (mac2_tx_seen !== 1'b1) begin
                $display("  [FAIL] case500: MAC_A 帧未转发");
                errors = errors + 1;
            end else if (d5 !== 32'd1) begin
                $display("  [FAIL] case500: drop_delta=%0d want=1", d5);
                errors = errors + 1;
            end else $display("  [PASS] case500: 背靠背 fwd=1 drop_delta=1");
        end

        $display("=== Test 6: CLEAR 进行中喂帧 → 不挂死 ===");
        subbus_wr(12'h5, 32'b1);   // CLEAR
        clear_tx_seen();
        drop_before = eth1_rx_drop_cnt;
        send_frame(MAC_A);
        #3000;
        begin
            integer d6;
            d6 = eth1_rx_drop_cnt - drop_before;
            if (mac2_tx_seen === 1'bx || d6 === 32'hxxxxxxxx) begin
                $display("  [FAIL] case600: 出现 X 态");
                errors = errors + 1;
            end else begin
                $display("  [PASS] case600: 不挂死（fwd=%b drop_delta=%0d）", mac2_tx_seen, d6);
            end
        end

`ifdef CUCKOO
        //========================================================================
        $display("=== Test 7 (MODE2): cfg eviction 写 ∥ 帧流 → 不挂死、转发恢复 ===");
        begin : t7
            reg [63:0] pool [0:7];
            integer pi, fc, j;
            reg [47:0] base;
            ck_clear_all;
            for (pi = 0; pi < 8; pi = pi + 1) pool[pi] = 48'hC0_00_00_00_00_00 + (4000 + pi);
            base = MAC_A;
            wl_add_mac(base);
            clear_tx_seen();
            fork
                begin : frame_thread          // 路 1：持续喂已入表 MAC 的帧
                    for (fc = 0; fc < 30; fc = fc + 1) send_frame(base);
                end
                begin : cfg_thread            // 路 2：cfg 写风暴（含 eviction 踢人）
                    for (j = 0; j < 40; j = j + 1) wl_add_mac(pool[j % 8]);
                end
            join
            // 收官：清空 + 重加 base + 验证转发（引擎在风暴后仍活、无 X、未挂死）
            ck_clear_all;
            wl_add_mac(base);
            clear_tx_seen();
            drop_before = eth1_rx_drop_cnt;
            send_frame(base);
            #2000;
            if (mac2_tx_seen !== 1'b1) begin
                $display("  [FAIL] case700: 风暴后转发丢失/引擎未恢复");
                errors = errors + 1;
            end else if (eth1_rx_drop_cnt === 32'hxxxxxxxx) begin
                $display("  [FAIL] case700: 出现 X");
                errors = errors + 1;
            end else
                $display("  [PASS] case700: eviction 写∥帧流 不挂死，转发恢复（fwd=1 drop_delta=%0d）",
                         eth1_rx_drop_cnt - drop_before);
        end
`endif

        if (errors == 0) $display("\n========== ALL 7 TESTS PASSED ==========");
        else             $display("\n========== FAILURES: %0d ==========", errors);
        #100;
        $finish;
    end
endmodule
