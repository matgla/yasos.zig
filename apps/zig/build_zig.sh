#!/bin/bash
# Build the Zig compiler for YasOS and install it into a rootfs.
#
#   build_zig.sh <zig-source-dir> <rootfs-dir> [workdir]
#
# <zig-source-dir> is a Zig tree (the yasos fork). The compiler reaches YasOS
# as C: its own C backend renders it as one file, and the YasOS cross compiles
# that. Steps, each cached in [workdir] (default .cache/zig-build):
#
#  1. A HOST compiler built from <zig-source-dir>. `zig build -Donly-c` renders
#     with the C backend of the compiler RUNNING the build, so the fork's C
#     backend changes (undefined renders as 0 without safety: -77 KB of
#     .text) only reach zig.c when the fork itself does the rendering. No LLVM:
#     the C backend and the x86_64 backend for build.zig are all it needs.
#  2. zig.c, rendered by it for thumb-linux-musleabi. YasOS is not a target Zig
#     knows; its libc is Linux-flavoured, and yasos_compat.c bridges the rest.
#  3. Zig's compiler-rt through the same C backend (build_compiler_rt.sh).
#  4. zig.c and yasos_compat.c through the cross, then the link.
#  5. The binary into <rootfs-dir>/usr/bin/zig. lib/std plus the headers a
#     compile of its output needs go to the SD card, not the romfs image (18.6
#     MB, four fifths of it otherwise): into $ZIG_CARD_DIR/var/lib/zig
#     (default: sdcard/ beside <rootfs-dir>, a staging tree laid out like the
#     card), which the compiler searches when no lib sits next to it
#     (-Dzig-lib-search). Copy it onto a board's card with
#     `scripts/target_sync.py push sdcard/var/lib/zig /var/lib/zig`; on QEMU
#     the harnesses put it on the fatdisk volume and pass --zig-lib-dir.
#
# CC is the YasOS cross (default armv8m-tcc); ZIG is the host zig that builds
# the host compiler (default zig). ZIG_OPT is the cross's level (default -O2).
# ZIG_CPU_FAMILIES (default arm) are the architecture families the device
# compiler can target: the CPU tables of every other family are left out, which
# is ~200 KB of .data, i.e. RAM in every run. Empty keeps all of them.
# ZIG_ZIR_BUDGET (default 1572864) is how many bytes of ZIR the device compiler
# keeps loaded; the rest is dropped and re-read from the ZIR cache when needed
# (~32 ms a re-read on the Pico Plus 2's card).  Kernel render on the board,
# 2026-11-09: 1 MB 307 s 6.14 MB peak, 1.5 MB 288 s 6.75 MB, 2 MB 281 s 7.45 MB.
# 0 keeps all ZIR loaded.
# zig.c is compiled with lseek/ftruncate renamed to yasos_compat.c's 64-bit
# wrappers: Zig's off_t is 64-bit, YasOS's libc takes a 32-bit one.
#
# `zig build` on the device: the device compiler is built with -Dtcc-default
# (every native or ARM compile goes C backend -> a `tcc` child process,
# `-ftcc`) and -Dyasos-host (native programs link the YasOS libc,
# single-threaded).  Its lib directory on the card carries what that needs, in
# tcc/:
#   tcc/zig_c_prelude.h, tcc/include/   force-included prelude, freestanding headers
#   tcc/yasos/yasos_compat.o, compiler_rt.o   linked into every native program
#   tcc/yasos/ip-hints-configurer       InternPool sizes for the configurer's first compile
# and compiler/configurer.zig, which the device compiles per project.  `zig build`'s
# maker, built here on the PC (its C is 36 MB), goes into the rootfs as
# /usr/bin/zig-maker (-Dprebuilt-maker): from the romfs its code runs in place
# instead of taking RAM.
set -euo pipefail

ZIG_SRC="$(realpath "${1:?zig source dir}")"
ROOTFS="$(realpath "${2:?rootfs dir}")"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(realpath -m "${3:-$HERE/../../.cache/zig-build}")"
CC="${CC:-armv8m-tcc}"
HOST_ZIG="${ZIG:-zig}"
ZIG_OPT="${ZIG_OPT:--O2}"
CPU_FAMILY_FLAGS=()
for family in ${ZIG_CPU_FAMILIES-arm}; do CPU_FAMILY_FLAGS+=("-Dcpu-family=$family"); done
ZIR_BUDGET="${ZIG_ZIR_BUDGET-1572864}"
CARD_DIR="$(realpath -m "${ZIG_CARD_DIR:-$(dirname "$ROOTFS")/sdcard}")"
LIB_ON_CARD=/var/lib/zig
mkdir -p "$WORK"

