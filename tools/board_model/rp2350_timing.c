/*
 * rp2350_timing: a QEMU TCG plugin that charges an RP2350 board's costs to
 * the guest and shows the guest its modeled clock.
 *
 * The board runs code and read-only data out of flash and spills process
 * heaps into PSRAM; both sit behind the one XIP cache in front of the QSPI
 * memory interface, and a miss there costs a QSPI transaction, ~100+ core
 * cycles at 532 MHz.  On-chip SRAM costs nothing extra.  QEMU's mps3-an524 has
 * no such thing, so profiles taken on it weigh every byte the same.
 *
 * Model:
 *   cycles = insns * cpi
 *          + per XIP access: hit cycles, or miss cycles (a line fill), plus
 *            writeback cycles when the evicted line is dirty (PSRAM only;
 *            flash lines are never written)
 *   Instruction fetches from XIP regions go through the cache by 8-byte line
 *   (one lookup per line a translation block covers, per execution); data
 *   accesses by address.  Everything else (SRAM, MMIO) is free beyond cpi.
 *
 * The guest sees modeled time through a u64 of nanoseconds at `clock=ADDR`
 * (the kernel's yasos_modeled_clock_ns, hal/source/arm/qemu_mps3/source/time.zig),
 * rewritten every `quantum` instructions; a kernel built with the modeled
 * clock reads it instead of its hardware timer.  Idle time (WFI) is added
 * from host time so timeouts still expire.
 *
 * Idle time (WFI) counts only while every vCPU is idle.
 *
 * Args (all optional except clock; defaults are the 2026-10-07 calibration
 * against a Pimoroni Pico Plus 2 at 532 MHz, scripts/board_model.py calibrate):
 *   clock=ADDR            guest address of the u64 ns word
 *   flash=LO:HI           XIP flash region (repeatable, max 4), half-open
 *   psram=LO:HI           PSRAM region (repeatable, max 4)
 *   nocache=LO:HI         PC range whose PSRAM stores are uncached (the page clear)
 *   mhz=532               core clock
 *   cpi_milli=2203        cycles per instruction, x1000
 *   hit=0                 cycles for an XIP cache hit
 *   imiss=122 dmiss=84    cycles for a line fill: instruction fetch, data
 *   wb=0                  cycles for a dirty writeback
 *   ucw=178               cycles for an uncached PSRAM store
 *   cache_kb=16 ways=2 line=8
 *   quantum=2000          instructions between clock updates
 *   pcprof=FILE           at exit write "pc,insns,extra_cycles,fetch_cycles" per guest PC: what
 *                         each instruction ran and the stalls it caused (a fetch
 *                         stall goes to the first instruction of its block)
 *   dprof=FILE            at exit write "page,reads,writes,read_miss,write_miss" per
 *                         4 KiB data page: how concentrated the misses are
 *   watch=LO:HI           log each new lowest address written in the range and the PC
 *                         that wrote it, to see what makes a stack as deep as it is
 *   watchskip=LO:HI       (up to four) ...ignoring writes from these PCs (memset, painting a new stack)
 *                         At exit, log the code-looking words on the stack as it stood at
 *                         its deepest: return addresses, so the call chain that got there.
 *   allocprof=FILE        at exit write accesses and misses per allocation site. The
 *                         guest declares its allocations through a port: the word it
 *                         first stores ALLOCPROF_HELLO to, then for each event
 *                         1<<28|site, address, size (alloc) or 2<<28, address (free).
 *   fast=FILE             what if these were in SRAM: sorted "lo hi" lines of hex, free of
 *                         XIP costs (selfhost_profile.py run --fast)
 *   callers=FILE          hex entry PCs, whose callers to count, ...
 *   callers_out=CSV       ... written at exit (selfhost_profile.py callers)
 *   attr=ENTRY:ZERO:LOOP  count runs of a block by who called what, see on_callee
 */

#include <glib.h>
#include <inttypes.h>
#include <pthread.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

#define MAX_REGIONS 4

typedef struct
{
  uint64_t lo, hi;
} Region;

static Region flash_r[MAX_REGIONS], psram_r[MAX_REGIONS], nocache_pc;
static int n_flash, n_psram;

static uint64_t clock_addr;
static uint64_t mhz = 532, cpi_milli = 2203, hit_c = 0, imiss_c = 122, dmiss_c = 84, wb_c = 0, ucw_c = 178;
static uint64_t quantum = 2000;
static unsigned cache_kb = 16, ways = 2, line_bytes = 8;

