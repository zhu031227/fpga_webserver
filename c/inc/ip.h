#ifndef _IP_H_
#define _IP_H_

uint16 ip_proc();
uint16 ip_header_checksum(uint16 total_len, uint16 checksum_ini);
void ip_header_update(uint32 src_ip, uint16 total_len);

#endif // _IP_H_
