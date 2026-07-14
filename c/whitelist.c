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

void whitelist_set_default_pass(uint8_t pass)
{
    uint32 ctrl = lcpu_baseaddr->wl_ctrl;
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

    // Two-step delete: (1) select entry, (2) trigger DEL
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, (uint32)index);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_DEL, 1);

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
// Hardware diagnostic — delete-focused tests
// ============================================================

static int wh(char *buf, uint32 v) {
    int i, p = 0;
    buf[p++] = '0'; buf[p++] = 'x';
    for (i = 28; i >= 0; i -= 4)
        buf[p++] = "0123456789abcdef"[(v >> i) & 0xF];
    return p;
}
static int ws(char *buf, const char *s) { int p=0; while(*s)buf[p++]=*s++; return p; }
static int wd(char *buf, int v) {
    int p=0; if(v<0){buf[p++]='-';v=-v;}
    if(v>=100){buf[p++]='0'+v/100;v%=100;}
    if(v>=10||p>(buf[0]=='-'?1:0)){buf[p++]='0'+v/10;v%=10;}
    buf[p++]='0'+v; return p;
}
static void wr(uint32 a, uint32 d) { LCPU_REG32_WRITE(a,d); volatile uint32 _=LCPU_REG32_READ(0x500A); (void)_; }
static uint32 rr(uint32 a) { return LCPU_REG32_READ(a); }

int whitelist_hw_diag(char *buf, int buf_size)
{
    int p=0, rem; uint32 v; uint32 S=WL_SUBBUS_ADDR;
    p+=ws(buf+p,"{"); rem=buf_size-p-4;

    // T1: Register snapshot (compact: reg name=hex)
    if(rem>300){ const char *rn[]={"i","H","L","W","D","C","rh","rl","rv","fr","mx","us"};
        p+=ws(buf+p,"\"r\":{");
        for(int i=0;i<12;i++){ if(i)p+=ws(buf+p,","); p+=ws(buf+p,"\""); p+=ws(buf+p,rn[i]);
            p+=ws(buf+p,"\":"); p+=wh(buf+p,rr(S+i)); }
        p+=ws(buf+p,"}"); rem=buf_size-p-4; }

    // T2: Test DEL at offset 4 (entry slot 2)
    if(rem>250){
        // Add entry 2
        wr(S+0,2); wr(S+1,0xAABBCCDD); wr(S+2,0xEEFF); wr(S+3,1);
        wr(S+0,2); uint32 v2=rr(S+8);
        // Delete: INDEX=2, DEL=1
        wr(S+0,2); wr(S+4,1);
        wr(S+0,2); uint32 d2=rr(S+8);
        p+=ws(buf+p,"\"t2\":{\"av\":"); p+=wh(buf+p,v2);
        p+=ws(buf+p,",\"dv\":"); p+=wh(buf+p,d2);
        p+=ws(buf+p,",\"uc\":"); p+=wh(buf+p,rr(S+0xB));
        p+=ws(buf+p,"}"); rem=buf_size-p-4;
    }

    // T3: Test DEL with entry 5
    if(rem>250){
        wr(S+0,5); wr(S+1,0x11112222); wr(S+2,0x3333); wr(S+3,1);
        wr(S+0,5); uint32 v5=rr(S+8);
        wr(S+0,5); wr(S+4,1);
        wr(S+0,5); uint32 d5=rr(S+8);
        p+=ws(buf+p,"\"t5\":{\"av\":"); p+=wh(buf+p,v5);
        p+=ws(buf+p,",\"dv\":"); p+=wh(buf+p,d5);
        p+=ws(buf+p,"}"); rem=buf_size-p-4;
    }

    // T4: Test cfg_mac==0 delete via WR (entry 12)
    if(rem>300){
        // Add entry 12 with non-zero MAC
        wr(S+0,12); wr(S+1,0xCAFE0000); wr(S+2,0xBABE); wr(S+3,1);
        wr(S+0,12); uint32 v12=rr(S+8);
        // Zero out MAC registers, then WR — cfg_mac==0 should trigger delete
        wr(S+1,0); wr(S+2,0);
        wr(S+0,12); wr(S+3,1);  // WR with cfg_mac==0
        wr(S+0,12); uint32 d12=rr(S+8);
        p+=ws(buf+p,"\"t12\":{\"av\":"); p+=wh(buf+p,v12);
        p+=ws(buf+p,",\"dv\":"); p+=wh(buf+p,d12);
        p+=ws(buf+p,"}"); rem=buf_size-p-4;
    }

    // T5: Test bit31 delete (entry 13) — for future RTL
    if(rem>250){
        wr(S+0,13); wr(S+1,0xDEAD0000); wr(S+2,0xBEEF); wr(S+3,1);
        wr(S+0,13); uint32 v13=rr(S+8);
        wr(S+0, 13u|0x80000000u);
        wr(S+0,13); uint32 d13=rr(S+8);
        p+=ws(buf+p,"\"t13\":{\"av\":"); p+=wh(buf+p,v13);
        p+=ws(buf+p,",\"dv\":"); p+=wh(buf+p,d13);
        p+=ws(buf+p,"}"); rem=buf_size-p-4;
    }

    // T6: Final state
    if(rem>80){
        p+=ws(buf+p,"\"f\":{\"u\":"); p+=wh(buf+p,rr(S+0xB));
        p+=ws(buf+p,",\"fr\":"); p+=wh(buf+p,rr(S+9));
        p+=ws(buf+p,"}"); }

    buf[p++]= '}'; buf[p]=0; return p;
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
