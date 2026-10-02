# Networking and SSH — plan for yasos.zig

Drafted 2026-09-30. Nothing here is implemented yet; §9 lists the choices this plan proposes and
§11 the questions still open.

## 1. Why

The only way into a running board today is the console UART: one session, raw bytes, file
transfer by ZMODEM, and on MSPC v3 a debugprobe bridge that drops bytes at high baud rates. The
goal is `ssh root@yasos.local`: several sessions, `scp`, and a link that does not care about
UART framing. It also gives yasboot's `yasupdate` (bootloader plan §8.5) a network to fetch
images from.

State of the tree at drafting time:

- **No network stack.** `libs/libc/sys/socket.c` is seven printf-"TODO" stubs, `netdb.c` and
  `inet_ntop` are stubs, `netinet/tcp.h`, `net/if.h`, `sys/un.h`, `pty.h` are empty,
  `sys/select.h` does not exist, and `netinet/in.h` defines `sa_family_t` as `int`.
- **No PTYs, sessions or signal delivery.** `setsid()` is a TODO stub, `TIOCSCTTY` is only a
  `#define`, `sigaction` records nothing, and `sys_kill` ignores its arguments and kills the
  caller (`source/kernel/interrupts/syscall_handlers.zig:666`).
- **No kernel threads or timers.** Kernel work runs in syscalls and IRQs; `create_process`
  makes unprivileged processes only; there is no timed wait (`sleep_for_us` spins and yields).
- **What already fits:** every open file is an `IFile` with non-blocking `poll`
  (`source/kernel/fs/ifile.zig:92`), pipes show the block/wake pattern
  (`source/kernel/fs/pipe.zig`), `vfork` + `execve` + `waitpid` work, the UART implements a
  termios subset, and pico-sdk already carries **lwIP 2.2.1** and **TinyUSB 0.18** as
  submodules (`hal/libs/pico-sdk/lib/`), unused so far. Toybox has `nc`, `ping`, `ifconfig`,
  `telnetd`.

## 2. Boards and links

| board | link | host sees | driver |
|---|---|---|---|
| QEMU mps3-an524 | emulated LAN9118 Ethernet, `-nic user,model=lan9118,hostfwd=…` | forwarded ports on localhost | LAN9118 register driver (MMIO at `0x41400000`, behind a TrustZone PPC port — confirmed with `info mtree`) |
| Pimoroni Pico Plus 2 | the board's USB port as a USB network adapter (CDC-NCM) | a `usb0`/`enx…` interface, DHCP from the board | TinyUSB device stack + NCM class, RP2350 USB controller (`dcd_rp2040.c`) |
| MSPC v3 | Wi-Fi through the ESP32-S2 north bridge | the board on the Wi-Fi LAN | frame channel to the ESP32-S2 (§5.3) |
| MSPC v2, Pico 2, QEMU an505 | none planned | — | — |

USB on the Pico Plus 2 is unused today, so NCM does not displace anything; the console stays on
UART0. The MSPC v3 board has no HAL board directory yet (`hal/boards/` has `mspc_v2` only);
that arrives with the v3 bring-up, not with this plan.

## 3. Goals and non-goals

1. **One stack, many links.** lwIP in the kernel; each board contributes one link driver. The
   socket layer, PTYs and the SSH server are board-independent.
2. **Built and tested on QEMU first.** Everything above the link driver runs in the smoke suite
   before either hardware driver exists.
3. BSD sockets for userspace (TCP, UDP, DNS lookup), enough for dropbear, toybox `nc`, and
   ports of ordinary POSIX network code.
4. Interactive remote shells: PTYs, sessions, hang-up on disconnect.
5. **SSH with public-key authentication** (dropbear), plus `scp`.
6. Zero-configuration on USB: plug in, the host gets an address, `ssh root@yasos.local` works.

Non-goals for now: IPv6, routing/forwarding/NAT, Wi-Fi access-point mode, password login,
`sftp`, TLS in userspace, the full `ifconfig`/`ip` ioctl surface, job control (Ctrl-Z).

## 4. Architecture

### 4.1 Layers

