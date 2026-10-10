# Yasld port in Zig 

## Relocated-image templates

Relocating an image on every exec repeats the same decisions each time: which
import resolves to which export, which GOT slot gets a thunk. Only the bases
move, because every process gets its own data region and thunk block.
`source/template.zig` records what a load wrote, and which base each word
moved with. The next load of the same image then copies data and GOT from the
image as usual and replays that list. Two sources:

- **RAM cache.** Filled by loads of romfs (XIP) images as they happen, in
  process-pool pages owned by pid -2, from the slow tier first. When an
  allocation finds the pool full, the pool's `reclaim_hook` drops the least
  recently used templates that no load is reading. `/proc/meminfo` reports
  them as `LoaderCache` and `LoaderCacheHits`.
- **Precache.** `build_rootfs.sh` runs `yasld-prelink` (`tools/`, built for a
  32-bit host with `zig build prelink`) over the staged rootfs. It runs this
  same loader and writes `/lib/yasld.cache`, which the kernel reads in place
  from flash. Entries are keyed by a hash of everything a template depends
  on: the header, the tables ahead of the code, and the initial GOT. A
  precache that does not match the images is ignored.

`verify_templates` in `loader.zig` is the debug check. Every hit is also
relocated in full and compared word by word.
