#ifndef _ICMP_H_
#define _ICMP_H_

#include <stdint.h>

#define ICMP_ECHO_REPLY   0x00u
#define ICMP_ECHO_REQUEST 0x08u

#pragma pack(push, 1)

// ICMP 场景下使用的以太网头（14 字节，线上为网络字节序）。
typedef struct {
	uint8_t  dst_mac[6];
	uint8_t  src_mac[6];
	uint16_t ether_type; // 0x0800 (IPv4)
} icmp_eth_header_t;

// IPv4 头（无选项时 20 字节，IHL=5）。
typedef struct {
	uint8_t  ver_ihl;
	uint8_t  dscp_ecn;
	uint16_t total_len;
	uint16_t identification;
	uint16_t flags_frag_offset;
	uint8_t  ttl;
	uint8_t  protocol; // 0x01 (ICMP)
	uint16_t hdr_checksum;
	uint8_t  src_ip[4];
	uint8_t  dst_ip[4];
} icmp_ipv4_header_t;

// ICMP Echo 头（8 字节），后面可跟可变长度数据。
typedef struct {
	uint8_t  type;       // 0x08 request, 0x00 reply
	uint8_t  code;       // Echo 固定为 0
	uint16_t checksum;
	uint16_t identifier;
	uint16_t sequence;
} icmp_echo_header_t;

// 完整 ICMP Echo 帧（不含 FCS，data 为可变长度）。
typedef struct {
	icmp_eth_header_t  eth;
	icmp_ipv4_header_t ip;
	icmp_echo_header_t icmp;
} icmp_echo_frame_t;

#pragma pack(pop)

/*
 * ICMP Echo 请求报文（常见 Ping Request）：
 * eth.ether_type = 0x0800
 * ip.protocol    = 0x01
 * icmp.type      = 0x08
 * icmp.code      = 0x00
 * icmp.identifier/sequence/data 由请求端给出
 *
 * ICMP Echo 响应报文（常见 Ping Reply）：
 * 以太网源/目的地址互换，IP 源/目的地址互换
 * icmp.type      = 0x00
 * icmp.code      = 0x00
 * icmp.identifier/sequence/data 与请求保持一致
 * icmp.checksum  基于新的 type 和负载重新计算
 */

uint16 icmp_body_checksum(uint16 icmp_req_len, uint16 checksum_ini);
void icmp_reply(void);

#endif // _ICMP_H_
