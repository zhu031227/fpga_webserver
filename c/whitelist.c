// whitelist.c — MAC whitelist management via SubBus 0x5000
//
// MODE-AWARE (runtime): the same firmware serves LOOKUP_MODE 0 (sequential, 16)
// and MODE 2 (cuckoo-hash, 96). Mode is read at runtime from wl_status[7:0]
// (0x301, LOOKUP_MODE constant from RTL).
//   MODE=0: original index-based add/delete on 0..15 (unchanged behavior).
//   MODE=2: cuckoo hashing — add places each MAC in one of its two hash slots
//           {0,h0} / {1,h1}, with bounded eviction (max 8 hops, snapshot rollback);
//           delete is one-shot INDEX|bit31 on the slot. Slot# = {bank,row[5:0]}.
// Hash h0/h1 are bit-exact with rtl/mac_whitelist_cuckoo.v (fold6 on MAC /
// byte-swapped MAC). Keep the two implementations in sync.
//
// Snapshot persistence: the on-flash format is fixed at 16 positional entries
// (flash_cfg_wl_t). We persist a COMPACT list (slot order, up to
// FLASH_CFG_WL_MAX), independent of hash layout; restore re-adds via whitelist_add
// (hash re-places). So ≥96-slot operation persists only the first 16 entries —
// the on-flash format cap (see doc 模式2 §2.2 decision a/b).

#include <string.h>
#include "inc/lcpu_general.h"
#include "inc/whitelist.h"
#include "inc/local_config.h"

// SubBus write helper: write a 32-bit word to a SubBus address
// Must wait for SubBus ack to ensure transaction completes before next write
static inline void subbus_write(uint16_t subbus_base, uint16_t reg_offset, uint32_t data)
{
    LCPU_REG32_WRITE(subbus_base + reg_offset, data);
    // Read back to flush pipeline and wait for SubBus transaction to complete
    volatile uint32_t dummy = LCPU_REG32_READ(subbus_base + WL_REG_MAX_ENTRIES);
    (void)dummy;
}

// SubBus read helper
static inline uint32_t subbus_read(uint16_t subbus_base, uint16_t reg_offset)
{
    return LCPU_REG32_READ(subbus_base + reg_offset);
}

// ---- runtime lookup mode (wl_status[7:0] = LOOKUP_MODE from RTL) ----
static uint8_t wl_mode(void)
{
    return (uint8_t)(lcpu_baseaddr->wl_status & 0xFFu);
}
static int wl_is_mode2(void) { return wl_mode() == 2; }

// ============================================================
// Mode 2 hash helpers (bit-exact with RTL wl_fold/wl_hash0/wl_hash1)
// ============================================================
#define WL_SLOTS      128   // 2 banks x 64
#define WL_CAP        96    // design capacity (75% load)
#define WL_MAX_EVICT  8
#define WL_SLOT(bank, row)  ((uint8_t)(((bank) << 6) | (row)))

// fold6: 48-bit split into 8 x 6-bit chunks, all XORed -> 6 bits
static uint8_t wl_fold_u64(uint64_t x)
{
    return (uint8_t)((x & 0x3FULL) ^ ((x >> 6)  & 0x3FULL) ^ ((x >> 12) & 0x3FULL)
                   ^ ((x >> 18) & 0x3FULL) ^ ((x >> 24) & 0x3FULL) ^ ((x >> 30) & 0x3FULL)
                   ^ ((x >> 36) & 0x3FULL) ^ ((x >> 42) & 0x3FULL));
}
static uint64_t wl_mac_u64(const uint8_t mac[6])
{
    return ((uint64_t)mac[0] << 40) | ((uint64_t)mac[1] << 32) | ((uint64_t)mac[2] << 24)
         | ((uint64_t)mac[3] << 16) | ((uint64_t)mac[4] << 8)  |  (uint64_t)mac[5];
}
static uint64_t wl_bswap48(uint64_t x)   // 6-byte reversal
{
    return ((x & 0x0000000000FFULL) << 40) | ((x & 0x00000000FF00ULL) << 24)
         | ((x & 0x000000FF0000ULL) << 8)  | ((x & 0x0000FF000000ULL) >> 8)
         | ((x & 0x00FF00000000ULL) >> 24) | ((x & 0xFF0000000000ULL) >> 40);
}
static uint8_t wl_h0(const uint8_t mac[6]) { return wl_fold_u64(wl_mac_u64(mac)); }
static uint8_t wl_h1(const uint8_t mac[6]) { return wl_fold_u64(wl_bswap48(wl_mac_u64(mac))); }
static int wl_is_zero_mac(const uint8_t mac[6])
{
    return (mac[0] | mac[1] | mac[2] | mac[3] | mac[4] | mac[5]) == 0;
}

