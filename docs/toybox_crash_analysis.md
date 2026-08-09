# Toybox `ls` Crash Analysis

**Date started**: ~March 2026
**Status**: Root cause identified (idx=-1), investigating why stridx returns -1

---

## 1. Symptom

Running `ls` in toybox on yasos (ARM Cortex-M33, RP2350) crashes with a HardFault:

```
HardFault at PC=0x10369712 (parse_optflaglist+1934)
Instruction: ldr.w ip, [r1]   — loading opt->c
r1 = 0x08 (NULL + offsetof(struct opts, c))
opt = NULL
```

The crash occurs in the trailing-group parsing section of `parse_optflaglist()` in
`apps/toybox/lib/args.c`. The inner `for` loop walks all 40 option nodes without
finding a match for character 'C' (0x43), falls off the end, `opt` becomes NULL,
and dereferencing `opt->c` faults.

---

## 2. Root Cause Chain

```
stridx("-+!", *++options) returns -1
    ↓
idx = -1  (stored at [r7, #-12])
    ↓
CFG_TOYBOX_DEBUG=0, so guard `if (idx==-1) error_exit(...)` is compiled out
    ↓
opt->dex[idx] computes address: opt + 16 + (-1)*8 = opt + 8 = &opt->c
    ↓
opt->dex[idx] |= bits & ~ll   ORs garbage bits into opt->c field
    ↓
opt->c corrupted (e.g., 'C'=0x43 becomes 0x0C43)
    ↓
Character matching loop can't find 'C', walks all 40 nodes, opt=NULL → crash
```

### 2.1 Evidence

**GDB confirmation of idx=-1:**
```
>>> printf "idx = %d\n", *(int*)($r7-12)
idx = -1
```

**Hardware watchpoint on corrupted node 28 (c field at 0x1103e378):**
- Fired at PC=0x10369738, writing value 0xC43 instead of 0x43
- Store was to `[r12]` where r12=0x1103e378 = opt+8 (the c field, NOT dex[0])

**Corrupted nodes found by walking linked list (40 nodes total):**
| Node | Address    | Expected c | Actual c      | Corruption              |
|------|------------|-----------|---------------|-------------------------|
| 1    | 0x1103ea30 | 'x' (0x78)| 0x10000C78    | Upper bits OR'd in      |
| 10   | 0x1103e7b0 | 'o' (0x6F)| 0x1000086F    | Upper bits OR'd in      |
| 11   | 0x1103e778 | 'n' (0x6E)| 0x1000046E    | Upper bits OR'd in      |
| 28   | 0x1103e370 | 'C' (0x43)| 0x00000C43    | Extra bits OR'd in      |

---

## 3. Open Question: Why does stridx return -1?

The trailing groups in the ls option string are:
```
[-Cxm1][-Cxml][-Cxmo][-Cxmg][-cu][-ftS][-HL][-Nqb][-k\377]
```

Each group starts with `[`, then the FIRST character should be `-`, `+`, or `!`.
Indeed, all groups start with `[-`, so `stridx("-+!", '-')` should return 0.

### 3.1 stridx implementation (at 0x10370F14, file offset 0x8a34)

```asm
stridx:
  push    {r4, r5, lr}    ; save regs
  sub     sp, #4
  mov     r4, r0           ; r4 = string ("-+!")
  mov     r5, r1           ; r5 = character to find
  stmdb   sp!, {r9, r12}   ; save GOT ptr
  mov     r1, r5           ; r1 = char
  mov     r0, r4           ; r0 = string
  bl      __tcc_strchr      ; call strchr(string, char)
  ldmia   sp!, {r9, r12}   ; restore GOT ptr
  cmp     r0, #0           ; result == NULL?
  bne     .found
  movw    r0, #0xffff      ; return -1
  movt    r0, #0xffff
  b       .done
.found:
  subs    r0, r0, r4       ; return (result - string) = index
.done:
  add     sp, #4
  pop     {r4, r5, pc}
```