```
 userspace   dropbear   toybox nc/telnetd   yasvi/toysh on a PTY
 ──────────────────── libc: socket(), accept(), select() over poll(), getaddrinfo(), openpty()
 syscalls    sys_socketcall(op, ctx)      ioctl / read / write / poll on fds
 kernel      SocketFile : IFile           Ptmx / PtsFile : IFile  (shared tty line discipline)
             ── net lock ──
             lwIP 2.2.1 (NO_SYS=1, raw API): IPv4, TCP, UDP, ICMP, DHCP client, DNS, mDNS
             netd kernel thread: RX queue, lwIP timers, link-driver service calls
 link        lan9118 (QEMU)   tinyusb NCM (Pico Plus 2)   north-bridge channel (MSPC v3)
```

### 4.2 lwIP in the kernel

- **Build:** compiled into the kernel the same way littlefs is (`source/fs/littlefs/build.zig`,
  wired in `build.zig:561-582`): a static C library from `hal/libs/pico-sdk/lib/lwip/src`, a
  yasos `lwipopts.h` and `arch/cc.h`, and `addTranslateC` for the headers the Zig side uses.
- **`NO_SYS=1`, raw API.** lwIP's own sockets/netconn layers need a full `sys_arch` port
  (threads, mailboxes, semaphores) and keep their own fd table, which would clash with yasos
  fds. The raw API plus a thin kernel socket file (§4.3) fits the `IFile` model directly.
- **Concurrency: one net lock.** lwIP is not reentrant. A kernel mutex guards all lwIP state.
  Syscalls take it and call the raw API directly; `netd` takes it to feed received frames and
  run timers. lwIP callbacks (`tcp_recv`, `tcp_accept`, `tcp_sent`, `tcp_err`) therefore run
  under the lock, append to socket buffers, and call `wake_all_blocked_on(socket)`. Link-driver
  IRQs never touch lwIP: they push frames onto a lock-free ring and wake `netd`.
- **`netd`** is the first kernel thread: a privileged `create_process` variant with a kernel
  entry point. Its loop is: drain RX rings into `netif->input`, service the link driver
  (`tud_task()` on USB), run `sys_check_timeouts()`, then block until an IRQ wakes it or the
  next lwIP timeout is due (`sys_timeouts_sleeptime()`), which needs a timed block (§5, item 1).
- **Memory:** lwIP's heap and pbuf pool live in SRAM, not PSRAM (exclusives never succeed on
  PSRAM — `yasos-psram-exclusives-hang-thunk-refcount` — and latency matters here). See §7.

### 4.3 Sockets

- **`SocketFile : IFile`** wraps a TCP/UDP PCB, an RX pbuf chain and connection state. `read`
  and `write` map to `recv`/`send`, `poll` reports readable (data, pending accept, EOF),
  writable (`tcp_sndbuf` > 0) and error/hang-up, `delete` closes or aborts the PCB. Because it
  is an `IFile`, `dup`, fd inheritance across `vfork`/`execve`, `poll` and the generic
  `read`/`write`/`close` syscalls work without changes. Blocking reads and writes use the
  pipe pattern (`block_on` / `wake_all_blocked_on`); `O_NONBLOCK` returns `EAGAIN`.
- **One syscall, `sys_socketcall(op, ctx)`**, in the style of Linux i386. The syscall table is
  full (`YASOS_SYSCALL_COUNT` is 64 and asserted equal to the enum); one slot instead of a
  dozen keeps it small and gives the whole family one slow-path (blocking) classification.
  Ops: `socket bind listen accept connect sendto recvfrom shutdown getsockopt setsockopt
  getsockname getpeername getaddrinfo`. Per-op context structs live in `libs/libc/sys/syscall.h`
  like the others; `sys_ioctl`'s pointer checks (`check_ioctl_arg`) grow `FIONBIO`/`FIONREAD`
  for sockets.
- **Socket options** needed by dropbear and nc: `SO_REUSEADDR`, `SO_KEEPALIVE`, `SO_ERROR`,
  `TCP_NODELAY`, `IPTOS_LOWDELAY` (accepted and ignored). `FD_CLOEXEC` must be honoured on
  exec — check it before dropbear (§5, item 4).
