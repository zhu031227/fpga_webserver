// whitelist.c — MAC whitelist management via SubBus 0x1500
#include "inc/lcpu_general.h"
#include "inc/whitelist.h"

// SubBus write helper: write a 32-bit word to a SubBus address
// Must wait for SubBus ack to ensure transaction completes before next write
static inline void subbus_write(uint16 subbus_base, uint16 reg_offset, uint32 data)
{
    LCPU_REG32_WRITE(subbus_base + reg_offset, data);
    // Read back to flush pipeline and wait for SubBus transaction to complete
    volatile uint32 dummy = LCPU_REG32_READ(subbus_base + WL_REG_MAX_ENTRIES);
    (void)dummy;
}

// SubBus read helper
static inline uint32 subbus_read(uint16 subbus_base, uint16 reg_offset)
{
    return LCPU_REG32_READ(subbus_base + reg_offset);
}

// ============================================================
// HW BRAM read-back (reads actual BRAM content, not sw cache)
// ============================================================
int whitelist_hw_read_entry(uint8_t index, uint8_t mac_out[6])
{
    if (index >= 16) return -1;

    // Set index, then read shadow BRAM via 0x06/0x07/0x08
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, (uint32)index);

    uint32 mac_h = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_RD_MAC_H);
    uint32 mac_l = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_RD_MAC_L);
    uint32 valid = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_RD_VALID);

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

uint8_t whitelist_hw_get_free_index(void)
{
    return (uint8_t)(subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_FREE_IDX) & 0xFF);
}

// Software mirror of whitelist entries (workaround for SubBus HW write issue)
#define WL_SW_CACHE_SIZE 16
static uint8_t  sw_wl_valid[WL_SW_CACHE_SIZE];
static uint8_t  sw_wl_mac[WL_SW_CACHE_SIZE][6];
static uint16_t sw_wl_count;

void whitelist_init(void)
{
    int i;
    for (i = 0; i < WL_SW_CACHE_SIZE; i++) {
        sw_wl_valid[i] = 0;
    }
    sw_wl_count = 0;
    lcpu_baseaddr->wl_ctrl = 0x0;  // [0]=enable=0 (off), [1]=default_pass=0 (block all)
}

void whitelist_enable(uint8_t enable)
{
    uint32 ctrl = lcpu_baseaddr->wl_ctrl;
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

int whitelist_add(uint8_t mac[6])
{
    uint32 mac_h = ((uint32)mac[0] << 24) | ((uint32)mac[1] << 16) |
                   ((uint32)mac[2] << 8)  | mac[3];
    uint32 mac_l = ((uint32)mac[4] << 8)  | mac[5];

    // Software cache: find free slot
    int i;
    for (i = 0; i < WL_SW_CACHE_SIZE; i++) {
        if (!sw_wl_valid[i]) {
            int j;
            for (j = 0; j < 6; j++) sw_wl_mac[i][j] = mac[j];
            sw_wl_valid[i] = 1;
            sw_wl_count++;

            // Also try HW write (may silently fail until RTL SubBus write is fixed)
            subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, (uint32)i);
            subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_H, mac_h);
            subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_L, mac_l);
            subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_WR, 1);
            return i;
        }
    }
    return -1;  // table full
}

int whitelist_delete(uint8_t index)
{
    if (index >= 16) return -1;

    // Delete: write INDEX with bit31=1 (delete flag)
    // Single SubBus write to 0x5000, no additional addresses needed
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, ((uint32)index) | 0x80000000u);

    // Update software cache
    sw_wl_valid[index] = 0;
    if (sw_wl_count > 0) sw_wl_count--;
    return 0;
}

void whitelist_clear_all(void)
{
    int i;
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_CLEAR, 1);
    for (i = 0; i < WL_SW_CACHE_SIZE; i++) sw_wl_valid[i] = 0;
    sw_wl_count = 0;
}