### 3.2 __tcc_strchr (at 0x103a989c)

```asm
__tcc_strchr:
  stmdb   sp!, {r4, r12}
  mov     r2, r0           ; r2 = string pointer
  ldrb    r3, [r2, #0]     ; r3 = *string
  cmp     r3, r1           ; compare with target char
  ...                      ; (need to disassemble more)
```

**Direct GDB test shows strchr works correctly:**
```
>>> set $test = (char*)"-+!"
>>> call (char*)__tcc_strchr($test, 0x2d)
$1 = 0x20004400 "-+!"    ← correctly found '-' at position 0
```

### 3.3 Possible explanations (to investigate)

1. **String literal address not resolved correctly in PIC mode**: The "-+!" string
   is loaded via `ldr r0, [pc, #536]` then `add r0, r9` (GOT-relative). If GOT
   entry is wrong, r0 may not point to "-+!".

2. **Character argument garbled**: The character loaded from `*options` might not
   be '-' due to options pointer being wrong in some iteration.

3. **`stmdb sp!, {r9, r12}` / `ldmia sp!, {r9, r12}` around PLT call**: TCC
   saves/restores r9 (GOT pointer) around external calls. If __tcc_strchr
   internally uses r9 or if there's a stack alignment issue, this could corrupt
   arguments.

4. **The idx=-1 occurs in a specific trailing group iteration** where options
   doesn't point to a `[-` sequence (e.g., it mistakenly points to a character
   inside a group rather than the `-` after `[`).

5. **Register pressure / spill bug in TCC**: The options pointer (`r5`/`r8`)
   might get clobbered across iterations of the trailing group loop.

---

## 4. Key Addresses

All runtime addresses assume .text base = 0x103684e0.

| Symbol/Location | File Offset | Runtime Address | Description |
|----------------|-------------|-----------------|-------------|
| parse_optflaglist entry | 0x0aa4 | 0x10369384 | Stack frame = 232 bytes |
| xzalloc(56) call | 0x0be2 | 0x103690c2 | Allocates new opts node |
| new->c = *options | 0x0ed4 | 0x103693b4 | Initial c assignment |
| Trailing group outer loop | 0x102c | 0x1036950c | `while (*options)` |
| `idx = stridx(...)` call | 0x105e | 0x1036953e | stridx("-+!", *++options) |
| idx stored to stack | 0x1066 | 0x10369546 | `str r0, [r7, #-12]` |
| Inner while loop | 0x1072 | 0x10369552 | `while (*options++ != ']')` |
| Inner for loop | 0x1086 | 0x10369566 | `for (ll=1, opt=...; ...)` |
| dex[idx] addr computed | 0x115e-0x1176 | 0x1036963e-0x10369656 | opt+16+idx*8 |
| dex[idx] \|= bits&~ll | 0x117a-0x11f2 | 0x1036965a-0x103696d2 | The destructive OR |
| **CRASH SITE** | 0x1232 | 0x10369712 | `ldr.w ip, [r1]` opt->c |
| stridx | 0x8a34 | 0x10370f14 | |
| __tcc_strchr | N/A (PLT) | 0x103a989c | Direct, not via PLT |
| .plt base | | 0x103aa710 | PLT appears zeroed out |

---

## 5. struct opts Layout

```c
struct opts {
    struct opts *next;   // offset 0  (4 bytes)
    long *arg;           // offset 4  (4 bytes)
    int c;               // offset 8  (4 bytes)
    int flags;           // offset 12 (4 bytes)
    unsigned long long dex[3]; // offset 16 (24 bytes) — dex[0]@16, dex[1]@24, dex[2]@32
    char type;           // offset 40
    union { long val[3]; ... }; // offset 44
};
// sizeof(struct opts) = 56 (0x38)
```

