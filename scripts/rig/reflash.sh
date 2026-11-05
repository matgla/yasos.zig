#!/bin/bash
# reflash.sh ROOTFS_SHA KERNEL_SHA, on the rig, holding the board lock.  Same steps as
# remote_smoke_tui.py's flash, except that the rootfs is erased in 64 KiB chunks, each timed
# and retried: failing erases come in bursts ("failed erasing sectors").
#
# The hashes are checked at the start only and write_image reads the files later, so
# whoever calls this must keep them from changing: run_selfhost.sh checks again after.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REMOTE=${YASOS_RIG_REMOTE:-$HOME/yasos_remote_smoke}; W=$REMOTE/workdir; R=$W/rootfs.img; K=$W/yasos_kernel; ADDR=$((0x10100000))
[ "$(sha256sum < $R | cut -d' ' -f1)" = "$1" ] || { echo "rootfs sha mismatch"; exit 8; }
[ "$(sha256sum < $K | cut -d' ' -f1)" = "$2" ] || { echo "kernel sha mismatch"; exit 8; }
TCL=/tmp/yasos_reflash.tcl; SZ=$(stat -c %s $R); CH=$((64*1024))
{
cat <<'TCL'
set retries 0
set slow 0
proc erase_chunk {addr size} {
    global retries slow
    for {set i 1} {$i <= 6} {incr i} {
        set t0 [ms]
        set rc [catch {flash erase_address pad $addr $size} err]
        set dt [expr {[ms]-$t0}]
        if {$rc == 0} {
            if {$dt > 1000} { incr slow; echo [format "CHUNK 0x%08x try=%d %d ms" $addr $i $dt] }
            return
        }
        incr retries
        echo [format "CHUNK 0x%08x try=%d FAILED after %d ms" $addr $i $dt]
    }
    error [format "erase of 0x%08x failed 6 times" $addr]
}
TCL
  echo 'set t0 [ms]'
  for ((o=0; o<SZ; o+=CH)); do n=$((SZ-o<CH?SZ-o:CH)); printf 'erase_chunk 0x%x %d\n' $((ADDR+o)) $n; done
  echo 'echo [format "STEP rootfs erased in %.1fs retries=%d slow_chunks=%d" [expr {([ms]-$t0)/1000.0}] $retries $slow]'
  echo 'set t0 [ms]'
  printf 'flash write_image %s 0x%x bin\n' "$R" $ADDR
  echo 'echo [format "STEP rootfs written in %.1fs" [expr {([ms]-$t0)/1000.0}]]'
  echo 'set t0 [ms]'
  printf 'verify_image %s 0x%x bin\n' "$R" $ADDR
  echo 'echo [format "STEP rootfs verified in %.1fs" [expr {([ms]-$t0)/1000.0}]]'
  echo 'set t0 [ms]'
  echo "program $K verify"
  echo 'echo [format "STEP kernel flashed+verified in %.1fs" [expr {([ms]-$t0)/1000.0}]]'
} > $TCL
# Both cores: a running core 1 writes into the work area being programmed from (AGENTS.md).
openocd -f interface/cmsis-dap.cfg -f target/rp2350.cfg -c "adapter speed 8000" -c init -c "reset halt" -c "source $TCL" -c exit 2>&1 | grep -vE "^(Open On|Licensed|For bug|\s+http|Info : (CMSIS|Using|SWCLK|Hardware|Listening|starting)|cortex_m|0$)"
rc=${PIPESTATUS[0]}
echo "openocd rc=$rc"
[ $rc = 0 ] || exit $rc
mkdir -p $W/.artifact-state; echo "$2" > $W/.artifact-state/kernel.sha256; echo "$1" > $W/.artifact-state/rootfs.sha256
cd "$REMOTE" && workdir/venv/bin/python "$HERE/boot_check.py"