int whitelist_get_entry(uint8_t index, uint8_t mac_out[6])
{
    if (index >= WL_SW_CACHE_SIZE || !sw_wl_valid[index]) return -1;
    int j;
    for (j = 0; j < 6; j++) mac_out[j] = sw_wl_mac[index][j];
    return 0;
}

uint16_t whitelist_get_max_entries(void)
{
    return WL_SW_CACHE_SIZE;
}

uint16_t whitelist_get_used_count(void)
{
    return sw_wl_count;
}


uint8_t whitelist_get_free_index(void)
{
    int i;
    for (i = 0; i < WL_SW_CACHE_SIZE; i++) {
        if (!sw_wl_valid[i]) return (uint8_t)i;
    }
    return 0xFF;
}

// ============================================================
// Hardware diagnostic — step-by-step register readback test
// ============================================================

static int write_hex32(char *buf, uint32 v) {
    int i, p = 0;
    buf[p++] = '0'; buf[p++] = 'x';
    for (i = 28; i >= 0; i -= 4) {
        uint8 nib = (v >> i) & 0xF;
        buf[p++] = (nib < 10) ? ('0' + nib) : ('a' + nib - 10);
    }
    return p;
}

int whitelist_hw_diag(char *buf, int buf_size)
{
    int p = 0;
    const char *s;
    uint32 v;

    // Test 1: read MAX_ENTRIES (constant, no BRAM needed)
    v = subbus_read(WL_SUBBUS_ADDR, WL_REG_MAX_ENTRIES);
    s = "\"max_entries\":";
    while (*s && p < buf_size) buf[p++] = *s++;
    p += write_hex32(buf + p, v);
    buf[p++] = ',';

    // Test 2: write INDEX=5, read back INDEX
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, 5);
    v = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX);
    s = "\"idx_wr5_rd\":";
    while (*s && p < buf_size) buf[p++] = *s++;
    p += write_hex32(buf + p, v);
    buf[p++] = ',';

    // Test 3: write MAC_H=0xAABBCCDD, read back
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_H, 0xAABBCCDDu);
    v = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_H);
    s = "\"mach_wr_rd\":";
    while (*s && p < buf_size) buf[p++] = *s++;
    p += write_hex32(buf + p, v);
    buf[p++] = ',';

    // Test 4: write MAC_L=0xEEFF, read back
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_L, 0x0000EEFFu);
    v = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_L);
    s = "\"macl_wr_rd\":";
    while (*s && p < buf_size) buf[p++] = *s++;
    p += write_hex32(buf + p, v);
    buf[p++] = ',';

    // Test 5: WR trigger (write to BRAM[5]), then read shadow BRAM
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_WR, 1);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, 5);
    v = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_RD_VALID);
    s = "\"bram5_valid\":";
    while (*s && p < buf_size) buf[p++] = *s++;
    p += write_hex32(buf + p, v);
    buf[p++] = ',';

    v = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_RD_MAC_H);
    s = "\"bram5_mach\":";
    while (*s && p < buf_size) buf[p++] = *s++;
    p += write_hex32(buf + p, v);
    buf[p++] = ',';

    v = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_RD_MAC_L);
    s = "\"bram5_macl\":";
    while (*s && p < buf_size) buf[p++] = *s++;
    p += write_hex32(buf + p, v);
    buf[p++] = ',';

    // Test 6: read USED_CNT
    v = subbus_read(WL_SUBBUS_ADDR, WL_REG_USED_CNT);
    s = "\"used_cnt\":";
    while (*s && p < buf_size) buf[p++] = *s++;
    p += write_hex32(buf + p, v);

    buf[p] = '\0';
    return p;
}

int whitelist_save_to_flash(void)
{
    // Placeholder: Flash save not yet implemented in HW
    return 0;
}

int whitelist_load_from_flash(void)
{
    // Placeholder: Flash load not yet implemented in HW
    return 0;
}