echo "zig: host compiler from $ZIG_SRC"
(cd "$ZIG_SRC" && ZIG_LIB_DIR="$ZIG_SRC/lib" "$HOST_ZIG" build -Doptimize=ReleaseFast -Denable-llvm=false \
    -Dno-lib --prefix "$WORK/host")
FORK_ZIG="$WORK/host/bin/zig"

# The device compiler is single-threaded, and single-threaded the fork numbers its
# output differently (declarations get their Nav when first used): this one makes the
# host references the device's output must equal (scripts/kernel_tcc/zig_device.py).
# Without threads the fork needs libc's allocator.
echo "zig: single-threaded host compiler (references for the device's output)"
(cd "$ZIG_SRC" && ZIG_LIB_DIR="$ZIG_SRC/lib" "$HOST_ZIG" build -Doptimize=ReleaseFast -Denable-llvm=false \
    -Dno-lib -Dsingle-threaded -Dforce-link-libc --prefix "$WORK/host-st")

echo "zig: rendering the compiler as C"
# -Ddev must be explicit: -Donly-c alone pins the bootstrap feature set.
(cd "$ZIG_SRC" && ZIG_LIB_DIR="$ZIG_SRC/lib" "$FORK_ZIG" build -Donly-c -Dofmt=c -Ddev=cbe \
    -Denable-llvm=false -Dsingle-threaded -Dforce-link-libc -Dtarget=thumb-linux-musleabi \
    -Dcpu=cortex_m33 -Doptimize=ReleaseFast -Dstrip ${CPU_FAMILY_FLAGS[@]+"${CPU_FAMILY_FLAGS[@]}"} \
    -Dzir-budget="$ZIR_BUDGET" -Dzig-lib-search="$LIB_ON_CARD" \
    -Dtcc-default -Dyasos-host -Dprebuilt-maker=/usr/bin/zig-maker --prefix "$WORK/zigc")

echo "zig: compiler-rt"
ZIG="$FORK_ZIG" "$HERE/build_compiler_rt.sh" "$ZIG_SRC" "$CC" "$WORK/compiler_rt.o" "$WORK/compiler_rt"

echo "zig: compiling zig.c with $CC $ZIG_OPT"
# -ffunction-sections: the link's --hot-text picks functions by their sections.
"$CC" $ZIG_OPT -w -c "$WORK/zigc/bin/zig.c" -o "$WORK/zig.o" -ffunction-sections \
    -I "$ZIG_SRC/lib" -include "$HERE/zig_c_prelude.h" -fvisibility=hidden \
    -Dlseek=yz_lseek64 -Dftruncate=yz_ftruncate64
"$CC" -O2 -c "$HERE/yasos_compat.c" -o "$WORK/compat.o" -fvisibility=hidden

# The stack is reserved in full at exec (16 MB made the process 21 MB instead of 5).
# Deepest stack use of the device compiler, scanned for the lowest written word below
# main (2026-11-08, QEMU): 144 KB, for hello world and for the whole yasos kernel
# alike; 512 KB -> 320 KB gave a board compile that memory back.  2026-11-09, the board
# model's watch on the stack (zig's own stores only): 151 KB for the kernel render, deepest
# in Sema's type-layout and inline-body recursion (~3 KB a level).  192 KB keeps the stack
# and zig's 124 KB .data both in SRAM: exec allocates the stack first, and the pool's fast
# tier is ~430 KB.  ZIG_STACK_SIZE overrides; a deeper compile faults (STKOF), not corrupts.
# hot_functions.txt: the functions the loader copies to SRAM (fetch stalls of the kernel
# render; the stack, its hot block and .data all fit the pool's ~430 KB fast tier).
"$CC" -fvisibility=hidden -stack-size=${ZIG_STACK_SIZE:-196608} -Wl,--hot-text="$HERE/hot_functions.txt" "$WORK/zig.o" "$WORK/compat.o" "$WORK/compiler_rt.o" \
    -lm -o "$WORK/zig"

