// whitelist.c — MAC whitelist management via SubBus 0x1500
#include "inc/lcpu_general.h"
#include "inc/whitelist.h"

// SubBus write helper: write a 32-bit word to a SubBus address
static inline void subbus_write(uint16 subbus_base, uint16 reg_offset, uint32 data)
{
    LCPU_REG32_WRITE(subbus_base + reg_offset, data);
}

// SubBus read helper
static inline uint32 subbus_read(uint16 subbus_base, uint16 reg_offset)
{
    return LCPU_REG32_READ(subbus_base + reg_offset);
}

void whitelist_init(void)
{
    // Currently, BRAM is empty at power-up (no Flash auto-load yet)
    // Enable whitelist by default (block-all mode)
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

    // Find free index
    uint8 free_idx = (uint8)(subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_FREE_IDX) & 0xFF);
    if (free_idx == 0xFF) return -1;  // table full

    // Write MAC
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, free_idx);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_H, mac_h);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_L, mac_l);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_WR, 1);  // trigger write

    return (int)free_idx;
}

int whitelist_delete(uint8_t index)
{
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, index);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_DEL, 1);
    return 0;
}

int whitelist_get_entry(uint8_t index, uint8_t mac_out[6])
{
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, index);
    uint32 mac_h = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_RD_MAC_H);
    uint32 mac_l = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_RD_MAC_L);
    uint32 valid = subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_RD_VALID);

    if (!(valid & 0x1)) return -1;  // entry not valid

    mac_out[0] = (uint8_t)((mac_h >> 24) & 0xFF);
    mac_out[1] = (uint8_t)((mac_h >> 16) & 0xFF);
    mac_out[2] = (uint8_t)((mac_h >> 8) & 0xFF);
    mac_out[3] = (uint8_t)(mac_h & 0xFF);
    mac_out[4] = (uint8_t)((mac_l >> 8) & 0xFF);
    mac_out[5] = (uint8_t)(mac_l & 0xFF);
    return 0;
}

void whitelist_clear_all(void)
{
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_CLEAR, 1);
}

uint16_t whitelist_get_max_entries(void)
{
    return (uint16_t)(subbus_read(WL_SUBBUS_ADDR, WL_REG_MAX_ENTRIES) & 0xFFFF);
}

uint16_t whitelist_get_used_count(void)
{
    return (uint16_t)(subbus_read(WL_SUBBUS_ADDR, WL_REG_USED_CNT) & 0xFFFF);
}

uint8_t whitelist_get_free_index(void)
{
    return (uint8_t)(subbus_read(WL_SUBBUS_ADDR, WL_REG_ENTRY_FREE_IDX) & 0xFF);
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
