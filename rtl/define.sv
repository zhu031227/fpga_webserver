// Interface mode selection for FPGA WebServer
// Xilinx platform: RGMII (with rgmii2gmii bridge to internal GMII)
// Altera platform:  GMII (direct connection)
//
// The platform-specific top modules handle the PHY interface conversion.
// The internal webserver_wrapper always uses GMII signaling.