// HW write/delete one entry (INDEX param is a slot#, 7-bit in mode2)
static void wl_hw_write_entry(uint8_t slot, const uint8_t mac[6])
{
    uint32_t mac_h = ((uint32_t)mac[0] << 24) | ((uint32_t)mac[1] << 16)
                   | ((uint32_t)mac[2] << 8)  | mac[3];
    uint32_t mac_l = ((uint32_t)mac[4] << 8)  | mac[5];
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, (uint32_t)slot);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_H, mac_h);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_L, mac_l);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_WR, 1);
}
static void wl_hw_delete_entry(uint8_t slot)
{
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, 0x80000000u | (uint32_t)slot);
}

// CLEAR + wait for the clear sequencer to sweep all slots (128 in mode2).
// Mode2 rollback correctness depends on the sweep finishing before rewrites.
static void wl_hw_clear_all_and_wait(void)
{
    volatile int w;
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_CLEAR, 1);
    for (w = 0; w < 40000; w++) { __asm__ volatile(""); }  // > 128 cfg cycles
}

// ============================================================
// HW BRAM read-back (reads actual BRAM content, not sw cache)
// ============================================================
int whitelist_hw_read_entry(uint8_t index, uint8_t mac_out[6])
{
    uint8_t bound = wl_is_mode2() ? WL_SLOTS : 16;
    if (index >= bound) return -1;

    // Set index, then read shadow BRAM via 0x06/0x07/0x08
    // 2026-09-02: 读回前必须确认 cfg_idx 已锁存。板上快速逐槽扫描时, INDEX 写后
    // cfg_idx 未及在 cfg_clk 锁存, 0x06/7/8 会读到上一个槽 → hwlist/list 误显示
    // "错位条目"(JTAG 直读证明 HW 表正确)。subbus_write 的 flush 读 0x500A 不足,
    // 需读回 0x5000 确认 cfg_idx==index 再读内容。
    {   int _tr;
        for (_tr = 0; _tr < 8; _tr++) {
            subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, (uint32_t)index);
            if ((subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX) & 0x7Fu) == index) break;
        }
    }
    uint32_t mac_h = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_RD_MAC_H);
    uint32_t mac_l = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_RD_MAC_L);
    uint32_t valid = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_RD_VALID);

    if (!(valid & 0x1)) return -1;  // entry not valid

    mac_out[0] = (uint8_t)(mac_h >> 24);
    mac_out[1] = (uint8_t)(mac_h >> 16);
    mac_out[2] = (uint8_t)(mac_h >> 8);
    mac_out[3] = (uint8_t)(mac_h);
    mac_out[4] = (uint8_t)(mac_l >> 8);
    mac_out[5] = (uint8_t)(mac_l);
    return 0;
}

uint16_t whitelist_hw_get_used_count(void)
{
    return (uint16_t)(subbus_read(WL_SUBBUS_ADDR, WL_REG_USED_CNT) & 0xFF);
}

uint16_t whitelist_hw_get_max_entries(void)
{
    return (uint16_t)(subbus_read(WL_SUBBUS_ADDR, WL_REG_MAX_ENTRIES) & 0xFF);
}

uint16_t whitelist_hw_get_slot_count(void)
{
    // 列表/硬件表枚举要扫全部物理槽（mode2 哈希条目可落 0..127，按容量 96 扫会漏
    // 掉高槽条目——2026-09-02 上板实测 hwlist 只出 80/96）。mode0 无差异(16)。
    return wl_is_mode2() ? WL_SLOTS : 16;
}

uint8_t whitelist_hw_get_free_index(void)
{
    return (uint8_t)(subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_FREE_IDX) & 0xFF);
}

