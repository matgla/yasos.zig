# Virtual Terminal Architecture for YasOS

## Overview

This document describes the architecture for implementing virtual terminals (VTs)
in YasOS, enabling multiple independent terminal sessions multiplexed over a single
physical UART. The design draws inspiration from Linux's `tty0`-`ttyN` model and
tmux's session/window/pane hierarchy, adapted for a bare-metal, no-MMU, resource-
constrained embedded OS.

## Goals

1. **Multiple independent terminal sessions** — at least 5 VTs, each running its own
   process tree (shell, background job, etc.)
2. **UART multiplexing** — a single physical UART (uart0) serves all VTs via a mux
   driver, with switchable active VT
3. **Process isolation** — each VT has its own process group, file descriptors, and
   controlling process
4. **Minimal resource overhead** — designed for Cortex-M33/M23 with limited RAM
5. **Compatibility** — VTs behave like standard TTYs for userland apps (termios,
   ioctls, read/write semantics)
6. **Linux-compatible naming** — device nodes at `/dev/tty0`-`/dev/ttyN`, switching
   via the `chvt` command (mirrors Linux VT console)

## Current State

```
┌─────────────────────────────────────────────┐
│  Physical UART (uart0 @ 3 Mbaud)            │
│  /dev/uart0, /dev/stdin, /dev/stdout,       │
│  /dev/stderr                                │
└─────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────┐
│  /bin/sh (init process, pid=1)              │
│  Single shell session, no VT switching      │
└─────────────────────────────────────────────┘
```

The current UART driver (`UartDriver`/`UartFile`) provides a single char device
that the init process uses as its sole console. There is no multiplexing, no VT
switching, and no concept of multiple terminal sessions.

## Architecture

### 1. Layered Design

```
┌─────────────────────────────────────────────────────────────────┐
│  Userland: /bin/sh, chvt, user processes             │
├─────────────────────────────────────────────────────────────────┤
│  VT Layer: VtDriver (mux) → VtNode (per VT)                   │
│  Each VtNode: buffer, process group, termios, cursor state     │
├─────────────────────────────────────────────────────────────────┤
│  UART Layer: UartDriver (physical uart0)                      │
│  Handles raw byte I/O to/from the hardware                    │
└─────────────────────────────────────────────────────────────────┘
```

### 2. Core Components

#### 2.1 VtDriver (Mux Driver)

A driver that manages multiple VT instances and routes I/O to the active one.

```
/dev/tty0  →  VtNode[0]  ──┐
/dev/tty1  →  VtNode[1]  ──┤
/dev/tty2  →  VtNode[2]  ──┼──→  VtMux (active VT selector)
...                       │       ↓
/dev/ttyN  →  VtNode[N]  ──┘   /dev/uart0 (physical)
```

The `VtDriver` implements `IDriver` and registers nodes `/dev/tty0` through
`/dev/ttyN`. Each VT node is a char device that, when read/written, routes
through the mux to the active VT's underlying buffer.

#### 2.2 VtNode (Per-VT State)

Each virtual terminal maintains:

- **Input buffer** — ring buffer for keystrokes destined for this VT
- **Output buffer** — ring buffer for text to be displayed (ESC sequences, etc.)
- **Process group** — the PID of the controlling process (e.g., the shell)
- **Termios state** — canonical/raw mode, echo, baudrate (for ioctl)
- **Cursor state** — row, col, visibility (for ANSI rendering)
- **Active flag** — whether this VT is currently receiving UART input
- **History** — scrollback buffer (optional, configurable depth)

#### 2.3 VtMux (Switching Logic)

The mux is a singleton that:

- Tracks the **active VT** index
- Routes incoming UART bytes to the active VT's input buffer
- Routes outgoing UART bytes from the active VT's output buffer
- Handles VT switching commands (e.g., `Ctrl+Alt+1` → switch to VT1)
- Provides ioctl interface for switching VTs programmatically

