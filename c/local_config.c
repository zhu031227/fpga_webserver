// local_config.c — Local IP/MAC configuration management
#include "inc/lcpu_general.h"
#include "inc/local_config.h"

// Flash config base address
#define FLASH_CONFIG_BASE   0x00C20000

extern uint32 g_local_ip;
extern uint32 g_local_mac_high;
extern uint32 g_local_mac_low;

static local_config_t g_config;

// Read default config from HW registers
static void local_config_read_regs(void)
{
    g_local_mac_high = lcpu_baseaddr->local_mac_h;
    g_local_mac_low  = lcpu_baseaddr->local_mac_l;
    g_local_ip       = lcpu_baseaddr->local_ip;
}

void local_config_init(void)
{
    // Use local_config_valid flag (HW sets it only after Flash→regs load succeeds)
    if (lcpu_baseaddr->local_config_valid != 0) {
        local_config_read_regs();
    }

    // Populate the config struct
    // MAC byte order: high[31:24]=mac[0], ..., high[7:0]=mac[3], low[15:8]=mac[4], low[7:0]=mac[5]
    // (matches Ethernet wire order used in eth.c and arp.c)
    g_config.mac[0] = (uint8_t)((g_local_mac_high >> 24) & 0xFF);
    g_config.mac[1] = (uint8_t)((g_local_mac_high >> 16) & 0xFF);
    g_config.mac[2] = (uint8_t)((g_local_mac_high >> 8) & 0xFF);
    g_config.mac[3] = (uint8_t)(g_local_mac_high & 0xFF);
    g_config.mac[4] = (uint8_t)((g_local_mac_low >> 8) & 0xFF);
    g_config.mac[5] = (uint8_t)(g_local_mac_low & 0xFF);

    // Use runtime globals (not HW registers — those may be zero/garbage)
    if (lcpu_baseaddr->local_config_valid != 0) {
        g_config.ip      = lcpu_baseaddr->local_ip;
        g_config.netmask = lcpu_baseaddr->local_netmask;
        g_config.gateway = lcpu_baseaddr->local_gateway;
    } else {
        g_config.ip      = g_local_ip;
        g_config.netmask = 0xFFFFFF00;  // 255.255.255.0 (/24)
        g_config.gateway = (g_local_ip & 0xFFFFFF00) | 0x00000001;  // .1 default
    }
}

void local_config_get(local_config_t *c)
{
    if (c) *c = g_config;
}

int local_config_set(local_config_t *c)
{
    if (!c) return -1;
    g_config = *c;

    // Update HW registers (MAC byte order: high=mac[0:3], low=mac[4:5])
    lcpu_baseaddr->local_mac_h = ((uint32_t)c->mac[0] << 24) | ((uint32_t)c->mac[1] << 16) |
                                  ((uint32_t)c->mac[2] << 8)  | c->mac[3];
    lcpu_baseaddr->local_mac_l = ((uint32_t)c->mac[4] << 8)  | c->mac[5];
    lcpu_baseaddr->local_ip      = c->ip;
    lcpu_baseaddr->local_netmask = c->netmask;
    lcpu_baseaddr->local_gateway = c->gateway;

    // Update runtime globals
    g_local_ip      = c->ip;
    g_local_mac_high = lcpu_baseaddr->local_mac_h;
    g_local_mac_low  = lcpu_baseaddr->local_mac_l;

    return 0;
}

int local_config_save_to_flash(void)
{
    // Trigger WC pulse to save config to Flash
    lcpu_baseaddr->local_config_save = 1;
    return 0;
}

int local_config_load_from_flash(void)
{
    // Trigger WC pulse to reload from Flash
    lcpu_baseaddr->local_config_load = 1;
    local_config_read_regs();
    return 0;
}
