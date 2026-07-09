// tb_webserver_arp.cpp — Verilator ARP test case
//
// Tests that the DUT correctly responds to an ARP request:
//   1. HW sends ARP request (broadcast DstMAC, target IP = DUT IP)
//   2. DUT firmware processes it via LCPU BFM
//   3. Check that DUT sends ARP reply with correct MAC
//========================================================================

#include <cstdio>
#include <cstdint>
#include "Vtb_webserver.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

int main(int argc, char **argv) {
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->commandArgs(argc, argv);

#if VM_TRACE
    Verilated::traceEverOn(true);
    VerilatedVcdC *tfp = new VerilatedVcdC;
#endif

    const std::unique_ptr<Vtb_webserver> top{new Vtb_webserver{contextp.get(), "TOP"}};

#if VM_TRACE
    top->trace(tfp, 2);
    tfp->open("tb_webserver_arp.vcd");
#endif

    printf("========================================\n");
    printf(" ARP Test Case — Verilator Simulation\n");
    printf("========================================\n");

    // Run simulation
    while (!contextp->gotFinish()) {
        top->eval();
#if VM_TRACE
        if (tfp) tfp->dump(contextp->time());
#endif
        if (!top->eventsPending()) break;
        contextp->time(top->nextTimeSlot());
    }

    printf("== Simulation complete at %" PRIu64 " ps ==\n", contextp->time());

#if VM_TRACE
    if (tfp) { tfp->close(); delete tfp; }
#endif

    top->final();
    contextp->statsPrintSummary();
    return 0;
}
