#include "inc/lcpu_general.h"
#include "inc/comlib.h"
#include "inc/ip.h"

uint32 src_ip;
uint16 ip_total_len;

uint16 ip_proc() {
    uint32 fifo_data = 0;
    uint32 ip_protocol_type = 0;
    src_ip = 0;

    // Validate IP version and IHL
    LCPU_RD_SET_ADDR(OFF_IP_VER_IHL);
    uint8 ver_ihl = LCPU_RD_DATA8();
    if ((ver_ihl & 0xF0) != 0x40) {   // Version must be 4
        return NO_PROC;
    }
    if ((ver_ihl & 0x0F) < 5) {       // IHL must be >= 5 (20 bytes)
        return NO_PROC;
    }

    // Destination IP must match local IP
    uint32 i = 0;
    for (i = 0; i < 4; i++) {
        LCPU_RD_SET_ADDR(OFF_IP_DST_IP + i);
        fifo_data = LCPU_RD_DATA8();
        if (fifo_data != ((Local_IP_ADDR >> (24 - i * 8)) & 0xFF)) {
            return NO_PROC;
        }
    }

    // Read source IP
    for (i = 0; i < 4; i++) {
        LCPU_RD_SET_ADDR(OFF_IP_SRC_IP + i);
        fifo_data = LCPU_RD_DATA8();
        src_ip |= (uint32)(fifo_data << (24 - i * 8));
    }
#if DEBUG_En_ip
    printf("src_ip is: 0x%x\n", src_ip);
#endif

    // Read IP protocol field
    LCPU_RD_SET_ADDR(OFF_IP_PROTO);
    ip_protocol_type = LCPU_RD_DATA8();
#if DEBUG_En_ip
    printf("ip_protocol_type is: 0x%x\n", ip_protocol_type);
#endif

    // Read IP total length for upper-layer handlers
    LCPU_RD_SET_ADDR(OFF_IP_TOTAL_LEN);
    fifo_data = LCPU_RD_DATA8();
    ip_total_len = fifo_data * 256;
    LCPU_RD_SET_ADDR(OFF_IP_TOTAL_LEN + 1);
    fifo_data = LCPU_RD_DATA8();
    ip_total_len = ip_total_len + fifo_data;

    if (ip_protocol_type == IP_PROTOCOL_ICMP) return ICMP_PROC;
    if (ip_protocol_type == IP_PROTOCOL_UDP)  return UDP_PROC;
    if (ip_protocol_type == IP_PROTOCOL_TCP)  return TCP_PROC;

    return NO_PROC;
}

uint16 ip_header_checksum(uint16 total_len, uint16 checksum_ini) {
    uint16 ip_checksum = checksum_ini;
    uint32 hi_byte = 0;
    uint32 fifo_data = 0;

    uint32 i = 0;
    for (i = eth_header_len; i < eth_header_len + ip_header_len; i++) {
        LCPU_RD_SET_ADDR(i);
        fifo_data = LCPU_RD_DATA8();
        if (i == OFF_IP_CHECKSUM || i == OFF_IP_CHECKSUM + 1) fifo_data = 0;
        if (i == OFF_IP_TOTAL_LEN)     fifo_data = (total_len >> 8) & 0xFF;
        if (i == OFF_IP_TOTAL_LEN + 1) fifo_data = (total_len >> 0) & 0xFF;
        if (i % 2 == 0) {
            hi_byte = fifo_data;
        } else {
            ip_checksum = cks_sum_cal(hi_byte, fifo_data, ip_checksum);
        }
    }
    return ~ip_checksum;
}

void ip_header_update(uint32 src_ip, uint16 total_len) {
    uint16 ip_checksum = ip_header_checksum(total_len, 0);
    uint32 i = 0;
    for (i = eth_header_len; i < eth_header_len + ip_header_len; i++) {
        LCPU_WR_SET_ADDR(i);
        // Update total length
        if (i >= OFF_IP_TOTAL_LEN && i < OFF_IP_TOTAL_LEN + 2) {
            LCPU_WR_SET_DATA((total_len >> (8 - (i - OFF_IP_TOTAL_LEN) * 8)) & 0xFF);
            LCPU_WR_PULSE_WEN();
        }
        // Update source IP (swap: use Local_IP_ADDR as source)
        else if (i >= OFF_IP_SRC_IP && i < OFF_IP_SRC_IP + 4) {
            LCPU_WR_SET_DATA((Local_IP_ADDR >> (24 - (i - OFF_IP_SRC_IP) * 8)) & 0xFF);
            LCPU_WR_PULSE_WEN();
        }
        // Update destination IP (swap: use src_ip as destination)
        else if (i >= OFF_IP_DST_IP && i < OFF_IP_DST_IP + 4) {
            LCPU_WR_SET_DATA((src_ip >> (24 - (i - OFF_IP_DST_IP) * 8)) & 0xFF);
            LCPU_WR_PULSE_WEN();
        }
        // Update header checksum
        else if (i >= OFF_IP_CHECKSUM && i < OFF_IP_CHECKSUM + 2) {
            LCPU_WR_SET_DATA((ip_checksum >> (8 - (i - OFF_IP_CHECKSUM) * 8)) & 0xFF);
            LCPU_WR_PULSE_WEN();
        }
        else {
            LCPU_RD_SET_ADDR(i);
            LCPU_WR_SET_DATA(LCPU_RD_DATA8());
            LCPU_WR_PULSE_WEN();
        }
    }
}