- **libc:** real `sys/socket.h` (Linux struct layout, `sa_family_t` = `uint16_t`, `SOCK_*`,
  `MSG_*`), `netinet/in.h` (`INADDR_ANY`, `IPPROTO_*`), `netinet/tcp.h`, `arpa/inet.h`
  (`inet_pton`/`inet_ntop`/`inet_aton`), `netdb.h` (`getaddrinfo` numeric-first, then the
  kernel's lwIP DNS through `sys_socketcall`), and a `sys/select.h` whose `select()` is built on
  `poll()`. Changing `sa_family_t` is an ABI change: rebuild all of userspace.

### 4.4 Addressing and naming

| link | device address | host side |
|---|---|---|
| QEMU user networking | DHCP from QEMU's built-in server (10.0.2.15) | `hostfwd=tcp::2222-:22,hostfwd=tcp::2323-:23` |
| USB NCM | static `192.168.7.1/24`; the board runs a small DHCP server (as in TinyUSB's `net_lwip_webserver` example) handing out `192.168.7.2` | Linux `cdc_ncm` and NetworkManager pick it up with no setup; macOS and Windows 11 have NCM drivers built in |
| Wi-Fi | DHCP client | whatever the LAN provides |

lwIP's mDNS responder announces `yasos.local` (hostname from `/etc/hostname` when there is
one) on every link, so the same `ssh root@yasos.local` works over USB and Wi-Fi. Link state and
addresses are readable from `/proc/net/if`; a small `netctl` tool covers `up`/`down`/static
addresses. Full toybox `ifconfig` (the SIOC* ioctls) is deferred.

### 4.5 PTYs and sessions

- **`/dev/ptmx` + `/dev/pts/N`** as a driver in `driverfs`: opening `ptmx` allocates a pair;
  the slave side is an `IFile` with the tty line discipline.
- **Shared line discipline:** `apply_termios` and the canonical/echo/`ONLCR` logic move out of
  `source/kernel/drivers/uart/uart_file.zig` into a tty module used by UART, VT and PTY slaves,
  so all three behave the same. `TIOCGWINSZ`/`TIOCSWINSZ` on the pair carry window size from
  ssh to yasvi and curses apps.
- **Sessions:** `setsid()` for real, a per-process session id and controlling terminal,
  `TIOCSCTTY`. When the master side closes (the ssh connection dropped), the session leader and
  its session get SIGHUP.
- **libc:** `posix_openpt`, `grantpt`, `unlockpt`, `ptsname`, `openpty`, `login_tty`.

### 4.6 Signals: the minimum

Remote sessions need processes to die when a connection drops. The minimum is `kill(pid, sig)`
that targets the named process (or process group / session), with the default action
(terminate) for SIGHUP, SIGINT, SIGTERM and SIGKILL. Handlers (`sigaction` delivery) and
SIGCHLD are not in this plan: dropbear reaps children from a SIGCHLD handler, so it is patched
to call `waitpid(-1, …, WNOHANG)` from its main loop instead. SIGINT from the PTY on Ctrl-C
comes with the same default-action path.

### 4.7 Entropy

Both sshd and TCP initial sequence numbers need randomness. A `/dev/urandom` driver: a
ChaCha20-based generator seeded from the RP2350's hardware TRNG, reseeded periodically. QEMU has
no TRNG, so there it is seeded from timer jitter and logged as insecure (development only).
`getrandom()`/`getentropy()` in libc read the device.

### 4.8 SSH server: dropbear

- **Why dropbear:** MIT licence, small, already runs on MMU-less uClinux through its `vfork`
  build, and bundles its own crypto (libtomcrypt/libtommath), so no OpenSSL port.
- **Build:** with the native tcc toolchain like the other apps (`apps/dropbear` submodule,
  built by `build_rootfs.sh`), configured `-DDROPBEAR_VFORK`, algorithms trimmed to ed25519 host
  keys, curve25519 key exchange and chacha20-poly1305 / aes-ctr + hmac-sha256. No RSA/DSS key
  generation (slow and not needed).
- **Accounts and keys:** `getpwnam("root")` returns the same static entry as today's
  `getpwuid`. Public-key login only, from `/root/.ssh/authorized_keys`. The host key is created
  on first use (`dropbear -R`) and must be kept on writable, persistent storage (§11, question 3).
- **Services:** `dropbear` for shells and commands, `scp` from the dropbear tree. A telnetd
  (toybox) is available earlier as the no-crypto bring-up path and stays off by default.
- **Startup:** launched from the init script when a link comes up, or by hand during bring-up.

### 4.9 USB network adapter on the Pico Plus 2

- TinyUSB's device stack compiled into the kernel as a C library, like lwIP, with the RP2350
  port (`dcd_rp2040.c`; the RP2350 USB controller is the RP2040's). The pico-sdk support it
  needs (IRQ install, resets, clock queries) is either compiled in from pico-sdk or provided as
  small Zig shims; the HAL uses pico-sdk only for headers today.
- Class: **CDC-NCM** (`ncm_device.c`), one configuration. A composite device with a CDC-ACM
  console is a possible later step.
- The USB IRQ calls `tud_int_handler`; `netd` runs `tud_task()`. NCM RX/TX hands whole Ethernet
  frames to/from the netif.
- The USB clock comes from PLL_USB at 48 MHz, which `crt.zig` already manages; the low-clock VREG
  finding (`yasos-low-clock-vreg-breaks-pll-usb`) applies when USB is on.

### 4.10 Wi-Fi on MSPC v3: the ESP32-S2 north bridge

The mainboard schematic (`mspc/mainboard/mainboard/north_bridge.kicad_sch`) puts an **ESP32-S2**
on the board as the "north bridge", with `NORTH_UART_TX/RX`, `USB_NORTH_D±`, MSPC bus lines
(`BUS_D_0..8`, `BUS_CLK`, `BUS_RWDS`, `BUS_INT`, `BUS_RE`) and a debug header. As of
2026-09-30 that sheet is not yet instantiated in `mainboard.kicad_sch`, so the RP2350↔ESP link is
still open. (The bootloader plan says ESP32-C3; the schematic says S2 — §11, question 1.)

**What the Wi-Fi driver needs from the hardware:**

- a full-duplex frame channel between the RP2350 and the S2: SPI (the S2 is SPI slave, tens of
  Mbit/s) or the north bus; the UART works as a fallback at ~300 KB/s (3 Mbaud), which is enough
  for SSH but not for bulk copies;
- a data-ready interrupt line from the S2 to the RP2350;
- the S2's `EN` (reset) and `GPIO0` (boot strap) driven by the RP2350, so yasos can reset the S2
  and reflash its firmware in the field, the way yasboot updates the GPU card.

**Firmware on the S2:**

- **If the S2 runs dedicated north-bridge firmware anyway:** add a network channel to it using
  the ESP-IDF hooks esp-hosted itself is built on (`esp_wifi_internal_tx`,
  `esp_wifi_internal_reg_rxcb`). Raw Ethernet frames cross the link; a few control messages
  (scan, connect, disconnect, status, MAC) use the yasboot frame format
  (`AA 55 | len | seq | cmd | payload | crc32`). The S2 does no TCP/IP; lwIP on the RP2350 stays
  the only stack.
- **If the S2 is only a Wi-Fi chip:** run Espressif's esp-hosted slave firmware unmodified and
  port its host side (transport + control RPC) to the kernel. Check which esp-hosted variant
  supports the S2 over the chosen link before committing.
- **Not ESP-AT:** it would put TCP on the S2, give yasos a second socket backend used only on
  this board, and cap connections at a handful.

Wi-Fi credentials are stored on writable storage (`/etc/wifi.conf` or the SD card) and applied
by a `wifictl` tool through ioctls on `/dev/wlan0`.

## 5. Kernel changes, by area

1. **Kernel threads and timed waits.** A privileged `create_process` variant with a kernel
   entry point (for `netd`), and `block_on` with a deadline. The timed wait can later replace
   the 2 ms re-poll loop in `sys_poll` (`syscall_handlers.zig:595`) with real wakeups.
2. **lwIP library + `netd` + net lock + netif registry** (`source/kernel/net/`).
3. **`SocketFile` + `sys_socketcall`** (`libs/libc/sys/syscall.h`, `syscall_ids.h`,
   `SyscallFactory` in `source/kernel/interrupts/system_call.zig`).
4. **Exec-time fd hygiene:** confirm `FD_CLOEXEC` is honoured by `execve`; add it if not.
5. **tty module** shared by UART, VT, PTY; **ptmx/pts driver**; sessions, `setsid`, `TIOCSCTTY`,
   SIGHUP on master close.
6. **`kill` fixed** to signal the named process, group or session with default actions.
7. **`/dev/urandom`** (TRNG on RP2350, jitter on QEMU).
8. **Link drivers:** LAN9118 (`hal/source/arm/qemu_mps3/`), TinyUSB NCM
   (`hal/source/raspberry/rp2350/`), north-bridge channel (MSPC v3 board).
9. **Driver registration** in `source/main.zig` next to the UART/flash/MMC drivers, gated by
   Kconfig: `CONFIG_NET`, `CONFIG_NET_LAN9118`, `CONFIG_NET_USB_NCM`, `CONFIG_NET_NORTH_BRIDGE`,
   `CONFIG_PTY`.
10. **`/proc/net/if`** and the `netctl` / `wifictl` tools.

## 6. Userspace and tooling changes

- libc: §4.3 networking headers and functions, §4.5 PTY functions, `select()`, `getrandom()`,
  `getpwnam("root")`.
- `apps/dropbear` (new submodule, patched for SIGCHLD-less reaping), built by
  `build_rootfs.sh`.
- Toybox: enable `nc` and `telnetd` in the rootfs build; `ping` later (needs raw or ICMP
  sockets).
- `/etc/hostname`, `/etc/passwd` (root only), init script starting `dropbear` once a link is up.
- Smoke harness: `tests/smoke/framework/qemu.py` gains
  `-nic user,model=lan9118,hostfwd=tcp::<port>-:22`; new smoke tests connect over TCP and SSH.
  The fatdisk script (`scripts/qemu_fatdisk_run.py`) gets the same option.

## 7. Size and memory budget (estimates)

| part | flash | SRAM |
|---|---|---|
| lwIP (IPv4, TCP, UDP, ICMP, DHCP, DNS, mDNS, `-Os`) | 45–60 KB | heap 16 KB + pbuf pool 12 × 1536 ≈ 18 KB + PCBs/buffers ≈ 8 KB |
| socket layer, `netd`, PTY, tty, urandom | 10–15 KB | per socket < 1 KB + RX data (pbufs from the pool) |
| TinyUSB device + NCM (Pico Plus 2) | 12–18 KB | ~8 KB (two 2 KB NTBs each way) |
| LAN9118 or north-bridge driver | 3–6 KB | 2–4 KB |
| **kernel total** | **~70–100 KB** | **~50–60 KB** |
| dropbear + scp (tcc build, in the romfs) | ~250–350 KB | per session heap ~100–200 KB, in PSRAM |

TCP window is 4 × MSS (5.8 KB) per connection; eight TCP PCBs, four listening. Figures are
guesses from typical lwIP builds and tcc's measured ~1.7× size versus clang `-Oz`; phase 1 and
phase 4 measure them.

## 8. Phases

| phase | deliverable | exit criterion |
|---|---|---|
| **0 — kernel prerequisites** | kernel thread, timed block, `kill` fix, `/dev/urandom`, `FD_CLOEXEC` check | unit tests for each; existing smoke suite still green |
| **1 — stack on QEMU** | lwIP library, `netd`, net lock, LAN9118 driver, Kconfig | on `-nic user`, the kernel logs a DHCP lease; a debug-build kernel TCP echo service on port 7 answers through `hostfwd` from the host |
| **2 — sockets** | `SocketFile`, `sys_socketcall`, libc networking, `select()` | toybox `nc -l -p 23` on the guest talks to `nc localhost 2323` on the host, both directions; a smoke test does this |
| **3 — PTYs and telnet** | tty module, ptmx/pts, sessions, SIGHUP, `openpty` | `telnet localhost 2323` gives toysh; yasvi works and resizes; dropping the connection kills the shell |
| **4 — SSH** | dropbear, scp, host key on writable storage, init hook | `ssh -p 2222 root@localhost` with a key; `scp` both ways; smoke test over SSH |
| **5 — Pico Plus 2 USB** | TinyUSB NCM driver, DHCP server, mDNS | plug the board into a Linux host: an address arrives with no setup and `ssh root@yasos.local` works |
| **6 — MSPC v3 Wi-Fi** | north-bridge link, S2 firmware channel (or esp-hosted), `wifictl` | the board joins a WPA2 network and accepts SSH over Wi-Fi; the S2 is reflashed from yasos |
| later | IPv6, ICMP sockets for `ping`, SIOC* for `ifconfig`, sftp-server, event-driven `poll`, NTP for the wall clock, `yasupdate` over the network, smoke runner on the rig using SSH instead of the console | — |

Phases 0–4 need only QEMU. Phase 5 needs a Pico Plus 2 and a USB cable. Phase 6 waits for the
MSPC v3 hardware and its HAL board.

## 9. Proposed decisions

| id | proposal | reasoning |
|---|---|---|
| N1 | lwIP 2.2.1 from the pico-sdk submodule, in the kernel | already in the tree; one stack for every board |
| N2 | `NO_SYS=1`, raw API, one net lock, `netd` kernel thread | fits `IFile` and block/wake; no `sys_arch` port, no second fd table |
| N3 | one `sys_socketcall` syscall | syscall table is full; one slow-path entry |
| N4 | Linux-layout `struct sockaddr` family, `sa_family_t` = `uint16_t` | ported code expects it |
| N5 | USB NCM with the board as `192.168.7.1` and DHCP server; mDNS `yasos.local` | zero-configuration on the host |
| N6 | Wi-Fi: raw frames over a link to the ESP32-S2, lwIP on the RP2350 | not ESP-AT (§4.10) |
| N7 | dropbear, public-key only, ed25519 + curve25519 | small, MIT, MMU-less support |
| N8 | minimal signals: default actions only; dropbear patched for SIGCHLD | full signal delivery is its own project |

## 10. Risks and traps

- **LAN9118 behind the an524's TrustZone PPC:** accesses fault unless the PPC port is opened for
  the security state the kernel runs in. Check first thing in phase 1. Its IRQ number comes from
  QEMU's `hw/arm/mps2-tz.c`.
- **lwIP from a preemptible, SMP kernel:** every lwIP call must hold the net lock, including
  from callbacks that trigger further sends. A missed lock shows up as pbuf pool corruption
  hours later; build lwIP with `LWIP_ASSERT` on and `MEMP_OVERFLOW_CHECK` in debug builds.
- **IRQ → `netd` handoff:** RX rings are single-producer (IRQ) / single-consumer (`netd`); size
  them so a burst drops frames instead of blocking the IRQ.
- **Busy `poll`:** `sys_poll` re-polls every 2 ms. Acceptable for SSH, but an idle dropbear
  costs CPU; moving `poll` to timed waits (phase 0 primitive) fixes it.
- **Host key persistence:** the rootfs is a read-only romfs and `/tmp` is RAM. Without writable
  storage, each boot gets a new host key and ssh warns about a changed key.
- **QEMU entropy is weak:** keys generated under QEMU are for testing only.
- **dropbear under tcc:** a large new C code base through the self-hosted toolchain will find
  compiler bugs. Build it with the cross first and follow
  `libs/tinycc/docs/selfhost_miscompile_debugging.md`; its crypto is test-vector checkable.
- **TinyUSB on yasos:** the RP2350 port expects pico-sdk runtime pieces (IRQ install, `clk_usb`
  queries, resets) that the HAL does not compile today.
- **ESP32-S2 link not designed yet:** phase 6 depends on hardware decisions (§11).

## 11. Open questions

1. **Which ESP32 is on MSPC v3?** The schematic has an ESP32-S2 north bridge; the bootloader plan
   says "on-board ESP32-C3". One of them needs updating.
2. **RP2350↔S2 link:** SPI, the north bus, or the UART, plus data-ready, `EN` and `GPIO0`
   control lines (§4.10). Does the S2 run dedicated north-bridge firmware (then add the network
   channel to it) or only Wi-Fi (then esp-hosted)?
3. **Writable storage for `/etc` state** (host key, `authorized_keys`, `wifi.conf`, hostname):
   the SD card on the Pico Plus 2 rig and MSPC, a littlefs partition in flash, or both? The
   bootloader plan (Q2) chose no flash data partition and the SD card as the writable medium.
4. Should the Pico Plus 2 USB device also carry a CDC-ACM console (composite device), or stay
   network-only?
