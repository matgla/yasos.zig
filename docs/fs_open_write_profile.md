# `open`, `write` and `close` — where the time is, and what was removed

**Status (2026-08-10):** measured on the RP2350 rig at 532 MHz, `--profile`
build. Follows `docs/syscall_path_profile.md`, which established that the
syscall *path* is ~1% of syscall time and the handlers are the other 99%. This
is the other 99%.

What landed, each measured:

| Change | Effect |
|---|---|
| romfs entry: one read, no allocation | reads per directory entry 6 -> 1, allocations 1 -> 0 |
| romfs walk steps in place, no struct copies | romfs lookup 84 us -> 57 us |
| block-layer attribution (`diskprof`) | found the write cost, and refuted the first fix for it |
| contiguous writes combined into one multi-block command | `write` 3.28 ms -> 1.94 ms; sequential 512-byte writes 7x faster |

Net: a romfs open is ~22% cheaper, a failed romfs lookup **53%** cheaper, and a
tcc compile's syscall time falls from 10.50 ms to **8.90 ms** (36.1% -> 30.6% of
its run).

What is left on the write side is four single-block commands at ~875 us each,
and the card is not a measurable part of that -- it is the driver's own
per-command setup and teardown, which is where the next work belongs; see
below.

## How to reproduce

```bash
scripts/remote_smoke_tui.py --profile --pytest-args \
    "tests/smoke/io_profile_test.py -m measure -s -k open_cost_by_directory"
```

The `openprof` line now carries the attribution the fixes were found with:

    openprof pid=2 calls=1 misses=0 resolve_us=.. lookup_us=.. attach_us=..
             rf_hdrs=.. rf_reads=.. rf_allocs=.. rf_hdr_us=..
             kheap=../..us mount_us=.. fsget_us=.. walk_us=.. node_us=..

and `diskprof` splits write()/close() into the card's own time:

    diskprof pid=2 writes=7/7blk/6130us cardwait=10us reads=1/4blk/280us

## The open path

`io_profile_test.py::test_profile_open_cost_by_directory`, best case (romfs,
XIP, small directory, warm), tracked through the three states:

| | open | lookup | entry reads | allocs | walk |
|---|---|---|---|---|---|
| before | 154-166 us | 137 us | 57 | 10 | — |
| one read per entry | 143 us | 110-117 us | 10 | 0 | 84 us |
| walking in place | **120-125 us** | **89-93 us** | 10 | 0 | **57 us** |

and the failed-probe case, which is what a library or include search is made of:

| romfs MISS at depth 3 | open | lookup | entry reads |
|---|---|---|---|
| before | 594-603 us | 594 us | 453 |
| now | **276-280 us** | 265-268 us | 80 |

**A failed romfs lookup is 53% cheaper**; a hit is ~22% cheaper.

### What was wrong, in order of how it was found

The attribution had to be built before anything could be fixed, and the first
two hypotheses were wrong — worth recording, because both were plausible.

**1. Reads and allocations per directory entry (real, but not the biggest).**
`FileHeader.init` read the same 32 bytes of memory-mapped XIP flash about six
times: `FileReader.init` seeking and reading to find where the name ended, a
separate seek+read for each of three `u32` fields, and `read_string` copying the
name onto the kernel heap so the caller could compare it and free it again.
`next()` then re-read the word `init` had already parsed. One 32-byte read now
covers the fixed header and the name, the name lives in the header rather than
on the heap, and the next-entry offset is kept from the parse.

Counters confirmed the mechanism exactly (57 reads and 10 allocations for a
two-component path). But removing 82% of the reads took only 20% off the
lookup — so this was not where the time was.

**2. The kernel heap (refuted).** Ten to twelve allocations per open, 16-21 us
total. Not it.

**3. Struct copies (real, and the bigger half).** With reads and heap excluded,
`fs.get` was 102 us of a 114 us lookup and only 26 us of that was entry reads.
`FileHeader` is ~120 bytes, and `next()` returned one *by value* per entry
stepped over: the walk compiled to nine `__aeabi_memcpy8` calls against a
byte/word copy that bounds-checks its pointers as it goes. `step_to_next` now
loads the next entry over the existing header, so scanning a directory copies
nothing.

### What is left

