// flash_cfg.c — 本机配置 + MAC 白名单的 SPI Flash 持久化（v2 健壮化版）
//
// 2026-08-30 重构要点（事故：v1 保存中途挂死留半写扇区，引导经内存映射窗读扇区
// 时 CPU 停等假死，JTAG 擦扇区才救活）：
//   * 引导读路径 100% 走 lcpu_sflash 寄存器（可轮询/可超时），不再碰
//     flash_mem_reader 内存映射窗（停等无超时，挂死无法救）
//   * A/B 双扇区（0xC20000/0xC21000）交替保存 + SEQ 序号，引导择优
//   * 每次读均有超时，任何一步超时立即放弃（宁用默认配置，不挂引导）
//   * 字节序自校准：以扇区首字 MAGIC 探测 R_WORD 的 native/bswap 约定
#include "inc/lcpu_general.h"
#include "inc/flash_cfg.h"
#include "inc/local_config.h"

// ---- lcpu_sflash SubBus 0x4000 寄存器 ----
#define SFLASH_W_HI    0x4000u  // spi_high_word_send（命令+地址，MSB-first）
#define SFLASH_W_LO    0x4001u  // spi_low_word_send（数据）
#define SFLASH_W_LEN   0x4002u  // channel_len（总 bit 数）
#define SFLASH_R_WORD  0x4003u  // spi_word_get（读回字）
#define SFLASH_R_IDLE  0x4004u  // spi_idle（1=空闲）
#define SFLASH_W_START 0x4005u  // op_start（写任意值触发）

#define SPI_CMD_WREN   0x06u
#define SPI_CMD_PP     0x02u   // Page Program
#define SPI_CMD_SE     0x20u   // Sector Erase (4KB)
#define SPI_CMD_RD     0x03u   // Read Data
#define SPI_CMD_RDSR   0x05u

// 引导阶段号（写 debug_rw_2，JTAG 直读定位假死点）
#define BOOT_ST_WL_ENTER   0x00000010u
#define BOOT_ST_LOAD_START 0x00000011u
#define BOOT_ST_LOAD_OK    0x00000012u
#define BOOT_ST_LOAD_FAIL  0x00000013u

static inline void subbus_write(uint16 subbus_base, uint16 reg_offset, uint32 data)
{
    LCPU_REG32_WRITE(subbus_base + reg_offset, data);
    volatile uint32 dummy = LCPU_REG32_READ(subbus_base + 0x0Bu); // 读 WL_USED_CNT 冲流水
    (void)dummy;
}

static inline uint32 subbus_read(uint16 subbus_base, uint16 reg_offset)
{
    return LCPU_REG32_READ(subbus_base + reg_offset);
}

// 忙等 N 拍。50MHz，每拍约 1~2 周期。
static void __attribute__((unused)) busy_delay(uint32_t n)
{
    volatile uint32_t i;
    for (i = 0; i < n; i++) { }
}

// 等 sflash 控制器回到空闲。timeout=轮询次数（每次约数百 ns，含总线读）
static int sflash_wait_idle(uint32_t timeout)
{
    uint32_t to = 0;
    while (LCPU_REG32_READ(SFLASH_R_IDLE) != 1) {
        if (++to > timeout) return -1;
    }
    return 0;
}

// 发一次 SPI 事务（写路径/读路径共用）
static int sflash_tx(uint32_t hi, uint32_t lo, uint16 len)
{
    if (sflash_wait_idle(500000) != 0) return -1;
    LCPU_REG32_WRITE(SFLASH_W_HI, hi);
    LCPU_REG32_WRITE(SFLASH_W_LO, lo);
    LCPU_REG32_WRITE(SFLASH_W_LEN, (uint32)len);
    LCPU_REG32_WRITE(SFLASH_W_START, 1);
    return sflash_wait_idle(500000);
}

static int flash_wren(void)
{
    return sflash_tx(0x06000000u, 0x0u, 8u);
}

static int flash_wait_busy(void)
{
    uint32_t st, to;
    to = 0;
    while (1) {
        if (sflash_tx(0x05000000u, 0x0u, 0x10u) != 0) return -1;
        st = LCPU_REG32_READ(SFLASH_R_WORD);
        if ((st & 0x1u) == 0) return 0;
        if (++to > 200000) return -1;
    }
}

static int flash_sector_erase(uint32_t addr)
{
    if (flash_wren() != 0) return -1;
    if (sflash_tx((SPI_CMD_SE << 24) | (addr & 0xFFFFFFu), 0x0u, 32u) != 0) return -1;
    return flash_wait_busy();
}