/* cache state: sets x ways, tag (line address) + dirty + lru age */
static unsigned n_sets, line_shift;
static uint64_t *tags;
static uint8_t *dirty;
static uint32_t *age;
static uint32_t tick;

/* statistics */
static uint64_t extra_cycles;
static uint64_t st_ifetch_hit, st_ifetch_miss, st_dread_hit, st_dread_miss, st_dwrite_hit, st_dwrite_miss,
    st_wb, st_flash_data, st_psram_data, st_uncached_w;
static uint64_t idle_ns, idle_since_host_ns;

/* One per guest PC, shared by every translation of it. */
typedef struct
{
  uint64_t pc, insns, extra, fetch;
  int uncached; /* a store from the uncached page clear */
} PcStat;
static Region watch_r, watch_skip[4];
static int watch_skip_count;

static bool watch_pc_skipped(uint64_t pc)
{
  for (int i = 0; i < watch_skip_count; i++)
    if (pc >= watch_skip[i].lo && pc < watch_skip[i].hi)
      return true;
  return false;
}
static uint64_t clear_next, clear_len, clear_hist[32], clear_bytes[32];
static uint64_t watch_low;
static uint32_t *watch_shadow, *watch_snap;
static uint64_t watch_snap_low;
static const char *pcprof_path;
static const char *dprof_path;
typedef struct
{
  uint64_t reads, writes, read_miss, write_miss;
} DataPage;
#define DATA_PAGES (1u << 20) /* a 32-bit address space by 4 KiB */
static DataPage *data_pages;

#define ALLOCPROF_HELLO 0xA110C8EDu
#define ALLOC_SITES 4096u
#define SITE_OTHER_SRAM (ALLOC_SITES - 1) /* not declared: stacks, images, other processes */
#define SITE_OTHER_PSRAM (ALLOC_SITES - 2)
#define ALLOC_GRANULES (1u << 29) /* a 32-bit address space by 8 B; touched lazily */
typedef struct
{
  uint64_t fast_accesses, slow_reads, slow_writes, read_miss, write_miss;
  uint64_t allocs, bytes, live, peak_live, max_size;
} AllocSite;
static const char *allocprof_path;
static AllocSite *alloc_sites;
static uint16_t *granule_site; /* site + 1 */
static uint32_t *granule_size; /* at an allocation's first granule */
static uint64_t alloc_port;
static uint32_t port_state[3];
static unsigned port_fill;

static void allocprof_event(uint32_t word)
{
  port_state[port_fill++] = word;
  unsigned kind = port_state[0] >> 28;
  uint64_t g = port_fill > 1 ? port_state[1] >> 3 : 0;
  if (kind == 2 && port_fill == 2)
  {
    port_fill = 0;
    if (!granule_size[g])
      return;
    AllocSite *s = &alloc_sites[granule_site[g] - 1];
    uint64_t n = (granule_size[g] + 7) >> 3;
    s->live -= granule_size[g];
    granule_size[g] = 0;
    for (uint64_t i = 0; i < n; i++)
      granule_site[g + i] = 0;
  }
  else if (kind == 1 && port_fill == 3)
  {
    port_fill = 0;
    uint32_t site = port_state[0] & (ALLOC_SITES - 1);
    uint32_t size = port_state[2];
    AllocSite *s = &alloc_sites[site];
    uint64_t n = (size + 7) >> 3;
    granule_size[g] = size;
    for (uint64_t i = 0; i < n; i++)
      granule_site[g + i] = (uint16_t)(site + 1);
    s->allocs++;
    s->bytes += size;
    s->live += size;
    if (s->live > s->peak_live)
      s->peak_live = s->live;
    if (size > s->max_size)
      s->max_size = size;
  }
  else if (kind != 1 && kind != 2)
    port_fill = 0;
}

static AllocSite *allocprof_site_of(uint64_t vaddr, int fast)
{
  uint16_t s = granule_site[(vaddr >> 3) & (ALLOC_GRANULES - 1)];
  return &alloc_sites[s ? s - 1u : (fast ? SITE_OTHER_SRAM : SITE_OTHER_PSRAM)];
}
/* open addressing, keyed by PC; QEMU's static glib exports no hash table */
#define PC_STATS_SIZE (1u << 21)
static PcStat **pc_stats;