// ============================================================
// Software mirror of whitelist entries
//   slot index == HW slot#. Mode0 uses slots 0..15 (seq HW), mode2 uses 0..127.
// ============================================================
#define WL_SW_CACHE_SIZE 16     // mode0 HW depth (legacy add/dup scan bound)
// 守卫 canary（诊断 .bss 越界写来源）。volatile+非零初值防优化/重排。
static volatile uint32_t wl_gpre  = 0x5AA5A55Au;
static uint8_t  sw_wl_valid[WL_SLOTS];
static uint8_t  sw_wl_mac[WL_SLOTS][6];
static uint16_t sw_wl_count;
static volatile uint32_t wl_gpost = 0xA55A5AA5u;

// eviction 回滚快照（文件级 static, 单线程安全）
static uint8_t wl_saved_mac[WL_CAP][6];
static uint8_t wl_saved_slot[WL_CAP];

// 供 /api/wl/dbg 输出守卫与一致性
void whitelist_guard_check(uint32_t *gpre, uint32_t *gpost, uint16_t *pop)
{
    uint16_t p = 0; int i;
    for (i = 0; i < WL_SLOTS; i++) p += (sw_wl_valid[i] ? 1 : 0);
    *gpre = wl_gpre; *gpost = wl_gpost; *pop = p;
}

void whitelist_init(void)
{
    int i;
    flash_cfg_local_t lc;
    flash_cfg_wl_t wl;

    // 引导阶段打点（JTAG 读 debug_rw_2/0x12 定位假死点）：
    // 0x10=进入init 0x11=读Flash开始 0x12=加载成功 0x13=加载失败走默认
    LCPU_REG32_WRITE(0x12u, 0x00000010u);

    for (i = 0; i < WL_SLOTS; i++) {
        sw_wl_valid[i] = 0;
    }
    sw_wl_count = 0;

    // 启动时从 Flash 自动加载白名单 + wl_ctrl（任何失败走默认：禁用、空表）
    LCPU_REG32_WRITE(0x12u, 0x00000011u);
    if (flash_cfg_load(&lc, &wl) == 0) {
        whitelist_apply_snapshot(&wl);
        LCPU_REG32_WRITE(0x12u, 0x00000012u);
    } else {
        lcpu_baseaddr->wl_ctrl = 0x0;
        LCPU_REG32_WRITE(0x12u, 0x00000013u);
    }
}

void whitelist_enable(uint8_t enable)
{
    uint32_t ctrl = lcpu_baseaddr->wl_ctrl;
    if (enable)
        ctrl |= 0x1;
    else
        ctrl &= ~0x1u;
    lcpu_baseaddr->wl_ctrl = ctrl;
}

uint8_t whitelist_is_enabled(void)
{
    return (uint8_t)(lcpu_baseaddr->wl_ctrl & 0x1);
}

void whitelist_set_default_pass(uint8_t pass)
{
    uint32_t ctrl = lcpu_baseaddr->wl_ctrl;
    if (pass)
        ctrl |= 0x2;
    else
        ctrl &= ~0x2u;
    lcpu_baseaddr->wl_ctrl = ctrl;
}

uint8_t whitelist_get_default_pass(void)
{
    return (uint8_t)((lcpu_baseaddr->wl_ctrl >> 1) & 0x1);
}

// ---- 运行时查找模式切换（2026-09-03，RTL 双引擎常驻）----
// 返回当前运行时模式（0=顺序 seq, 2=布谷鸟 cuckoo）。读 wl_status[7:0]。
uint8_t whitelist_get_mode(void)
{
    return wl_mode();
}

// 设置运行时模式：清空两引擎表（cfg 写口广播，CLEAR 同时清 seq+cuckoo）+ 重置
// sw 镜像，然后写 wl_ctrl[2]（1=布谷鸟, 0=顺序）。模式经 CDC 同步到 125MHz 域后
// 生效，期间旧引擎已清空，无脏数据。mode 仅接受 0 或 2。
int whitelist_set_mode(uint8_t mode)
{
    uint32_t ctrl;
    if (mode != 0 && mode != 2) return -1;
    whitelist_clear_all();                 // 清空两引擎 + 重置 sw_wl_valid/count
    ctrl = lcpu_baseaddr->wl_ctrl;
    if (mode == 2) ctrl |= 0x4u;           // wl_ctrl[2]=1 → 布谷鸟
    else           ctrl &= ~0x4u;          // wl_ctrl[2]=0 → 顺序
    lcpu_baseaddr->wl_ctrl = ctrl;
    return 0;
}

