import sys
src = open(sys.argv[1] if len(sys.argv) > 1 else "../tcl/InstructRAM.tcl").readlines()
dst = sys.argv[2] if len(sys.argv) > 2 else "InstructRAM_local.tcl"
BSS_TCL_START = 0x8931
BSS_TCL_END   = 0x89FF
with open(dst, "w") as f:
    for line in src[:-1]:
        f.write(line)
    for a in range(BSS_TCL_START, BSS_TCL_END + 1):
        f.write("jwrite 0x%04X 0x00000000\n" % a)
    f.write(src[-1])
n = BSS_TCL_END - BSS_TCL_START + 1
print("  BSS zeroed: 0x%04X..0x%04X (%d words)" % (BSS_TCL_START, BSS_TCL_END, n))
