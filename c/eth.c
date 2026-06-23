#include "inc/lcpu_general.h"

uint16 eth_proc()
{
    uint32 fifo_data = 0;
    uint16 eth_type = 0;

    // Read Ethernet type (bytes 12-13)
    LCPU_RD_SET_ADDR(OFF_ETH_TYPE);
    fifo_data = LCPU_RD_DATA8();
    eth_type = (uint16)fifo_data << 8;
    LCPU_RD_SET_ADDR(OFF_ETH_TYPE + 1);
    fifo_data = LCPU_RD_DATA8();
    eth_type = eth_type | fifo_data;

    if (eth_type == ETH_TYPE_ARP) {
        return ARP_PROC;
    }
    else if (eth_type == ETH_TYPE_IP) {
        // Batch-read destination MAC high 4 bytes (raddr 0→4)
        uint32 dst_mac_high = 0;
        LCPU_RD_SET_ADDR(OFF_ETH_DST_MAC);
        dst_mac_high  = (uint32)LCPU_RD_DATA8() << 24;
        LCPU_RD_INC_ADDR();
        dst_mac_high |= (uint32)LCPU_RD_DATA8() << 16;
        LCPU_RD_INC_ADDR();
        dst_mac_high |= (uint32)LCPU_RD_DATA8() << 8;
        LCPU_RD_INC_ADDR();
        dst_mac_high |= (uint32)LCPU_RD_DATA8();
        LCPU_RD_INC_ADDR();  // raddr now at 4

        // Batch-read destination MAC low 2 bytes (raddr 4→6)
        uint32 dst_mac_low = 0;
        dst_mac_low  = (uint32)LCPU_RD_DATA8() << 8;
        LCPU_RD_INC_ADDR();
        dst_mac_low |= (uint32)LCPU_RD_DATA8();

        // Single comparison for all 6 bytes
        if (dst_mac_high != Local_MAC_HIGH || dst_mac_low != (uint32)Local_MAC_LOW) {
            return NO_PROC;
        }

        // Write local MAC as source MAC (bytes 6-11)
        LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 0, (Local_MAC_HIGH >> 24) & 0xFF);
        LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 1, (Local_MAC_HIGH >> 16) & 0xFF);
        LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 2, (Local_MAC_HIGH >> 8) & 0xFF);
        LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 3, (Local_MAC_HIGH >> 0) & 0xFF);
        LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 4, (Local_MAC_LOW >> 8) & 0xFF);
        LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 5, (Local_MAC_LOW >> 0) & 0xFF);

        // Swap source MAC → destination MAC (copy RX[6..11] to TX[0..5])
        uint32 i;
        for (i = 0; i < 6; i++) {
            LCPU_RD_SET_ADDR(OFF_ETH_SRC_MAC + i);
            fifo_data = LCPU_RD_DATA8();
            LCPU_WR_BYTE(OFF_ETH_DST_MAC + i, fifo_data);
        }

        // Copy Ethernet type
        LCPU_WR_BYTE(OFF_ETH_TYPE,     (eth_type >> 8) & 0xFF);
        LCPU_WR_BYTE(OFF_ETH_TYPE + 1, (eth_type >> 0) & 0xFF);

        return IP_PROC;
    }
    else {
        return NO_PROC;
    }
}