// ---- mode0 (sequential): find free slot 0..15 ----
static int wl_add_mode0(uint8_t mac[6])
{
    uint32_t mac_h = ((uint32_t)mac[0] << 24) | ((uint32_t)mac[1] << 16) |
                     ((uint32_t)mac[2] << 8)  | mac[3];
    uint32_t mac_l = ((uint32_t)mac[4] << 8)  | mac[5];
    int i, j;

    for (i = 0; i < WL_SW_CACHE_SIZE; i++) {
        if (sw_wl_valid[i]) {
            int same = 1;
            for (j = 0; j < 6; j++) if (sw_wl_mac[i][j] != mac[j]) { same = 0; break; }
            if (same) return i;              // dup: idempotent
        }
    }
    for (i = 0; i < WL_SW_CACHE_SIZE; i++) {
        if (!sw_wl_valid[i]) {
            for (j = 0; j < 6; j++) sw_wl_mac[i][j] = mac[j];
            sw_wl_valid[i] = 1;
            sw_wl_count++;
            subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, (uint32_t)i);
            subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_H, mac_h);
            subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_L, mac_l);
            subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_WR, 1);
            return i;
        }
    }
    return -1;
}

// ---- mode2 (cuckoo hash): hash placement + bounded eviction ----
// 返回：成功 = 落位槽位号（0~127）。失败码（2026-09-03 起区分，供 web 层报不同
// msg、也供步骤 9.3-3 判据"灌到首次回滚"识别回滚点）：
//   -1 = 8 跳 eviction 回滚（布谷鸟 d=2 负载阈值≈50% 决定的高负载固有冲突，非 bug）
//   -2 = 判满（sw_wl_count >= WL_CAP，真容量满）
//   -3 = 全零 MAC 拒绝
// 每跳都满足 INV-B（cur 永远放进自己的哈希槽）；任意退出路径（成功/判满/回滚）
// 都保证全表 INV-A/B。INV-C：插入含 eviction 时被踢条目在安家前查不到
// （≤8 跳×4 笔写 ≈ 数十 µs），本设计接受该瞬时 miss 窗口（模式2 §1.1/8.5）。
static int wl_add_mode2(uint8_t mac[6])
{
    uint8_t  s0 = WL_SLOT(0, wl_h0(mac));
    uint8_t  s1 = WL_SLOT(1, wl_h1(mac));
    uint8_t  cur[6], victim[6], tgt;
    uint8_t  saved_cnt = 0, i;
    int      bank, hop, placed;

    if (wl_is_zero_mac(mac)) return -3;                  // 0. 全零拒绝
    if (sw_wl_count >= WL_CAP) return -2;                // 2. 判满 (75% load)
    if (sw_wl_valid[s0] && !memcmp(sw_wl_mac[s0], mac, 6)) return s0;   // 1. 查重幂等
    if (sw_wl_valid[s1] && !memcmp(sw_wl_mac[s1], mac, 6)) return s1;

    /* 3. 空位直达（优先 h0），不踢人 */
    if (!sw_wl_valid[s0] || !sw_wl_valid[s1]) {
        tgt = sw_wl_valid[s0] ? s1 : s0;
        wl_hw_write_entry(tgt, mac);
        sw_wl_valid[tgt] = 1; memcpy(sw_wl_mac[tgt], mac, 6);
        sw_wl_count++;
        return tgt;
    }

    /* 4. 双槽皆占 → bounded eviction。交替 bank 防乒乓：被踢者刚从 bank b 的槽
     *    出来，按 INV-B 那正是它 bank-b 的哈希槽——它唯一没试过的是 bank 1-b 侧。 */
    for (i = 0; i < WL_SLOTS; i++)
        if (sw_wl_valid[i]) { wl_saved_slot[saved_cnt] = i; memcpy(wl_saved_mac[saved_cnt], sw_wl_mac[i], 6); saved_cnt++; }

    memcpy(cur, mac, 6); bank = 0; placed = 0;
    tgt = s0;                                  // 新 MAC 恒在首跳写入 bank0 槽 s0
    for (hop = 0; hop < WL_MAX_EVICT && !placed; hop++) {
        uint8_t cur_tgt = (bank == 0) ? WL_SLOT(0, wl_h0(cur)) : WL_SLOT(1, wl_h1(cur));
        if (!sw_wl_valid[cur_tgt]) {           // 流浪者找到空位 → 完成
            wl_hw_write_entry(cur_tgt, cur);
            sw_wl_valid[cur_tgt] = 1; memcpy(sw_wl_mac[cur_tgt], cur, 6);
            sw_wl_count++; placed = 1;
        } else {
            memcpy(victim, sw_wl_mac[cur_tgt], 6);   // ★ 先存受害者再覆盖
            wl_hw_write_entry(cur_tgt, cur);
            memcpy(sw_wl_mac[cur_tgt], cur, 6);
            memcpy(cur, victim, 6);
            bank = 1 - bank;
        }
    }

    /* 5. 8 跳失败 → 快照回滚（CLEAR 后按原槽直接写回，必然无冲突）。返回 -1（回滚） */
    if (!placed) {
        wl_hw_clear_all_and_wait();
        memset(sw_wl_valid, 0, sizeof(sw_wl_valid)); sw_wl_count = 0;
        for (i = 0; i < saved_cnt; i++) {
            wl_hw_write_entry(wl_saved_slot[i], wl_saved_mac[i]);
            sw_wl_valid[wl_saved_slot[i]] = 1; memcpy(sw_wl_mac[wl_saved_slot[i]], wl_saved_mac[i], 6);
            sw_wl_count++;
        }
        return -1;
    }
    return tgt;                                        // 6. 影子已同步、count 已增
}