**Note:** `chvt N` is the userland command that triggers VT switching (mirrors
Linux's `chvt` utility). It can be implemented as a shell built-in or a standalone
binary that calls `ioctl(VT_SET_ACTIVE, N)` on `/dev/tty0`.

### 3. VT Switching

#### 3.1 Hardware Keys (Ctrl+Alt+N)

Standard VT switching: `Ctrl+Alt+1` through `Ctrl+Alt+5` (or more) switch
to the corresponding VT. The mux intercepts these key combinations before
they reach the active VT's process.

#### 3.2 ioctl Switching

```c
// Switch to VT N
ioctl(fd, VT_SET_ACTIVE, N)

// Get active VT
ioctl(fd, VT_GET_ACTIVE, &N)

// Set VT title (optional)
ioctl(fd, VT_SET_TITLE, "my-session")
```

#### 3.3 Shell Built-in

A `chvt N` command triggers VT switching (mirrors Linux's `chvt` utility). It can be implemented as a shell built-in or a standalone binary that calls `ioctl(VT_SET_ACTIVE, N)` on `/dev/tty0`.

### 4. Process Integration

#### 4.1 VT Assignment

Each process can be assigned to a VT via:

- **Parent inheritance** — child processes inherit the parent's VT assignment
- **Explicit assignment** — `vt_assign N` syscall or built-in
- **Auto-assign** — new processes default to the active VT

#### 4.2 Process Group Isolation

Each VT has its own process group. When a VT is inactive:

- Its process group is **suspended** (blocked on I/O)
- Its buffers retain state (no data loss)
- When reactivated, the process group resumes

### 5. UART Multiplexing Implementation

#### 5.1 Driver Registration

```zig
// In main.zig, after uart0 driver registration:

const vt_driver = try VtDriver.create(allocator, 5); // 5 VTs
try driverfs.data().append(vt_driver, "tty0");
try driverfs.data().append(vt_driver, "tty1");
try driverfs.data().append(vt_driver, "tty2");
try driverfs.data().append(vt_driver, "tty3");
try driverfs.data().append(vt_driver, "tty4");
```

#### 5.2 Data Flow

**Input (UART → VT):**

```
UART RX interrupt/poll
    ↓
VtMux reads byte
    ↓
If Ctrl+Alt+N: switch active VT
Else: write to active VT's input buffer
    ↓
Signal active VT's process (wake up read)
```

**Output (VT → UART):**

```
Active VT's write() called
    ↓
Append to VT's output buffer
    ↓
VtMux drains output buffer to UART TX
    ↓
Physical UART transmits bytes
```

### 6. Resource Estimation

Per VT (minimum viable):

- Input buffer: 256 bytes (ring buffer)
- Output buffer: 512 bytes (ring buffer, supports ~20 lines of text)
- Process group state: ~64 bytes
- Termios state: ~32 bytes
- Total per VT: ~864 bytes

For 5 VTs: ~4.3 KB RAM overhead (negligible on Cortex-M33 with 256KB+ RAM).

### 7. Implementation Phases

#### Phase 1: Core VT Infrastructure

- [ ] Implement `VtDriver` and `VtNode` (driverfs registration)
- [ ] Basic ring buffers for input/output
- [ ] UART mux routing (single active VT)
- [ ] Register `/dev/tty0` through `/dev/tty4`

#### Phase 2: VT Switching

- [ ] Ctrl+Alt+N key handling
- [ ] ioctl-based switching
- [ ] Shell built-in `chvt`

#### Phase 3: Process Integration

- [ ] VT assignment for new processes
- [ ] Process group isolation per VT
- [ ] Suspend/resume on VT switch

#### Phase 4: Advanced Features

- [ ] Scrollback history (configurable depth)
- [ ] VT titles (for status display)
- [ ] Multi-pane support (tmux-like, optional)
- [ ] VT-specific termios profiles

### 8. Key Design Decisions

#### 8.1 Why Not Just Fork the Shell?

Forking `/bin/sh` creates a new process, but without VTs, all processes share
the same console. VTs provide **session isolation**: each VT can run a
different program (shell, vim, top, background job) with its own terminal
state.

#### 8.2 Why Ring Buffers, Not Linked Lists?

Ring buffers provide:

- **O(1) read/write** — critical for embedded real-time
- **Predictable memory** — fixed size, no fragmentation
- **Simple overflow handling** — overwrite oldest or drop

Linked lists would allow dynamic sizing but add allocation overhead and
complexity.

#### 8.3 Why Not Use Linux's TTY Layer?

Linux's TTY layer is complex (pseudoterminals, line discipline, etc.).
YasOS needs a **minimal** implementation that covers 90% of use cases:

- Canonical/raw mode (termios)
- Basic ANSI ESC sequences
- VT switching
- Process group isolation

Advanced features (pty, line discipline, etc.) can be added later.

### 9. Example Usage

#### 9.1 Boot Sequence

```
YasOS boots
    ↓
UART0 initialized
    ↓
VtDriver registers /dev/tty0-vt4
    ↓
Init process (pid=1) attached to /dev/tty0
    ↓
/bin/sh launched on /dev/tty0
    ↓
User sees shell prompt on tty0
```

#### 9.2 Switching VTs

```
User presses Ctrl+Alt+1
    ↓
VtMux switches active VT to tty1
    ↓
Vt1's process group (if any) is resumed
    ↓
Vt0's process group is suspended
    ↓
User sees tty1's output (or shell prompt if tty1 has a shell)
```

#### 9.3 Running Multiple Shells

```bash
# In VT0 shell:
chvt 1
/bin/sh   # new shell on tty1

chvt 2
/bin/sh   # new shell on tty2

chvt 0
# Back to tty0, original shell resumes
```

### 10. File Structure

```
source/kernel/drivers/vt/
├── vt_driver.zig      # VtDriver (mux, manages VtNodes)
├── vt_node.zig        # VtNode (per-VT state, ring buffers)
├── vt_mux.zig         # VtMux (switching logic, routing)
├── vt_ioctl.zig       # ioctl handlers (VT_SET_ACTIVE, etc.)
└── tests/
    ├── vt_driver_test.zig
    ├── vt_node_test.zig
    └── vt_mux_test.zig
```

### 11. Integration with Existing Code

#### 11.1 main.zig Changes

```zig
// After uart0 driver registration:
const vt_driver = try VtDriver.create(allocator, 5);
try driverfs.data().append(vt_driver, "vt0");
try driverfs.data().append(vt_driver, "vt1");
// ... vt2-vt4
try driverfs.data().load_all();
```

#### 11.2 Process Attachment

```zig
// attach_default_filedescriptors_to_root_process:
// Use /dev/vt0 instead of /dev/uart0 for stdin/stdout/stderr
const maybe_vt0 = kernel.fs.get_ivfs().interface.get("/dev/vt0") catch null;
if (maybe_vt0) |vt0| {
    _ = try process.attach_file_with_fd(0, "/dev/vt0", vt0);
    // ... repeat for stdout, stderr
}
```

### 12. Testing Strategy

#### 12.1 Unit Tests

- Ring buffer overflow/underflow
- VT switching logic
- ioctl handling
- Process group isolation

#### 12.2 Integration Tests

- Boot with VTs, verify `/dev/vt0`-`/dev/vt4` exist
- Switch VTs via Ctrl+Alt+N, verify active VT changes
- Run shell on multiple VTs, verify isolation
- UART output routing (only active VT's output goes to UART)

#### 12.3 QEMU Smoke Tests

- `vt_switch_test.py` — automated VT switching via serial
- `multi_shell_test.py` — run multiple shells, verify isolation

### 13. Future Extensions

#### 13.1 tmux-like Panes

Add a pane layer on top of VTs:

```
VT0 → Pane 0 (shell) | Pane 1 (vim)
VT1 → Pane 0 (top)   | Pane 1 (background job)
```

#### 13.2 Pseudoterminals (pty)

For remote access (SSH, netcat), add pty support:

```
/dev/ptmx → pty master
/dev/pts/0 → pty slave (appears as /dev/tty)
```

#### 13.3 VT-specific Settings

Per-VT termios profiles, cursor shapes, colors.

#### 13.4 VT Notification

Notify processes when VT is switched (SIGWINCH, etc.).

---

## References

- Linux TTY layer: `drivers/tty/`
- tmux: https://github.com/tmux/tmux
- Linux VT console: `drivers/tty/vt/`
- POSIX TTY: IEEE Std 1003.1-2017, Section 11.2

---

## Next Steps

1. Implement Phase 1 (core VT infrastructure)
2. Add VT switching (Phase 2)
3. Integrate with process model (Phase 3)
4. Test on QEMU, then hardware
