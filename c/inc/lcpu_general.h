#ifndef _LCPU_GEN_H_
#define _LCPU_GEN_H_

#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>

typedef unsigned char   uint8;
typedef unsigned short  uint16;
typedef unsigned int    uint32;
typedef char            int8;
typedef short           int16;
typedef int             int32;

#define DEBUG_En_tmp     0

#define DEBUG_En_ip      0
#define DEBUG_En_icmp    0
#define DEBUG_En_tcp     0

// Local MAC address & IP address
#define Local_MAC_HIGH   0x00000102
#define Local_MAC_LOW    0x0406
//#define Local_IP_ADDR    0xA9FE0058  //169.254.0.88
//#define Local_IP_ADDR    0xC0A80142  //192.168.1.66
#define Local_IP_ADDR    0xC0A80158  //192.168.1.88

// Standard header lengths
#define eth_header_len   14
#define ip_header_len    20
#define tcp_header_len   20

// Ethernet frame field offsets (byte offset from packet start)
#define OFF_ETH_DST_MAC   0
#define OFF_ETH_SRC_MAC   6
#define OFF_ETH_TYPE      12

// IP header field offsets (byte offset from packet start = eth_header_len + N)
#define OFF_IP_VER_IHL    (eth_header_len + 0)
#define OFF_IP_TOTAL_LEN  (eth_header_len + 2)
#define OFF_IP_TTL        (eth_header_len + 8)
#define OFF_IP_PROTO      (eth_header_len + 9)
#define OFF_IP_CHECKSUM   (eth_header_len + 10)
#define OFF_IP_SRC_IP     (eth_header_len + 12)
#define OFF_IP_DST_IP     (eth_header_len + 16)

// TCP header field offsets (byte offset from packet start = eth_header_len + ip_header_len + N)
#define OFF_TCP_SRC_PORT  (eth_header_len + ip_header_len + 0)
#define OFF_TCP_DST_PORT  (eth_header_len + ip_header_len + 2)
#define OFF_TCP_SEQ_NUM   (eth_header_len + ip_header_len + 4)
#define OFF_TCP_ACK_NUM   (eth_header_len + ip_header_len + 8)
#define OFF_TCP_DATA_OFS  (eth_header_len + ip_header_len + 12)
#define OFF_TCP_FLAGS     (eth_header_len + ip_header_len + 13)
#define OFF_TCP_WINDOW    (eth_header_len + ip_header_len + 14)
#define OFF_TCP_CHECKSUM  (eth_header_len + ip_header_len + 16)
#define OFF_TCP_PAYLOAD   (eth_header_len + ip_header_len + tcp_header_len)

// IP header offsets within 20-byte header (relative to OFF_IP_VER_IHL)
#define IP_OFS_TOTAL_LEN  2
#define IP_OFS_PROTO      9
#define IP_OFS_CHECKSUM   10
#define IP_OFS_SRC_IP     12
#define IP_OFS_DST_IP     16

// ARP frame field offsets (byte offset from packet start)
#define OFF_ARP_HTYPE      14
#define OFF_ARP_PTYPE      16
#define OFF_ARP_HLEN       18
#define OFF_ARP_PLEN       19
#define OFF_ARP_OPCODE     20
#define OFF_ARP_SENDER_MAC 22
#define OFF_ARP_SENDER_IP  28
#define OFF_ARP_TARGET_MAC 32
#define OFF_ARP_TARGET_IP  38

// Ethernet types
#define ETH_TYPE_IP   0x0800
#define ETH_TYPE_ARP  0x0806

// IP protocols
#define IP_PROTOCOL_ICMP  0x01
#define IP_PROTOCOL_UDP   0x11
#define IP_PROTOCOL_TCP   0x06

// ARP / ICMP opcodes
#define ARP_REQUEST     0x0001
#define ICMP_REQUEST    0x08

