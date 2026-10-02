# yasboot — bootloader plan for yasos.zig boards and MSPC cards

Drafted 2026-09-21; decisions applied the same day (§10). The existing `matgla/Yasboot`
repository (CMake, last touched 2025-05) is wiped and reimplemented from this plan. This file
becomes a pointer to that repository once it exists.

## 1. Why

Today every board boots the kernel straight from flash offset 0: the RP2350 bootrom finds the
hand-written picobin IMAGE_DEF block in `hal/source/raspberry/rp2350/startup/boot2_rom.zig`,
jumps to `_start`, and the kernel assumes the romfs at a linker-fixed `0x10100000`.

- **Flashing is SWD-only** (`scripts/flash.sh`, 32–42 s, needs OpenOCD and a healthy probe).
  Nothing in the tree writes flash on hardware: the RP2350 `flash.zig` driver's `write`/`erase`
  are stubs and `hardware_flash` is not compiled into the HAL.
- **No fallback.** A kernel that faults before the console is up leaves the board dead until
  someone reflashes it. The unattended CI node then climbs the reset / power-cycle / reflash
  ladder, and phantom failures from stale firmware are a known class.
- **The MSPC v3 cards cannot be reached** once in the chassis. The GPU card is an RP2354B with
  its flash inside the package, no USB, and only SWD (J4) plus the mainboard link.

yasboot is one bootloader, one image format, one update protocol and one host tool for every
board, with three ways in: the console UART, the SD card, and the MSPC link.

## 2. Boards

| board | chip | flash | how updates reach it | port |
|---|---|---|---|---|
| MSPC v2 mainboard | RP2350B | 8 MB W25Q64 (CS0), PSRAM on CS1 | UART0 GP44/45; SD on GP32–37 (PIO SPI or SDIO); external SWD probe | mainboard, 8 MB layout |
| MSPC v3 mainboard | RP2350B | 16 MB W25Q128 | UART1 GPIO24/25 and SWD through the on-board debugprobe; SDIO GPIO13–18 (+ SD_DET 19); links to card 0 (8-bit, GPIO1–12) and card 2 (4-bit, GPIO32–39); BOOTSEL via SW202 + J90 | mainboard, 16 MB layout |
| GPU card v3 | RP2354B | 2 MB in-package | link slave on GPIO5–11; UART0 J1; SWD J4; RST# from the host on RUN | card |
| Pimoroni Pico Plus 2 (CI rig) | RP2350B | 16 MB | UART0 GP32/33; SD CLK 5 / CMD 18 / D0–3 19–22; SWD; USB BOOTSEL | mainboard, 16 MB layout |
| Raspberry Pico 2 | RP2350A | 4 MB | UART, SWD, USB BOOTSEL | mainboard, small layout (no full rootfs) |
| QEMU mps2-an505 / mps3-an524 | Cortex-M33 model | none (RAM at 0x10000000) | `-kernel` / `-device loader`; the existing host-readable FAT disk stands in for the SD card | qemu (CI) |

RP2040 is out: the Raspberry Pico port and any RP2040-based card bridge are not yasboot
targets. If the FPGA card's bridge becomes an RP2350, it takes the card port as-is.

Two ports share almost everything: **mainboard** (UART, SD, link master) and **card** (link
slave, UART). The qemu port is the mainboard port on CMSDK peripherals.

## 3. Goals and non-goals

1. Boot the existing kernel unchanged in shape: linked at `0x10000000`, carrying its IMAGE_DEF,
   still bare-flashable at offset 0 during the migration.
2. **Kernel A/B** with try-before-you-buy and automatic rollback; **one rootfs** that takes the
   rest of the flash and is rewritten in place.
3. Updates from **the SD card** (files dropped there by yasos, e.g. fetched over the network),
   from **the console UART** (host tool), and for cards over **the MSPC link**.
4. Reboot-to-loader from a running kernel; a loader reachable after any reset even when the
   kernel image is garbage; yasboot itself never touched by an update.
5. Card firmware upload over the link from yasos at runtime and from the mainboard's yasboot
   at boot; RAM-run of a card image for development.
