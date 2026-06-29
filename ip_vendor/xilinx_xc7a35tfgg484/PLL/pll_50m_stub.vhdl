-- Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
-- Copyright 2022-2024 Advanced Micro Devices, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2024.1 (lin64) Build 5076996 Wed May 22 18:36:09 MDT 2024
-- Date        : Mon Jun 29 10:23:43 2026
-- Host        : huamingh-XT12-Pro running 64-bit Ubuntu 26.04 LTS
-- Command     : write_vhdl -force -mode synth_stub
--               /home/huamingh/work/fpga_webserver/webserver_xilinx_xc7a35tfgg484_v0001_20260629_095848/ip_vendor/xilinx_xc7a35tfgg484/PLL/pll_50m_stub.vhdl
-- Design      : pll_50m
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7a35tfgg484-2
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity pll_50m is
  Port ( 
    c0 : out STD_LOGIC;
    c1 : out STD_LOGIC;
    c2 : out STD_LOGIC;
    locked : out STD_LOGIC;
    inclk0 : in STD_LOGIC
  );

end pll_50m;

architecture stub of pll_50m is
attribute syn_black_box : boolean;
attribute black_box_pad_pin : string;
attribute syn_black_box of stub : architecture is true;
attribute black_box_pad_pin of stub : architecture is "c0,c1,c2,locked,inclk0";
begin
end;
