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

static int region_kind(uint64_t a)
{
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
    extra_cycles += cache_access(f->lines[i], 0, imiss_c, &hit);
    if (hit)
      st_ifetch_hit++;
    else
      st_ifetch_miss++;
  }
  pthread_mutex_unlock(&lock);
}

static void on_mem(unsigned int cpu_index, qemu_plugin_meminfo_t info, uint64_t vaddr, void *udata)
{
  int kind = region_kind(vaddr);
  if (kind == KIND_NONE)
    return;
  int is_write = qemu_plugin_mem_is_store(info);
  unsigned size = 1u << qemu_plugin_mem_size_shift(info);
  pthread_mutex_lock(&lock);
  if (udata && is_write && kind == KIND_PSRAM)
  {
    /* a store from the uncached page clear */
    for (uint64_t l = vaddr >> line_shift; l <= (vaddr + size - 1) >> line_shift; l++)
      cache_invalidate(l << line_shift);
    st_uncached_w++;
    extra_cycles += ucw_c;
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
    extra_cycles += cache_access(l << line_shift, is_write && kind == KIND_PSRAM, dmiss_c, &hit);
    if (is_write)
      hit ? st_dwrite_hit++ : st_dwrite_miss++;
    else
      hit ? st_dread_hit++ : st_dread_miss++;
  }
  pthread_mutex_unlock(&lock);
}

static void on_tb_trans(struct qemu_plugin_tb *tb, void *userdata)
{
  size_t n = qemu_plugin_tb_n_insns(tb);
  qemu_plugin_register_vcpu_tb_exec_inline_per_vcpu(tb, QEMU_PLUGIN_INLINE_ADD_U64, sb_quantum, n);
  qemu_plugin_register_vcpu_tb_exec_cond_cb(tb, on_quantum, QEMU_PLUGIN_CB_NO_REGS, QEMU_PLUGIN_COND_GE,
                                            sb_quantum, quantum, NULL);

  /* the XIP lines this block's instructions are fetched from */
  uint64_t lines[256];
  unsigned nl = 0;
  for (size_t i = 0; i < n; i++)
  {
    struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
    uint64_t a = qemu_plugin_insn_vaddr(insn);
    size_t sz = qemu_plugin_insn_size(insn);
    if (region_kind(a) == KIND_FLASH || region_kind(a) == KIND_PSRAM)
      for (uint64_t l = a >> line_shift; l <= (a + sz - 1) >> line_shift; l++)
        if ((nl == 0 || lines[nl - 1] != (l << line_shift)) && nl < 256)
          lines[nl++] = l << line_shift;
    void *uncached = (a >= nocache_pc.lo && a < nocache_pc.hi) ? (void *)1 : NULL;
    qemu_plugin_register_vcpu_mem_cb(insn, on_mem, QEMU_PLUGIN_CB_NO_REGS, QEMU_PLUGIN_MEM_RW, uncached);
  }
  if (nl)
  {
    TbFetch *f = malloc(sizeof(TbFetch) + nl * sizeof(uint64_t));
    f->n_lines = nl;
    memcpy(f->lines, lines, nl * sizeof(uint64_t));
    qemu_plugin_register_vcpu_tb_exec_cb(tb, on_tb_fetch, QEMU_PLUGIN_CB_NO_REGS, f);
  }
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

  sb = qemu_plugin_scoreboard_new(sizeof(uint64_t));
  sb_quantum = qemu_plugin_scoreboard_u64(sb);

  qemu_plugin_register_vcpu_tb_trans_cb(id, on_tb_trans, NULL);
  qemu_plugin_register_vcpu_idle_cb(id, on_idle, NULL);
  qemu_plugin_register_vcpu_resume_cb(id, on_resume, NULL);
  qemu_plugin_register_atexit_cb(id, on_plugin_exit, NULL);
  return 0;
}