int whitelist_add(uint8_t mac[6])
{
    if (wl_is_mode2()) return wl_add_mode2(mac);
    return wl_add_mode0(mac);
}

int whitelist_delete(uint8_t index)
{
    if (wl_is_mode2()) {
        if (index >= WL_SLOTS || !sw_wl_valid[index]) return -1;
        wl_hw_delete_entry(index);             // INDEX|bit31 一笔带删（含 flush）
        sw_wl_valid[index] = 0;
        memset(sw_wl_mac[index], 0, 6);
        if (sw_wl_count > 0) sw_wl_count--;
        return 0;
    }
    /* mode0 legacy */
    if (index >= 16) return -1;
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, (uint32_t)index);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_DEL, 1);
    sw_wl_valid[index] = 0;
    if (sw_wl_count > 0) sw_wl_count--;
    return 0;
}

void whitelist_clear_all(void)
{
    int i;
    // 必须等 CLEAR 序列器扫完 128 槽（>128 cfg 拍 ≈2.56µs），否则 boot 快照恢复
    // （whitelist_apply_snapshot：clear 后立刻重灌）头几条会被仍在跑的序列器抹掉。
    // 2026-09-03 修复：原直接 subbus_write(CLEAR,1) 不等待，与回滚路径不一致。
    wl_hw_clear_all_and_wait();
    for (i = 0; i < WL_SLOTS; i++) sw_wl_valid[i] = 0;
    sw_wl_count = 0;
}

int whitelist_get_entry(uint8_t index, uint8_t mac_out[6])
{
    if (wl_is_mode2()) {
        if (index >= WL_SLOTS || !sw_wl_valid[index]) return -1;
    } else {
        if (index >= WL_SW_CACHE_SIZE || !sw_wl_valid[index]) return -1;
    }
    memcpy(mac_out, sw_wl_mac[index], 6);
    return 0;
}

uint16_t whitelist_get_max_entries(void)
{
    return wl_is_mode2() ? WL_CAP : (uint16_t)WL_SW_CACHE_SIZE;
}

uint16_t whitelist_get_used_count(void)
{
    return sw_wl_count;
}

uint8_t whitelist_get_free_index(void)
{
    int i, n = wl_is_mode2() ? WL_SLOTS : WL_SW_CACHE_SIZE;
    for (i = 0; i < n; i++) if (!sw_wl_valid[i]) return (uint8_t)i;
    return 0xFF;
}

// ============================================================
// Hardware diagnostic — delete-focused tests (unchanged; manual only)
// ============================================================