For the warm romfs hit: lookup 89 us = mount 6 + `fs.get` 76 (walk 57 + node
16). The walk's 57 us against 10 entries is 5.7 us an entry, of which 2.9 us is
the entry read itself. The remainder is loop and interface overhead executing
from XIP flash — `get_file_header`, `FileHeader.init` and `__aeabi_memcpy8` all
live at `0x1001xxxx`. Moving them to `.time_critical` is the same lever that
took syscall dispatch 5.5x down (see `docs/syscall_path_profile.md`), and is the
obvious next thing to try; it costs kernel RAM, so measure before keeping it.

The FAT rows are unchanged by this work and remain the territory of
`docs/vfs_lookup_cache_plan.md`.

## The write/close path

For `tcc -O0 hello.c` the two costliest syscalls were `write` (16 calls,
3.28 ms) and `close` (9 calls, 2.61 ms) — 5.89 ms of a 28.8 ms run, on 1460
bytes of output. That is not bandwidth; it is per-operation cost. The block
counters say where:

    disk: 7 writes / 7 blk in 5.96ms, 1 reads / 4 blk in 0.28ms

**851 us per single-block write**, and the 5.96 ms of block time accounts for
essentially all of the 5.89 ms the two syscalls cost. Against that, the wire
time for a 512-byte block is ~21 us (measured 2026-08-06, recorded in
`sdio_write`). So a write costs ~40x its own transfer, and the question is what
the rest is.

### The obvious answer was wrong

`sdio_write` waits for the card to finish its internal program cycle before
returning, which looked like the whole story: nothing needs the card idle until
the *next* thing asked of it, and both `sdio_read` and `sdio_write` already open
every chunk with `wait_for_card_dat0()`, so the trailing wait is redundant with
the next operation's leading one. Deferring it should have taken ~800 us off
every write.

It changed nothing — 5.96 ms before, 6.12 ms after, on the same seven writes.
Splitting the wait out of the measurement said why:

    disk: 7 writes / 7 blk in 6.13ms (card wait 0.01ms)

**The card was idle 99.8% of the time** by the point that wait was reached. The
change was reverted — it moved no time — and the counter that showed why is
kept. The reason it was idle turned out to be the interesting part; see below.

### Where it actually is: inside the PIO

The wait was not missing, it was in a different place. The TX PIO program will
not report a write until the card releases DAT0:

    wait_idle:
        jmp pin, done   side 0   ; Wait for card to indicate idle condition
        jmp wait_idle   side 1
    done:
        push            side 0   ; Push the response token

(`sdio_rp2350.pio`, `sdio_data_tx_hs`.) So the card's program cycle is paid
*inside* `write_sdio_data`, per command — which is why `wait_for_card_dat0`
afterwards found the card already idle and deferring it changed nothing. The
original reading was right; the instrument was in the wrong place.

Since the cost is per *command*, the lever is fewer and larger commands. The
same card does ~113 us a block inside a multi-block write against 875 us for a
single-block one — roughly 8x.

### The fix: combine writes before they reach the card

FatFs hands the block layer one sector at a time, and the DiskWrapper cache was
write-through, so each one became its own command. But a compile's writes are
not scattered. Traced:

    diskw sector=1200 count=1
    diskw sector=1201 count=1
    diskw sector=1202 count=1
    diskw sector=1200 count=1     <- rewrite
    diskw sector=96   count=1     <- FAT
    diskw sector=3200 count=1     <- directory
    diskw sector=3200 count=1     <- rewrite

`write_combined` now holds one contiguous run (8 sectors, 4 KiB) and issues it
as a single multi-block write. A write that continues the run is appended; one
that lands inside it overwrites in place and costs nothing; anything else
flushes the run and starts a new one. Reads that overlap the buffer flush it
first, and `CTRL_SYNC` — a no-op until now — is the flush that makes FatFs's
"the volume is consistent" true. FatFs calls it from `f_close`, `f_sync`,
`f_unlink`, `f_mkdir` and `f_rename`, which is what makes this safe.
`invalidate` (mount, reformat) drops the buffer rather than writing it: what it
holds describes a volume that is no longer on the card.

Measured, `tcc -O0 hello.c`:

| | before | after |
|---|---|---|
| disk writes | 7 commands / 6.10 ms | **5 commands / 4.56 ms** |
| `write` syscall total | 3.28 ms | **1.94 ms** |
| syscalls, whole compile | 10.50 ms (36.1% of run) | **8.86 ms (30.5%)** |

and on `sdbench`, against the references in `sd_write_perf_test.py`:

| pass | reference | now |
|---|---|---|
| seq_write 512 B | 376 KiB/s | **2701 KiB/s** |
| seq_write 4 KiB | 2139 KiB/s | 2642 KiB/s |
| seq_write 32 KiB | 3514 KiB/s | 4539 KiB/s |
| rand_write 512 B | 368 KiB/s | 524 KiB/s |

**Sequential single-sector writes are 7x faster**, because they now reach the
card as 4 KiB runs.

### Deferring the card's program cycle: done correctly, and it is not the cost

With combining done, the floor is four single-block commands at ~875 us each.
The natural reading is that this is the card's program cycle, which the TX PIO
program waits out before reporting the block (`wait_idle` in
`sdio_rp2350.pio`). Two attempts were made to stop waiting for it. The first was
buggy; the second worked, and showed the premise was wrong.

**First attempt (buggy, proves nothing).** A flag word appended to the CRC/end
tokens, pulled with `out X, 1` and tested with `jmp !X`. It never took effect
and corrupted multi-block writes. `tx_loop` is driven by X = `8 + 2*blocksize +
16 + 1 - 1` = 1048 for a 512-byte block, consuming 1049 nibbles = 4196 bits,
while the words handed to the state machine are start token (1) + data (128) +
CRC/end (3) = 132 words = 4224 bits. **28 bits of the end token are still in the
OSR**, so `out X, 1` read the leftover `0xFFFFFFFF` instead of autopulling, X was
always 1, and the wait was always taken. The unconsumed flag word then sat in the
TX FIFO and shifted the next block's stream by a word -- the corrupted 4096-byte
write, the retries, and 39 ms of card wait. The data stream is the wrong channel
for this: the program does not end on a word boundary and
`sdio_start_next_block_tx` does not clear the FIFO between blocks.

**Second attempt (correct).** Two extra PIO programs, `sdio_data_tx_nowait` and
`sdio_data_tx_hs_nowait`, identical to their counterparts minus the two
`wait_idle` instructions, selected by the offset passed to `pio_sm_init`. The
driver already loads one data program at a time, so this is a variant choice in
`load_pio_data_tx_program`, plus a guard in `rp2350_sdio_tx_start` so a
continuation cannot silently reuse the wrong variant. Enabled only for genuine
single-block writes, which is where the cost is and which need no
block-to-block readiness.

It worked -- 15/15 on the rig, no corruption -- and that settles a question worth
recording: **`rp2350_sdio_stop()` is safe to run while the card is still driving
DAT0 busy.** It also settles the bigger one:

| run | disk write time | card wait |
|---|---|---|
| wait in the PIO | 4.62, 4.56, 4.61, 4.64, **4.45** ms | 0.01 ms |
| wait removed, 4 of 5 writes | **4.44** ms | 0.01 ms |

The no-wait figure sits inside the run-to-run band of the unmodified driver, so
**removing the wait saved nothing measurable at all.** It first looked like a
180 us win against a single 4.62 ms baseline; repeating the baseline after the
revert gave 4.45 ms and dissolved it.

So the card's program cycle is below the noise floor of a ~875 us command, and
essentially all of that command is host-side driver work -- program swapping
between the command and data state machines, `pio_sm_init`, DMA configuration,
the double abort spin in `rp2350_sdio_stop`, and the software CRC16 over the
block.

The change was reverted: it buys nothing measurable, and two more PIO programs
plus variant swapping in this driver is not a free thing to carry. It is easy to
reinstate if the trade ever looks different.

What it leaves behind is a much better target. The per-command cost is not the
card and not FatFs; it is the driver's own setup and teardown, it is ~95% of a
single-block write, and going after it needs no PIO changes and risks no data.
Instrument `send_sdio_command`, `rp2350_sdio_tx_start` and `rp2350_sdio_stop`
separately before changing any of them -- the same method that found everything
above, and that would have caught the mis-attribution here two attempts earlier.

That change also invalidated a gate. `sd_write_perf_test.py` detected a lost
CMD25 path by the *ratio* of the 32 KiB rate to the 512-byte rate; combining
lifts the denominator to the same speed as the numerator, so every ratio
collapsed to ~1.0 on a change that made writes seven times faster. The ratios
are replaced by a floor on the 512-byte rate itself, which separates "combined"
(2700) from "one command per sector" (376) with 2.7x of margin either side.
