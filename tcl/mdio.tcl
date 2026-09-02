# #RTL8211F-CG on xilinx board:  RGMII PYH
#set phy_addr 0x0
# buy GMII module RTL8211EG
set phy_addr 0x1

proc wr_mdio {wr_addr wr_data} {
  global base_addr_1
  global phy_addr
	## write op code = 0x1
	jwrite [expr $base_addr_1 + 0x0 ] 0x1
	## write phy address = 0x1
	jwrite [expr $base_addr_1 + 0x1 ] $phy_addr
	## write reg address
	jwrite [expr $base_addr_1 + 0x2 ] $wr_addr
	## write reg wr_data
	jwrite [expr $base_addr_1 + 0x3 ] $wr_data
	## trigger op start
	jwrite [expr $base_addr_1 + 0x14 ] 0x1
}

proc rd_mdio {rd_addr} {
  global base_addr_1
  global phy_addr
	#read mdio
	## write op code = 0x2
	jwrite [expr $base_addr_1 + 0x0 ] 0x2
	## write phy address = 0x1
	jwrite [expr $base_addr_1 + 0x1 ] $phy_addr
	## write reg address
	jwrite [expr $base_addr_1 + 0x2 ] $rd_addr
	## trigger op start
	jwrite [expr $base_addr_1 + 0x14 ] 0x1
	## get read data
	jread [expr $base_addr_1 + 0xb ]
}
# ETH PHY0
set base_addr_1 0x1000
# ETH PHY1
#set base_addr_1 0x2000

## RTL8211E PHY_ID
rd_mdio 0x2
0x001C
rd_mdio 0x3
0xC916/0xC915


# for buy GMII module RTL8211EG
# Address=0x11	: Link Status
# 15:14		13			10
#	Speed		Duplex	Link Status

#Speed 10:1000M 01:100M 00:10Mbps
#Duplex	1:Full duplex 0:Half duplex
#Link Status	1:link Up  0: Link Down
rd_mdio 0x11
# when connect to network
# get value=0xAD02
# 1000M; Full duplex; Link Up

# for RTL8211F-CG on xilinx board:  RGMII PYH
rd_mdio 0x1A
0x0000302c

# 5:4				3				2
# speed		Duplex		Link
# 10:GE    1:Full		1:Ok
# 01:FE    0:Half		0:NOk
# 00: 10M