static int flash_program_word(uint32_t addr, uint32_t word)
{
    uint32_t w;
    w = ((word & 0x000000FFu) << 24) | ((word & 0x0000FF00u) << 8) |
        ((word & 0x00FF0000u) >> 8)  | ((word & 0xFF000000u) >> 24);  // bswap32
    if (flash_wren() != 0) return -1;
    if (sflash_tx((SPI_CMD_PP << 24) | (addr & 0xFFFFFFu), w, 64u) != 0) return -1;
    return flash_wait_busy();
}

// 经 sflash 控制器读一个字（带超时，绝不挂死）。*raw 为 R_WORD 原样值，
// 字节序由调用方以 MAGIC 自校准。
static int sflash_read_word(uint32_t flash_addr, uint32_t *raw)
{
    if (sflash_tx((SPI_CMD_RD << 24) | (flash_addr & 0xFFFFFFu), 0x0u, 64u) != 0) return -1;
    *raw = LCPU_REG32_READ(SFLASH_R_WORD);
    return 0;
}

static uint32_t bswap32(uint32_t v)
{
    return ((v & 0x000000FFu) << 24) | ((v & 0x0000FF00u) << 8) |
           ((v & 0x00FF0000u) >> 8)  | ((v & 0xFF000000u) >> 24);
}

static uint32_t cfg_checksum(const uint32_t *w, uint32_t from, uint32_t to)
{
    uint32_t i, s = 0;
    for (i = from; i < to; i++) s += w[i];
    return s;
}

// 读一个扇区的全部记录字并校验。成功（magic+version+csum 全过）返回 0 并
// 填 w[]（已按自校准的字节序转为原生字）；任何超时/校验失败返回 -1。
// swap_out 返回该扇区的字节序约定：0=native 1=需要 bswap（供 save 回读校验复用）。
static int load_sector_words(uint32_t base, uint32_t w[FLASH_CFG_NUM_WORDS], int *swap_out)
{
    uint32_t raw0;
    int i, swap;

    // 首字探测字节序：MAGIC 非回文，两种序必有且仅有一种命中
    if (sflash_read_word(base, &raw0) != 0) return -1;
    if (raw0 == FLASH_CFG_MAGIC)      swap = 0;
    else if (bswap32(raw0) == FLASH_CFG_MAGIC) swap = 1;
    else return -1;                          // 扇区空/半写/magic 不符

    for (i = 1; i < FLASH_CFG_NUM_WORDS; i++) {
        uint32_t raw;
        if (sflash_read_word(base + (i << 2), &raw) != 0) return -1;
        w[i] = swap ? bswap32(raw) : raw;
    }
    w[0] = FLASH_CFG_MAGIC;
    if (w[FLASH_CFG_W_VERSION] != FLASH_CFG_VERSION) return -1;
    if (cfg_checksum(w, FLASH_CFG_W_MAC_H, FLASH_CFG_NUM_WORDS) != w[FLASH_CFG_W_CSUM]) return -1;
    *swap_out = swap;
    return 0;
}

// 择优：扫描 A/B 两扇区头 4 字（magic/version/seq），返回有效且 SEQ 高者的基址。
// *swap_out 返回该扇区的字节序约定。两份皆无效返回 0。
static uint32_t pick_best_sector(int *swap_out)
{
    const uint32_t bases[2] = { FLASH_CFG_BASE_A, FLASH_CFG_BASE_B };
    uint32_t best_base = 0, best_seq = 0;
    int i;
    for (i = 0; i < 2; i++) {
        uint32_t raw0, raw3;
        int s;
        if (sflash_read_word(bases[i] + 0x00, &raw0) != 0) continue;
        if (sflash_read_word(bases[i] + 0x0c, &raw3) != 0) continue;
        if (raw0 == FLASH_CFG_MAGIC)      s = 0;
        else if (bswap32(raw0) == FLASH_CFG_MAGIC) s = 1;
        else continue;
        {
            uint32_t seq = s ? bswap32(raw3) : raw3;
            if (seq == FLASH_CFG_SEQ_INVALID) continue;
            if (best_base == 0 || seq > best_seq) { best_base = bases[i]; best_seq = seq; if (swap_out) *swap_out = s; }
        }
    }
    return best_base;
}

// 择本次保存的目标扇区：最佳有效扇区的"另一块"；无有效者用 A。
static uint32_t pick_save_target(int *swap_out)
{
    uint32_t best = pick_best_sector(swap_out);
    if (best == FLASH_CFG_BASE_A) return FLASH_CFG_BASE_B;
    if (best == FLASH_CFG_BASE_B) return FLASH_CFG_BASE_A;
    return FLASH_CFG_BASE_A;
}