// TCP timing constants (in local_time ticks — scaled for 50MHz system clock)
// Note: local_time is a 32-bit free-running counter. Max safe timeout is
//       2^31 = 2,147,483,648 ticks ≈ 42.9s at 50MHz (modular arithmetic limit).
#ifndef TCP_TIMEWAIT_TICKS
#define TCP_TIMEWAIT_TICKS      100000000u  // TIME_WAIT duration (~2s at 50MHz)
#endif
#ifndef TCP_IDLE_TIMEOUT_TICKS
#define TCP_IDLE_TIMEOUT_TICKS  2000000000u // Idle connection timeout (~40s at 50MHz, max safe)
#endif
#ifndef TCP_SYN_RETRY_TICKS
#define TCP_SYN_RETRY_TICKS     150000000u  // SYN+ACK retry interval (~3s at 50MHz)
#endif
#define TCP_SYN_MAX_RETRIES     3

// HTTP
#define HTTP_PORT  80

// Protocol dispatch codes
#define NO_PROC     0x0000
#define ARP_PROC    0x0001
#define IP_PROC     0x1000
#define ICMP_PROC   0x1100
#define TCP_PROC    0x1200
#define HTTP_PROC   0x1201
#define FTP_PROC    0x1202
#define Telnet_PROC 0x1203
#define UDP_PROC    0x1300
#define NTP_PROC    0x1301

#define Local_Open_PORT_NUM  1

extern uint32 src_ip;
extern uint16 src_port;
extern uint16 ip_total_len;

struct str_wr_pkt_fifo
{
    uint32 full;
    uint32 wen;
    uint32 waddr;
    uint32 wdata;
    uint32 wpkt_len;
    uint32 wpkt_para;
    uint32 wpkt_push;
    uint32 reg_rw_0;
    uint32 reg_rw_1;
    uint32 reg_rw_2;
    uint32 reg_rw_3;
    uint32 reg_ro_0;
    uint32 reg_ro_1;
    uint32 reg_wc_0;
    uint32 reg_rc_0;
    uint32 reg_rc_1;
}__attribute__((aligned(4)));

struct str_rd_pkt_fifo
{
    uint32 empty;
    uint32 rpkt_pop;
    uint32 rpkt_len;
    uint32 rpkt_para;
    uint32 ren;
    uint32 raddr;
    uint32 rdata;
    uint32 reop_pre;
    uint32 reg_rw_0;
    uint32 reg_rw_1;
    uint32 reg_rw_2;
    uint32 reg_rw_3;
    uint32 reg_ro_0;
    uint32 reg_ro_1;
    uint32 reg_wc_0;
    uint32 reg_rc_0;
}__attribute__((aligned(4)));

struct lcpu_registers
{
    // ---- 0x00 - 0x08: General registers ----
    uint32 fpga_build_date;          // 0x00 RO
    uint32 fpga_build_time;          // 0x01 RO
    uint32 sw_build_date;            // 0x02 RW
    uint32 sw_build_time;            // 0x03 RW
    uint32 eth_greset;               // 0x04 RW [3:0]
    uint32 second_event;             // 0x05 RO [0]
    uint32 get_local_time;           // 0x06 WC [0]
    uint32 local_time_l;             // 0x07 RO
    uint32 local_time_h;             // 0x08 RO
    uint32 reserve0[0x10 - 0x09];   // 0x09..0x0F

    // ---- 0x10 - 0x13: Debug RW ----
    uint32 debug_rw_0;               // 0x10 RW
    uint32 debug_rw_1;               // 0x11 RW
    uint32 debug_rw_2;               // 0x12 RW
    uint32 debug_rw_3;               // 0x13 RW
    uint32 reserve1[0x20 - 0x14];   // 0x14..0x1F

    // ---- 0x20 - 0x23: Debug RO ----
    uint32 debug_ro_0;               // 0x20 RO
    uint32 debug_ro_1;               // 0x21 RO
    uint32 debug_ro_2;               // 0x22 RO
    uint32 debug_ro_3;               // 0x23 RO
    uint32 reserve2[0x30 - 0x24];   // 0x24..0x2F

    // ---- 0x30: LED ----
    uint32 Led;                      // 0x30 RW [3:0]
    uint32 reserve3[0x100 - 0x31];  // 0x31..0xFF

