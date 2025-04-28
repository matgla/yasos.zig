# Yasos.zig (**WIP**)

> [!CAUTION]
> **_work in progress_** - it may contains bugs, unoptimized implementations or stubs instead of real functionalities. 

The Yasos.zig project is general purpose operating system for microcontollers. 
Created in mind to be optimized for resource contrained devices, but with POSIX compatibility and userland which is similar the Linux or Unix operating systems. 

# Supported Boards 

Implementation is ongoing on MSPC v2 board.
MSPCv2 board is RP2350 custom development board. 
Project is maintained inside [MSPCv2](https://github.com/matgla/mspc/tree/mspc_v2)

Currently I am working on experimental revision of board MSPC v2 which contains hardware part to implement external MMU (memory management unit) controller on FPGA for external RAM attached to RP2350. 

# Zig version
Zig language is under heavily development, which means frequent changes of standard library and language API.

`main` branch should be compatible with zig: `zig-linux-x86_64-0.15.0-dev.384+c06fecd46`

# How to build
Yasos.zig project requires working `arm-none-eabi-gcc` toolchain for pico-sdk compilation. 
Also `python3` is necessary to use pykconfig lib and to convert elf files into yaff. 

To configure project call: 
```
zig build menuconfig
```

Then select `Board selection` -> `MSPC v2` since this is only supported board right now. 

After configuration use:

```
zig build
```

## Zig ubsan issue

If you encounter linking issue with ubsan runtime library then make sure that your zig contains fix [UBSan configuration](https://github.com/ziglang/zig/pull/23582)

