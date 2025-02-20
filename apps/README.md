# Limitations

Right now to compile relocatable executable that supports dynamic linking GCC toolchain must be used.

LLVM with ZIG produces arm version of bx instruction for thumb thunk when jump to PLT.
Check if there is not arm flag, armv6-m supports only T16 and T32 instruction set.
And zig doens't handle no-plt flag. 