    // ---- 0x100 - 0x106: ETH statistics ----
    uint32 eth_rx_correct_pkt_cnt;   // 0x100 RO
    uint32 eth_rx_crc_err_pkt_cnt;   // 0x101 RO
    uint32 eth_tx_correct_pkt_cnt;   // 0x102 RO
    uint32 eth_tx_error_pkt_cnt;     // 0x103 RO
    uint32 eth_rx_afifo_full_cnt;    // 0x104 RO
    uint32 eth_rx_afifo_empty_cnt;   // 0x105 RO
    uint32 eth_rx_data_err_line;     // 0x106 RO
    uint32 reserve4[0x200 - 0x107]; // 0x107..0x1FF

    // ---- 0x200 - 0x201: MAC filter ----
    uint32 filter_data;              // 0x200 RW [15:0]
    uint32 filter_offset;            // 0x201 RW [15:0]
    uint32 reserve5[0x6000 - 0x202]; // 0x202..0x5FFF

    // ---- 0x6000: Read packet FIFO (16 regs) ----
    struct str_rd_pkt_fifo rd_pkt_fifo;
    uint32 reserve6[0x100 - 0x10];   // 0x6010..0x60FF

    // ---- 0x6100: Write packet FIFO (15 regs) ----
    struct str_wr_pkt_fifo wr_pkt_fifo;
    uint32 reserve7[0x1000 - 0x100 - 0x10]; // pad to 0x7000

    // ---- 0x7000: program_ram ----
    uint32 program_ram[0x1000];
}__attribute__((aligned(4)));

#define lcpu_baseaddr  ((volatile struct lcpu_registers *)(0x80000000))

#define LCPU_SECOND_EVENT()     ((uint8)(lcpu_baseaddr->second_event & 0xFFu))
#define LCPU_SET_LED(value)     do { lcpu_baseaddr->Led = (uint32)(value); } while (0)
#define LCPU_LOCAL_TIME_L()     (lcpu_baseaddr->local_time_l)

#define LCPU_RD_EMPTY()         ((lcpu_baseaddr->rd_pkt_fifo.empty) != 0u)
#define LCPU_RD_START_PACKET()  do { lcpu_baseaddr->rd_pkt_fifo.rpkt_pop = 1u; lcpu_baseaddr->rd_pkt_fifo.ren = 1u; } while (0)
#define LCPU_RD_PKT_LEN()       ((uint16)(lcpu_baseaddr->rd_pkt_fifo.rpkt_len & 0xFFFFu))
#define LCPU_RD_SET_ADDR(addr)  do { lcpu_baseaddr->rd_pkt_fifo.raddr = (uint32)(addr); } while (0)
#define LCPU_RD_INC_ADDR()      do { lcpu_baseaddr->rd_pkt_fifo.raddr++; } while (0)
#define LCPU_RD_DATA8()         ((uint8)(lcpu_baseaddr->rd_pkt_fifo.rdata & 0xFFu))

#define LCPU_WR_SET_ADDR(addr)  do { lcpu_baseaddr->wr_pkt_fifo.waddr = (uint32)(addr); } while (0)
#define LCPU_WR_SET_DATA(data)  do { lcpu_baseaddr->wr_pkt_fifo.wdata = (uint32)(data); } while (0)
#define LCPU_WR_PULSE_WEN()     do { lcpu_baseaddr->wr_pkt_fifo.wen = 1u; } while (0)
#define LCPU_WR_BYTE(addr, data) do { LCPU_WR_SET_ADDR(addr); LCPU_WR_SET_DATA(data); LCPU_WR_PULSE_WEN(); } while (0)
#define LCPU_WR_PUSH_PACKET(pkt_len) do { lcpu_baseaddr->wr_pkt_fifo.wpkt_len = (uint32)(pkt_len); lcpu_baseaddr->wr_pkt_fifo.wpkt_push = 1u; } while (0)
#define LCPU_WR_TEST_ENABLE()   ((lcpu_baseaddr->wr_pkt_fifo.reg_rw_0) != 0u)

#define LCPU_REG32_WRITE(word_addr, data) do { *((volatile uint32 *)((uintptr_t)lcpu_baseaddr + ((word_addr) * sizeof(uint32)))) = (uint32)(data); } while (0)
#define LCPU_REG32_READ(word_addr)       (*((volatile uint32 *)((uintptr_t)lcpu_baseaddr + ((word_addr) * sizeof(uint32)))))


#endif /* _LCPU_GEN_H_ */
