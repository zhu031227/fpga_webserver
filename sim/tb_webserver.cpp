// tb_webserver.cpp — Verilator harness with --timing and VCD trace support
//
// Properly drives the Verilator timing engine (eventsPending/nextTimeSlot)
// and optionally generates a VCD waveform.
//========================================================================

#include <cstdio>
#include "Vtb_webserver.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

int main(int argc, char **argv) {
    // Parse command-line arguments (including +trace for VCD)
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->commandArgs(argc, argv);

#if VM_TRACE
    Verilated::traceEverOn(true);
    VerilatedVcdC *tfp = new VerilatedVcdC;
#endif

    // Construct the model
    const std::unique_ptr<Vtb_webserver> top{new Vtb_webserver{contextp.get(), "TOP"}};

#if VM_TRACE
    top->trace(tfp, 2);
    tfp->open("tb_webserver_verilator.vcd");
#endif

    printf("== Verilator simulation start ==\n");

    // Simulate until $finish or no events pending
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
