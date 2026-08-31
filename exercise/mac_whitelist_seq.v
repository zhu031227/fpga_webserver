//==============================================================================
// mac_whitelist_seq — 模式 0：BRAM 顺序查找（练习实现）
// 接口契约以 sim/tb_mac_whitelist_seq.sv 为准；参考答案在 rtl/ 下，写完再对照。
//
// 规格（模式0-步骤1 固化）：
//   1. 容量 ENTRY_NUM=16，ADDR_WIDTH=$clog2(16)=4
//   2. 条目 49bit = {valid, mac[47:0]}；BRAM 主存 + shadow 双副本，同拍写
//   3. 时序预算：最小帧间隔 84B*8ns=672ns；查找 18 拍*8ns=144ns ≪ 672ns → 线速不丢包
//   4. 关闭行为：en=0 不查表，match 恒 = default_pass（S_DONE 拍锁存实现）
//   5. index 是物理槽位，无顺序含义
//
// 逐拍时序（req 采样沿记 0）：
//   E0  采样 req，IDLE→COMPARE，cmp_index<=0（地址 c1 发 0）
//   E1~E15  cmp_index 递增，地址 c_k 发 k-1；E2 起比较（守卫 cmp_index>0 拦掉 E1 旧数据）
//   E16  cmp_index==15 → S_DONE；c17 期间 q_b=d15 有效
//   E17  DONE 态补比 idx15，锁存 match = en ? (found|hit15) : default_pass，done 单拍
//   E18  done 撤销，回 IDLE
//==============================================================================
`include "define.sv"

module mac_whitelist_seq #(
    parameter ENTRY_NUM = 16,
    parameter ADDR_WIDTH = 4
) (
    // 查找口（125MHz 域）
    input                   clk,
    input                   reset_l,
    input                   lookup_req,
    input  [47:0]           lookup_mac,
    output reg              lookup_match,
    output reg              lookup_done,
    output                  lookup_busy,
    // 配置口（50MHz 域）
    input                   cfg_clk,
    input                   cfg_reset_l,
    input                   cfg_rlwh,       // 1=写 0=读（电平敏感，多拍，幂等）
    input  [11:0]           cfg_addr,       // 偏移 = cfg_addr[3:0]
    input  [31:0]           cfg_wdata,
    output reg [31:0]       cfg_rdata,      // 组合读，零延迟
    // 控制字（125MHz 域，上游 wrapper 负责 CDC）
    input                   whitelist_en,
    input                   default_pass
);

//==============================================================================
// 1) 存储体：BRAM 主存（A 口 cfg_clk 写 / B 口 clk 读）+ shadow 读回副本
//==============================================================================
// A 口写通道（cfg_clk 域时序逻辑驱动，clear_active 期间被序列器独占）
reg                bram_we;
reg  [48:0]        bram_wdata;
reg  [ADDR_WIDTH-1:0] bram_waddr;
// shadow（cfg_clk 域寄存器堆，供 0x6/0x7/0x8 组合读回）
reg                sh_valid [0:ENTRY_NUM-1];
reg  [47:0]        sh_mac   [0:ENTRY_NUM-1];
// B 口读出：bram_q = {valid, mac[47:0]}，滞后地址 1 拍
wire [48:0]        bram_q;
wire [ADDR_WIDTH-1:0] bram_rd_addr;

dual_clock_simple_dual_port_ram #(
    .data_width      (49),
    .addr_width      (ADDR_WIDTH),
    .depth           (ENTRY_NUM),
    .block_ram_size  (32),
    .ram_type        (`LARGER_RAM),
    .vendor          (`DEVICE_VENDOR)
) u_bram (
    .clock_a    (cfg_clk),
    .wren_a     (bram_we),
    .data_a     (bram_wdata),
    .address_a  (bram_waddr),
    .clock_b    (clk),
    .address_b  (bram_rd_addr),
    .q_b        (bram_q)
);

//==============================================================================
// 2) 查找 FSM（clk 域）：S_IDLE → S_COMPARE ×16 → S_DONE，共 18 拍
//==============================================================================
localparam [1:0] S_IDLE    = 2'd0,
                 S_COMPARE = 2'd1,
                 S_DONE    = 2'd2;

reg [1:0]        state;
reg [ADDR_WIDTH-1:0] cmp_index;
reg [47:0]       cmp_mac_r;
reg              match_found;

// X 安全比较：仿真中未初始化槽位 q_b 为 X，=== 把 X 判为不命中（合成版可换 &）
wire entry_hit = (bram_q[48] === 1'b1) && (bram_q[47:0] === cmp_mac_r);

assign bram_rd_addr = (state == S_COMPARE) ? cmp_index : {ADDR_WIDTH{1'b0}};
assign lookup_busy  = (state != S_IDLE);

always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
        state         <= S_IDLE;
        cmp_index     <= {ADDR_WIDTH{1'b0}};
        cmp_mac_r     <= 48'd0;
        match_found   <= 1'b0;
        lookup_done   <= 1'b0;
        lookup_match  <= 1'b0;
    end else begin
        lookup_done <= 1'b0;                    // 默认单拍
        case (state)
            S_IDLE: if (lookup_req) begin       // 接受请求
                state       <= S_COMPARE;
                cmp_index   <= {ADDR_WIDTH{1'b0}};
                cmp_mac_r   <= lookup_mac;
                match_found <= 1'b0;
            end
            S_COMPARE: begin
                if (cmp_index > {ADDR_WIDTH{1'b0}} && entry_hit)
                    match_found <= 1'b1;        // 守卫：E1 拍 q_b 还是旧数据
                if (cmp_index == {ADDR_WIDTH{1'b1}})
                    state <= S_DONE;            // 地址已发完 0~15
                else
                    cmp_index <= cmp_index + 1'b1;
            end
            S_DONE: begin                       // 补比最后一条 idx=15
                if (entry_hit)
                    match_found <= 1'b1;
                lookup_match <= whitelist_en ? (match_found | entry_hit)
                                             : default_pass;
                lookup_done  <= 1'b1;
                state        <= S_IDLE;
            end
            default: state <= S_IDLE;
        endcase
    end
end

//==============================================================================
// 3) 配置通路（cfg_clk 域）：电平敏感写译码 + CLEAR 序列器 + BRAM A 口仲裁
//==============================================================================
wire [3:0] cfg_off = cfg_addr[3:0];

reg  [ADDR_WIDTH-1:0] cfg_idx_r;
reg  [31:0]           cfg_mac_h_r;
reg  [15:0]           cfg_mac_l_r;
reg                   clear_active;
reg  [ADDR_WIDTH-1:0] clear_cnt;

// shadow 写通道
reg                sh_we;
reg                sh_wv;
reg  [47:0]        sh_wm;
reg  [ADDR_WIDTH-1:0] sh_wa;

always @(posedge cfg_clk or negedge cfg_reset_l) begin
    if (!cfg_reset_l) begin
        cfg_idx_r    <= {ADDR_WIDTH{1'b0}};
        cfg_mac_h_r  <= 32'd0;
        cfg_mac_l_r  <= 16'd0;
        clear_active <= 1'b0;
        clear_cnt    <= {ADDR_WIDTH{1'b0}};
        bram_we      <= 1'b0;
        bram_wdata   <= 49'd0;
        bram_waddr   <= {ADDR_WIDTH{1'b0}};
        sh_we        <= 1'b0;
        sh_wv        <= 1'b0;
        sh_wm        <= 48'd0;
        sh_wa        <= {ADDR_WIDTH{1'b0}};
    end else begin
        bram_we <= 1'b0;                        // 默认本拍不写
        sh_we   <= 1'b0;
        if (clear_active) begin
            // CLEAR 序列器：16 拍逐条写 49'b0，期间独占 A 口（普通写让位）
            bram_we    <= 1'b1;
            bram_wdata <= 49'd0;
            bram_waddr <= clear_cnt;
            sh_we      <= 1'b1;
            sh_wa      <= clear_cnt;
            sh_wv      <= 1'b0;
            sh_wm      <= 48'd0;
            if (clear_cnt == {ADDR_WIDTH{1'b1}})
                clear_active <= 1'b0;
            else
                clear_cnt <= clear_cnt + 1'b1;
        end else if (cfg_rlwh) begin
            // 电平敏感写：保持期间每个 cfg_clk 沿都命中，靠幂等保证无害
            case (cfg_off)
                4'h0: begin                     // INDEX（bit31=1 附带删除）
                    cfg_idx_r <= cfg_wdata[ADDR_WIDTH-1:0];
                    if (cfg_wdata[31]) begin
                        bram_we    <= 1'b1;
                        bram_wdata <= 49'd0;
                        bram_waddr <= cfg_wdata[ADDR_WIDTH-1:0];
                        sh_we      <= 1'b1;
                        sh_wa      <= cfg_wdata[ADDR_WIDTH-1:0];
                        sh_wv      <= 1'b0;
                    end
                end
                4'h1: cfg_mac_h_r <= cfg_wdata;                    // MAC_H
                4'h2: cfg_mac_l_r <= cfg_wdata[15:0];              // MAC_L
                4'h3: begin                     // WR：双副本同拍写
                    bram_we    <= 1'b1;
                    bram_wdata <= {1'b1, cfg_mac_h_r, cfg_mac_l_r};
                    bram_waddr <= cfg_idx_r;
                    sh_we      <= 1'b1;
                    sh_wa      <= cfg_idx_r;
                    sh_wv      <= 1'b1;
                    sh_wm      <= {cfg_mac_h_r, cfg_mac_l_r};
                end
                4'h4: begin                     // DEL：双副本同拍清
                    bram_we    <= 1'b1;
                    bram_wdata <= 49'd0;
                    bram_waddr <= cfg_idx_r;
                    sh_we      <= 1'b1;
                    sh_wa      <= cfg_idx_r;
                    sh_wv      <= 1'b0;
                end
                4'h5: begin                     // CLEAR：启动序列器（幂等：
                    clear_active <= 1'b1;       // active 后重触发被挡）
                    clear_cnt    <= {ADDR_WIDTH{1'b0}};
                end
                default: ;                      // 0x6~0xF 写无定义
            endcase
        end
        if (sh_we) begin                        // shadow 统一写口
            sh_valid[sh_wa] <= sh_wv;
            sh_mac[sh_wa]   <= sh_wm;
        end
    end
end

//==============================================================================
// 4) 辅助组合逻辑：free_idx 优先级联 / used_cnt 加法链 / 读 mux
//==============================================================================
wire [7:0]           used_cnt;
wire [ADDR_WIDTH-1:0] free_idx;

genvar gi;
wire [7:0]           cnt_chain [0:ENTRY_NUM];      // 加法器链 popcount
wire [ENTRY_NUM:0]   no_free;                      // no_free[i]: 槽 0..i-1 全占用
wire [ADDR_WIDTH:0]  free_chain [0:ENTRY_NUM];     // 级联优先编码器，全满=0x1F→[3:0]=F

assign cnt_chain[0] = 8'd0;
assign no_free[0]   = 1'b1;
assign free_chain[0] = {(ADDR_WIDTH+1){1'b1}};

generate
    for (gi = 0; gi < ENTRY_NUM; gi = gi + 1) begin: g_aux
        wire [ADDR_WIDTH+1:0] idx_w = gi;
        assign cnt_chain[gi+1]  = cnt_chain[gi] + {7'b0, sh_valid[gi]};
        assign no_free[gi+1]    = no_free[gi] & sh_valid[gi];
        assign free_chain[gi+1] = (no_free[gi] & ~sh_valid[gi]) ? idx_w
                                                                : free_chain[gi];
    end
endgenerate

assign used_cnt = cnt_chain[ENTRY_NUM];
assign free_idx = free_chain[ENTRY_NUM][ADDR_WIDTH-1:0];

// 读 mux：!cfg_rlwh 读方向，缺省 0；shadow 读指 cfg_idx_r
wire [47:0] sh_rd_mac = sh_mac[cfg_idx_r];
wire        sh_rd_v   = sh_valid[cfg_idx_r];

always @(*) begin
    cfg_rdata = 32'b0;
    if (!cfg_rlwh) begin
        case (cfg_off)
            4'h6:    cfg_rdata = sh_rd_mac[47:16];              // RD_MAC_H
            4'h7:    cfg_rdata = {16'b0, sh_rd_mac[15:0]};      // RD_MAC_L
            4'h8:    cfg_rdata = {31'b0, sh_rd_v};              // RD_VALID
            4'h9:    cfg_rdata = {28'b0, free_idx};             // FREE_IDX
            4'hA:    cfg_rdata = ENTRY_NUM;                     // MAX_ENTRIES
            4'hB:    cfg_rdata = {24'b0, used_cnt};             // USED_CNT
            default: cfg_rdata = 32'b0;
        endcase
    end
end

endmodule
