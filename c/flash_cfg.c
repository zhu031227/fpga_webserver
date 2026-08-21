// flash_cfg.c — 本机配置 + MAC 白名单的 SPI Flash 持久化
//
// 写：RISC-V → lcpu_sflash(SubBus 0x4000) → SPI Flash（MX25L12845, SPI Mode 0）
//   命令序列与 tcl/Instruct_flash_initial.tcl 一致：
//     WREN(0x06) → Sector Erase(0x20, 24bit addr) → 每字 Page Program(0x02)
//     → RDSR(0x05) 轮询 WIP(bit0) 清零。
// 读：RISC-V → flash_mem_reader(0x90000000 内存映射)，配置区 0xC20000 → 0x90C20000。
//
// 字节序：lcpu_sflash 写 MSB-first（word MSB 落 flash 低地址），flash_mem_reader 读
// 做 32bit 字节交换（flash 低地址落 word 字节 0）。故保存时每个 word 先 bswap32 再写，
// 读回即得原生 word。
#include "inc/lcpu_general.h"
#include "inc/flash_cfg.h"

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
#define SPI_CMD_RDSR   0x05u

// 忙等 N 拍（volatile 防优化）。50MHz，每拍约 1~2 周期。
static void busy_delay(uint32_t n)
{
    volatile uint32_t i;
    for (i = 0; i < n; i++) { }
}

// 等待上一次 SPI 事务完成（spi_idle=1）。先忙等让 op_start 经 lcpu_clock_cross
// 传到 5MHz 域并让 op_done 拉低，避免把"触发前残留的 idle=1"误判为完成。
static int flash_spi_wait_idle(void)
{
    uint32_t to;
    busy_delay(200);  // ~4us @ 50MHz，覆盖 op_start 传播 + 最短命令
    to = 0;
    while (LCPU_REG32_READ(SFLASH_R_IDLE) != 1) {
        if (++to > 500000) return -1;  // 超时保护
    }
    return 0;
}

// 发送一次 SPI 事务：hi=高4字节 lo=低4字节 len=总bit数
static int flash_spi_tx(uint32_t hi, uint32_t lo, uint32_t len)
{
    LCPU_REG32_WRITE(SFLASH_W_HI, hi);
    LCPU_REG32_WRITE(SFLASH_W_LO, lo);
    LCPU_REG32_WRITE(SFLASH_W_LEN, len);
    LCPU_REG32_WRITE(SFLASH_W_START, 1);
    return flash_spi_wait_idle();
}

// Write Enable (0x06)
static int flash_wren(void)
{
    return flash_spi_tx(0x06000000u, 0x0u, 8u);
}

// 轮询 flash 忙标志：RDSR(0x05) 直到 WIP(bit0) 清零
static int flash_wait_busy(void)
{
    uint32_t st, to;
    to = 0;
    while (1) {
        if (flash_spi_tx(0x05000000u, 0x0u, 0x10u) != 0) return -1;
        st = LCPU_REG32_READ(SFLASH_R_WORD);
        if ((st & 0x1u) == 0) return 0;  // WIP=0，空闲
        if (++to > 200000) return -1;    // 超时保护
    }
}

// Sector Erase (0x20 + 24bit 地址)，4KB
static int flash_sector_erase(uint32_t addr)
{
    if (flash_wren() != 0) return -1;
    if (flash_spi_tx((SPI_CMD_SE << 24) | (addr & 0xFFFFFFu), 0x0u, 32u) != 0) return -1;
    return flash_wait_busy();
}

// Page Program (0x02 + 24bit 地址 + 4 字节数据)，64bit 事务。word 为原生字节序，
// 内部先 bswap32 再写（对齐 flash_mem_reader 的字节交换）。
static int flash_program_word(uint32_t addr, uint32_t word)
{
    uint32_t w;
    w = ((word & 0x000000FFu) << 24) | ((word & 0x0000FF00u) << 8) |
        ((word & 0x00FF0000u) >> 8)  | ((word & 0xFF000000u) >> 24);  // bswap32
    if (flash_wren() != 0) return -1;
    if (flash_spi_tx((SPI_CMD_PP << 24) | (addr & 0xFFFFFFu), w, 64u) != 0) return -1;
    return flash_wait_busy();
}

// 读配置区一个字（经 flash_mem_reader 0x90000000 内存映射）
static uint32_t flash_cfg_read_word(uint32_t word_idx)
{
    return *(volatile uint32_t *)(0x90000000u + FLASH_CFG_BASE + (word_idx << 2));
}

// 32bit 加和校验
static uint32_t cfg_checksum(const uint32_t *w, uint32_t from, uint32_t to)
{
    uint32_t i, s = 0;
    for (i = from; i < to; i++) s += w[i];
    return s;
}

int flash_cfg_save(const flash_cfg_local_t *lc, const flash_cfg_wl_t *wl)
{
    uint32_t w[FLASH_CFG_NUM_WORDS];
    uint32_t i;

    if (!lc || !wl) return -1;

    w[FLASH_CFG_W_MAGIC]   = FLASH_CFG_MAGIC;
    w[FLASH_CFG_W_VERSION] = FLASH_CFG_VERSION;
    w[FLASH_CFG_W_CSUM]    = 0;  // 先占位，下面回填
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

    // 擦 4KB 扇区 0xC20000，再逐字编程
    if (flash_sector_erase(FLASH_CFG_BASE) != 0) return -1;
    for (i = 0; i < FLASH_CFG_NUM_WORDS; i++) {
        if (flash_program_word(FLASH_CFG_BASE + (i << 2), w[i]) != 0) return -1;
    }

    // 写后回读校验：经 flash_mem_reader 读回全部 word 与写入对比。
    // 若擦写静默失败（op_start 漏发/RDSR 误判空闲），这里能抓出来并返回错误。
    for (i = 0; i < FLASH_CFG_NUM_WORDS; i++) {
        if (flash_cfg_read_word(i) != w[i]) return -1;
    }
    return 0;
}

int flash_cfg_load(flash_cfg_local_t *lc, flash_cfg_wl_t *wl)
{
    uint32_t w[FLASH_CFG_NUM_WORDS];
    uint32_t i, csum;

    if (!lc || !wl) return -1;

    for (i = 0; i < FLASH_CFG_NUM_WORDS; i++) {
        w[i] = flash_cfg_read_word(i);
    }

    if (w[FLASH_CFG_W_MAGIC] != FLASH_CFG_MAGIC) return -1;
    if (w[FLASH_CFG_W_VERSION] != FLASH_CFG_VERSION) return -1;
    csum = cfg_checksum(w, FLASH_CFG_W_MAC_H, FLASH_CFG_NUM_WORDS);
    if (w[FLASH_CFG_W_CSUM] != csum) return -1;

    lc->mac_h   = w[FLASH_CFG_W_MAC_H];
    lc->mac_l   = w[FLASH_CFG_W_MAC_L];
    lc->ip      = w[FLASH_CFG_W_IP];
    lc->netmask = w[FLASH_CFG_W_NETMASK];
    lc->gateway = w[FLASH_CFG_W_GATEWAY];

    wl->ctrl       = w[FLASH_CFG_W_WL_CTRL];
    wl->valid_mask = (uint16_t)w[FLASH_CFG_W_WL_MASK];
    for (i = 0; i < FLASH_CFG_WL_MAX; i++) {
        wl->mac_h[i] = w[FLASH_CFG_W_WL_BASE + i * 2];
        wl->mac_l[i] = w[FLASH_CFG_W_WL_BASE + i * 2 + 1];
    }
    return 0;
}