**Critical**: `&opt->dex[-1]` = opt + 16 + (-1)*8 = opt + 8 = `&opt->c`

---

## 6. Runtime Memory Layout

```
toybox .text:  0x103684e0
toybox .data:  0x1102a000
toybox .bss:   0x11030ad8
toybox .got:   0x11032c60
toybox .plt:   0x103aa710

libc .text:    0x10181c40
libc .data:    0x11025000
libc .bss:     0x11026740
libc .got:     0x11027448
```

---

## 7. ls Option String

```
(sort):(color):;(full-time)(show-control-chars)\377(block-size)#=1024<1\241
(group-directories-first)\376ZgoACFHLNRSUXabcdfhikl@mnpqrstuw#=80<0x1
[-Cxm1][-Cxml][-Cxmo][-Cxmg][-cu][-ftS][-HL][-Nqb][-k\377]
```

9 trailing groups, each starting with `[-`.

---

## 8. Bugs Fixed Along the Way

### 8.1 vfprintf %llx bug (FIXED)

**File**: `libs/libc/stdio.c`

yasos libc's `vfprintf` used `va_arg(ap, long)` (4 bytes on 32-bit ARM) for ALL
integer formats including `%llx`. This consumed only 4 bytes of a 64-bit `long long`
argument, causing subsequent `va_arg` calls to read garbage.

**Fix**: Changed `oint()` and `digits()` to take `unsigned long long`. Added
`l_count` tracking for `l`/`ll` modifiers. Use `va_arg(ap, long long)` when
byte size >= sizeof(long long).

### 8.2 dprintf/vdprintf (IMPLEMENTED)

**File**: `libs/libc/stdio.c`

Was a stub "TODO: Implement dprintf". Implemented using stack-allocated FILE
struct + vfprintf.

---

## 9. Observations

- **dprintfs in args.c mask the bug**: Adding 4 debug dprintf calls to
  parse_optflaglist changes register allocation enough that the crash disappears
  and `ls` completes successfully. This strongly suggests a register
  pressure / spill issue in TCC's codegen.

- **PLT appears zeroed out** at 0x103aa710 (`movs r0, r0` = 0x0000). The
  `__tcc_strchr` call resolves directly (not via PLT), which is expected for
  intra-module calls.

- **strchr works when called directly from GDB** with known-good arguments,
  suggesting the bug is in how arguments are passed to stridx/strchr at runtime,
  not in strchr itself.

---

## 10. Root Cause: R9 (GOT Pointer) Clobbered by TCC Codegen

### 10.1 Discovery

GDB breakpoints on the stridx call site (0x1036953e) revealed:

| Hit | r9 (GOT)    | r0 (string) | Result  |
|-----|-------------|-------------|---------|
| 1   | 0x11032c60  | correct     | idx=0   |
| 2   | 0x1102b36a  | **garbage** | idx=-1  |
| 3   | 0x1102b371  | **garbage** | idx=-1  |

R9 should always be 0x11032c60 (GOT base). After iteration 1, R9 is clobbered
with the `options` pointer value. Since "-+!" is loaded via
`ldr r0, [pc, #N]; add r0, r9`, wrong R9 → wrong address → stridx gets garbage
string → can't find '-' → returns -1.

### 10.2 Disassembly Evidence

In the inner `while (*options++ != ']')` loop, TCC emits:
```asm
mov r9, r5        ; 0x46a9 — uses R9 as scratch for old value of options
add.w r5, r9, #1  ; options++
ldrb.w r1, [r9]   ; load *old_options
```
This destroys R9 (GOT base) to implement post-increment.

### 10.3 TCC Bug: `try_reassign_scratch_conflict` in ir/codegen.c

The **actual code path** that produces R9 as a destination register:

