# Limitations

Right now to compile relocatable executable that supports dynamic linking GCC toolchain must be used.

LLVM with ZIG produces arm bx instruction for thumb thunk when jump to PLT. 
And zig doens't handle no-plt flag. 