int flash_cfg_save(const flash_cfg_local_t *lc, const flash_cfg_wl_t *wl)
{
    uint32_t w[FLASH_CFG_NUM_WORDS];
    uint32_t base, i;
    int swap;

    if (!lc || !wl) return -1;

    w[FLASH_CFG_W_MAGIC]   = FLASH_CFG_MAGIC;
    w[FLASH_CFG_W_VERSION] = FLASH_CFG_VERSION;
    w[FLASH_CFG_W_CSUM]    = 0;
    // SEQ = 当前最佳有效 SEQ + 1（按该扇区自身字节序读取，无效则从 1 起）
    {
        int best_swap = 0;
        uint32_t b = pick_best_sector(&best_swap);
        uint32_t seq = 1;
        if (b != 0) {
            uint32_t raw3;
            if (sflash_read_word(b + 0x0c, &raw3) == 0) {
                uint32_t cur = best_swap ? bswap32(raw3) : raw3;
                if (cur != FLASH_CFG_SEQ_INVALID && cur + 1u != FLASH_CFG_SEQ_INVALID) seq = cur + 1u;
            }
        }
        w[FLASH_CFG_W_SEQ] = seq;
    }
    w[FLASH_CFG_W_MAC_H]   = lc->mac_h;
    w[FLASH_CFG_W_MAC_L]   = lc->mac_l;
    w[FLASH_CFG_W_IP]      = lc->ip;
    w[FLASH_CFG_W_NETMASK] = lc->netmask;
    w[FLASH_CFG_W_GATEWAY] = lc->gateway;
    w[FLASH_CFG_W_WL_CTRL] = wl->ctrl;
    w[FLASH_CFG_W_WL_MASK] = (uint32_t)wl->valid_mask;
    for (i = 0; i < FLASH_CFG_WL_MAX; i++) {
        w[FLASH_CFG_W_WL_BASE + i * 2]     = wl->mac_h[i];
        w[FLASH_CFG_W_WL_BASE + i * 2 + 1] = wl->mac_l[i];
    }
    w[FLASH_CFG_W_CSUM] = cfg_checksum(w, FLASH_CFG_W_MAC_H, FLASH_CFG_NUM_WORDS);

    // 只写目标扇区，另一份原样保留 —— 半写毒不死引导
    {
        int target_swap = 0;
        base = pick_save_target(&target_swap);
    }
    if (flash_sector_erase(base) != 0) return -1;
    for (i = 0; i < FLASH_CFG_NUM_WORDS; i++) {
        if (flash_program_word(base + (i << 2), w[i]) != 0) return -1;
    }

    // 回读校验：字节序自校准（首字 MAGIC 探测），随后逐字比对
    {
        uint32_t raw0;
        int s;
        if (sflash_read_word(base, &raw0) != 0) return -1;
        if (raw0 == FLASH_CFG_MAGIC)      s = 0;
        else if (bswap32(raw0) == FLASH_CFG_MAGIC) s = 1;
        else return -1;
        swap = s;
        for (i = 0; i < FLASH_CFG_NUM_WORDS; i++) {
            uint32_t raw;
            if (sflash_read_word(base + (i << 2), &raw) != 0) return -1;
            if ((swap ? bswap32(raw) : raw) != w[i]) return -1;
        }
    }
    return 0;
}

int flash_cfg_load(flash_cfg_local_t *lc, flash_cfg_wl_t *wl)
{
    uint32_t w[FLASH_CFG_NUM_WORDS];
    int swap, rc;
    uint32_t best = pick_best_sector(0);

    if (best == 0) return -1;

    rc = load_sector_words(best, w, &swap);
    if (rc != 0) {
        // 择优扇区完整校验失败：尝试另一块（它可能 SEQ 低但完整）
        uint32_t alt = (best == FLASH_CFG_BASE_A) ? FLASH_CFG_BASE_B : FLASH_CFG_BASE_A;
        rc = load_sector_words(alt, w, &swap);
        if (rc != 0) return -1;
    }
    (void)swap;

    lc->mac_h   = w[FLASH_CFG_W_MAC_H];
    lc->mac_l   = w[FLASH_CFG_W_MAC_L];
    lc->ip      = w[FLASH_CFG_W_IP];
    lc->netmask = w[FLASH_CFG_W_NETMASK];
    lc->gateway = w[FLASH_CFG_W_GATEWAY];

    wl->ctrl       = w[FLASH_CFG_W_WL_CTRL];
    wl->valid_mask = (uint16_t)w[FLASH_CFG_W_WL_MASK];
    {
        uint32_t i;
        for (i = 0; i < FLASH_CFG_WL_MAX; i++) {
            wl->mac_h[i] = w[FLASH_CFG_W_WL_BASE + i * 2];
            wl->mac_l[i] = w[FLASH_CFG_W_WL_BASE + i * 2 + 1];
        }
    }
    return 0;
}
