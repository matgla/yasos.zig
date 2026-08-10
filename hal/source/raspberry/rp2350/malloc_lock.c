// Interrupt-safe newlib malloc lock for the RP2350 kernel build.
//
// newlib's libc_nano malloc guards its free-list with __malloc_lock/__malloc_unlock.
// The default newlib stubs (libc_a-mlock.o) are no-ops, so the kernel heap (newlib
// malloc, used by the dynamic loader during execve / lazy PLT resolve) would have NO
// protection against re-entrancy: a SysTick -> PendSV context switch preempting a
// malloc/free mid free-list update lets another kernel allocation splice the chain ->
// wild `pop {pc}` HardFault.
//
// On mps2 the kernel provides this lock from Zig (system_stubs.zig). On RP2350 the
// pico-sdk references malloc early, which pulls newlib's strong mlock.o into the link
// BEFORE the Zig compilation unit (yasos_kernel_zcu.o) is scanned -> duplicate-symbol
// link error. Providing the override from THIS C object (linked alongside the pico-sdk
// C objects, ahead of libc_nano.a) makes the reference resolve here, so mlock.o is
// never pulled and there is no duplicate. The Zig export is compiled out on RP2350.
//
// A blocking mutex is wrong here (the lazy PLT resolver already runs in SVC/exception
// context; a nested SVC -> HardFault). A short interrupt-disabled critical section is
// the correct primitive, and it must be nesting-safe because newlib's realloc takes
// the lock and then calls the (also-locking) _malloc_r / _free_r.
#include <stdint.h>

// The lock itself lives in Zig (source/kernel/memory/heap/kheap_lock.zig) so
// there is one implementation rather than two that have to be kept in step.
// This file exists only to satisfy the link order described above: it must
// *define* __malloc_lock, but it need not implement it.
//
// What changed: this used to be a PRIMASK nesting counter, which excludes this
// core's own interrupt handlers and provides nothing at all against a second
// core. It is now a ranked recursive spinlock underneath the same nesting
// counter, so it does both.
void yasos_kheap_lock(void);
void yasos_kheap_unlock(void);

void __malloc_lock(void *reent)
{
    (void)reent;
    yasos_kheap_lock();
}

void __malloc_unlock(void *reent)
{
    (void)reent;
    yasos_kheap_unlock();
}
