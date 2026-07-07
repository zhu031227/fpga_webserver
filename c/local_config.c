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
    // Try load from Flash first (simplified: always use register defaults for now)
    local_config_read_regs();

    // Populate the config struct
    g_config.mac[0] = (uint8_t)((g_local_mac_high >> 8) & 0xFF);
    g_config.mac[1] = (uint8_t)(g_local_mac_high & 0xFF);
    g_config.mac[2] = (uint8_t)((g_local_mac_low >> 24) & 0xFF);
    g_config.mac[3] = (uint8_t)((g_local_mac_low >> 16) & 0xFF);
    g_config.mac[4] = (uint8_t)((g_local_mac_low >> 8) & 0xFF);
    g_config.mac[5] = (uint8_t)(g_local_mac_low & 0xFF);
    g_config.ip      = lcpu_baseaddr->local_ip;
    g_config.netmask = lcpu_baseaddr->local_netmask;
    g_config.gateway = lcpu_baseaddr->local_gateway;
}

void local_config_get(local_config_t *c)
{
    if (c) *c = g_config;
}

int local_config_set(local_config_t *c)
{
    if (!c) return -1;
    g_config = *c;

    // Update HW registers
    lcpu_baseaddr->local_mac_h = ((uint32_t)c->mac[0] << 8) | c->mac[1];
    lcpu_baseaddr->local_mac_l =
        ((uint32_t)c->mac[2] << 24) | ((uint32_t)c->mac[3] << 16) |
        ((uint32_t)c->mac[4] << 8)  | c->mac[5];
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
