#ifndef _COMLIB_H_
#define _COMLIB_H_

void heart_beat_mod1();
void heart_beat_mod2();
void heart_beat_mod3();
void cp_fifo_test(uint16 rec_pkt_len);
void delay(volatile uint32 count);
uint16 cks_sum_cal(uint32 a, uint32 b, uint16 c);
uint16 tcp_calculate_checksum(uint16 tcp_len);
uint32 get_local_time_l();
void write_lcpu_register(uint32 addr, uint32 data);
uint32 read_lcpu_register(uint32 addr);
void str_hex_chk(char str_in[8], char str_hex[8]);
void to_hex_string(unsigned int data, char hex_str[8]);
uint8_t hex_char_to_val(char ch);
unsigned int read_ascii_hex(uint16_t base_addr);
char hex_to_ascii(uint8_t nibble);

#endif // _COMLIB_H_