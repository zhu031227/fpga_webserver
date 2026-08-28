#include "inc/system.h"

// 项目里面不要用数组设计，也不要使用strcmp函数等方式设计，可以直接读取RAM方式实现。
// 在RISCV中保持设计稳定。

#define embeded_cpu_mode 0  //0: RiscV; 1: Xilinx MicroBlaze; 2: Altera NiosII

#if embeded_cpu_mode == 0
	/*
	 * Inputs: None.
	 * Outputs: None.
	 * Side effects: Fixed reset vector at address 0, jumps directly to program_main.
	 */
	__attribute__((naked, used, section(".text.bootloader"))) void reset_entry() {
		asm volatile(
			"j program_main\n"
		);
	}

	/*
	 * Inputs: None.
	 * Outputs: Exit code.
	 * Side effects: Keeps a normal C entry for toolchain/debug convenience.
	 */
	int main() {
			program_main();
			return 0;
	}
	
	/*
	 * Inputs: None.
	 * Outputs: None.
	 * Side effects: Starts application main loop.
	 */
	void program_main() {
		designApp();
	}
	
#elif embeded_cpu_mode == 1 || embeded_cpu_mode == 2

	/*
	 * Inputs: None.
	 * Outputs: Exit code.
	 * Side effects: Starts application main loop.
	 */
	int main() {
			designApp();
			return 0;
	}
	
	
#else
	#error "Unsupported embeded_cpu_mode"
#endif