echo "zig: installing into $ROOTFS, the lib into $CARD_DIR$LIB_ON_CARD"
install -D -m 755 "$WORK/zig" "$ROOTFS/usr/bin/zig"
rm -rf "$ROOTFS/usr/lib/zig" "$CARD_DIR$LIB_ON_CARD"
mkdir -p "$CARD_DIR$LIB_ON_CARD"
cp -r "$ZIG_SRC/lib/std" "$CARD_DIR$LIB_ON_CARD/std"
# The card's std only ever builds YasOS and freestanding Arm programs: switches on the
# native OS or CPU lose their prongs for other systems (trim_std.zig).  In zig build's
# configurer that takes the ZIR pinned at once from 2.8 to 2.1 MB (c.zig 803 -> 249 KB).
"$FORK_ZIG" build-exe -OReleaseFast --zig-lib-dir "$ZIG_SRC/lib" "$HERE/trim_std.zig" \
    --cache-dir "$WORK/trim-cache" --global-cache-dir "$WORK/trim-cache" -femit-bin="$WORK/trim_std"
"$WORK/trim_std" "$CARD_DIR$LIB_ON_CARD/std"
# compiler-rt as source too: the kernel's tcc build renders it with the C
# backend like the kernel itself (build/kernel_tcc.zig), on the device as well.
cp -r "$ZIG_SRC/lib/compiler_rt" "$CARD_DIR$LIB_ON_CARD/compiler_rt"
cp "$ZIG_SRC/lib/compiler_rt.zig" "$CARD_DIR$LIB_ON_CARD/"
cp "$ZIG_SRC/lib/zig.h" "$HERE/zig_c_prelude.h" "$CARD_DIR$LIB_ON_CARD/"
# zig build: the configurer's root (the device compiles it per build.zig), and
# what -ftcc reads and links (see the top).
mkdir -p "$CARD_DIR$LIB_ON_CARD/compiler"
cp "$ZIG_SRC/lib/compiler/configurer.zig" "$CARD_DIR$LIB_ON_CARD/compiler/"
cp -r "$ZIG_SRC/lib/tcc" "$CARD_DIR$LIB_ON_CARD/tcc"
mkdir -p "$CARD_DIR$LIB_ON_CARD/tcc/yasos"
# Built again for programs the device links: there the soft-float helpers
# (__aeabi_*) bind to a shared library, so calls must keep their R9 reload
# (-fno-module-local-calls).  The device zig itself keeps the faster copies.
"$CC" -O2 -fno-module-local-calls -c "$HERE/yasos_compat.c" -o "$CARD_DIR$LIB_ON_CARD/tcc/yasos/yasos_compat.o" \
    -fvisibility=hidden
"$CC" -O2 -fno-module-local-calls -c "$WORK/compiler_rt/compiler_rt_tcc.c" \
    -o "$CARD_DIR$LIB_ON_CARD/tcc/yasos/compiler_rt.o" -ffunction-sections \
    -I "$ZIG_SRC/lib" -include "$HERE/zig_c_prelude.h" -fvisibility=hidden -w

# The maker, built by the PC's fork the way the device would build it (-ftcc
# against the card's lib, so with the YasOS runtime) -- ReleaseSmall where the
# device's jitCmd would pick ReleaseSafe: 44 MB of C either way.  Its stack:
# Fetch.run, which runs for every project's root package, has a 164 KB frame
# under tcc (131 KB of git/zip buffers), past the 128 KB -ftcc default.
echo "zig: zig build's maker for YasOS"
ZIG_LIB_DIR="$CARD_DIR$LIB_ON_CARD" ZIG_TCC="$(command -v "$CC")" "$WORK/host-st/bin/zig" build-exe -ftcc \
    -target thumb-linux-musleabi -mcpu cortex_m33 -OReleaseSmall -fsingle-threaded -lc -fstrip \
    --tcc-arg -stack-size=262144 \
    -Mroot="$ZIG_SRC/lib/compiler/Maker.zig" --name maker \
    --cache-dir "$WORK/maker-cache" --global-cache-dir "$WORK/maker-cache" -femit-bin="$WORK/maker"