6. QEMU-testable format, state machine, protocol and SD-update path.
7. Small and self-contained: 128 KB flash region, runs from SRAM, no dependency on the kernel
   or the yasos HAL.

Non-goals for now: signatures / secure boot (fields reserved), USB DFU (the bootrom's BOOTSEL
covers boards with a USB device port), a factory kernel slot, an interactive shell.

## 4. Architecture

### 4.1 Boot chain

```
chip bootrom ──► yasboot (flash offset 0, bootrom copies it to SRAM) ──► kernel
                  │  1. boot-request word (scratch register): stay | slot override
                  │  2. SD card: apply /yasboot/*.ybi that are newer than what is flashed
                  │  3. boot state (flash sector): pending slot, tries, confirmed
                  │  4. verify the chosen kernel slot and the rootfs (YBI descriptors)
                  │  5. attention window on the UART (100 ms) — HELLO keeps the loader up
                  │  6. map the kernel slot (QMI ATRANS0), fill BootInfo, set VTOR/MSP, jump
```

yasboot runs entirely from SRAM: its IMAGE_DEF carries a `LOAD_MAP`, so the bootrom copies it
before jumping (pico-sdk's `copy_to_ram` binary type on RP2350). Running from RAM is what makes
remapping the flash window and programming flash uneventful.

### 4.2 Flash layouts

Flash storage offsets; "XIP view" is what the kernel sees. Sector granularity is 4 KB, which is
also the QMI address-translation granularity.

**Mainboard, 16 MB (MSPC v3, Pico Plus 2):**

```
offset    size     XIP view                    content
0x000000  128 KB   hidden (window 0 remapped)   yasboot: IMAGE_DEF + LOAD_MAP, code
0x020000    8 KB   -                            boot state, two ping-pong sectors
0x022000  1 MB     0x10000000 via ATRANS0       kernel slot A
0x122000  1 MB     0x10000000 via ATRANS0       kernel slot B
0x222000  ~1.9 MB  -                            spare (loader staging, card config)
0x400000  12 MB    0x10400000 identity          rootfs = 4 KB YBI page + romfs image
```

Why the rootfs is 12 MB and not "everything after kernel B": the XIP address space per chip
select is 16 MB, and window 0 (4 MB of it) is spent on showing the 1 MB active kernel. The
rootfs must be contiguous in the XIP view, so it starts on the next 4 MB window and can extend
to the end of flash. Translating windows 1–3 to start right after kernel B would gain nothing:
the last 1.9 MB of flash would become invisible instead. The spare block is free for the
loader's own use.

Only the active kernel slot is visible; the inactive one is read or written through
`rom_flash_op` with the storage address space. Kernel `.text` is ~305 KB today, so 1 MB per
slot also fits Debug builds; the rootfs image is 3.45 MB.

**Mainboard, 8 MB (MSPC v2):** same first 4 MB; rootfs `0x400000`–`0x7FFFFF` (4 MB).

**Card, 2 MB (GPU card, RP2354B):**

```
0x000000  128 KB  yasboot (card port: link slave + UART0)
0x020000    8 KB  boot state
0x022000  956 KB  app slot A  (0x10000000 via ATRANS0)
0x111000  956 KB  app slot B
```

**Raspberry Pico 2, 4 MB:** loader, state, kernel A/B, then whatever is left (~2 MB) as the
rootfs. Not a full-rootfs target.

**QEMU mps2-an505:** no flash. yasboot is the `-kernel` ELF, linked into a RAM region the
kernel does not touch until it has consumed BootInfo (the bottom of the kernel stack region);
the kernel and rootfs are placed with `-device loader,file=…,addr=…` at their usual addresses;
the `ramflash` driver backs the state sectors and the existing `fatdisk` region plays the SD
card, so `scripts/qemu_fatdisk_run.py` can drop update files exactly as a user would.

### 4.3 Image format: the YBI descriptor

A payload is a raw image, not a container: the descriptor lives **inside** the image's first
4 KB, like the RP2350 IMAGE_DEF, so the same bytes are bare-flashable at offset 0,
slot-independent, and picotool-visible. The kernel already places `.vectors` then `.bootmeta` at
the start of `.text`; a `.ybi` section follows `.bootmeta`. yasboot scans the first 4 KB for the
magic, the way the bootrom scans for its block loop.

```
struct ybi {                        // little-endian, 128 bytes, 4-byte aligned, C header in abi/
    uint32_t magic;                 // "YBI1"
    uint16_t header_size, header_version;
    uint8_t  image_type;            // kernel | rootfs | card_app | loader | ram_image
    uint8_t  chip;                  // rp2350 | mps2 | ...
    uint16_t board_id;              // shared table: mspc_v2, mspc_v3, gpu_card_v3, pico_plus2, ...
    uint32_t flags;                 // needs_confirm, ram_only, has_sha256, has_signature, ...
    uint32_t version[4];            // major, minor, patch, build — build is monotonic
                                    // (commit count from CI), so "newer" is a plain compare
    uint32_t git_hash;              // for humans and logs only
    uint32_t load_addr, entry, image_size, crc32;   // crc32 over the image, this field zeroed
    uint32_t companion_min_version[3]; // kernel: oldest rootfs it accepts, and vice versa
    uint8_t  sha256[32];            // optional (flag)
    uint8_t  reserved[...];         // signature TLVs later
};
```

`tools/ybi.py` patches `image_size` and `crc32` after linking, as `boot2_rom.zig` already does
for the RP2040 boot2 CRC. A rootfs image is data, so `build_rootfs.sh` prepends a 4 KB YBI
page; the kernel is handed the romfs address after that page.

### 4.4 Boot state and slot selection

State is a 64-byte record with a sequence number and CRC, written alternately into the two
state sectors; the newer valid record wins.

```
struct boot_state { seq, crc, active_slot, pending_slot, tries_left, confirmed,
                    last_boot_reason, kernel_version[2], rootfs_version, boot_count,
                    failure_count, allow_reflash }
```

1. **Boot-request word** in a reset-surviving scratch register (`WATCHDOG_SCRATCH`; a RAM word
   on QEMU): `LOADER` → serve the transports and do not boot; `SLOT_A`/`SLOT_B` → one-shot
   override. Cleared on read.
2. **SD card pass** (§4.5). May write the rootfs in place and/or stage a kernel into the
   inactive slot as pending.
3. If `pending_slot` is set and `tries_left > 0`: decrement, persist, boot it. If it is
   exhausted and not confirmed: revert to `active_slot`, record the failure.
4. Verify the chosen kernel and the rootfs YBI: magic, chip, board, size within slot,
   companion versions; full CRC32 only when the slot is pending or the failure count is
   non-zero, so a normal boot costs milliseconds.
5. **Attention window** (100 ms mainboard, 50 ms card): a `HELLO` frame keeps yasboot alive.
6. Map, fill BootInfo, jump.

**Confirmation:** the kernel writes `confirmed = 1` once the rootfs is mounted and the root
process is running (a kernel-side flash write, §8.1). A card app confirms itself after its POST.
Anything that does not confirm within its tries is rolled back to the other kernel slot.

### 4.5 Updates from the SD card

The SD card is the update medium for everything on the mainboard. yasos puts files there
(downloaded over the network on v3 through the on-board ESP32-C3, copied over UART/ZMODEM, or
written by a build script on the rig) and reboots; yasboot applies them at boot.

```
/yasboot/kernel.ybi       -> inactive kernel slot, marked pending with 3 tries
/yasboot/rootfs.ybi       -> rootfs, rewritten in place
/yasboot/gpu_card.ybi     -> card 2 over the link (mainboard yasboot as link master, §4.8)
/yasboot/fpga_card.ybi    -> card 0, when that card exists
```

Rules:

- A file is applied when its descriptor verifies (header + full CRC, read from the card) and
  its `version` is newer than the flashed image's, or `allow_reflash` is set in the boot state
  (`bootctl stage` from userland sets it, for developers re-flashing the same version).
- Order: rootfs first, then kernel, then cards, so a new kernel meets the rootfs it asked for.
  A kernel whose `companion_min_version` the flashed rootfs does not meet is skipped and logged.
- Erase only what the image needs (3.5 MB of rootfs ≈ 56 × 64 KB blocks ≈ 8 s plus ~5 s of
  programming), never the whole region.
- Read-only FatFs (`FF_FS_READONLY`, 8.3 names) in the loader: nothing on the card is renamed
  or deleted by yasboot. The version compare prevents re-applying the same file every boot;
  userland tidies the directory after a confirmed boot.
- No card, or no `/yasboot` directory: the pass costs one failed card init (~10 ms) and is
  skipped on boards whose table says "no SD".
- The one non-A/B hazard is power loss while the rootfs is being rewritten. Next boot yasboot
  finds an invalid rootfs descriptor and re-applies the file from the card; if that is gone too,
  the UART path is left.

### 4.6 BootInfo handoff

A 512-byte `BootInfo` at a fixed SRAM address per port (`0x20000000` on RP2350, the first
512 bytes of kernel RAM on mps2), also passed as a pointer in `r0`. The kernel's linker script
reserves it as a NOLOAD section ahead of `.ram_vector_table` (the vector table moves to
`+0x200`, keeping its 512-byte alignment), and `crt_init` never zeroes it.

```
struct boot_info { magic "YBIF", version, loader_version, board_id, chip,
                   boot_reason (cold|warm|watchdog|loader-request|rollback),
                   active_kernel_slot, pending, tries_left,
                   kernel_storage_base, rootfs_xip_base, rootfs_size,
                   flash_size, layout_id, console_baud, sd_update_applied, flags }
```

A kernel that finds no magic behaves as today (romfs at the link-time address), so kernels
flashed bare at offset 0 keep working throughout the migration.

### 4.7 RP2350 specifics

- **yasboot's own IMAGE_DEF** carries `LOAD_MAP` (copy to SRAM) and `VERSION`, so picotool and
  the bootrom's flash-update boot type recognise it; produced by pico-sdk's CMake.
- **Slot mapping** by QMI address translation: `ATRANS0.BASE = slot_offset / 4 KB`,
  `SIZE = 1 MB / 4 KB`, XIP cache flush, all from SRAM. Window 0 then shows the chosen kernel at
  `0x10000000`; windows 1–3 stay identity. One kernel image serves both slots. `rom_chain_image`
  stays the alternative if signed images are ever wanted.
- **Flash programming** through `rom_flash_op` with the storage address space, bounds checked by
  the ROM.
- **Reboot** through `rom_reboot`: normal, or `BOOTSEL` on boards with a USB device port.
- **What yasboot leaves for the kernel:** clk_sys on the 150 MHz boot PLL (pico-sdk's standard
  clock init; the kernel's `crt_init` re-runs its own), VREG untouched, QMI CS0 timing as the
  bootrom left it (the kernel's `apply_overclock` starts from that state), PSRAM CS1 untouched,
  no interrupts pending, core 1 never started.

### 4.8 Transports and the protocol

One frame format for every transport, so the codec exists once in yasboot, once in the kernel
driver and once in the Python tool:

```
AA 55 | len:u16 | seq:u8 | cmd:u8 | payload[len] | crc32
```

Loader commands: `HELLO/INFO` (board, chip, loader version, slots, state), `SET_BAUD`,
`ERASE slot`, `WRITE slot off data` (≤ 4 KB, streaming, 4 frames in flight, NAK rewinds),
`VERIFY slot → crc32`, `ACTIVATE slot tries flags`, `CONFIRM`/`REVERT`, `BOOT slot|auto`,
`REBOOT mode`, `RAM_LOAD` / `RAM_RUN`, `READ_STATE`, `SD_APPLY` (run the §4.5 pass now),
`CARD n <forwarded frame>`, `LOG`. Replies: `ACK`, `NAK code`, `DATA`. Every app (kernel, card
app) answers `INFO` and `ENTER_LOADER`, so a host can always reach the loader without a reset
line.

- **UART** (mainboard and card): the console UART at 115200, then `SET_BAUD` up. The MSPC v3
  console runs through the debugprobe, which drops bytes at 921600; per-frame CRC and
  retransmit make that survivable, and the tool steps the baud down when the NAK rate climbs.
  A 3.45 MB rootfs at ~300 KB/s is ~12 s of transfer against ~13 s of erase + program, on par
  with SWD today and independent of OpenOCD.
- **MSPC link, card end (slave):** the card's yasboot runs the same PIO slave program the card
  app uses; the v3 plan's `[CMD][ADDR][LEN][DATA…]` framing carries these frames as payload.
  On reset the loader raises INT#/DET and listens for `HELLO` for 50 ms; a host that wants the
  loader pulses RST#, waits for DET, and speaks within the window. A cold boot never speaks, so
  the card boots its app immediately. A strap on a data line at reset release is the fallback if
  the window proves fragile.
- **MSPC link, mainboard end (master):** present in **both** the yasos kernel (PIO + DMA driver
  behind `/dev/card0`, `/dev/card2`, with `cardctl`) **and** the mainboard's yasboot. The loader
  needs it for the SD pass (`gpu_card.ybi` applied at boot) and for `CARD n` recovery from the
  PC with no OS running; the kernel needs it anyway for runtime GPU commands and for
  `cardctl update` without a reboot. Same PIO program and codec for both, from `common/`. The
  program serves both slot widths (layout INT#, RST#, CLK, CS#, D0..Dn is common) and can be
  prototyped on two existing RP2350 boards over jumper wires before the v3 hardware exists.
- **SD card:** §4.5.
- **SWD** stays the bring-up and last-resort recovery path, unchanged.

### 4.9 GPU card firmware lifecycle

The card boots from its own flash, so the display is alive before the OS is. The GPU firmware
repo builds `gpu_card.ybi`; yasos ships it in the rootfs under `/lib/firmware/mspc/` and can
also drop it into `/yasboot/` on the SD card. Three ways it reaches the card: the mainboard's
yasboot at boot (SD pass), `cardctl update card2` at runtime, or `yasboot.py card2 flash` from
the PC through the mainboard loader. The kernel's card driver reads `INFO` at boot and flags a
missing, invalid or stale app. Development loop: `cardctl run card2 image.ybi` RAM-loads and runs
without touching flash. The card app carries a YBI descriptor, answers `INFO`/`ENTER_LOADER`, and
confirms itself after POST.

## 5. Language and build

**C11 on pico-sdk, built with CMake** — the same shape as the wiped repository.

- Everything yasboot touches is C-first: pico-sdk's boot machinery (`copy_to_ram` / LOAD_MAP,
  `flash_safe_execute`, bootrom API), FatFs, the SDIO PIO driver already in the tree
  (`hal/source/raspberry/rp2350/source/mmc/sdio_rp2350.c`), the PIO assembler output, and the
  card firmware, which will be pico-sdk C for the same reasons (HSTX, PIO, DMA).
- A bootloader is write-once, keep-stable code. Zig's standard library and language still move
  between releases (the README says as much); every Zig bump would touch a component nobody
  wants to touch. C with pico-sdk does not have that cost.
- The ABI is C headers regardless, and the kernel consumes them the way it already consumes
  `libc_imports.h`/`cimports.zig`: `@cImport`. A Zig kernel and a C loader agree on struct
  layout because both compile the same header; a host-side test asserts the Python mirror
  matches.
- The mps2 port is bare C on CMSIS under the same CMake tree, with its own toolchain file.

## 6. Repositories

One common core and one repository per subproject:

```
yasboot/                 the core (wipes matgla/Yasboot)
  loader/                the bootloader: boot logic, state, transports, SD pass
  ports/rp2350/          IMAGE_DEF + LOAD_MAP, flash (rom_flash_op), ATRANS, UART, PIO, SDIO
  ports/mps2/            CMSDK UART, ramflash, fatdisk, RAM scratch word, semihosting exit
  boards/                per-board tables: pins, flash size, layout id, console, SD, link role
  common/                consumed by every subproject as a submodule:
    abi/                 ybi.h, boot_info.h, boot_state.h, frame.h, board_ids.h
    link/                mspc_link.pio, master + slave drivers, frame codec
    crc/                 crc32 (and sha256 later)
  tools/                 yasboot.py (pyserial host tool), ybi.py (descriptor patcher)
  tests/                 host unit tests (format, state, codec, Python mirror), QEMU boot test
  libs/pico-sdk          submodule
  libs/fatfs             submodule (read-only config)
yasos.zig                submodule common/ at libs/yasboot; kernel + userland changes (§8)
mspc-gpu                 GPU card firmware; common/ for link slave + abi; emits gpu_card.ybi
mspc-fpga                FPGA card firmware, if its bridge becomes an RP2350
```

## 7. Size budget

C, `-Os`, Cortex-M33, estimates from comparable pico-sdk code:

| part | KB |
|---|---|
| crt, clock init, IMAGE_DEF, board tables | 3–4 |
| UART + frame codec + CRC32 | 4 |
| flash ops, ATRANS, boot state, YBI verify, boot logic | 5–6 |
| FatFs read-only (8.3 names) + SDIO PIO driver | 14–18 |
| link master (PIO + DMA) or slave | 4–6 |
| logging (no printf) | 2 |
| **total, mainboard port** | **32–40** |
| card port (no SD, no master) | ~20 |

A 128 KB region leaves headroom for SHA-256, signatures and whatever the SD pass grows into;
CI fails the build past 96 KB so the margin is never silently spent.

## 8. Changes in yasos.zig

1. **Flash write driver** for RP2350 (`hal/source/raspberry/rp2350/source/flash.zig`):
   `rom_flash_op` behind a `flash_safe_execute`-style helper that parks core 1, masks interrupts
   and runs from SRAM. During a program or erase the QMI is in direct mode, so PSRAM on CS1 is
   unreachable too: nothing on either core may touch PSRAM-resident process memory during the
   operation. Needed for confirmation and `bootctl`.
2. **BootInfo consumption**: linker scripts reserve the section; `crt` keeps it; the kernel takes
   the romfs base/size and the MPU romfs region (`source/kernel/uaccess.zig`) from it, with the
   legacy fallback.
3. **Boot control**: `/proc/boot` (state, slots, versions), `bootctl confirm|revert|activate|stage`,
   `reboot [-l|-b]` writing the boot-request word and resetting. Confirmation from the kernel
   after init (§4.4).
4. **Card link driver** (PIO + DMA master per slot) and `cardctl` (info, reset, update, run,
   hold-in-loader). Firmware images under `/lib/firmware/mspc/`.
5. **Update staging**: a userland `yasupdate` that fetches `*.ybi` (network on v3, or a host
   over the console meanwhile) into `/yasboot/` on the SD card, verifies the descriptor, and
   reboots; it also tidies the directory after a confirmed boot.
6. **Build outputs**: `zig build` patches the kernel's YBI; `build_rootfs.sh` emits `rootfs.ybi`;
   `build_image.sh` packages both plus yasboot's UF2/ELF per board.
7. **Tooling**: `scripts/flash.sh --uart /dev/ttyACM0` uses `yasboot.py` (reboot-to-loader
   through the running kernel, else reset through the probe and hit the attention window);
   SWD stays the fallback. The remote smoke runner and CI switch to UART or SD updates with
   TBYB, so a kernel that does not come up rolls back instead of triggering the recovery ladder.
8. **QEMU scripts** gain a `--with-yasboot` mode so the smoke gate covers the handoff and the
   SD pass (through the fatdisk).

## 9. Phases

| phase | deliverable | exit criterion |
|---|---|---|
| **0 — skeleton** | repo, `common/`, YBI + BootInfo + state + codec with unit tests, `ybi.py`, mps2 port incl. fatdisk-backed SD pass | yasboot boots the current yasos kernel in QEMU; a kernel dropped on the fatdisk is applied; the smoke gate passes through the loader |
| **1 — RP2350 single slot** | rp2350 port (LOAD_MAP, ATRANS, rom_flash_op, SDIO), UART transport, `yasboot.py`, kernel BootInfo + legacy fallback, `flash.sh --uart` | Pico Plus 2 and MSPC v2 update kernel + rootfs over UART and from the SD card; reboot-to-loader from the shell; SWD-flashed bare kernels still boot |
| **2 — A/B + TBYB** | kernel B slot, state machine, kernel flash driver, `bootctl`, kernel confirmation, `yasupdate` | a deliberately broken kernel staged with 3 tries rolls back on its own; the CI rig updates over UART/SD with TBYB |
| **3 — link** | shared PIO master/slave, kernel link driver + `cardctl`, card yasboot port, link master in the mainboard yasboot (SD pass + `CARD n`), RAM-run | prototyped on two boards over jumpers, then the GPU card: firmware pushed from the SD pass, from yasos and from the PC; loader held via RST# + HELLO; card self-confirms |
| **4 — hardening** | FPGA card port if it is RP2350, size and CI gates, SHA-256 in the descriptor | every board in §2 builds in yasboot CI |
| later | signatures / RP2350 secure boot, anti-rollback counters, loader self-update through a bootrom-managed A/B pair of yasboot partitions | — |

Phases 0–2 need only QEMU, the Pico Plus 2 and MSPC v2. Phase 3's link work starts before the
v3 boards exist.

## 10. Decisions (resolved 2026-09-21)

| id | decision | outcome |
|---|---|---|
| D1 | name, repo, language | `yasboot`, reimplemented in the existing repository; **C11 + pico-sdk + CMake** (§5) |
| D2 | HAL dependency | self-contained loader + `common/` package |
| D3 | A/B mechanism | QMI ATRANS on RP2350; **RP2040 dropped** entirely |
| D4 | layout | loader **128 KB** (64 was too tight once the SD pass, FatFs and the link master are in); kernel A/B 1 MB each; rootfs takes the rest, 12 MB on 16 MB parts (§4.2 explains the ceiling), rewritten in place from the SD card |
| D5 | who confirms | the kernel, after init |
| D6 | card loader entry | RST# pulse + HELLO within a 50 ms window |
| D7 | link master in the mainboard yasboot | **yes** (§4.8): with the SD drop-folder model the loader is where card firmware gets applied at boot, and it gives card recovery with no OS; the kernel keeps its own driver for runtime |
| D8 | rootfs A/B | no; kernel A/B only, rootfs in place |
| D9 | descriptor placement | inside the image |
| D10 | transports | custom framed protocol on the UART, the same frames over the MSPC link, and files on the SD card |
| Q1 | repositories | one common core (`yasboot`) + one per subproject (yasos, gpu, fpga) |
| Q2 | flash data partition | none; the SD card is the writable medium and the update source |
| Q3 | factory slot | none; A/B is enough |

## 11. Risks and traps

- **Flash ops from a running SMP kernel with PSRAM in use** (§8.1): helper in SRAM, never in
  PSRAM (`yasos-psram-exclusives-hang-thunk-refcount`), core 1 parked first.
- **ATRANS and the XIP cache**: change the window only from SRAM and flush the cache before
  jumping, as the bootrom's own boot path does.
- **Kernel expectations at entry**: the overclock sequence assumes bootrom-default QMI timing
  and the 150 MHz boot PLL; yasboot must not configure flash timing beyond what the bootrom did.
- **Power loss during the in-place rootfs rewrite** (§4.5): recovered by re-applying from the
  card at the next boot; the SD file is the backup until userland deletes it after confirmation.
- **SD pass on every boot**: card init and directory lookup must stay under ~50 ms with no
  files present; the board table disables the pass where there is no slot.
- **Debugprobe byte loss at 921600**: the protocol is designed for loss; the tool reports NAK
  rates so a marginal link is visible.
- **Attention window cost**: 100 ms mainboard, 50 ms card, per-board configurable.
- **Migration**: kernels without `.ybi` and rootfs images without the page keep booting bare
  until every script emits the new outputs; the legacy fallback is removed only after the rig
  runs on yasboot.
- **Card 2's RST# is the host's**: a driver bug that toggles it mid-frame reboots the display;
  the driver owns that line exclusively and logs every assertion.

## 12. Still open

1. SD file convention: `/yasboot/<name>.ybi` as above, or a per-board subdirectory so one card
   can carry files for several boards?
2. The `build` field's source: commit count (`git rev-list --count`) from CI is the proposal;
   local developer builds get `allow_reflash` instead of a bigger number.
