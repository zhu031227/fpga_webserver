#include "inc/lcpu_general.h"
#include "inc/arp.h"

void arp_reply() {
    uint16 i;
    uint16 arp_type = 0;
    uint32 dst_mac_high = 0;
    uint16 dst_mac_low = 0;
    uint32 target_ip = 0;

    // Read destination MAC (bytes 0-5) in batches: high 4 bytes + low 2 bytes
    for (i = 0; i < 4; i++) {
        LCPU_RD_SET_ADDR(i);
        dst_mac_high = (dst_mac_high << 8) | (LCPU_RD_DATA8() & 0xFFu);
    }
    for (i = 4; i < 6; i++) {
        LCPU_RD_SET_ADDR(i);
        dst_mac_low = (uint16)((dst_mac_low << 8) | (LCPU_RD_DATA8() & 0xFFu));
    }

    // Accept only ARP packets sent to local MAC or broadcast MAC
    if (!((dst_mac_high == Local_MAC_HIGH && dst_mac_low == Local_MAC_LOW) ||
          (dst_mac_high == 0xFFFFFFFFu && dst_mac_low == 0xFFFFu))) {
        return;
    }

    // Read ARP target IP (bytes 38-41) and verify it matches local IP
    target_ip = 0;
    for (i = OFF_ARP_TARGET_IP; i < OFF_ARP_TARGET_IP + 4; i++) {
        LCPU_RD_SET_ADDR(i);
        target_ip = (target_ip << 8) | (LCPU_RD_DATA8() & 0xFFu);
    }
    if (target_ip != Local_IP_ADDR) return;

    // Read ARP opcode (bytes 20-21)
    LCPU_RD_SET_ADDR(OFF_ARP_OPCODE);
    arp_type = (uint16)LCPU_RD_DATA8() << 8;
    LCPU_RD_SET_ADDR(OFF_ARP_OPCODE + 1);
    arp_type |= LCPU_RD_DATA8();

    if (arp_type != ARP_REQUEST) return;

    // --- Build ARP reply frame in sections (reduces per-byte branching) ---

    // Section 1: Copy RX → TX for bytes 0-5 (dst MAC ← src MAC from RX[6..11])
    for (i = 0; i < 6; i++) {
        LCPU_RD_SET_ADDR(OFF_ETH_SRC_MAC + i);
        LCPU_WR_BYTE(i, LCPU_RD_DATA8());
    }

    // Section 2: Write local MAC as source MAC (bytes 6-11)
    for (i = 0; i < 4; i++) {
        LCPU_WR_BYTE(OFF_ETH_SRC_MAC + i, (Local_MAC_HIGH >> (24 - i * 8)) & 0xFF);
    }
    for (i = 0; i < 2; i++) {
        LCPU_WR_BYTE(OFF_ETH_SRC_MAC + 4 + i, (Local_MAC_LOW >> (8 - i * 8)) & 0xFF);
    }

    // Section 3: Copy Ethernet type (bytes 12-13) unchanged
    for (i = OFF_ETH_TYPE; i < OFF_ETH_TYPE + 2; i++) {
        LCPU_RD_SET_ADDR(i);
        LCPU_WR_BYTE(i, LCPU_RD_DATA8());
    }

    // Section 4: Copy hardware type, protocol type, hlen, plen (bytes 14-19) unchanged
    for (i = OFF_ARP_HTYPE; i < OFF_ARP_OPCODE; i++) {
        LCPU_RD_SET_ADDR(i);
        LCPU_WR_BYTE(i, LCPU_RD_DATA8());
    }

    // Section 5: Write ARP opcode = REPLY (bytes 20-21)
    LCPU_WR_BYTE(OFF_ARP_OPCODE,     (ARP_ECHO_REPLY >> 8) & 0xFF);
    LCPU_WR_BYTE(OFF_ARP_OPCODE + 1, (ARP_ECHO_REPLY >> 0) & 0xFF);

    // Section 6: Write local MAC as sender MAC (bytes 22-27)
    for (i = 0; i < 4; i++) {
        LCPU_WR_BYTE(OFF_ARP_SENDER_MAC + i, (Local_MAC_HIGH >> (24 - i * 8)) & 0xFF);
    }
    for (i = 0; i < 2; i++) {
        LCPU_WR_BYTE(OFF_ARP_SENDER_MAC + 4 + i, (Local_MAC_LOW >> (8 - i * 8)) & 0xFF);
    }

    // Section 7: Write local IP as sender IP (bytes 28-31)
    for (i = 0; i < 4; i++) {
        LCPU_WR_BYTE(OFF_ARP_SENDER_IP + i, (Local_IP_ADDR >> (24 - i * 8)) & 0xFF);
    }

    // Section 8: Copy sender MAC from RX to target MAC in TX (bytes 32-37 ← RX[22..27])
    for (i = 0; i < 6; i++) {
        LCPU_RD_SET_ADDR(OFF_ARP_SENDER_MAC + i);
        LCPU_WR_BYTE(OFF_ARP_TARGET_MAC + i, LCPU_RD_DATA8());
    }

    // Section 9: Copy sender IP from RX to target IP in TX (bytes 38-41 ← RX[28..31])
    for (i = 0; i < 4; i++) {
        LCPU_RD_SET_ADDR(OFF_ARP_SENDER_IP + i);
        LCPU_WR_BYTE(OFF_ARP_TARGET_IP + i, LCPU_RD_DATA8());
    }

    // Pad to 64 bytes
    for (i = 42; i < 64; i++) {
        LCPU_WR_BYTE(i, 0);
    }

    LCPU_WR_PUSH_PACKET(64);
}
