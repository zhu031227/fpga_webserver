`timescale 1ns/1ps
//==============================================================================
// tb_mac_whitelist_cuckoo — mac_whitelist_cuckoo L1 单元仿真
//
// 验证模式 2（BRAM 布谷鸟哈希，双 bank 并行读，2 拍查找）：
//   T1  写 3 条（h0 落位 / h1 落位 / 1 跳 eviction）→ 全命中
//   T2  未添加 MAC → miss（2 拍）
//   T3  DEL 一条 → 该条 miss、其余仍 hit
//   T4  CLEAR → 任意 miss + USED_CNT=0（128 拍序列器扫全双 bank）
//   T5  灌到 CAP=96 → 全命中 + 第 97 条判满拒 + USED_CNT=96 + MAX=96 + FREE=0x7F
//   T6  en=0 + default_pass 两态 → match 恒 = default_pass
//   T7  周期数 ==2 强断言（三模式分水岭）
//   T8  busy 期间持续 req → 第二笔不丢（两笔都完成且正确）
//   T9  双槽皆占触发 eviction（p/q/x 配方）→ x tb_add_hops==2，p/q/x 全命中
//   T10 eviction 链（g/t/w/v/s/x 配方）→ x tb_add_hops==4，6 条全命中
//   T11 金模型随机对拍 500 次（add/del/lookup 混合，含 INV-B/镜像/模型三裁判）
//   T12 空表 lookup → miss（2 拍）
//   T13 槽违例注入（写错槽）→ miss + INV-B 裁判报警（可诊断性）
//   T14 同一 MAC 加两次 → 返回同一槽位、条目数不涨
//
// 计数约定（同 tb_mac_whitelist_seq）：FSM 采到 req 的上升沿记 0，此后每拍 +1，
// lookup_done=1 停。模式 2 正确实现 cyc == 2。
//
// 说明（相对文档 5.2 的工程化调整）：
//  - INV-B/DUT↔镜像裁判用 cfg 读口读 DUT 真实存储（INDEX→0x6/0x7/0x8），
//    不做层次位选（iverilog memory 位选支持不一的坑）。
//  - 裁判非 fatal 计数，错误累积后统一 FAIL 汇总，便于定位。
//  - tb 复位后先 CLEAR 双 bank（真实固件启动同样先 clear；未初始化 BRAM 读 x
//    会经 hit_comb 传播成 match=x）。
//  - tb_cuckoo_add/tb_cuckoo_del 即 C 固件 8.3/8.4 的行为参照（哈希落位+交替
//    bank eviction+快照回滚）。
//==============================================================================

module tb_mac_whitelist_cuckoo;
    reg clk = 1'b0, cfg_clk = 1'b0;
    reg reset_l = 1'b0, cfg_reset_l = 1'b0;
    reg cfg_rlwh = 1'b0;
    reg [11:0] cfg_addr = 12'b0;
    reg [31:0] cfg_wdata = 32'b0;
    wire [31:0] cfg_rdata;
    reg lookup_req = 1'b0;
    reg [47:0] lookup_mac = 48'b0;
    wire lookup_match, lookup_done, lookup_busy;
    reg whitelist_en = 1'b1, default_pass = 1'b0;
    wire [7:0] wl_used_cnt;
    wire [15:0] wl_status = {wl_used_cnt, 8'd2};

    integer errors = 0;

    mac_whitelist_cuckoo #(
        .BUCKET_NUM(64), .ADDR_WIDTH(6), .CAPACITY(96)
    ) dut (
        .clk(clk), .reset_l(reset_l),
        .lookup_req(lookup_req), .lookup_mac(lookup_mac),
        .lookup_match(lookup_match), .lookup_done(lookup_done), .lookup_busy(lookup_busy),
        .cfg_clk(cfg_clk), .cfg_reset_l(cfg_reset_l),
        .cfg_rlwh(cfg_rlwh), .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata), .cfg_rdata(cfg_rdata),
        .whitelist_en(whitelist_en), .default_pass(default_pass),
        .wl_used_cnt(wl_used_cnt)
    );

    initial begin forever #4  clk     = ~clk;     end   // 125MHz
    initial begin forever #10 cfg_clk = ~cfg_clk; end   // 50MHz

    localparam integer EXP_CYC = 2;
    localparam longint unsigned SCAN_BASE = 48'hC0_00_00_00_00_00;
    localparam integer SCAN_N = 65536;

    // =====================================================================
    // tb 侧哈希副本（RTL wl_fold/hash0/hash1 的 64bit 精确复刻；48bit MAC 必须 64bit 容器）
    // =====================================================================
    function automatic integer tb_fold(input [63:0] x);
        integer i, r;
        begin
            r = 0;
            for (i = 0; i < 8; i = i + 1) r = r ^ ((x >> (6*i)) & 64'h3F);
            tb_fold = r;
        end
    endfunction
    function automatic [63:0] tb_bswap48(input [63:0] x);
        begin
            tb_bswap48 = ((x & 64'h0000000000FF) << 40) | ((x & 64'h00000000FF00) << 24)
                       | ((x & 64'h000000FF0000) << 8)  | ((x & 64'h0000FF000000) >> 8)
                       | ((x & 64'h00FF00000000) >> 24) | ((x & 64'hFF0000000000) >> 40);
        end
    endfunction
    function automatic integer tb_h0(input [63:0] mac);
        tb_h0 = tb_fold(mac);
    endfunction
    function automatic integer tb_h1(input [63:0] mac);
        tb_h1 = tb_fold(tb_bswap48(mac));
    endfunction

    // =====================================================================
    // 时钟/复位/总线基本任务
    // =====================================================================
    task automatic do_reset;
        begin
            reset_l = 0; cfg_reset_l = 0;
            #100; reset_l = 1; cfg_reset_l = 1; #100;
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

    task automatic subbus_rd(input [11:0] addr, output [31:0] data);
        begin
            cfg_rlwh = 1'b0; cfg_addr = addr;
            #5;
            data = cfg_rdata;
        end
    endtask

    task automatic do_lookup(input [63:0] mac, output reg hit, output integer cyc);
        integer g, t0;
        begin
            lookup_mac = mac[47:0];
            lookup_req = 1'b0;
            // 1ns 自由轮询组合信号（不用 @(posedge)，彻底规避 tb/DUT 同沿调度竞态）：
            // 先等 FSM 空闲且 done 已撤
            g = 0;
            while ((lookup_busy === 1'b1 || lookup_done === 1'b1) && g < 4000) begin #1; g = g + 1; end
            // 发 req（保持高电平直到 done 出现），数周期 = 时间差/8ns
            lookup_req = 1'b1;
            t0 = $time;
            g = 0;
            while (lookup_done !== 1'b1 && g < 4000) begin #1; g = g + 1; end
            lookup_req = 1'b0;              // done 一出现即撤 req（同周期内），不会重发
            cyc = ($time - t0) / 8;
            if (g >= 4000) $display("  [WARN] lookup_done timeout mac=%h state=%0d", mac, dut.state);
            hit = lookup_match;
            #1;
        end
    endtask

    task automatic check_hit(input [63:0] mac, input [0:0] exp, input integer tag);
        reg hit; integer cyc;
        begin
            do_lookup(mac, hit, cyc);
            // 周期断言 1~4：物理 req→done = 2 拍（16ns）；事件级测量受相位影响落 1~2，
            // 仍与模式 0(18)/1(≤10) 显著区分（2 拍由 RTL 结构保证 + 10.3 ILA 实测兜底）。
            if (hit !== exp || cyc < 1 || cyc > 4) begin
                $display("  [FAIL] case%0d: mac=%h hit=%b exp=%b cyc=%0d", tag, mac, hit, exp, cyc);
                errors = errors + 1;
            end else
                $display("  [PASS] case%0d: mac=%h hit=%b (cyc=%0d)", tag, mac, hit, cyc);
        end
    endtask

    // =====================================================================
    // 金模型：无序集合（定长数组 + 计数）
    // =====================================================================
    longint unsigned model_mac [0:127];
    integer          model_cnt = 0;

    function automatic integer model_lookup(input longint unsigned mac);
        integer i;
        begin
            model_lookup = 0;
            for (i = 0; i < model_cnt; i = i + 1)
                if (model_mac[i] == mac) model_lookup = 1;
        end
    endfunction
    task automatic model_add(input longint unsigned mac);
        begin
            if (!model_lookup(mac)) begin model_mac[model_cnt] = mac; model_cnt = model_cnt + 1; end
        end
    endtask
    task automatic model_del(input longint unsigned mac);
        integer i;
        begin
            for (i = 0; i < model_cnt; i = i + 1)
                if (model_mac[i] == mac) begin
                    model_mac[i] = model_mac[model_cnt-1];
                    model_cnt = model_cnt - 1;
                    i = model_cnt;
                end
        end
    endtask

    // =====================================================================
    // tb 槽位镜像（与 C 侧 sw_wl_* 同构：下标即槽位号）
    // =====================================================================
    reg [47:0] tb_slot_mac   [0:127];
    reg        tb_slot_valid [0:127];
    reg [47:0] snap_mac      [0:127];
    reg        snap_valid    [0:127];
    integer    snap_cnt = 0, i_snap = 0;
    integer    tb_add_hops = 0;
    reg [6:0]  tb_add_ret = 7'h7F;
    reg        tb_cap_reject = 0, tb_add_fail = 0;

    task automatic mirror_reset;
        integer s;
        begin
            for (s = 0; s < 128; s = s + 1) begin
                tb_slot_valid[s] = 0; tb_slot_mac[s] = 48'b0;
            end
            model_cnt = 0;
            tb_add_hops = 0; tb_add_ret = 7'h7F;
            tb_cap_reject = 0; tb_add_fail = 0;
        end
    endtask

    // =====================================================================
    // HW 写/清 原语
    // =====================================================================
    task automatic tb_hw_write_slot(input [6:0] slot, input [63:0] mac);
        begin
            subbus_wr(12'h0, {25'b0, slot});         // INDEX = slot#
            subbus_wr(12'h1, mac[47:16]);            // MAC_H
            subbus_wr(12'h2, {16'b0, mac[15:0]});    // MAC_L
            subbus_wr(12'h3, 32'b1);                 // WR 触发
            #3000;                                   // 跨域写稳定（裕量实验）
        end
    endtask

    task automatic tb_hw_clear_and_wait;
        integer w;
        begin
            subbus_wr(12'h5, 32'b1);                 // CLEAR 触发序列器（128 拍 cfg）
            #4000;                                   // 128*20ns + 裕量
        end
    endtask

    // =====================================================================
    // tb_cuckoo_add — 行为等同 C whitelist_add (8.3)：哈希定位 + 交替bank eviction
    // =====================================================================
    task automatic tb_cuckoo_add(input longint unsigned mac);
        reg [6:0] s0, s1, tgt;
        reg [47:0] cur, victim;
        integer bank, hop, placed;
        begin
            s0 = tb_h0(mac);            // bank0 槽号 = h0（0..63）
            s1 = 64 + tb_h1(mac);       // bank1 槽号 = 64 + h1
            tb_add_hops = 0; tb_add_ret = 7'h7F; tb_cap_reject = 0; tb_add_fail = 0; placed = 0;
            if (model_cnt >= 96) begin
                tb_cap_reject = 1;                                              // 判满（CAP=96）
            end else if ((tb_slot_valid[s0] && tb_slot_mac[s0] == mac[47:0])
                      || (tb_slot_valid[s1] && tb_slot_mac[s1] == mac[47:0])) begin
                model_add(mac);                                                 // 查重幂等
                if (tb_slot_valid[s0] && tb_slot_mac[s0] == mac[47:0]) tb_add_ret = s0;
                else tb_add_ret = s1;
            end else if (!tb_slot_valid[s0]) begin                              // 空位直达 h0
                tb_hw_write_slot(s0, mac[47:0]);
                tb_slot_valid[s0] = 1; tb_slot_mac[s0] = mac[47:0]; model_add(mac);
                tb_add_ret = s0; placed = 1;
            end else if (!tb_slot_valid[s1]) begin                              // 空位直达 h1
                tb_hw_write_slot(s1, mac[47:0]);
                tb_slot_valid[s1] = 1; tb_slot_mac[s1] = mac[47:0]; model_add(mac);
                tb_add_ret = s1; placed = 1;
            end else begin                                                      // 双槽皆占 → eviction
                cur = mac[47:0]; bank = 0;
                tb_add_ret = s0;                                                // 新 MAC 恒落首跳 bank0 槽 s0
                for (i_snap = 0; i_snap < 128; i_snap = i_snap + 1) begin
                    snap_valid[i_snap] = tb_slot_valid[i_snap];
                    snap_mac[i_snap]   = tb_slot_mac[i_snap];
                end
                snap_cnt = model_cnt;
                for (hop = 0; hop < 8 && !placed; hop = hop + 1) begin
                    tgt = (bank == 0) ? tb_h0(cur) : 64 + tb_h1(cur);
                    if (!tb_slot_valid[tgt]) begin
                        tb_hw_write_slot(tgt, cur);
                        tb_slot_valid[tgt] = 1; tb_slot_mac[tgt] = cur; model_add(cur);
                        tb_add_hops = hop + 1; placed = 1;
                    end else begin
                        victim = tb_slot_mac[tgt];          // 先存受害者
                        tb_hw_write_slot(tgt, cur);
                        tb_slot_mac[tgt] = cur; model_add(cur);
                        cur  = victim;
                        bank = 1 - bank;                    // 交替 bank（防乒乓）
                    end
                end
                if (!placed) begin                          // 8 跳失败 → 快照回滚
                    tb_hw_clear_and_wait;
                    for (i_snap = 0; i_snap < 128; i_snap = i_snap + 1) begin
                        tb_slot_valid[i_snap] = 0; tb_slot_mac[i_snap] = 48'b0;
                    end
                    for (i_snap = 0; i_snap < 128; i_snap = i_snap + 1) begin
                        if (snap_valid[i_snap]) begin
                            tb_hw_write_slot(i_snap[6:0], snap_mac[i_snap]);
                            tb_slot_valid[i_snap] = 1; tb_slot_mac[i_snap] = snap_mac[i_snap];
                        end
                    end
                    model_cnt = snap_cnt;
                    tb_add_fail = 1;
                end
            end
        end
    endtask

    // =====================================================================
    // tb_cuckoo_del — 单槽删除（INDEX|bit31 一笔带删）
    // =====================================================================
    task automatic tb_cuckoo_del(input [6:0] slot);
        reg [47:0] m;
        begin
            if (tb_slot_valid[slot]) begin
                m = tb_slot_mac[slot];
                subbus_wr(12'h0, {1'b1, 24'b0, slot});     // INDEX | bit31：带删
                #600;
                tb_slot_valid[slot] = 0; tb_slot_mac[slot] = 48'b0;
                model_del(m);
            end
        end
    endtask

    // =====================================================================
    // DUT 槽内容读取（走 cfg 读口：INDEX → 0x6/0x7/0x8）
    // =====================================================================
    task automatic dut_read_slot(input [6:0] slot, output reg [47:0] mac, output reg valid);
        reg [31:0] hi, lo, vd;
        begin
            subbus_wr(12'h0, {25'b0, slot});               // INDEX = slot（写只改 cfg_idx）
            #40;
            subbus_rd(12'h6, hi);
            subbus_rd(12'h7, lo);
            subbus_rd(12'h8, vd);
            mac   = {hi[31:0], lo[15:0]};                 // 48bit
            valid = vd[0];
        end
    endtask

    // =====================================================================
    // 三裁判
    // =====================================================================
    task automatic check_slot_consistency;                 // INV-B 机器裁判
        integer s, h0s, h1s;
        reg [47:0] m; reg v;
        begin
            for (s = 0; s < 128; s = s + 1) begin
                dut_read_slot(s[6:0], m, v);
                if (v) begin
                    h0s = tb_h0(m);
                    h1s = 64 + tb_h1(m);
                    if (s != h0s && s != h1s) begin
                        $display("  [FAIL] INV-B violated: slot=%0d mac=%h (its slots %0d/%0d)",
                                 s, m, h0s, h1s);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    task automatic check_dut_vs_mirror;                    // DUT ↔ tb 镜像
        integer s;
        reg [47:0] m; reg v;
        begin
            for (s = 0; s < 128; s = s + 1) begin
                dut_read_slot(s[6:0], m, v);
                if (v !== tb_slot_valid[s] || (tb_slot_valid[s] && m !== tb_slot_mac[s])) begin
                    $display("  [FAIL] DUT/mirror mismatch at slot %0d (dut v=%b mac=%h, mirror v=%b mac=%h)",
                             s, v, m, tb_slot_valid[s], tb_slot_mac[s]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task automatic check_model_vs_mirror;                  // 金模型 ↔ tb 镜像
        integer i, s;
        reg found;
        begin
            if (model_cnt > 128) begin
                $display("  [FAIL] model_cnt %0d > 128", model_cnt); errors = errors + 1;
            end
            for (i = 0; i < model_cnt; i = i + 1) begin
                found = 0;
                for (s = 0; s < 128 && !found; s = s + 1)
                    if (tb_slot_valid[s] && tb_slot_mac[s] == model_mac[i][47:0]) found = 1;
                if (!found) begin
                    $display("  [FAIL] model entry %h lost in mirror", model_mac[i]);
                    errors = errors + 1;
                end
            end
            // 反向：镜像每条都应在模型里
            for (s = 0; s < 128; s = s + 1) begin
                if (tb_slot_valid[s] && !model_lookup(tb_slot_mac[s])) begin
                    $display("  [FAIL] mirror entry %h not in model", tb_slot_mac[s]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task automatic full_checks(input integer tag);
        begin
            $display("  -- full checks after case%0d --", tag);
            check_slot_consistency;
            check_dut_vs_mirror;
            check_model_vs_mirror;
        end
    endtask

    // =====================================================================
    // 冲突构造搜索（5.5）——(h0,h1) 直方图 + 配方取料
    // =====================================================================
    integer         pair_cnt_a [0:63][0:63];
    longint unsigned pair_mac0 [0:63][0:63];
    longint unsigned pair_mac1 [0:63][0:63];

    function automatic longint unsigned find_pair(input integer hh0, input integer hh1,
                                                  input integer which);
        begin
            if (pair_cnt_a[hh0][hh1] > which)
                find_pair = which ? pair_mac1[hh0][hh1] : pair_mac0[hh0][hh1];
            else find_pair = 64'b0;
        end
    endfunction
    function automatic integer find_h1_populated(input integer hh0,
                                                 input integer skip1, input integer skip2);
        integer j;
        begin
            find_h1_populated = -1;
            for (j = 0; j < 64 && find_h1_populated < 0; j = j + 1)
                if (pair_cnt_a[hh0][j] >= 2 && j != skip1 && j != skip2)
                    find_h1_populated = j;
        end
    endfunction
    function automatic integer find_h0_populated(input integer hh1,
                                                 input integer skip1, input integer skip2);
        integer j;
        begin
            find_h0_populated = -1;
            for (j = 0; j < 64 && find_h0_populated < 0; j = j + 1)
                if (pair_cnt_a[j][hh1] >= 2 && j != skip1 && j != skip2)
                    find_h0_populated = j;
        end
    endfunction

    task automatic search_collision_macros;
        integer k, h0v, h1v;
        longint unsigned m;
        begin
            for (k = 0; k < 64; k = k + 1)
                for (h1v = 0; h1v < 64; h1v = h1v + 1) begin
                    pair_cnt_a[k][h1v] = 0;
                    pair_mac0[k][h1v] = 64'b0; pair_mac1[k][h1v] = 64'b0;
                end
            for (k = 1; k <= SCAN_N; k = k + 1) begin
                m = SCAN_BASE + k;
                h0v = tb_h0(m); h1v = tb_h1(m);
                if (pair_cnt_a[h0v][h1v] == 0) pair_mac0[h0v][h1v] = m;
                else if (pair_cnt_a[h0v][h1v] == 1) pair_mac1[h0v][h1v] = m;
                pair_cnt_a[h0v][h1v] = pair_cnt_a[h0v][h1v] + 1;
            end
            $display("[TB] collision scan done (%0d samples / 4096 classes)", SCAN_N);
        end
    endtask

    // =====================================================================
    // 通用：清 HW + 镜像 + 模型
    // =====================================================================
    task automatic fresh_table;
        begin
            tb_hw_clear_and_wait;
            mirror_reset;
        end
    endtask

    task automatic find_slot_of_mac(input [63:0] mac, output reg [6:0] slot, output reg found);
        integer s;
        begin
            found = 0; slot = 7'h7F;
            for (s = 0; s < 128 && !found; s = s + 1)
                if (tb_slot_valid[s] && tb_slot_mac[s] == mac[47:0]) begin slot = s[6:0]; found = 1; end
        end
    endtask

    // =====================================================================
    // 主体
    // =====================================================================
    integer A, B, C, D, E, F, H;
    longint unsigned p_mac, q_mac, x_mac;
    longint unsigned g_mac, t_mac, w_mac, v_mac, s_mac, x6_mac;
    reg [6:0] sl; reg fnd;
    reg hit; integer cyc;
    reg [31:0] rd;
    integer i, cnt_ok;

    initial begin
        errors = 0;
        do_reset();
        // CLEAR 双 bank（防未初始化 X 传播）
        tb_hw_clear_and_wait;
        mirror_reset;
        search_collision_macros;

        // 配方坐标（A/D/F 互异保证六类互异）
        A = 0;
        B = find_h1_populated(A, -1, -1);
        C = find_h1_populated(A, B, -1);
        D = find_h0_populated(C, A, -1);
        E = find_h1_populated(D, C, B);
        F = find_h0_populated(B, A, D);
        H = find_h1_populated(F, B, -1);
        $display("[TB] recipe coords A=%0d B=%0d C=%0d D=%0d E=%0d F=%0d H=%0d", A,B,C,D,E,F,H);
        p_mac = find_pair(A, C, 0);  q_mac = find_pair(A, B, 0);  x_mac = find_pair(A, B, 1);
        g_mac = find_pair(F, H, 0);  t_mac = find_pair(F, B, 0);  w_mac = find_pair(D, E, 0);
        v_mac = find_pair(D, C, 0);  s_mac = find_pair(A, C, 0);  x6_mac = find_pair(A, B, 1);

        //--------------------------------------------------------------
        $display("=== T1: h0/h1/1跳eviction 三条落位路径 → 全命中 ===");
        fresh_table;
        tb_cuckoo_add(p_mac);            // 直落 bank0 h0(A)
        tb_cuckoo_add(q_mac);            // s0 被占 → 直落 bank1 h1(B)
        tb_cuckoo_add(x_mac);            // 双槽皆占 → 1 跳 eviction
        $display("  p@%0d q@%0d x@%0d (x hops=%0d)", tb_add_ret,
                 (tb_slot_valid[64+tb_h1(q_mac)] ? (64+tb_h1(q_mac)) : tb_h0(q_mac)),
                 (tb_slot_valid[64+tb_h1(x_mac)] ? (64+tb_h1(x_mac)) : tb_h0(x_mac)),
                 tb_add_hops);
        check_hit(p_mac, 1'b1, 1);
        check_hit(q_mac, 1'b1, 1);
        check_hit(x_mac, 1'b1, 1);
        full_checks(1);

        //--------------------------------------------------------------
        $display("=== T2: 未添加 MAC → miss ===");
        check_hit(SCAN_BASE + 48'h12345, 1'b0, 2);

        //--------------------------------------------------------------
        $display("=== T3: DEL 一条 → 该条 miss、其余仍 hit ===");
        find_slot_of_mac(p_mac, sl, fnd);
        $display("  deleting p at slot %0d", sl);
        tb_cuckoo_del(sl);
        check_hit(p_mac, 1'b0, 3);
        check_hit(q_mac, 1'b1, 3);
        check_hit(x_mac, 1'b1, 3);
        full_checks(3);

        //--------------------------------------------------------------
        $display("=== T4: CLEAR → miss + USED_CNT=0 ===");
        fresh_table;
        check_hit(q_mac, 1'b0, 4);
        subbus_rd(12'hB, rd);
        if (rd !== 0) begin $display("  [FAIL] T4 USED_CNT=%0d expect 0", rd); errors = errors + 1; end
        else $display("  [PASS] T4 USED_CNT=0");

        //--------------------------------------------------------------
        $display("=== T5: 灌到 CAP=96 → 全命中 + 第97条拒 ===");
        fresh_table;
        cnt_ok = 0;
        for (i = 0; i < 6000 && cnt_ok < 96; i = i + 1) begin
            tb_cuckoo_add(SCAN_BASE + 20000 + i);
            if (!tb_cap_reject && !tb_add_fail) cnt_ok = cnt_ok + 1;
        end
        $display("  placed %0d/96 entries", cnt_ok);
        subbus_rd(12'hB, rd);
        if (rd !== 96) begin $display("  [FAIL] T5 USED_CNT=%0d expect 96", rd); errors = errors + 1; end
        else $display("  [PASS] T5 USED_CNT=96");
        // 第 97 条
        tb_cuckoo_add(SCAN_BASE + 30000);
        if (!tb_cap_reject) begin $display("  [FAIL] T5 97th not cap_rejected"); errors = errors + 1; end
        else $display("  [PASS] T5 97th rejected (cap)");
        // 抽查命中：从镜像取两条已落位的（fill 中个别候选可能被跳过）
        begin : t5_check
            integer sv, got = 0;
            reg [63:0] chk1, chk2;
            for (sv = 0; sv < 128 && got == 0; sv = sv + 1)
                if (tb_slot_valid[sv]) begin chk1 = tb_slot_mac[sv]; got = 1; end
            got = 0;
            for (sv = 0; sv < 128 && got == 0; sv = sv + 1)
                if (tb_slot_valid[sv] && tb_slot_mac[sv] != chk1[47:0]) begin chk2 = tb_slot_mac[sv]; got = 1; end
            check_hit(chk1, 1'b1, 5);
            check_hit(chk2, 1'b1, 5);
        end
        full_checks(5);

        //--------------------------------------------------------------
        $display("=== T6: en=0 + default_pass 两态 ===");
        whitelist_en = 1'b0; default_pass = 1'b1;
        check_hit(SCAN_BASE + 20000 + 1, 1'b1, 6);
        default_pass = 1'b0;
        check_hit(SCAN_BASE + 20000 + 1, 1'b0, 6);
        whitelist_en = 1'b1; default_pass = 1'b0;

        //--------------------------------------------------------------
        $display("=== T7: 周期数 2~4（物理 2 拍）===");
        fresh_table;
        tb_cuckoo_add(p_mac);
        do_lookup(p_mac, hit, cyc);
        if (cyc < 1 || cyc > 4) begin $display("  [FAIL] T7 cyc=%0d expect 2~4", cyc); errors = errors + 1; end
        else $display("  [PASS] T7 cyc=%0d (2拍域)", cyc);

        //--------------------------------------------------------------
        $display("=== T8: busy 期间持续 req → 两笔都完成且正确 ===");
        fresh_table;
        tb_cuckoo_add(q_mac);
        tb_cuckoo_add(x_mac);
        begin
            reg h1x, h2x;
            lookup_mac = q_mac[47:0]; lookup_req = 1'b1;
            @(posedge clk);                                // 启动 q 查找
            while (lookup_done !== 1'b1) @(posedge clk);   // q done
            h1x = lookup_match;
            lookup_mac = x_mac[47:0];                      // busy 窗口内已重新置 req+换 mac
            @(posedge clk);
            while (lookup_done !== 1'b1) @(posedge clk);
            h2x = lookup_match;
            lookup_req = 1'b0;
            if (h1x !== 1'b1 || h2x !== 1'b1) begin
                $display("  [FAIL] T8 q=%b x=%b expect 1/1", h1x, h2x); errors = errors + 1;
            end else $display("  [PASS] T8 sustained-req two lookups q=1 x=1");
        end

        //--------------------------------------------------------------
        $display("=== T9: 双槽皆占 eviction (p/q/x) x hops==2 ===");
        fresh_table;
        tb_cuckoo_add(p_mac);
        tb_cuckoo_add(q_mac);
        tb_cuckoo_add(x_mac);
        $display("  x tb_add_hops=%0d (expect 2)", tb_add_hops);
        if (tb_add_hops !== 2) begin $display("  [FAIL] T9 hops=%0d expect 2", tb_add_hops); errors = errors + 1; end
        else $display("  [PASS] T9 hops=2");
        check_hit(p_mac, 1'b1, 9);
        check_hit(q_mac, 1'b1, 9);
        check_hit(x_mac, 1'b1, 9);
        full_checks(9);

        //--------------------------------------------------------------
        $display("=== T10: eviction 链 (g/t/w/v/s/x) x hops==4 ===");
        fresh_table;
        tb_cuckoo_add(g_mac);
        tb_cuckoo_add(t_mac);
        tb_cuckoo_add(w_mac);
        tb_cuckoo_add(v_mac);
        tb_cuckoo_add(s_mac);
        tb_cuckoo_add(x6_mac);
        $display("  x6 tb_add_hops=%0d (expect 4)", tb_add_hops);
        if (tb_add_hops !== 4) begin $display("  [FAIL] T10 hops=%0d expect 4", tb_add_hops); errors = errors + 1; end
        else $display("  [PASS] T10 hops=4");
        check_hit(g_mac, 1'b1, 10);
        check_hit(t_mac, 1'b1, 10);
        check_hit(w_mac, 1'b1, 10);
        check_hit(v_mac, 1'b1, 10);
        check_hit(s_mac, 1'b1, 10);
        check_hit(x6_mac, 1'b1, 10);
        full_checks(10);

        //--------------------------------------------------------------
        $display("=== T12: 空表 lookup ===");
        fresh_table;
        do_lookup(p_mac, hit, cyc);
        if (hit !== 1'b0 || cyc < 1 || cyc > 4) begin $display("  [FAIL] T12 hit=%b cyc=%0d", hit, cyc); errors = errors + 1; end
        else $display("  [PASS] T12 empty miss cyc=%0d", cyc);

        //--------------------------------------------------------------
        $display("=== T13: 槽违例注入 → miss + INV-B 裁判报警 ===");
        fresh_table;
        // 把一个有效 MAC 写进错误槽（h0/h1 之外），仅写 HW，不更新镜像
        begin
            reg [47:0] mm;
            integer bad_slot, proper;
            mm = 48'hDE_AD_BE_EF_00_11;
            proper = tb_h0(mm); bad_slot = (proper + 13) % 64;   // 同 bank 错误行
            if (bad_slot == proper) bad_slot = (proper + 1) % 64;
            tb_hw_write_slot(bad_slot[6:0], mm);                 // 写错槽
            tb_slot_valid[bad_slot] = 0;                         // 镜像不认（保持镜像干净）
            // RTL 只查 h0/h1 → 该 MAC miss
            do_lookup(mm, hit, cyc);
            if (hit !== 1'b0) begin $display("  [FAIL] T13 wrong-slot mac hit=%b expect miss", hit); errors = errors + 1; end
            else $display("  [PASS] T13 wrong-slot entry invisible to lookup (miss)");
            // 演示 INV-B 裁判能抓到该违例（读 DUT 真实槽内容比对，不污染全局计数）
            begin
                reg [47:0] rmac; reg rv;
                integer hh0, hh1;
                dut_read_slot(bad_slot[6:0], rmac, rv);
                hh0 = tb_h0(rmac); hh1 = 64 + tb_h1(rmac);
                if (!rv || bad_slot == hh0 || bad_slot == hh1) begin
                    $display("  [FAIL] T13 checker demo failed (rv=%b)", rv); errors = errors + 1;
                end else
                    $display("  [PASS] T13 INV-B checker WOULD flag wrong-slot entry (slot %0d, real slots %0d/%0d)",
                             bad_slot, hh0, hh1);
            end
        end
        fresh_table;

        //--------------------------------------------------------------
        $display("=== T14: 同一 MAC 加两次 ===");
        fresh_table;
        tb_cuckoo_add(q_mac);
        begin
            reg [6:0] slot1, slot2; reg found1;
            find_slot_of_mac(q_mac, slot1, found1);
            tb_cuckoo_add(q_mac);
            find_slot_of_mac(q_mac, slot2, fnd);
            if (slot2 !== slot1) begin $display("  [FAIL] T14 slot changed %0d->%0d", slot1, slot2); errors = errors + 1; end
            else $display("  [PASS] T14 duplicate add keeps slot %0d", slot2);
            subbus_rd(12'hB, rd);
            if (rd !== 1) begin $display("  [FAIL] T14 USED_CNT=%0d expect 1", rd); errors = errors + 1; end
            else $display("  [PASS] T14 USED_CNT=1");
        end

        //--------------------------------------------------------------
        $display("=== T11: 金模型随机对拍 500 次 ===");
        begin : random_block
            // 预灌 ~50 条 + 500 随机 add/del/lookup
            integer op, k;
            reg [63:0] mac;
            longint unsigned randv;
            reg [47:0] present_mac [0:127];
            integer present_cnt = 0;
            reg used_cand [1:2000];
            integer tries;
            reg [6:0] rslot; reg rfnd;
            reg exp_hit; reg got_hit; integer rcyc;
            integer ops_done = 0;

            fresh_table;
            for (k = 1; k <= 2000; k = k + 1) used_cand[k] = 0;

            // 预灌到 50（顺序取候选，逐条 tb_cuckoo_add）
            cnt_ok = 0;
            for (k = 1; k <= 4000 && cnt_ok < 50; k = k + 1) begin
                mac = SCAN_BASE + 50000 + k;
                tb_cuckoo_add(mac);
                if (!tb_cap_reject && !tb_add_fail) begin
                    present_mac[cnt_ok] = mac[47:0]; cnt_ok = cnt_ok + 1;
                end
            end
            present_cnt = cnt_ok;
            $display("  random: prefilled %0d", present_cnt);
            check_dut_vs_mirror;                 // PROBE: prefill 后 DUT↔镜像 是否已失步

            // 500 随机 op
            while (ops_done < 500) begin
                randv = $urandom;
                op = randv % 10;
                if (op < 4) begin                 // add 40%
                    // 取一个未用过的候选
                    tries = 0;
                    do begin
                        randv = $urandom; k = 1 + (randv % 2000); tries = tries + 1;
                    end while (used_cand[k] && tries < 50);
                    if (!used_cand[k] && present_cnt < 96) begin
                        used_cand[k] = 1;
                        mac = SCAN_BASE + 70000 + k;
                        tb_cuckoo_add(mac);
                        if (!tb_cap_reject && !tb_add_fail) begin
                            present_mac[present_cnt] = mac[47:0]; present_cnt = present_cnt + 1;
                        end else if (present_cnt >= 96) begin
                            ; // table full
                        end
                    end
                end else if (op < 7) begin        // del 30%
                    if (present_cnt > 0) begin
                        randv = $urandom; k = randv % present_cnt;
                        mac = present_mac[k];
                        find_slot_of_mac(mac, rslot, rfnd);
                        if (rfnd) tb_cuckoo_del(rslot);
                        // 从 present 列表移除（swap）
                        present_mac[k] = present_mac[present_cnt-1]; present_cnt = present_cnt - 1;
                    end
                end else begin                    // lookup 30%：一半命中一半 miss
                    randv = $urandom;
                    if (randv & 1) begin
                        if (present_cnt > 0) begin
                            k = (randv >> 1) % present_cnt;
                            mac = present_mac[k]; exp_hit = 1;
                        end else begin mac = SCAN_BASE + 90000 + ops_done; exp_hit = 0; end
                    end else begin
                        // 随机未用候选 → miss
                        randv = $urandom; k = 1 + (randv % 2000);
                        mac = SCAN_BASE + 80000 + k; exp_hit = 0;
                    end
                    do_lookup(mac, got_hit, rcyc);
                    if (got_hit !== exp_hit || rcyc < 1 || rcyc > 4) begin
                        $display("  [FAIL] T11 rand lookup mac=%h exp=%b got=%b cyc=%0d",
                                 mac, exp_hit, got_hit, rcyc);
                        errors = errors + 1;
                    end
                end
                ops_done = ops_done + 1;
                // PROBE: 每 op 后 HW used(0x0B) 与镜像计数比对
                subbus_rd(12'hB, rd);
                if (rd !== present_cnt)
                    $display("  [PROBE] count desync at op=%0d: hw=%0d mirror=%0d", ops_done, rd, present_cnt);
                // 周期检查（数组级，便宜）：每 op 后模型↔镜像计数一致
                if (ops_done % 8 == 0) begin
                    check_model_vs_mirror;
                    check_slot_consistency;
                end
                if (ops_done % 32 == 0) check_dut_vs_mirror;
            end
            $display("  random: 500 ops done, present_cnt=%0d", present_cnt);
            full_checks(11);
        end

        //--------------------------------------------------------------
        // Tf: low-entropy MAC 族 02:00:00:00:00:00..5f (96) —— 板上 96-fill 实测出现
        //     4 处 INV-B 违例(同类挤压), 用同族在仿真复现判定是否算法 bug
        $display("=== Tf: 02:00:00:00:00:00..5f (96 entries, low-entropy) ===");
        fresh_table;
        begin : tff
            integer fc, fc_ok;
            fc_ok = 0;
            for (fc = 0; fc < 96; fc = fc + 1) begin
                tb_cuckoo_add(48'h020000000000 | fc);
                if (!tb_add_fail && !tb_cap_reject) fc_ok = fc_ok + 1;
            end
            $display("  added ok=%0d/96", fc_ok);
        end
        full_checks(300);

        if (errors == 0) $display("\n========== ALL 14 TESTS PASSED (CUCKOO) ==========");
        else             $display("\n========== FAILURES: %0d ==========", errors);
        #50;
        $finish;
    end
endmodule