static int wh(char *buf, uint32_t v) {
    int i, p = 0;
    /* 08-31 修复：JSON 数值不支持 0x 前缀，十六进制改以字符串输出 */
    buf[p++] = '"'; buf[p++] = '0'; buf[p++] = 'x';
    for (i = 28; i >= 0; i -= 4)
        buf[p++] = "0123456789abcdef"[(v >> i) & 0xF];
    buf[p++] = '"';
    return p;
}
static int ws(char *buf, const char *s) { int p=0; while(*s)buf[p++]=*s++; return p; }
static void wr(uint32_t a, uint32_t d) { LCPU_REG32_WRITE(a,d); volatile uint32_t _=LCPU_REG32_READ(0x500A); (void)_; }
static uint32_t rr(uint32_t a) { return LCPU_REG32_READ(a); }

int whitelist_hw_diag(char *buf, int buf_size)
{
    int p=0, rem; uint32_t v; uint32_t S=WL_SUBBUS_ADDR;
    int first_sec=1; /* 08-31 修复：顶层节间逗号 */
    p+=ws(buf+p,"{"); rem=buf_size-p-4;

    // T1: Register snapshot
    if(rem>300){ const char *rn[]={"i","H","L","W","D","C","rh","rl","rv","fr","mx","us"};
        if(!first_sec)p+=ws(buf+p,","); first_sec=0;
        p+=ws(buf+p,"\"r\":{");
        for(int i=0;i<12;i++){ if(i)p+=ws(buf+p,","); p+=ws(buf+p,"\""); p+=ws(buf+p,rn[i]);
            p+=ws(buf+p,"\":"); p+=wh(buf+p,rr(S+i)); }
        p+=ws(buf+p,"}"); rem=buf_size-p-4; }

    // T2: DEL@slot2 / T3: DEL@slot5 / T4: cfg_mac==0 / T5: bit31 delete — 保留诊断
    //（mode2 下这些显式槽写会落非哈希位 → INV-B 违例；diag 仅手动调试用）
    if(rem>250){
        if(!first_sec)p+=ws(buf+p,","); first_sec=0;
        wr(S+0,2); wr(S+1,0xAABBCCDD); wr(S+2,0xEEFF); wr(S+3,1);
        wr(S+0,2); uint32_t v2=rr(S+8);
        wr(S+0,2); wr(S+4,1);
        wr(S+0,2); uint32_t d2=rr(S+8);
        p+=ws(buf+p,"\"t2\":{\"av\":"); p+=wh(buf+p,v2);
        p+=ws(buf+p,",\"dv\":"); p+=wh(buf+p,d2);
        p+=ws(buf+p,",\"uc\":"); p+=wh(buf+p,rr(S+0xB));
        p+=ws(buf+p,"}"); rem=buf_size-p-4;
    }
    if(rem>250){
        if(!first_sec)p+=ws(buf+p,","); first_sec=0;
        wr(S+0,5); wr(S+1,0x11112222); wr(S+2,0x3333); wr(S+3,1);
        wr(S+0,5); uint32_t v5=rr(S+8);
        wr(S+0,5); wr(S+4,1);
        wr(S+0,5); uint32_t d5=rr(S+8);
        p+=ws(buf+p,"\"t5\":{\"av\":"); p+=wh(buf+p,v5);
        p+=ws(buf+p,",\"dv\":"); p+=wh(buf+p,d5);
        p+=ws(buf+p,"}"); rem=buf_size-p-4;
    }
    if(rem>300){
        if(!first_sec)p+=ws(buf+p,","); first_sec=0;
        wr(S+0,12); wr(S+1,0xCAFE0000); wr(S+2,0xBABE); wr(S+3,1);
        wr(S+0,12); uint32_t v12=rr(S+8);
        wr(S+1,0); wr(S+2,0);
        wr(S+0,12); wr(S+3,1);
        wr(S+0,12); uint32_t d12=rr(S+8);
        wr(S+0,12); wr(S+4,1);
        p+=ws(buf+p,"\"t12\":{\"av\":"); p+=wh(buf+p,v12);
        p+=ws(buf+p,",\"dv\":"); p+=wh(buf+p,d12);
        p+=ws(buf+p,"}"); rem=buf_size-p-4;
    }
    if(rem>250){
        if(!first_sec)p+=ws(buf+p,","); first_sec=0;
        wr(S+0,13); wr(S+1,0xDEAD0000); wr(S+2,0xBEEF); wr(S+3,1);
        wr(S+0,13); uint32_t v13=rr(S+8);
        wr(S+0, 13u|0x80000000u);
        wr(S+0,13); uint32_t d13=rr(S+8);
        p+=ws(buf+p,"\"t13\":{\"av\":"); p+=wh(buf+p,v13);
        p+=ws(buf+p,",\"dv\":"); p+=wh(buf+p,d13);
        p+=ws(buf+p,"}"); rem=buf_size-p-4;
    }
    if(rem>80){
        if(!first_sec)p+=ws(buf+p,","); first_sec=0;
        p+=ws(buf+p,"\"f\":{\"u\":"); p+=wh(buf+p,rr(S+0xB));
        p+=ws(buf+p,",\"fr\":"); p+=wh(buf+p,rr(S+9));
        p+=ws(buf+p,"}"); }

    buf[p++]= '}'; buf[p]=0; return p;
}

