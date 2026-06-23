#ifndef _ARP_H_
#define _ARP_H_

#include <stdint.h>

#define ARP_ECHO_REPLY      0x0002u
#define ARP_OPCODE_REQUEST  0x0001u
#define ARP_OPCODE_REPLY    0x0002u

#pragma pack(push, 1)

// ARP 帧以太网头（14 字节，线上为网络字节序）。
typedef struct {
	uint8_t  dst_mac[6];
	uint8_t  src_mac[6];
	uint16_t ether_type; // 0x0806 (ARP)
} arp_eth_header_t;

// ARP 负载（28 字节，线上为网络字节序）。
typedef struct {
	uint16_t hardware_type; // 0x0001: Ethernet
	uint16_t protocol_type; // 0x0800: IPv4
	uint8_t  hardware_len;  // 6
	uint8_t  protocol_len;  // 4
	uint16_t opcode;        // 0x0001 request, 0x0002 reply
	uint8_t  sender_mac[6];
	uint8_t  sender_ip[4];
	uint8_t  target_mac[6];
	uint8_t  target_ip[4];
} arp_payload_t;

// 完整 ARP 以太网帧（不含 FCS，共 42 字节）。
typedef struct {
	arp_eth_header_t eth;
	arp_payload_t    arp;
} arp_frame_t;

#pragma pack(pop)

/*
 * ARP 请求报文（42 字节，不含 FCS）：
 * eth.dst_mac      = FF:FF:FF:FF:FF:FF（广播）
 * eth.src_mac      = 请求方 MAC
 * eth.ether_type   = 0x0806
 * arp.opcode       = 0x0001
 * arp.sender_mac/ip= 请求方 MAC/IP
 * arp.target_mac   = 00:00:00:00:00:00
 * arp.target_ip    = 被查询的目标 IP
 *
 * ARP 响应报文（42 字节，不含 FCS）：
 * eth.dst_mac      = 请求方 MAC
 * eth.src_mac      = 响应方（本机）MAC
 * eth.ether_type   = 0x0806
 * arp.opcode       = 0x0002
 * arp.sender_mac/ip= 响应方（本机）MAC/IP
 * arp.target_mac/ip= 请求方 MAC/IP
 */

void arp_reply();

#endif // _ARP_H_