install -D -m 755 "$WORK/maker" "$ROOTFS/usr/bin/zig-maker"

# The configurer's InternPool sizes, for its first compile on the device (the
# device compiler keeps its own afterwards, in its global cache).  A hello-world
# build script; the second run reads the first one's sizes and writes them back
# trimmed, which is what a device run would see.
echo "zig: InternPool hints for the configurer"
HP="$WORK/hints-project"
rm -rf "$HP" && mkdir -p "$HP/src"
cat > "$HP/build.zig" <<'ZIG'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{ .name = "hello", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    }) });
    b.installArtifact(exe);
    b.step("run", "Run it").dependOn(&b.addRunArtifact(exe).step);
}
ZIG
printf 'pub const packages = struct {};\npub const root_deps: []const struct { []const u8, []const u8 } = &.{};\n' > "$HP/dependencies.zig"
# Both runs also export std's ZIR (ZIG_ZIR_EXPORT_DIR, see below).
rm -rf "$CARD_DIR$LIB_ON_CARD/zir"
for run in 1 2; do
  (cd "$HP" && rm -rf cache && ZIG_LIB_DIR="$CARD_DIR$LIB_ON_CARD" ZIG_IP_HINTS="$HP/ip-hints-configurer" \
    ZIG_ZIR_EXPORT_DIR="$CARD_DIR$LIB_ON_CARD/zir" \
    "$WORK/host-st/bin/zig" build-exe -ofmt=c -target thumb-linux-musleabi -mcpu cortex_m33 -OReleaseSmall \
    -fsingle-threaded -lc --dep @build --dep @dependencies \
    -Mroot="$CARD_DIR$LIB_ON_CARD/compiler/configurer.zig" -M@dependencies=dependencies.zig -M@build=build.zig \
    --name configurer --cache-dir cache --global-cache-dir cache -femit-bin=cache/configurer.c)
done
install -m 644 "$HP/ip-hints-configurer" "$CARD_DIR$LIB_ON_CARD/tcc/yasos/ip-hints-configurer"

# std's ZIR, lowered here and shipped in the lib (lib/zir/): the device then never parses
# std, whose biggest files do not fit the free runs an 8 MB machine without an MMU has
# mid-compile (Io/Threaded.zig: 834 KB of source, a 1.3 MB AST).  Named by file, compiler
# version and lowering options (Zcu.shippedZirDigest), so every kind of compile the device
# runs is lowered once: the configurer above, programs for YasOS in Debug and
# ReleaseSmall, and freestanding ones (a bootloader).
echo "zig: std's ZIR for the card"
cat > "$HP/src/main.zig" <<'ZIG'
const std = @import("std");
pub fn main() void {
    std.debug.print("hello\n", .{});
}
ZIG
cat > "$HP/src/free.zig" <<'ZIG'
const std = @import("std");
export fn _start() callconv(.c) noreturn {
    var x: u32 = 0;
    while (true) x = std.math.rotl(u32, x +% 1, 3);
}
pub const panic = std.debug.no_panic;
ZIG
for args in "-target thumb-linux-musleabi -lc -ODebug src/main.zig" \
            "-target thumb-linux-musleabi -lc -OReleaseSmall src/main.zig" \
            "-target thumb-freestanding-eabi -OReleaseSmall src/free.zig" \
            "-target thumb-freestanding-eabi -ODebug src/free.zig"; do
  (cd "$HP" && rm -rf cache && ZIG_LIB_DIR="$CARD_DIR$LIB_ON_CARD" ZIG_ZIR_EXPORT_DIR="$CARD_DIR$LIB_ON_CARD/zir" \
    "$WORK/host-st/bin/zig" build-exe -ofmt=c -mcpu cortex_m33 -fsingle-threaded $args \
    --cache-dir cache --global-cache-dir cache -femit-bin=cache/out.c)
done
echo "zig: $(ls "$CARD_DIR$LIB_ON_CARD/zir" | wc -l) ZIR files, $(du -sh "$CARD_DIR$LIB_ON_CARD/zir" | cut -f1)"
echo "zig: done ($(stat -c %s "$WORK/zig") bytes; lib $(du -sb "$CARD_DIR$LIB_ON_CARD" | cut -f1) bytes for the card)"