// 从 sw cache + wl_ctrl 填充快照（供 flash_cfg 层保存）。compact：按槽序存前
// FLASH_CFG_WL_MAX 条（布局无关），上限受 flash 格式 16 槽限制（decision b）。
void whitelist_get_snapshot(flash_cfg_wl_t *wl)
{
    int s, idx = 0;
    if (!wl) return;
    wl->ctrl = lcpu_baseaddr->wl_ctrl & 0x3u;
    wl->valid_mask = 0;
    for (s = 0; s < WL_SLOTS && idx < FLASH_CFG_WL_MAX; s++) {
        if (sw_wl_valid[s]) {
            wl->valid_mask |= (uint16_t)(1u << idx);
            wl->mac_h[idx] = ((uint32_t)sw_wl_mac[s][0] << 24) | ((uint32_t)sw_wl_mac[s][1] << 16)
                           | ((uint32_t)sw_wl_mac[s][2] << 8)  | sw_wl_mac[s][3];
            wl->mac_l[idx] = ((uint32_t)sw_wl_mac[s][4] << 8)  | sw_wl_mac[s][5];
            idx++;
        }
    }
    for (; idx < FLASH_CFG_WL_MAX; idx++) { wl->mac_h[idx] = 0; wl->mac_l[idx] = 0; }
}

// 用快照恢复 sw cache + HW + wl_ctrl（逐条走 whitelist_add：mode2 哈希重放位）
void whitelist_apply_snapshot(const flash_cfg_wl_t *wl)
{
    int i;
    if (!wl) return;

    whitelist_clear_all();
    // 只恢复 enable/default_pass(bit[1:0])，保留 wl_ctrl[2](查找模式)——模式是运行时
    // 设置(复位默认布谷鸟 3'b100)，不进 flash 快照，boot 恢复不得清掉它。
    lcpu_baseaddr->wl_ctrl = (lcpu_baseaddr->wl_ctrl & ~0x3u) | (wl->ctrl & 0x3u);

    for (i = 0; i < FLASH_CFG_WL_MAX; i++) {
        if (wl->valid_mask & (uint16_t)(1u << i)) {
            uint8_t mac[6];
            mac[0] = (uint8_t)(wl->mac_h[i] >> 24);
            mac[1] = (uint8_t)(wl->mac_h[i] >> 16);
            mac[2] = (uint8_t)(wl->mac_h[i] >> 8);
            mac[3] = (uint8_t)wl->mac_h[i];
            mac[4] = (uint8_t)(wl->mac_l[i] >> 8);
            mac[5] = (uint8_t)wl->mac_l[i];
            whitelist_add(mac);
        }
    }
}

int whitelist_save_to_flash(void)
{
    flash_cfg_local_t lc;
    flash_cfg_wl_t wl;
    local_config_get_snapshot(&lc);
    whitelist_get_snapshot(&wl);
    return flash_cfg_save(&lc, &wl);
}

int whitelist_load_from_flash(void)
{
    flash_cfg_local_t lc;
    flash_cfg_wl_t wl;
    if (flash_cfg_load(&lc, &wl) != 0) return -1;
    whitelist_apply_snapshot(&wl);
    return 0;
}
