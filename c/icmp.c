#include "inc/lcpu_general.h"
#include "inc/comlib.h"
#include "inc/ip.h"
#include "inc/icmp.h"

// ICMP header field offsets relative to icmp_start
#define ICMP_OFS_TYPE       0
#define ICMP_OFS_CODE       1
#define ICMP_OFS_CHECKSUM   2
#define ICMP_OFS_IDENTIFIER 4
#define ICMP_OFS_SEQUENCE   6
#define ICMP_HEADER_LEN     8

uint16 icmp_body_checksum(uint16 icmp_req_len, uint16 checksum_ini) {
    uint16 icmp_start = eth_header_len + ip_header_len;
    uint16 icmp_checksum = checksum_ini;
    uint16 processed_len = 0;
    uint32 hi_byte = 0;
    uint32 fifo_data = 0;

    bool is_odd = false;
    if (icmp_req_len % 2) {
        is_odd = true;
        processed_len = icmp_req_len - 1;
    } else {
        is_odd = false;
        processed_len = icmp_req_len;
    }

    // Start with type=ECHO_REPLY(0), code=0
    icmp_checksum = cks_sum_cal(ICMP_ECHO_REPLY, 0, icmp_checksum);
#if DEBUG_En_icmp
    printf("icmp_checksum_0 is : 0x%x\n", icmp_checksum);
#endif

    // Include ID (bytes 4-5) and Seq (bytes 6-7) in checksum, then payload from byte 8
    uint32 i = 0;
    for (i = icmp_start + ICMP_OFS_IDENTIFIER; i < icmp_start + processed_len; i++) {
        LCPU_RD_SET_ADDR(i);
        fifo_data = LCPU_RD_DATA8();
        if (i % 2 == 0) {
            hi_byte = fifo_data;
        } else {
            icmp_checksum = cks_sum_cal(hi_byte, fifo_data, icmp_checksum);
#if DEBUG_En_icmp
            printf("icmp_checksum i %d is : 0x%x\n", i, icmp_checksum);
#endif
        }
    }
    if (is_odd) {
        LCPU_RD_SET_ADDR(icmp_start + processed_len);
        fifo_data = LCPU_RD_DATA8();
        icmp_checksum = cks_sum_cal(fifo_data, 0, icmp_checksum);
    }
    return ~icmp_checksum;
}

void icmp_reply() {
    uint16 icmp_start = eth_header_len + ip_header_len;
    uint16 icmp_req_len = 0;
    uint16 tx_pkt_len = 0;
    uint16 i = 0;

    icmp_req_len = ip_total_len - ip_header_len;
    tx_pkt_len = eth_header_len + ip_total_len + 4;
    if (tx_pkt_len < 64) tx_pkt_len = 64;

    ip_header_update(src_ip, ip_total_len);

    // Write ICMP type = Echo Reply, code = 0
    LCPU_WR_BYTE(icmp_start + ICMP_OFS_TYPE, ICMP_ECHO_REPLY);
    LCPU_WR_BYTE(icmp_start + ICMP_OFS_CODE, 0);

    // Copy ICMP ID (bytes 4-5) and Sequence (bytes 6-7) from request
    for (i = 0; i < 4; i++) {
        LCPU_RD_SET_ADDR(icmp_start + ICMP_OFS_IDENTIFIER + i);
        LCPU_WR_BYTE(icmp_start + ICMP_OFS_IDENTIFIER + i, LCPU_RD_DATA8());
    }

    // Copy ICMP payload (skip 8-byte ICMP header)
    for (i = icmp_start + ICMP_HEADER_LEN; i < icmp_start + icmp_req_len; i++) {
        LCPU_RD_SET_ADDR(i);
        LCPU_WR_BYTE(i, LCPU_RD_DATA8());
    }

    // Calculate checksum (over type+code+id+seq+payload, starting with type=0)
    uint16 icmp_checksum = icmp_body_checksum(icmp_req_len, 0);

#if DEBUG_En_icmp
    printf("insert icmp_checksum value is : 0x%x\n", icmp_checksum);
#endif

    // Write checksum (big-endian, 2 bytes)
    for (i = 0; i < 2; i++) {
        LCPU_WR_BYTE(icmp_start + ICMP_OFS_CHECKSUM + i,
                     (icmp_checksum >> (8 - i * 8)) & 0xFF);
    }

    // Zero pad to minimum Ethernet frame size
    for (i = eth_header_len + ip_total_len; i < tx_pkt_len - 4; i++) {
        LCPU_WR_BYTE(i, 0);
    }

    LCPU_WR_PUSH_PACKET(tx_pkt_len);

#if DEBUG_En_icmp
    printf("icmp reply done, packet length is : %d\n", tx_pkt_len);
#endif
}