static struct qemu_plugin_scoreboard *sb;
static qemu_plugin_u64 sb_quantum;
static uint64_t total_insns; /* folded in at every quantum */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t host_ns(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

enum
{
  KIND_NONE,
  KIND_FLASH,
  KIND_PSRAM
};

/* fast=FILE: what would moving these to SRAM buy?  Sorted "lo hi" lines of hex. */
#define MAX_FAST 4096
static uint64_t fast_lo[MAX_FAST], fast_hi[MAX_FAST];
static int n_fast;

static int fast_load(const char *path)
{
  FILE *f = fopen(path, "r");
  unsigned long long lo, hi;
  if (!f)
    return -1;
  while (n_fast < MAX_FAST && fscanf(f, "%llx %llx", &lo, &hi) == 2)
  {
    fast_lo[n_fast] = lo;
    fast_hi[n_fast++] = hi;
  }
  fclose(f);
  return 0;
}

static int region_kind(uint64_t a)
{
  for (int l = 0, h = n_fast - 1; l <= h;)
  {
    int m = (l + h) / 2;
    if (a < fast_lo[m])
      h = m - 1;
    else if (a >= fast_hi[m])
      l = m + 1;
    else
      return KIND_NONE;
  }
  for (int i = 0; i < n_psram; i++)
    if (a >= psram_r[i].lo && a < psram_r[i].hi)
      return KIND_PSRAM;
  for (int i = 0; i < n_flash; i++)
    if (a >= flash_r[i].lo && a < flash_r[i].hi)
      return KIND_FLASH;
  return KIND_NONE;
}

/* One access to the line holding `addr`; returns the cycles it costs. */
static uint64_t cache_access(uint64_t addr, int is_write, uint64_t miss_c, int *hit_out)
{
  uint64_t lineaddr = addr >> line_shift;
  unsigned set = (unsigned)(lineaddr & (n_sets - 1));
  uint64_t *t = &tags[set * ways];
  uint8_t *d = &dirty[set * ways];
  uint32_t *a = &age[set * ways];
  tick++;
  for (unsigned w = 0; w < ways; w++)
    if (t[w] == lineaddr + 1)
    {
      a[w] = tick;
      if (is_write)
        d[w] = 1;
      *hit_out = 1;
      return hit_c;
    }
  unsigned victim = 0;
  for (unsigned w = 1; w < ways; w++)
    if (t[w] == 0 || (t[victim] != 0 && a[w] < a[victim]))
      victim = w;
  uint64_t c = miss_c;
  if (t[victim] && d[victim])
  {
    c += wb_c;
    st_wb++;
  }
  t[victim] = lineaddr + 1;
  d[victim] = (uint8_t)(is_write != 0);
  a[victim] = tick;
  *hit_out = 0;
  return c;
}

/* Drop the line holding `addr` without writing it back: the board's
 * maintenance-interface invalidate, ahead of a write through the uncached
 * mirror. */
static void cache_invalidate(uint64_t addr)
{
  uint64_t lineaddr = addr >> line_shift;
  unsigned set = (unsigned)(lineaddr & (n_sets - 1));
  for (unsigned w = 0; w < ways; w++)
    if (tags[set * ways + w] == lineaddr + 1)
    {
      tags[set * ways + w] = 0;
      dirty[set * ways + w] = 0;
    }
}

static uint64_t modeled_ns(void)
{
  uint64_t insns = total_insns;
  uint64_t cycles = insns * cpi_milli / 1000 + extra_cycles;
  return cycles * 1000 / mhz + idle_ns;
}

static void publish_clock(void)
{
  uint64_t ns = modeled_ns();
  GByteArray data = {.data = (guint8 *)&ns, .len = sizeof(ns)};
  qemu_plugin_write_memory_vaddr(clock_addr, &data);
}

/* every `quantum` instructions */
static void on_quantum(unsigned int cpu_index, void *udata)
{
  pthread_mutex_lock(&lock);
  uint64_t q = qemu_plugin_u64_get(sb_quantum, cpu_index);
  total_insns += q;
  qemu_plugin_u64_set(sb_quantum, cpu_index, 0);
  publish_clock();
  pthread_mutex_unlock(&lock);
}

typedef struct
{
  PcStat *first;
  unsigned n_lines;
  uint64_t lines[]; /* line-aligned fetch addresses in XIP regions */
} TbFetch;

static void on_tb_fetch(unsigned int cpu_index, void *udata)
{
  TbFetch *f = udata;
  pthread_mutex_lock(&lock);
  for (unsigned i = 0; i < f->n_lines; i++)
  {
    int hit;
    uint64_t c = cache_access(f->lines[i], 0, imiss_c, &hit);
    extra_cycles += c;
    f->first->extra += c;
    f->first->fetch += c;
    if (hit)
      st_ifetch_hit++;
    else
      st_ifetch_miss++;
  }
  pthread_mutex_unlock(&lock);
}

static void on_mem(unsigned int cpu_index, qemu_plugin_meminfo_t info, uint64_t vaddr, void *udata)
{
  PcStat *st = udata;
  int kind = region_kind(vaddr);
  if (watch_r.hi && vaddr >= watch_r.lo && vaddr < watch_r.hi && qemu_plugin_mem_is_store(info) &&
      !watch_pc_skipped(st->pc))
  {
    size_t words = (watch_r.hi - watch_r.lo) / 4;
    if (!watch_shadow)
    {
      watch_shadow = calloc(words, 4);
      watch_snap = calloc(words, 4);
    }
    if (qemu_plugin_mem_size_shift(info) == 2)
      watch_shadow[(vaddr - watch_r.lo) / 4] = qemu_plugin_mem_get_value(info).data.u32;
    if (!watch_low || vaddr < watch_low)
    {
      char line[64];
      watch_low = vaddr;
      watch_snap_low = vaddr;
      memcpy(watch_snap, watch_shadow, words * 4);
      snprintf(line, sizeof(line), "WATCH %" PRIu64 " pc 0x%" PRIx64 "\n", watch_r.hi - vaddr, st->pc);
      qemu_plugin_outs(line);
    }
  }
  if (alloc_sites)
  {
    pthread_mutex_lock(&lock);
    if (qemu_plugin_mem_is_store(info) && qemu_plugin_mem_size_shift(info) == 2)
    {
      uint32_t value = qemu_plugin_mem_get_value(info).data.u32;
      if (!alloc_port && value == ALLOCPROF_HELLO)
        alloc_port = vaddr;
      else if (vaddr == alloc_port)
      {
        allocprof_event(value);
        pthread_mutex_unlock(&lock);
        return;
      }
    }
    if (kind == KIND_NONE)
    {
      if ((vaddr >> 28) != 4 && (vaddr >> 28) != 5) /* not MMIO */
        allocprof_site_of(vaddr, 1)->fast_accesses++;
    }
    pthread_mutex_unlock(&lock);
  }
  if (kind == KIND_NONE)
  {
    /* SRAM misses nothing, but dprof says what lives there */
    if (data_pages)
    {
      pthread_mutex_lock(&lock);
      DataPage *dp = &data_pages[(vaddr >> 12) & (DATA_PAGES - 1)];
      if (qemu_plugin_mem_is_store(info))
        dp->writes++;
      else
        dp->reads++;
      pthread_mutex_unlock(&lock);
    }
    return;
  }
  int is_write = qemu_plugin_mem_is_store(info);
  unsigned size = 1u << qemu_plugin_mem_size_shift(info);
  pthread_mutex_lock(&lock);
  if (st->uncached && is_write && kind == KIND_PSRAM)
  {
    /* a store from the uncached page clear; runs of them are one clear */
    if (vaddr != clear_next)
    {
      if (clear_len)
      {
        unsigned b = 0;
        while (b < 31 && (1ull << b) < clear_len)
          b++;
        clear_hist[b]++;
        clear_bytes[b] += clear_len;
      }
      clear_len = 0;
    }
    clear_next = vaddr + size;
    clear_len += size;
    for (uint64_t l = vaddr >> line_shift; l <= (vaddr + size - 1) >> line_shift; l++)
      cache_invalidate(l << line_shift);
    st_uncached_w++;
    extra_cycles += ucw_c;
    st->extra += ucw_c;
    pthread_mutex_unlock(&lock);
    return;
  }
  if (kind == KIND_FLASH)
    st_flash_data++;
  else
    st_psram_data++;
  /* an unaligned access may straddle two lines */
  uint64_t first = vaddr >> line_shift, last = (vaddr + size - 1) >> line_shift;
  for (uint64_t l = first; l <= last; l++)
  {
    int hit;
    uint64_t c = cache_access(l << line_shift, is_write && kind == KIND_PSRAM, dmiss_c, &hit);
    extra_cycles += c;
    st->extra += c;
    if (alloc_sites && kind == KIND_PSRAM)
    {
      AllocSite *as = allocprof_site_of(l << line_shift, 0);
      if (is_write)
      {
        as->slow_writes++;
        as->write_miss += !hit;
      }
      else
      {
        as->slow_reads++;
        as->read_miss += !hit;
      }
    }
    if (data_pages)
    {
      DataPage *dp = &data_pages[(l << line_shift >> 12) & (DATA_PAGES - 1)];
      if (is_write)
      {
        dp->writes++;
        dp->write_miss += !hit;
      }
      else
      {
        dp->reads++;
        dp->read_miss += !hit;
      }
    }
    if (is_write)
      hit ? st_dwrite_hit++ : st_dwrite_miss++;
    else
      hit ? st_dread_hit++ : st_dread_miss++;
  }
  pthread_mutex_unlock(&lock);
}

static PcStat *pc_stat(uint64_t pc)
{
  pthread_mutex_lock(&lock);
  unsigned i = (unsigned)(pc >> 1) & (PC_STATS_SIZE - 1);
  while (pc_stats[i] && pc_stats[i]->pc != pc)
    i = (i + 1) & (PC_STATS_SIZE - 1);
  if (!pc_stats[i])
  {
    PcStat *st = calloc(1, sizeof(*st));
    st->pc = pc;
    st->uncached = pc >= nocache_pc.lo && pc < nocache_pc.hi;
    pc_stats[i] = st;
  }
  PcStat *st = pc_stats[i];
  pthread_mutex_unlock(&lock);
  return st;
}

static void on_tb_exec_prof(unsigned int cpu_index, void *udata)
{
  PcStat **stats = udata;
  pthread_mutex_lock(&lock);
  for (; *stats; stats++)
    (*stats)->insns++;
  pthread_mutex_unlock(&lock);
}

/* ---- callers=FILE (hex entry PCs), callers_out=CSV: who runs these, as "callee,a,b,n".
   A block's last instruction is what got us to the next block: for a function's first
   block, that is the call.  Veneers and PLT stubs do not count: they end in bx ip or a
   load into pc, and the block before them is the call.  No registers: QEMU links glib
   statically and exports none of it.

   a = the caller, b = 0.  attr=ENTRY:ZERO:LOOP: count each run of LOOP (a block repeated
   inside ENTRY) instead, with a = who last called ENTRY, b = who last called ZERO. ---- */
#define MAX_CALLEES 256
#define MAX_EDGES (1u << 17)

typedef struct
{
  uint64_t callee, a, b, n;
} CallEdge;

static uint64_t callee_pc[MAX_CALLEES];
static int n_callees;
static const char *callers_out;
static CallEdge *call_edges;
static uint64_t last_end;
static uint64_t attr_entry, attr_zero, attr_loop, attr_entry_by, attr_zero_by;

static int callers_load(const char *path)
{
  FILE *f = fopen(path, "r");
  unsigned long long pc;
  if (!f)
    return -1;
  while (n_callees < MAX_CALLEES && fscanf(f, "%llx", &pc) == 1)
    callee_pc[n_callees++] = pc;
  fclose(f);
  call_edges = calloc(MAX_EDGES, sizeof(*call_edges));
  return 0;
}

static void on_block_end(unsigned int cpu_index, void *udata)
{
  last_end = (uint64_t)(uintptr_t)udata;
}

static int is_stub_end(const struct qemu_plugin_insn *insn)
{
  uint16_t hw[2] = {0, 0};
  size_t len = qemu_plugin_insn_data(insn, hw, sizeof(hw));
  if (len == 2)
    return hw[0] == 0x4760; /* bx ip */
  return (hw[0] & 0xfff0) == 0xf8d0 && (hw[1] & 0xf000) == 0xf000; /* ldr.w pc, [rn, #imm] */
}

static void on_callee(unsigned int cpu_index, void *udata)
{
  uint64_t callee = (uint64_t)(uintptr_t)udata, a = last_end, b = 0;
  if (attr_loop)
  {
    if (callee == attr_entry)
      attr_entry_by = a;
    else if (callee == attr_zero)
      attr_zero_by = a;
    if (callee != attr_loop)
      return;
    a = attr_entry_by;
    b = attr_zero_by;
  }
  uint64_t h = (callee * 11400714819323198485ull ^ a * 0x9E3779B97F4A7C15ull ^ b * 0xC2B2AE3D27D4EB4Full) >> 47;
  pthread_mutex_lock(&lock);
  for (unsigned i = 0; i < MAX_EDGES; i++)
  {
    CallEdge *e = &call_edges[(h + i) & (MAX_EDGES - 1)];
    if (!e->n)
    {
      *e = (CallEdge){callee, a, b, 1};
      break;
    }
    if (e->callee == callee && e->a == a && e->b == b)
    {
      e->n++;
      break;
    }
  }
  pthread_mutex_unlock(&lock);
}

static void callers_dump(void)
{
  FILE *f = call_edges && callers_out ? fopen(callers_out, "w") : NULL;
  if (!f)
    return;
  for (unsigned i = 0; i < MAX_EDGES; i++)
    if (call_edges[i].n)
      fprintf(f, "%" PRIx64 ",%" PRIx64 ",%" PRIx64 ",%" PRIu64 "\n", call_edges[i].callee, call_edges[i].a,
              call_edges[i].b, call_edges[i].n);
  fclose(f);
}

static void on_tb_trans(struct qemu_plugin_tb *tb, void *userdata)
{
  size_t n = qemu_plugin_tb_n_insns(tb);
  if (n_callees && n)
  {
    uint64_t start = qemu_plugin_insn_vaddr(qemu_plugin_tb_get_insn(tb, 0));
    struct qemu_plugin_insn *last = qemu_plugin_tb_get_insn(tb, n - 1);
    /* on_callee first: it must see the block before this one */
    for (int i = 0; i < n_callees; i++)
      if (callee_pc[i] == start)
        qemu_plugin_register_vcpu_tb_exec_cb(tb, on_callee, QEMU_PLUGIN_CB_NO_REGS, (void *)(uintptr_t)start);
    if (!is_stub_end(last))
      qemu_plugin_register_vcpu_tb_exec_cb(tb, on_block_end, QEMU_PLUGIN_CB_NO_REGS,
                                           (void *)(uintptr_t)qemu_plugin_insn_vaddr(last));
  }
  qemu_plugin_register_vcpu_tb_exec_inline_per_vcpu(tb, QEMU_PLUGIN_INLINE_ADD_U64, sb_quantum, n);
  qemu_plugin_register_vcpu_tb_exec_cond_cb(tb, on_quantum, QEMU_PLUGIN_CB_NO_REGS, QEMU_PLUGIN_COND_GE,
                                            sb_quantum, quantum, NULL);

  /* the XIP lines this block's instructions are fetched from */
  uint64_t lines[256];
  unsigned nl = 0;
  PcStat *first = NULL;
  PcStat **prof = pcprof_path ? calloc(n + 1, sizeof(*prof)) : NULL;
  for (size_t i = 0; i < n; i++)
  {
    struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
    uint64_t a = qemu_plugin_insn_vaddr(insn);
    size_t sz = qemu_plugin_insn_size(insn);
    if (region_kind(a) == KIND_FLASH || region_kind(a) == KIND_PSRAM)
      for (uint64_t l = a >> line_shift; l <= (a + sz - 1) >> line_shift; l++)
        if ((nl == 0 || lines[nl - 1] != (l << line_shift)) && nl < 256)
          lines[nl++] = l << line_shift;
    PcStat *st = pc_stat(a);
    if (!first)
      first = st;
    if (prof)
      prof[i] = st;
    qemu_plugin_register_vcpu_mem_cb(insn, on_mem, QEMU_PLUGIN_CB_NO_REGS, QEMU_PLUGIN_MEM_RW, st);
  }
  if (nl)
  {
    TbFetch *f = malloc(sizeof(TbFetch) + nl * sizeof(uint64_t));
    f->first = first;
    f->n_lines = nl;
    memcpy(f->lines, lines, nl * sizeof(uint64_t));
    qemu_plugin_register_vcpu_tb_exec_cb(tb, on_tb_fetch, QEMU_PLUGIN_CB_NO_REGS, f);
  }
  if (prof)
    qemu_plugin_register_vcpu_tb_exec_cb(tb, on_tb_exec_prof, QEMU_PLUGIN_CB_NO_REGS, prof);
}

/* Idle time counts only while every vCPU is idle: a second core parked in
 * WFI while the first compiles is not time the board spends waiting. */
static int idle_cpus;

static void on_idle(unsigned int cpu_index, void *udata)
{
  pthread_mutex_lock(&lock);
  if (++idle_cpus == qemu_plugin_num_vcpus())
    idle_since_host_ns = host_ns();
  pthread_mutex_unlock(&lock);
}

static void on_resume(unsigned int cpu_index, void *udata)
{
  pthread_mutex_lock(&lock);
  if (idle_since_host_ns)
    idle_ns += host_ns() - idle_since_host_ns;
  idle_since_host_ns = 0;
  if (idle_cpus > 0)
    idle_cpus--;
  pthread_mutex_unlock(&lock);
}

static void on_plugin_exit(void *p)
{
  callers_dump();
  uint64_t q = 0;
  for (int i = 0; i < qemu_plugin_num_vcpus(); i++)
    q += qemu_plugin_u64_get(sb_quantum, i);
  total_insns += q;
  uint64_t base = total_insns * cpi_milli / 1000;
  char buf[1024];
  snprintf(buf, sizeof(buf),
           "rp2350_timing: insns %" PRIu64 " base_cycles %" PRIu64 " extra_cycles %" PRIu64
           " modeled_ms %.1f (idle %.1f)\n"
           "rp2350_timing: ifetch hit %" PRIu64 " miss %" PRIu64 " | dread hit %" PRIu64 " miss %" PRIu64
           " | dwrite hit %" PRIu64 " miss %" PRIu64 " | writebacks %" PRIu64 " | data accesses flash %" PRIu64
           " psram %" PRIu64 " | uncached_w %" PRIu64 "\n",
           total_insns, base, extra_cycles, modeled_ns() / 1e6, idle_ns / 1e6, st_ifetch_hit, st_ifetch_miss,
           st_dread_hit, st_dread_miss, st_dwrite_hit, st_dwrite_miss, st_wb, st_flash_data, st_psram_data, st_uncached_w);
  qemu_plugin_outs(buf);
  for (int b = 0; b < 32; b++)
    if (clear_hist[b])
    {
      char line[96];
      snprintf(line, sizeof(line), "rp2350_timing: clears up to %" PRIu64 " KB: %" PRIu64 " times, %" PRIu64 " KB\n", (1ull << b) / 1024,
               clear_hist[b], clear_bytes[b] / 1024);
      qemu_plugin_outs(line);
    }
  if (watch_snap)
    for (uint64_t a = watch_snap_low & ~3ull; a < watch_r.hi; a += 4)
    {
      uint32_t w = watch_snap[(a - watch_r.lo) / 4];
      if ((w & 1) && ((w >> 28) == 1 || (w >> 28) == 6))
      {
        char line[64];
        snprintf(line, sizeof(line), "RET %" PRIu64 " 0x%x\n", watch_r.hi - a, w);
        qemu_plugin_outs(line);
      }
    }
  FILE *afp = allocprof_path ? fopen(allocprof_path, "w") : NULL;
  if (afp)
  {
    fprintf(afp, "site,fast_accesses,slow_reads,slow_writes,read_miss,write_miss,allocs,bytes,peak_live,max_size\n");
    for (unsigned i = 0; i < ALLOC_SITES; i++)
    {
      AllocSite *s = &alloc_sites[i];
      if (s->allocs || s->fast_accesses || s->slow_reads || s->slow_writes)
        fprintf(afp, "%u,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n",
                i, s->fast_accesses, s->slow_reads, s->slow_writes, s->read_miss, s->write_miss, s->allocs, s->bytes,
                s->peak_live, s->max_size);
    }
    fclose(afp);
  }
  FILE *dfp = dprof_path ? fopen(dprof_path, "w") : NULL;
  if (dfp)
  {
    fprintf(dfp, "page,reads,writes,read_miss,write_miss\n");
    for (unsigned i = 0; i < DATA_PAGES; i++)
      if (data_pages[i].reads || data_pages[i].writes)
        fprintf(dfp, "0x%x,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n", i << 12, data_pages[i].reads,
                data_pages[i].writes, data_pages[i].read_miss, data_pages[i].write_miss);
    fclose(dfp);
  }
  FILE *fp = pcprof_path ? fopen(pcprof_path, "w") : NULL;
  if (fp)
  {
    fprintf(fp, "pc,insns,extra_cycles,fetch_cycles\n");
    for (unsigned i = 0; i < PC_STATS_SIZE; i++)
    {
      PcStat *st = pc_stats[i];
      if (st && (st->insns || st->extra))
        fprintf(fp, "0x%" PRIx64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n", st->pc, st->insns, st->extra, st->fetch);
    }
    fclose(fp);
  }
}

static int parse_region(const char *v, Region *r)
{
  char *end;
  r->lo = strtoull(v, &end, 0);
  if (*end != ':')
    return -1;
  r->hi = strtoull(end + 1, &end, 0);
  return *end ? -1 : 0;
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info, int argc, char **argv)
{
  for (int i = 0; i < argc; i++)
  {
    char kbuf[64];
    const char *eq = strchr(argv[i], '=');
    if (!eq || (size_t)(eq - argv[i]) >= sizeof(kbuf))
      goto bad;
    memcpy(kbuf, argv[i], (size_t)(eq - argv[i]));
    kbuf[eq - argv[i]] = 0;
    const char *k = kbuf, *v = eq + 1;
    if (!strcmp(k, "clock"))
      clock_addr = strtoull(v, NULL, 0);
    else if (!strcmp(k, "flash") && n_flash < MAX_REGIONS && !parse_region(v, &flash_r[n_flash]))
      n_flash++;
    else if (!strcmp(k, "psram") && n_psram < MAX_REGIONS && !parse_region(v, &psram_r[n_psram]))
      n_psram++;
    else if (!strcmp(k, "nocache") && !parse_region(v, &nocache_pc))
      ;
    else if (!strcmp(k, "ucw"))
      ucw_c = strtoull(v, NULL, 0);
    else if (!strcmp(k, "mhz"))
      mhz = strtoull(v, NULL, 0);
    else if (!strcmp(k, "cpi_milli"))
      cpi_milli = strtoull(v, NULL, 0);
    else if (!strcmp(k, "hit"))
      hit_c = strtoull(v, NULL, 0);
    else if (!strcmp(k, "rmiss"))
      imiss_c = dmiss_c = strtoull(v, NULL, 0);
    else if (!strcmp(k, "imiss"))
      imiss_c = strtoull(v, NULL, 0);
    else if (!strcmp(k, "dmiss"))
      dmiss_c = strtoull(v, NULL, 0);
    else if (!strcmp(k, "wb"))
      wb_c = strtoull(v, NULL, 0);
    else if (!strcmp(k, "cache_kb"))
      cache_kb = (unsigned)strtoull(v, NULL, 0);
    else if (!strcmp(k, "ways"))
      ways = (unsigned)strtoull(v, NULL, 0);
    else if (!strcmp(k, "line"))
      line_bytes = (unsigned)strtoull(v, NULL, 0);
    else if (!strcmp(k, "quantum"))
      quantum = strtoull(v, NULL, 0);
    else if (!strcmp(k, "pcprof"))
      pcprof_path = strdup(v);
    else if (!strcmp(k, "watch") && !parse_region(v, &watch_r))
      ;
    else if (!strcmp(k, "watchskip") && (watch_skip_count == 4 || !parse_region(v, &watch_skip[watch_skip_count++])))
      ;
    else if (!strcmp(k, "fast"))
    {
      if (fast_load(v))
        goto bad;
    }
    else if (!strcmp(k, "callers"))
    {
      if (callers_load(v))
        goto bad;
    }
    else if (!strcmp(k, "callers_out"))
      callers_out = strdup(v);
    else if (!strcmp(k, "attr"))
    {
      unsigned long long entry, zero, loop;
      if (sscanf(v, "%llx:%llx:%llx", &entry, &zero, &loop) != 3)
        goto bad;
      attr_entry = entry;
      attr_zero = zero;
      attr_loop = loop;
    }
    else if (!strcmp(k, "allocprof"))
    {
      allocprof_path = strdup(v);
      alloc_sites = calloc(ALLOC_SITES, sizeof(*alloc_sites));
      granule_site = calloc(ALLOC_GRANULES, sizeof(*granule_site));
      granule_size = calloc(ALLOC_GRANULES, sizeof(*granule_size));
    }
    else if (!strcmp(k, "dprof"))
    {
      dprof_path = strdup(v);
      data_pages = calloc(DATA_PAGES, sizeof(*data_pages));
    }
    else
    {
    bad:
      fprintf(stderr, "rp2350_timing: bad option %s\n", argv[i]);
      return -1;
    }
  }
  if (!clock_addr || !mhz || !ways || !line_bytes || (line_bytes & (line_bytes - 1)))
  {
    fprintf(stderr, "rp2350_timing: need clock=ADDR and sane mhz/ways/line\n");
    return -1;
  }
  line_shift = (unsigned)__builtin_ctz(line_bytes);
  n_sets = cache_kb * 1024 / line_bytes / ways;
  if (n_sets & (n_sets - 1))
  {
    fprintf(stderr, "rp2350_timing: sets must be a power of two\n");
    return -1;
  }
  tags = calloc((size_t)n_sets * ways, sizeof(uint64_t));
  dirty = calloc((size_t)n_sets * ways, 1);
  age = calloc((size_t)n_sets * ways, sizeof(uint32_t));

  pc_stats = calloc(PC_STATS_SIZE, sizeof(*pc_stats));

  sb = qemu_plugin_scoreboard_new(sizeof(uint64_t));
  sb_quantum = qemu_plugin_scoreboard_u64(sb);

  qemu_plugin_register_vcpu_tb_trans_cb(id, on_tb_trans, NULL);
  qemu_plugin_register_vcpu_idle_cb(id, on_idle, NULL);
  qemu_plugin_register_vcpu_resume_cb(id, on_resume, NULL);
  qemu_plugin_register_atexit_cb(id, on_plugin_exit, NULL);
  return 0;
}