1. The LS register allocator correctly excludes R9 from `registers_map_for_allocator`
2. All pair/single register assignment functions check the allocator map → R9 rejected
3. **BUT**: `try_reassign_scratch_conflict()` (ir/codegen.c line ~960) has its own
   hardcoded callee-saved mask `ALL_CALLEE_SAVED = 0x0FF0` (bits 4-11 = R4..R11)
4. This mask includes **R9 (bit 9)** and only excludes R7 (FP) and optionally R10 (static chain)
5. When a scratch register conflict occurs, this function reassigns a vreg to R9,
   bypassing the LS allocator's exclusion entirely
6. The result: `ir_iv->allocation.r0 = 9` → `machine_op_from_ir()` produces
   `MACH_OP_REG { r0=9 }` → `tcc_gen_machine_assign_mop()` emits `MOV R9, R5`

Detection confirmed via `ot()` instrumentation:
```
[R9-CLOBBER] instruction 0x46a9 (size=2) writes to R9 (GOT pointer)!
  ind=0x942 ir_op=35
```

### 10.4 Fixes Applied

**Fix 1: Exclude R9 from `try_reassign_scratch_conflict`** (ir/codegen.c)
```c
const uint32_t ARM_R9 = 9u;
uint32_t reserved = (1u << ARM_FP_REG);
if (tcc_state->text_and_data_separation)
    reserved |= (1u << ARM_R9);  // R9 holds GOT base
```

**Fix 2: Remove dangerous `r0+1` fallback in `mach_make_hi_half`** (arm-thumb-gen.c)

The old code did `hi.u.reg.r0 = thumb_is_hw_reg(op->u.reg.r1) ? r1 : (r0 + 1)`.
If the allocator ever produced an invalid pair, this silently used the next register
which could be R9, R13 (SP), etc. Replaced with `tcc_error()` — a 64-bit REG with
invalid r1 means the allocator failed and must be fixed there.

**Fix 3: R9 safety net in `ot()`** (arm-thumb-gen.c)

Added `thumb_decode_dest_reg()` that decodes the destination register from any
Thumb/Thumb-2 instruction. The `ot()` emitter calls `tcc_error()` if any instruction
writes to R9 when `text_and_data_separation` is active. This catches any future
code paths that might clobber R9.

---

## 11. GDB Quick Reference

```gdb
# Load symbols
source scripts/yasld_gdb.py

# Set hardware breakpoint at crash site
hbreak *0x10369712

# Set hardware breakpoint at stridx call in trailing groups
hbreak *0x1036953e

# Check idx value
printf "idx = %d\n", *(int*)($r7-12)

# Walk opts linked list
define walk-opts-from
  set $node = (unsigned int)$arg0
  set $i = 0
  while ($node != 0)
    set $next = *(unsigned int*)$node
    set $c_val = *(unsigned int*)($node + 8)
    printf "Node %d @ 0x%08x: next=0x%08x c=%d (0x%x='%c')\n", $i, $node, $next, $c_val, $c_val, ($c_val < 128 && $c_val > 31) ? $c_val : '?'
    set $node = $next
    set $i = $i + 1
  end
end

# Examine key stack slots
printf "idx=%d opt=%p options=%p\n", *(int*)($r7-12), *(int*)($r7-192), $r5
```

---

## 12. Key Source Locations

- **args.c trailing group parsing**: `apps/toybox/lib/args.c` ~line 387
  ```c
  // Trailing group: [-abc] means -a, -b, -c are mutually exclusive
  while (*options) {
      unsigned long long bits = 0;
      idx = stridx("-+!", *++options);  // <-- idx=-1 here
      // ...
      if (CFG_TOYBOX_DEBUG && idx == -1)
          error_exit("[ needs +-!");    // <-- compiled out when DEBUG=0
      // ...
      opt->dex[idx] |= bits & ~ll;     // <-- with idx=-1, writes to opt->c
  }
  ```

- **vfprintf fix**: `libs/libc/stdio.c`
- **GDB script**: `scripts/toybox_debug.gdb`
