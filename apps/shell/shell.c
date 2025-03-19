#define ZIG_TARGET_MAX_INT_ALIGNMENT 16
#include "zig.h"
struct anon__lazy_49 {
 uint8_t const *ptr;
 uintptr_t len;
};
struct c_Sigaction__struct_2364__2364; /* c.Sigaction__struct_2364 */
union c_Sigaction__struct_2364__union_2367__2367; /* c.Sigaction__struct_2364__union_2367 */
typedef zig_under_align(1) void anon__aligned_55(int32_t);
typedef anon__aligned_55 uav__2409_41;
struct c_siginfo_t__struct_2374__2374; /* c.siginfo_t__struct_2374 */
union c_Sigaction__struct_2364__union_2367__2367 {
 anon__aligned_55 *handler;
 void (*sigaction)(int32_t, struct c_siginfo_t__struct_2374__2374 const *, void *);
};
struct c_Sigaction__struct_2364__2364 {
 union c_Sigaction__struct_2364__union_2367__2367 handler;
 uint32_t mask;
 unsigned int flags;
};
typedef struct anon__lazy_73 nav__126_44;
struct anon__lazy_73 {
 uint8_t **ptr;
 uintptr_t len;
};
typedef anon__aligned_55 nav__131_44;
struct fs_File__2581; /* fs.File */
struct fs_File__2581 {
 int32_t handle;
};
struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612; /* io.GenericWriter(fs.File,error{DiskQuota,FileTooBig,InputOutput,NoSpaceLeft,DeviceBusy,InvalidArgument,AccessDenied,BrokenPipe,SystemResources,OperationAborted,NotOpenForWriting,LockViolation,WouldBlock,ConnectionResetByPeer,ProcessNotFound,NoDevice,Unexpected},(function 'write')) */
struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 {
 struct fs_File__2581 context;
};
struct io_Writer__2628; /* io.Writer */
typedef struct anon__lazy_88 nav__2652_47;
typedef struct anon__lazy_49 nav__2652_49;
struct io_Writer__2628 {
 void const *context;
 struct anon__lazy_88 (*writeFn)(void const *, struct anon__lazy_49);
};
struct anon__lazy_88 {
 uintptr_t payload;
 uint16_t error;
};
typedef struct anon__lazy_88 nav__3195_38;
typedef struct anon__lazy_49 nav__3195_41;
typedef struct anon__lazy_88 nav__3212_41;
typedef struct anon__lazy_49 nav__3212_43;
struct Thread_Mutex_Recursive__2766; /* Thread.Mutex.Recursive */
struct Thread_Mutex__2764; /* Thread.Mutex */
struct Thread_Mutex_DarwinImpl__2775; /* Thread.Mutex.DarwinImpl */
struct c_darwin_os_unfair_lock__2781; /* c.darwin.os_unfair_lock */
struct c_darwin_os_unfair_lock__2781 {
 uint32_t _os_unfair_lock_opaque;
};
struct Thread_Mutex_DarwinImpl__2775 {
 struct c_darwin_os_unfair_lock__2781 oul;
};
struct Thread_Mutex__2764 {
 struct Thread_Mutex_DarwinImpl__2775 impl;
};
struct Thread_Mutex_Recursive__2766 {
 uint64_t thread_id;
 uintptr_t lock_count;
 struct Thread_Mutex__2764 mutex;
};
typedef struct anon__lazy_88 nav__3141_38;
typedef struct anon__lazy_49 nav__3141_41;
typedef struct anon__lazy_88 nav__3280_41;
typedef struct anon__lazy_49 nav__3280_43;
struct Progress__2662; /* Progress */
struct Thread__2686; /* Thread */
struct Thread_PosixThreadImpl__2725; /* Thread.PosixThreadImpl */
struct Thread_PosixThreadImpl__2725 {
 void *handle;
};
struct Thread__2686 {
 struct Thread_PosixThreadImpl__2725 impl;
};
typedef struct anon__lazy_133 nav__3251_45;
struct anon__lazy_133 {
 struct Thread__2686 payload;
 bool is_null;
};
typedef struct anon__lazy_135 nav__3251_48;
struct anon__lazy_135 {
 uint8_t *ptr;
 uintptr_t len;
};
struct Progress_Node_Storage__2711; /* Progress.Node.Storage */
typedef struct anon__lazy_139 nav__3251_52;
struct anon__lazy_139 {
 struct Progress_Node_Storage__2711 *ptr;
 uintptr_t len;
};
struct Thread_ResetEvent__2689; /* Thread.ResetEvent */
struct Thread_ResetEvent_FutexImpl__2736; /* Thread.ResetEvent.FutexImpl */
struct atomic_Value_28u32_29__2744; /* atomic.Value(u32) */
struct atomic_Value_28u32_29__2744 {
 uint32_t raw;
};
struct Thread_ResetEvent_FutexImpl__2736 {
 struct atomic_Value_28u32_29__2744 state;
};
struct Thread_ResetEvent__2689 {
 struct Thread_ResetEvent_FutexImpl__2736 impl;
};
struct Progress_TerminalMode__2684; /* Progress.TerminalMode */
struct Progress_TerminalMode__2684 {
 uint8_t tag;
};
struct Progress__2662 {
 struct anon__lazy_133 update_thread;
 uint64_t refresh_rate_ns;
 uint64_t initial_delay_ns;
 struct anon__lazy_135 draw_buffer;
 struct anon__lazy_135 node_parents;
 struct anon__lazy_139 node_storage;
 struct anon__lazy_135 node_freelist;
 struct fs_File__2581 terminal;
 struct Thread_ResetEvent__2689 redraw_event;
 uint32_t node_end_index;
 uint16_t rows;
 uint16_t cols;
 struct Progress_TerminalMode__2684 terminal_mode;
 bool done;
 bool need_clear;
 uint8_t node_freelist_first;
};
typedef struct anon__lazy_49 nav__3251_68;
typedef struct anon__lazy_88 nav__1571_38;
typedef struct anon__lazy_49 nav__1571_40;
typedef struct anon__lazy_49 nav__3203_40;
typedef struct anon__lazy_88 nav__3203_43;
typedef struct anon__lazy_49 nav__3270_39;
typedef struct anon__lazy_133 nav__3270_52;
typedef struct anon__lazy_135 nav__3270_55;
typedef struct anon__lazy_139 nav__3270_59;
typedef struct anon__lazy_88 nav__3202_38;
typedef struct anon__lazy_49 nav__3202_41;
typedef struct anon__lazy_49 nav__3142_40;
typedef struct anon__lazy_88 nav__3142_47;
struct Target_Cpu_Feature_Set__268; /* Target.Cpu.Feature.Set */
struct Target_Cpu_Feature_Set__268 {
 uintptr_t ints[5];
};
struct Target_Cpu__180; /* Target.Cpu */
struct Target_Cpu_Model__263; /* Target.Cpu.Model */
struct Target_Cpu__180 {
 struct Target_Cpu_Model__263 const *model;
 struct Target_Cpu_Feature_Set__268 features;
 uint8_t arch;
};
typedef struct anon__lazy_49 nav__237_46;
struct Target_Cpu_Model__263 {
 struct anon__lazy_49 name;
 struct anon__lazy_49 llvm_name;
 struct Target_Cpu_Feature_Set__268 features;
};
struct Target_Os__1419; /* Target.Os */
union Target_Os_VersionRange__1440; /* Target.Os.VersionRange */
struct SemanticVersion_Range__1444; /* SemanticVersion.Range */
struct SemanticVersion__1442; /* SemanticVersion */
typedef struct anon__lazy_49 nav__238_43;
struct SemanticVersion__1442 {
 uintptr_t major;
 uintptr_t minor;
 uintptr_t patch;
 struct anon__lazy_49 pre;
 struct anon__lazy_49 build;
};
struct SemanticVersion_Range__1444 {
 struct SemanticVersion__1442 zig_e_min;
 struct SemanticVersion__1442 zig_e_max;
};
struct Target_Os_HurdVersionRange__1446; /* Target.Os.HurdVersionRange */
struct Target_Os_HurdVersionRange__1446 {
 struct SemanticVersion_Range__1444 range;
 struct SemanticVersion__1442 glibc;
};
struct Target_Os_LinuxVersionRange__1448; /* Target.Os.LinuxVersionRange */
struct Target_Os_LinuxVersionRange__1448 {
 struct SemanticVersion_Range__1444 range;
 struct SemanticVersion__1442 glibc;
 uint32_t android;
};
struct Target_Os_WindowsVersion_Range__1504; /* Target.Os.WindowsVersion.Range */
struct Target_Os_WindowsVersion_Range__1504 {
 uint32_t zig_e_min;
 uint32_t zig_e_max;
};
union Target_Os_VersionRange__1440 {
 struct SemanticVersion_Range__1444 semver;
 struct Target_Os_HurdVersionRange__1446 hurd;
 struct Target_Os_LinuxVersionRange__1448 linux;
 struct Target_Os_WindowsVersion_Range__1504 windows;
};
struct Target_Os__1419 {
 union Target_Os_VersionRange__1440 version_range;
 uint8_t tag;
};
struct Target_DynamicLinker__1434; /* Target.DynamicLinker */
struct Target_DynamicLinker__1434 {
 uint8_t buffer[255];
 uint8_t len;
};
struct Target__178; /* Target */
typedef struct anon__lazy_49 nav__239_51;
struct Target__178 {
 struct Target_Cpu__180 cpu;
 struct Target_Os__1419 os;
 uint8_t abi;
 uint8_t ofmt;
 struct Target_DynamicLinker__1434 dynamic_linker;
};
struct builtin_CallingConvention__832; /* builtin.CallingConvention */
struct builtin_CallingConvention_CommonOptions__834; /* builtin.CallingConvention.CommonOptions */
typedef struct anon__lazy_204 nav__780_40;
struct anon__lazy_204 {
 uint64_t payload;
 bool is_null;
};
struct builtin_CallingConvention_CommonOptions__834 {
 struct anon__lazy_204 incoming_stack_alignment;
};
struct builtin_CallingConvention_X86RegparmOptions__836; /* builtin.CallingConvention.X86RegparmOptions */
struct builtin_CallingConvention_X86RegparmOptions__836 {
 struct anon__lazy_204 incoming_stack_alignment;
 uint8_t register_params;
};
struct builtin_CallingConvention_ArmInterruptOptions__838; /* builtin.CallingConvention.ArmInterruptOptions */
struct builtin_CallingConvention_ArmInterruptOptions__838 {
 struct anon__lazy_204 incoming_stack_alignment;
 uint8_t type;
};
struct builtin_CallingConvention_MipsInterruptOptions__840; /* builtin.CallingConvention.MipsInterruptOptions */
struct builtin_CallingConvention_MipsInterruptOptions__840 {
 struct anon__lazy_204 incoming_stack_alignment;
 uint8_t mode;
};
struct builtin_CallingConvention_RiscvInterruptOptions__842; /* builtin.CallingConvention.RiscvInterruptOptions */
struct builtin_CallingConvention_RiscvInterruptOptions__842 {
 struct anon__lazy_204 incoming_stack_alignment;
 uint8_t mode;
};
struct builtin_CallingConvention__832 {
 union {
  struct builtin_CallingConvention_CommonOptions__834 x86_64_sysv;
  struct builtin_CallingConvention_CommonOptions__834 x86_64_win;
  struct builtin_CallingConvention_CommonOptions__834 x86_64_regcall_v3_sysv;
  struct builtin_CallingConvention_CommonOptions__834 x86_64_regcall_v4_win;
  struct builtin_CallingConvention_CommonOptions__834 x86_64_vectorcall;
  struct builtin_CallingConvention_CommonOptions__834 x86_64_interrupt;
  struct builtin_CallingConvention_X86RegparmOptions__836 x86_sysv;
  struct builtin_CallingConvention_X86RegparmOptions__836 x86_win;
  struct builtin_CallingConvention_X86RegparmOptions__836 x86_stdcall;
  struct builtin_CallingConvention_CommonOptions__834 x86_fastcall;
  struct builtin_CallingConvention_CommonOptions__834 x86_thiscall;
  struct builtin_CallingConvention_CommonOptions__834 x86_thiscall_mingw;
  struct builtin_CallingConvention_CommonOptions__834 x86_regcall_v3;
  struct builtin_CallingConvention_CommonOptions__834 x86_regcall_v4_win;
  struct builtin_CallingConvention_CommonOptions__834 x86_vectorcall;
  struct builtin_CallingConvention_CommonOptions__834 x86_interrupt;
  struct builtin_CallingConvention_CommonOptions__834 aarch64_aapcs;
  struct builtin_CallingConvention_CommonOptions__834 aarch64_aapcs_darwin;
  struct builtin_CallingConvention_CommonOptions__834 aarch64_aapcs_win;
  struct builtin_CallingConvention_CommonOptions__834 aarch64_vfabi;
  struct builtin_CallingConvention_CommonOptions__834 aarch64_vfabi_sve;
  struct builtin_CallingConvention_CommonOptions__834 arm_aapcs;
  struct builtin_CallingConvention_CommonOptions__834 arm_aapcs_vfp;
  struct builtin_CallingConvention_ArmInterruptOptions__838 arm_interrupt;
  struct builtin_CallingConvention_CommonOptions__834 mips64_n64;
  struct builtin_CallingConvention_CommonOptions__834 mips64_n32;
  struct builtin_CallingConvention_MipsInterruptOptions__840 mips64_interrupt;
  struct builtin_CallingConvention_CommonOptions__834 mips_o32;
  struct builtin_CallingConvention_MipsInterruptOptions__840 mips_interrupt;
  struct builtin_CallingConvention_CommonOptions__834 riscv64_lp64;
  struct builtin_CallingConvention_CommonOptions__834 riscv64_lp64_v;
  struct builtin_CallingConvention_RiscvInterruptOptions__842 riscv64_interrupt;
  struct builtin_CallingConvention_CommonOptions__834 riscv32_ilp32;
  struct builtin_CallingConvention_CommonOptions__834 riscv32_ilp32_v;
  struct builtin_CallingConvention_RiscvInterruptOptions__842 riscv32_interrupt;
  struct builtin_CallingConvention_CommonOptions__834 sparc64_sysv;
  struct builtin_CallingConvention_CommonOptions__834 sparc_sysv;
  struct builtin_CallingConvention_CommonOptions__834 powerpc64_elf;
  struct builtin_CallingConvention_CommonOptions__834 powerpc64_elf_altivec;
  struct builtin_CallingConvention_CommonOptions__834 powerpc64_elf_v2;
  struct builtin_CallingConvention_CommonOptions__834 powerpc_sysv;
  struct builtin_CallingConvention_CommonOptions__834 powerpc_sysv_altivec;
  struct builtin_CallingConvention_CommonOptions__834 powerpc_aix;
  struct builtin_CallingConvention_CommonOptions__834 powerpc_aix_altivec;
  struct builtin_CallingConvention_CommonOptions__834 wasm_mvp;
  struct builtin_CallingConvention_CommonOptions__834 arc_sysv;
  struct builtin_CallingConvention_CommonOptions__834 bpf_std;
  struct builtin_CallingConvention_CommonOptions__834 csky_sysv;
  struct builtin_CallingConvention_CommonOptions__834 csky_interrupt;
  struct builtin_CallingConvention_CommonOptions__834 hexagon_sysv;
  struct builtin_CallingConvention_CommonOptions__834 hexagon_sysv_hvx;
  struct builtin_CallingConvention_CommonOptions__834 lanai_sysv;
  struct builtin_CallingConvention_CommonOptions__834 loongarch64_lp64;
  struct builtin_CallingConvention_CommonOptions__834 loongarch32_ilp32;
  struct builtin_CallingConvention_CommonOptions__834 m68k_sysv;
  struct builtin_CallingConvention_CommonOptions__834 m68k_gnu;
  struct builtin_CallingConvention_CommonOptions__834 m68k_rtd;
  struct builtin_CallingConvention_CommonOptions__834 m68k_interrupt;
  struct builtin_CallingConvention_CommonOptions__834 msp430_eabi;
  struct builtin_CallingConvention_CommonOptions__834 propeller_sysv;
  struct builtin_CallingConvention_CommonOptions__834 s390x_sysv;
  struct builtin_CallingConvention_CommonOptions__834 s390x_sysv_vx;
  struct builtin_CallingConvention_CommonOptions__834 ve_sysv;
  struct builtin_CallingConvention_CommonOptions__834 xcore_xs1;
  struct builtin_CallingConvention_CommonOptions__834 xcore_xs2;
  struct builtin_CallingConvention_CommonOptions__834 xtensa_call0;
  struct builtin_CallingConvention_CommonOptions__834 xtensa_windowed;
  struct builtin_CallingConvention_CommonOptions__834 amdgcn_device;
  struct builtin_CallingConvention_CommonOptions__834 amdgcn_cs;
 } payload;
 uint8_t tag;
};
struct std_Options__2244; /* std.Options */
typedef struct anon__lazy_218 nav__97_39;
struct anon__lazy_218 {
 uintptr_t payload;
 bool is_null;
};
struct std_Options__2244 {
 struct anon__lazy_218 page_size_min;
 struct anon__lazy_218 page_size_max;
 uintptr_t fmt_max_depth;
 bool enable_segfault_handler;
 uint8_t log_level;
 bool crypto_always_getrandom;
 bool crypto_fork_safety;
 bool keep_sigpipe;
 bool http_disable_tls;
 bool http_enable_ssl_key_log_file;
 uint8_t side_channels_mitigations;
};
typedef struct anon__lazy_133 nav__3226_44;
typedef struct anon__lazy_135 nav__3226_47;
typedef struct anon__lazy_139 nav__3226_51;
struct Progress_Node_Storage__2711 {
 uint32_t completed_count;
 uint32_t estimated_total_count;
 zig_align(8) uint8_t name[40];
};
typedef struct anon__lazy_49 nav__438_40;
typedef struct anon__lazy_73 nav__924_40;
typedef struct anon__lazy_73 nav__923_40;
struct macho_mach_header_64__3150; /* macho.mach_header_64 */
struct macho_mach_header_64__3150 {
 uint32_t magic;
 int cputype;
 int cpusubtype;
 uint32_t filetype;
 uint32_t ncmds;
 uint32_t sizeofcmds;
 uint32_t flags;
 uint32_t reserved;
};
static struct c_Sigaction__struct_2364__2364 const __anon_2409;
static uint8_t const __anon_2875[2];
static uint8_t const __anon_2943[4];
static uint8_t const __anon_3089[9];
static uint8_t const __anon_3092[9];
#define start_main__126 main
zig_extern int main(int, char **, char **);
static void debug_maybeEnableSegfaultHandler__205(void);
static void start_maybeIgnoreSigpipe__131(void);
static void shell_main__226(void);
static void start_noopSigHandler__132(int32_t);
static void posix_sigaction__1758(uint8_t, struct c_Sigaction__struct_2364__2364 const *, struct c_Sigaction__struct_2364__2364 *);
static void debug_print__anon_2449__2652(void);
static uint16_t posix_errno__anon_2570__3008(int);
static void debug_lockStdErr__161(void);
static struct fs_File__2581 io_getStdErr__3026(void);
static struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 fs_File_writer__3160(struct fs_File__2581);
static nav__3195_38 io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgume__3195(void const *, nav__3195_41);
static uint16_t io_Writer_print__anon_2651__3212(struct io_Writer__2628);
static void debug_unlockStdErr__162(void);
static void Progress_lockStdErr__3240(void);
static int32_t io_getStdErrHandle__3025(void);
static nav__3141_38 fs_File_write__3141(struct fs_File__2581, nav__3141_41);
static uint16_t fmt_format__anon_2677__3280(struct io_Writer__2628);
static void Progress_unlockStdErr__3241(void);
static void Thread_Mutex_Recursive_lock__3467(struct Thread_Mutex_Recursive__2766 *);
static uint16_t Progress_clearWrittenWithEscapeCodes__3251(void);
static nav__1571_38 posix_write__1571(int32_t, nav__1571_40);
static uint16_t io_Writer_writeAll__3203(struct io_Writer__2628, nav__3203_40);
static void Thread_Mutex_Recursive_unlock__3468(struct Thread_Mutex_Recursive__2766 *);
static uint64_t Thread_getCurrentId__3308(void);
static void Thread_Mutex_lock__3448(struct Thread_Mutex__2764 *);
static void debug_assert__179(bool);
static uint16_t Progress_write__3270(nav__3270_39);
static uint16_t posix_errno__anon_2965__3477(intptr_t);
static uint16_t posix_unexpectedErrno__1835(uint16_t);
static nav__3202_38 io_Writer_write__3202(struct io_Writer__2628, nav__3202_41);
static void Thread_Mutex_unlock__3449(struct Thread_Mutex__2764 *);
static uint64_t Thread_PosixThreadImpl_getCurrentId__3378(void);
static void Thread_Mutex_DarwinImpl_lock__3471(struct Thread_Mutex_DarwinImpl__2775 *);
static uint16_t fs_File_writeAll__3142(struct fs_File__2581, nav__3142_40);
static void Thread_Mutex_DarwinImpl_unlock__3472(struct Thread_Mutex_DarwinImpl__2775 *);
static uint64_t const builtin_zig_backend__230;
static bool const start_simplified_logic__109;
static uint8_t const builtin_output_mode__231;
static bool const builtin_link_libc__242;
static struct Target_Cpu_Feature_Set__268 const Target_Cpu_Feature_Set_empty__399;
static struct Target_Cpu__180 const builtin_cpu__237;
static uint8_t const start_native_arch__106;
static struct Target_Os__1419 const builtin_os__238;
static uint8_t const builtin_abi__236;
static uint8_t const builtin_object_format__240;
static struct Target_DynamicLinker__1434 const Target_DynamicLinker_none__859;
static struct Target__178 const builtin_target__239;
static struct builtin_CallingConvention__832 const builtin_CallingConvention_c__780;
static uint8_t const builtin_mode__241;
static bool const debug_runtime_safety__159;
static bool const debug_default_enable_segfault_handler__204;
static uint8_t const log_default_level__1032;
static struct std_Options__2244 const std_options__97;
static bool const debug_enable_segfault_handler__203;
static bool const posix_use_libc__1404;
static uint8_t const c_native_os__1846;
static uint32_t const c_empty_sigset__1944;
static uint32_t const posix_empty_sigset__1480;
zig_extern int sigaction(int, struct c_Sigaction__struct_2364__2364 const *, struct c_Sigaction__struct_2364__2364 *);
zig_extern int *zig_e___error(void) zig_mangled(zig_e___error, "__error");
static bool const Progress_is_windows__3222;
static uint8_t const Thread_native_os__3287;
static bool const Thread_use_pthreads__3298;
static bool const builtin_single_threaded__235;
static uint64_t const Thread_Mutex_Recursive_invalid_thread_id__3469;
static struct Thread_Mutex_Recursive__2766 const Thread_Mutex_Recursive_init__3465;
static struct Thread_Mutex_Recursive__2766 Progress_stderr_mutex__3277;
static bool const io_is_windows__3013;
static bool const fs_File_is_windows__3182;
static uint16_t const fmt_max_format_args__1236;
static struct Progress__2662 Progress_global_progress__3226;
static uint8_t const (*const Progress_clear__3245)[4];
static uint8_t const posix_native_os__1402;
zig_extern intptr_t write(int32_t, uint8_t const *, uintptr_t);
static bool const posix_unexpected_error_tracing__1833;
zig_extern int pthread_threadid_np(void *, uint64_t *);
zig_extern void os_unfair_lock_lock(struct c_darwin_os_unfair_lock__2781 *);
zig_extern void os_unfair_lock_unlock(struct c_darwin_os_unfair_lock__2781 *);
static struct Target_Cpu_Model__263 const Target_aarch64_cpu_apple_m3__438;
static nav__924_40 os_argv__924;
static nav__923_40 os_environ__923;
#define c_dummy_execute_header__1864 _mh_execute_header
zig_extern zig_weak_linkage struct macho_mach_header_64__3150 _mh_execute_header;
static uint8_t Progress_node_parents_buffer__3228[83];
static struct Progress_Node_Storage__2711 Progress_node_storage_buffer__3229[83];
static uint8_t Progress_node_freelist_buffer__3230[83];
enum {
 zig_error_DiskQuota = 1u,
 zig_error_FileTooBig = 2u,
 zig_error_InputOutput = 3u,
 zig_error_NoSpaceLeft = 4u,
 zig_error_DeviceBusy = 5u,
 zig_error_InvalidArgument = 6u,
 zig_error_AccessDenied = 7u,
 zig_error_BrokenPipe = 8u,
 zig_error_SystemResources = 9u,
 zig_error_OperationAborted = 10u,
 zig_error_NotOpenForWriting = 11u,
 zig_error_LockViolation = 12u,
 zig_error_WouldBlock = 13u,
 zig_error_ConnectionResetByPeer = 14u,
 zig_error_ProcessNotFound = 15u,
 zig_error_NoDevice = 16u,
 zig_error_Unexpected = 17u,
};
static uint8_t const zig_errorName_DiskQuota[10] = "DiskQuota";
static uint8_t const zig_errorName_FileTooBig[11] = "FileTooBig";
static uint8_t const zig_errorName_InputOutput[12] = "InputOutput";
static uint8_t const zig_errorName_NoSpaceLeft[12] = "NoSpaceLeft";
static uint8_t const zig_errorName_DeviceBusy[11] = "DeviceBusy";
static uint8_t const zig_errorName_InvalidArgument[16] = "InvalidArgument";
static uint8_t const zig_errorName_AccessDenied[13] = "AccessDenied";
static uint8_t const zig_errorName_BrokenPipe[11] = "BrokenPipe";
static uint8_t const zig_errorName_SystemResources[16] = "SystemResources";
static uint8_t const zig_errorName_OperationAborted[17] = "OperationAborted";
static uint8_t const zig_errorName_NotOpenForWriting[18] = "NotOpenForWriting";
static uint8_t const zig_errorName_LockViolation[14] = "LockViolation";
static uint8_t const zig_errorName_WouldBlock[11] = "WouldBlock";
static uint8_t const zig_errorName_ConnectionResetByPeer[22] = "ConnectionResetByPeer";
static uint8_t const zig_errorName_ProcessNotFound[16] = "ProcessNotFound";
static uint8_t const zig_errorName_NoDevice[9] = "NoDevice";
static uint8_t const zig_errorName_Unexpected[11] = "Unexpected";
static struct anon__lazy_49 const zig_errorName[18] = {{zig_errorName_DiskQuota, 9ul}, {zig_errorName_FileTooBig, 10ul}, {zig_errorName_InputOutput, 11ul}, {zig_errorName_NoSpaceLeft, 11ul}, {zig_errorName_DeviceBusy, 10ul}, {zig_errorName_InvalidArgument, 15ul}, {zig_errorName_AccessDenied, 12ul}, {zig_errorName_BrokenPipe, 10ul}, {zig_errorName_SystemResources, 15ul}, {zig_errorName_OperationAborted, 16ul}, {zig_errorName_NotOpenForWriting, 17ul}, {zig_errorName_LockViolation, 13ul}, {zig_errorName_WouldBlock, 10ul}, {zig_errorName_ConnectionResetByPeer, 21ul}, {zig_errorName_ProcessNotFound, 15ul}, {zig_errorName_NoDevice, 8ul}, {zig_errorName_Unexpected, 10ul}};

static struct c_Sigaction__struct_2364__2364 const __anon_2409 = {{ .handler = (uav__2409_41 *)&start_noopSigHandler__132 },UINT32_C(0),0u};

static uint8_t const __anon_2875[2] = ">\n";

static uint8_t const __anon_2943[4] = "\033[J";

static uint8_t const __anon_3089[9] = "apple_m3";

static uint8_t const __anon_3092[9] = "apple-m3";

int start_main__126(int const a0, char **const a1, char **const a2) {
 uintptr_t t1;
 uintptr_t t0;
 char *t2;
 uint8_t **t4;
 uint8_t **t5;
 uint8_t **t8;
 uint8_t **const *t6;
 nav__126_44 t7;
 nav__126_44 t9;
 bool t3;
 /* file:2:5 */
 t0 = (uintptr_t)0ul;
 /* dbg_var_ptr:env_count */
 zig_loop_8:
 /* file:3:12 */
 t1 = t0;
 /* file:3:18 */
 t2 = a2[t1];
 t3 = t2 != NULL;
 if (t3) {
  /* file:3:59 */
  (void)0;
  /* file:3:42 */
  t1 = t0;
  /* file:3:52 */
  t1 = t1 + (uintptr_t)1ul;
  t0 = t1;
  goto zig_block_1;
 }
 goto zig_block_0;

 zig_block_1:;
 goto zig_loop_8;

 zig_block_0:;
 /* file:4:34 */
 t4 = (uint8_t **)a2;
 t5 = t4;
 t6 = (uint8_t **const *)&t5;
 t1 = t0;
 /* file:4:51 */
 t4 = (*t6);
 t4 = (uint8_t **)(((uintptr_t)t4) + ((uintptr_t)0ul*sizeof(uint8_t *)));
 t7.ptr = t4;
 t7.len = t1;
 /* dbg_var_val:envp */
 /* file:6:9 */
 /* file:13:40 */
 t1 = (uintptr_t)a0;
 /* file:13:75 */
 t4 = (uint8_t **)a1;
 /* file:13:28 */
 /* inline:start.callMainWithArgs */
 /* dbg_arg_inline:argc */
 /* dbg_arg_inline:argv */
 /* dbg_arg_inline:envp */
 t8 = t4;
 t6 = (uint8_t **const *)&t8;
 /* file:2:23 */
 t4 = (*t6);
 t4 = (uint8_t **)(((uintptr_t)t4) + ((uintptr_t)0ul*sizeof(uint8_t *)));
 t9.ptr = t4;
 t9.len = t1;
 (*((nav__126_44 *)&os_argv__924)) = t9;
 /* file:3:11 */
 (*((nav__126_44 *)&os_environ__923)) = t7;
 /* file:5:41 */
 debug_maybeEnableSegfaultHandler__205();
 /* file:6:23 */
 start_maybeIgnoreSigpipe__131();
 /* file:8:20 */
 /* inline:start.callMain */
 /* file:4:13 */
 /* file:6:22 */
 shell_main__226();
 /* file:7:13 */
 goto zig_block_3;

 zig_block_3:;
 /* file:8:5 */
 goto zig_block_2;

 zig_block_2:;
 /* file:13:5 */
 return 0;
}

static void debug_maybeEnableSegfaultHandler__205(void) {
 /* file:2:9 */
 return;
}

static void start_maybeIgnoreSigpipe__131(void) {
 /* file:2:42 */
 /* dbg_var_val:have_sigpipe_support */
 /* file:21:9 */
 /* file:23:9 */
 /* file:27:26 */
 /* dbg_var_ptr:act */
 /* file:30:24 */
 posix_sigaction__1758(UINT8_C(13), ((struct c_Sigaction__struct_2364__2364 const *)&__anon_2409), NULL);
 goto zig_block_0;

 zig_block_0:;
 return;
}

static void shell_main__226(void) {
 /* file:2:20 */
 debug_print__anon_2449__2652();
 return;
}

static void start_noopSigHandler__132(int32_t const a0) {
 (void)a0;
 return;
}

static void posix_sigaction__1758(uint8_t const a0, struct c_Sigaction__struct_2364__2364 const *const a1, struct c_Sigaction__struct_2364__2364 *const a2) {
 int t0;
 uint16_t t1;
 /* file:2:35 */
 t0 = (int)a0;
 /* file:2:35 */
 t0 = sigaction(t0, a1, a2);
 /* file:2:18 */
 t1 = posix_errno__anon_2570__3008(t0);
 /* file:2:13 */
 switch (t1) {
  case UINT16_C(0): {
   /* file:3:21 */
   return;
  }
  case UINT16_C(22): {
   /* file:7:19 */
   zig_unreachable();
  }
  default: {
   /* file:8:17 */
   zig_unreachable();
  }
 }
}

static void debug_print__anon_2449__2652(void) {
 struct fs_File__2581 const *t2;
 struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 const *t5;
 struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 const *t9;
 struct io_Writer__2628 t8;
 struct io_Writer__2628 t15;
 struct io_Writer__2628 t11;
 struct io_Writer__2628 t16;
 struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 const *const *t10;
 void const **t12;
 void const *t13;
 nav__2652_47 (**t14)(void const *, nav__2652_49);
 struct io_Writer__2628 const *t17;
 struct fs_File__2581 t0;
 struct fs_File__2581 t1;
 struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 t3;
 struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 t4;
 struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 t7;
 uint16_t t6;
 uint16_t t18;
 uint16_t t19;
 bool t20;
 /* file:2:15 */
 debug_lockStdErr__161();
 /* file:4:32 */
 t0 = io_getStdErr__3026();
 t1 = t0;
 t2 = (struct fs_File__2581 const *)&t1;
 /* file:4:41 */
 t0 = (*t2);
 /* file:4:41 */
 t3 = fs_File_writer__3160(t0);
 t4 = t3;
 t5 = (struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 const *)&t4;
 /* dbg_var_val:stderr */
 /* file:5:5 */
 /* file:5:27 */
 t3 = (*t5);
 /* file:5:27 */
 /* inline:io.GenericWriter(fs.File,error{DiskQuota,FileTooBig,InputOutput,NoSpaceLeft,DeviceBusy,InvalidArgument,AccessDenied,BrokenPipe,SystemResources,OperationAborted,NotOpenForWriting,LockViolation,WouldBlock,ConnectionResetByPeer,ProcessNotFound,NoDevice,Unexpected},(function 'write')).print */
 /* dbg_arg_inline:self */
 /* dbg_arg_inline:format */
 t7 = t3;
 t5 = (struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 const *)&t7;
 /* file:2:39 */
 /* inline:io.GenericWriter(fs.File,error{DiskQuota,FileTooBig,InputOutput,NoSpaceLeft,DeviceBusy,InvalidArgument,AccessDenied,BrokenPipe,SystemResources,OperationAborted,NotOpenForWriting,LockViolation,WouldBlock,ConnectionResetByPeer,ProcessNotFound,NoDevice,Unexpected},(function 'write')).any */
 /* dbg_arg_inline:self */
 t9 = t5;
 t10 = (struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 const *const *)&t9;
 /* file:2:13 */
 t12 = (void const **)&t11.context;
 /* file:3:42 */
 t5 = (*t10);
 t2 = (struct fs_File__2581 const *)&t5->context;
 /* file:3:28 */
 t13 = (void const *)t2;
 (*t12) = t13;
 t14 = (nav__2652_47 (**)(void const *, nav__2652_49))&t11.writeFn;
 (*t14) = &io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgume__3195;
 /* file:2:13 */
 t15 = t11;
 t8 = t15;
 goto zig_block_2;

 zig_block_2:;
 t16 = t8;
 t17 = (struct io_Writer__2628 const *)&t16;
 /* file:2:47 */
 t8 = (*t17);
 /* file:2:47 */
 t18 = io_Writer_print__anon_2651__3212(t8);
 memcpy(&t19, &t18, sizeof(uint16_t));
 /* file:2:13 */
 t6 = t19;
 goto zig_block_1;

 zig_block_1:;
 t20 = t6 == UINT16_C(0);
 if (t20) {
  goto zig_block_0;
 }
 /* file:3:23 */
 debug_unlockStdErr__162();
 return;

 zig_block_0:;
 /* file:3:23 */
 debug_unlockStdErr__162();
 return;
}

static uint16_t posix_errno__anon_2570__3008(int const a0) {
 int *t3;
 int32_t t1;
 int t4;
 uint16_t t0;
 uint16_t t5;
 bool t2;
 /* file:2:9 */
 /* file:3:20 */
 t1 = a0;
 t2 = t1 == -INT32_C(1);
 if (t2) {
  /* file:3:55 */
  t3 = zig_e___error();
  t4 = (*t3);
  /* file:3:30 */
  t5 = (uint16_t)t4;
  t0 = t5;
  goto zig_block_0;
 }
 t0 = UINT16_C(0);
 goto zig_block_0;

 zig_block_0:;
 /* file:3:9 */
 return t0;
}

static void debug_lockStdErr__161(void) {
 /* file:2:28 */
 Progress_lockStdErr__3240();
 return;
}

static struct fs_File__2581 io_getStdErr__3026(void) {
 int32_t *t1;
 int32_t t2;
 struct fs_File__2581 t0;
 /* file:2:5 */
 t1 = (int32_t *)&t0.handle;
 /* file:2:40 */
 t2 = io_getStdErrHandle__3025();
 (*t1) = t2;
 /* file:2:5 */
 return t0;
}

static struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 fs_File_writer__3160(struct fs_File__2581 const a0) {
 struct fs_File__2581 *t1;
 struct io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgument_2cAccessDenied_2cBrokenPipe_2cSystemResources_2cOperationAborted_2cNotOpenForWriting_2cLockViolation_2cWouldBlock_2cConnectionResetByPeer_2cProcessNotFound_2cNoDevice_2cUnexpected_7d_2c_28function_20_27write_27_29_29__2612 t0;
 /* file:2:5 */
 t1 = (struct fs_File__2581 *)&t0.context;
 (*t1) = a0;
 /* file:2:5 */
 return t0;
}

static nav__3195_38 io_GenericWriter_28fs_File_2cerror_7bDiskQuota_2cFileTooBig_2cInputOutput_2cNoSpaceLeft_2cDeviceBusy_2cInvalidArgume__3195(void const *const a0, nav__3195_41 const a1) {
 struct fs_File__2581 const *t0;
 nav__3195_38 t2;
 nav__3195_38 t3;
 struct fs_File__2581 t1;
 /* file:2:41 */
 t0 = (struct fs_File__2581 const *)a0;
 /* dbg_var_val:ptr */
 /* file:3:27 */
 t1 = (*t0);
 /* file:3:27 */
 t2 = fs_File_write__3141(t1, a1);
 /* file:3:13 */
 memcpy(&t3, &t2, sizeof(nav__3195_38));
 return t3;
}

static uint16_t io_Writer_print__anon_2651__3212(struct io_Writer__2628 const a0) {
 uint16_t t0;
 uint16_t t1;
 /* file:2:26 */
 t0 = fmt_format__anon_2677__3280(a0);
 /* file:2:5 */
 memcpy(&t1, &t0, sizeof(uint16_t));
 return t1;
}

static void debug_unlockStdErr__162(void) {
 /* file:2:30 */
 Progress_unlockStdErr__3241();
 return;
}

static void Progress_lockStdErr__3240(void) {
 uint16_t t0;
 bool t1;
 /* file:2:22 */
 Thread_Mutex_Recursive_lock__3467(((struct Thread_Mutex_Recursive__2766 *)&Progress_stderr_mutex__3277));
 /* file:3:5 */
 /* file:3:32 */
 t0 = Progress_clearWrittenWithEscapeCodes__3251();
 t1 = t0 == UINT16_C(0);
 if (t1) {
  goto zig_block_0;
 }
 goto zig_block_0;

 zig_block_0:;
 return;
}

static int32_t io_getStdErrHandle__3025(void) {
 /* file:10:5 */
 return INT32_C(2);
}

static nav__3141_38 fs_File_write__3141(struct fs_File__2581 const a0, nav__3141_41 const a1) {
 nav__3141_38 t1;
 int32_t t0;
 /* file:6:28 */
 t0 = a0.handle;
 /* file:6:23 */
 t1 = posix_write__1571(t0, a1);
 /* file:6:5 */
 return t1;
}

static uint16_t fmt_format__anon_2677__3280(struct io_Writer__2628 const a0) {
 struct io_Writer__2628 const *t1;
 struct io_Writer__2628 t2;
 struct io_Writer__2628 t0;
 uint16_t t3;
 t0 = a0;
 t1 = (struct io_Writer__2628 const *)&t0;
 /* file:13:9 */
 /* file:29:9 */
 (void)0;
 /* file:29:9 */
 (void)0;
 /* file:35:13 */
 /* file:49:13 */
 /* file:50:32 */
 t2 = (*t1);
 /* file:50:32 */
 t3 = io_Writer_writeAll__3203(t2, (nav__3280_43){(uint8_t const *)&__anon_2875,(uintptr_t)2ul});
 if (t3) {
  /* file:50:13 */
  return t3;
 }
 /* file:54:13 */
 /* file:124:9 */
 return 0;
}

static void Progress_unlockStdErr__3241(void) {
 /* file:2:24 */
 Thread_Mutex_Recursive_unlock__3468(((struct Thread_Mutex_Recursive__2766 *)&Progress_stderr_mutex__3277));
 return;
}

static void Thread_Mutex_Recursive_lock__3467(struct Thread_Mutex_Recursive__2766 *const a0) {
 struct Thread_Mutex_Recursive__2766 *const *t1;
 uint64_t t2;
 uint64_t t6;
 struct Thread_Mutex_Recursive__2766 *t3;
 struct Thread_Mutex_Recursive__2766 *t0;
 uint64_t *t4;
 uint64_t const *t5;
 struct Thread_Mutex__2764 *t8;
 uintptr_t *t9;
 uintptr_t t10;
 bool t7;
 t0 = a0;
 t1 = (struct Thread_Mutex_Recursive__2766 *const *)&t0;
 /* file:2:54 */
 t2 = Thread_getCurrentId__3308();
 /* dbg_var_val:current_thread_id */
 /* file:3:9 */
 /* file:3:38 */
 t3 = (*t1);
 t4 = (uint64_t *)&t3->thread_id;
 t5 = (uint64_t const *)t4;
 zig_atomic_load(t6, (zig_atomic(uint64_t) *)t5, zig_memory_order_relaxed, u64, uint64_t);
 t7 = t6 != t2;
 if (t7) {
  /* file:4:10 */
  t3 = (*t1);
  t8 = (struct Thread_Mutex__2764 *)&t3->mutex;
  /* file:4:21 */
  Thread_Mutex_lock__3448(t8);
  /* file:5:17 */
  t9 = (uintptr_t *)&a0->lock_count;
  t10 = (*t9);
  t6 = t10;
  t7 = t6 == UINT64_C(0);
  /* file:5:15 */
  debug_assert__179(t7);
  /* file:6:39 */
  t3 = (*t1);
  t4 = (uint64_t *)&t3->thread_id;
  zig_atomic_store((zig_atomic(uint64_t) *)t4, t2, zig_memory_order_relaxed, u64, uint64_t);
  goto zig_block_0;
 }
 goto zig_block_0;

 zig_block_0:;
 /* file:8:6 */
 t3 = (*t1);
 t9 = (uintptr_t *)&t3->lock_count;
 t10 = (*t9);
 /* file:8:18 */
 t10 = t10 + (uintptr_t)1ul;
 (*t9) = t10;
 return;
}

static uint16_t Progress_clearWrittenWithEscapeCodes__3251(void) {
 struct Progress__2662 t0;
 uint16_t t2;
 bool t1;
 /* file:2:9 */
 t0 = (*((struct Progress__2662 *)&Progress_global_progress__3226));
 /* file:2:25 */
 t1 = t0.need_clear;
 t1 = !t1;
 if (t1) {
  /* file:2:38 */
  return 0;
 }
 goto zig_block_0;

 zig_block_0:;
 /* file:4:20 */
 (*&(((struct Progress__2662 *)&Progress_global_progress__3226))->need_clear) = false;
 /* file:5:14 */
 t2 = Progress_write__3270((nav__3251_68){(uint8_t const *)&__anon_2943,(uintptr_t)3ul});
 if (t2) {
  /* file:5:5 */
  return t2;
 }
 return 0;
}

static nav__1571_38 posix_write__1571(int32_t const a0, nav__1571_40 const a1) {
 uintptr_t t0;
 uint64_t t1;
 uint8_t const *t3;
 intptr_t t5;
 nav__1571_38 t7;
 uint32_t t4;
 uint16_t t6;
 bool t2;
 /* file:2:9 */
 /* file:2:14 */
 t0 = a1.len;
 t1 = t0;
 t2 = t1 == UINT64_C(0);
 if (t2) {
  /* file:2:25 */
  return (nav__1571_38){(uintptr_t)0ul,0};
 }
 goto zig_block_0;

 zig_block_0:;
 /* file:32:31 */
 /* file:34:59 */
 zig_loop_22:
 /* file:37:12 */
 /* file:38:42 */
 t3 = a1.ptr;
 /* file:38:58 */
 t0 = a1.len;
 t0 = ((uintptr_t)2147483647ul < t0) ? (uintptr_t)2147483647ul : t0;
 t4 = (uint32_t)t0;
 t0 = (uintptr_t)t4;
 /* file:38:32 */
 t5 = write(a0, t3, t0);
 /* dbg_var_val:rc */
 /* file:39:22 */
 t6 = posix_errno__anon_2965__3477(t5);
 /* file:39:17 */
 switch (t6) {
  case UINT16_C(0): {
   /* file:40:32 */
   t0 = (uintptr_t)t5;
   /* file:40:25 */
   t7.payload = t0;
   t7.error = UINT16_C(0);
   return t7;
  }
  case UINT16_C(4): {
   goto zig_block_1;
  }
  case UINT16_C(22): {
   /* file:42:23 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_InvalidArgument};
  }
  case UINT16_C(14): {
   /* file:43:23 */
   zig_unreachable();
  }
  case UINT16_C(2): {
   /* file:44:23 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_ProcessNotFound};
  }
  case UINT16_C(35): {
   /* file:45:23 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_WouldBlock};
  }
  case UINT16_C(9): {
   /* file:46:22 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_NotOpenForWriting};
  }
  case UINT16_C(39): {
   /* file:47:29 */
   zig_unreachable();
  }
  case UINT16_C(69): {
   /* file:48:23 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_DiskQuota};
  }
  case UINT16_C(27): {
   /* file:49:22 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_FileTooBig};
  }
  case UINT16_C(5): {
   /* file:50:20 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_InputOutput};
  }
  case UINT16_C(28): {
   /* file:51:23 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_NoSpaceLeft};
  }
  case UINT16_C(13): {
   /* file:52:23 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_AccessDenied};
  }
  case UINT16_C(1): {
   /* file:53:22 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_AccessDenied};
  }
  case UINT16_C(32): {
   /* file:54:22 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_BrokenPipe};
  }
  case UINT16_C(54): {
   /* file:55:27 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_ConnectionResetByPeer};
  }
  case UINT16_C(16): {
   /* file:56:22 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_DeviceBusy};
  }
  case UINT16_C(6): {
   /* file:57:22 */
   return (nav__1571_38){(uintptr_t)0xaaaaaaaaaaaaaaaaul,zig_error_NoDevice};
  }
  default: {
   /* dbg_var_val:err */
   /* file:58:49 */
   t6 = posix_unexpectedErrno__1835(t6);
   /* file:58:27 */
   t7.payload = (uintptr_t)0xaaaaaaaaaaaaaaaaul;
   t7.error = t6;
   return t7;
  }
 }

 zig_block_1:;
 goto zig_loop_22;
}

static uint16_t io_Writer_writeAll__3203(struct io_Writer__2628 const a0, nav__3203_40 const a1) {
 struct io_Writer__2628 const *t1;
 nav__3203_40 const *t3;
 uintptr_t t5;
 uintptr_t t6;
 uintptr_t t13;
 uintptr_t t4;
 uint64_t t7;
 uint64_t t8;
 struct io_Writer__2628 t10;
 struct io_Writer__2628 t0;
 nav__3203_40 t11;
 nav__3203_40 t2;
 uint8_t const *t12;
 nav__3203_43 t14;
 uint16_t t15;
 bool t9;
 t0 = a0;
 t1 = (struct io_Writer__2628 const *)&t0;
 t2 = a1;
 t3 = (nav__3203_40 const *)&t2;
 /* file:2:5 */
 t4 = (uintptr_t)0ul;
 /* dbg_var_ptr:index */
 zig_loop_13:
 /* file:3:12 */
 t5 = t4;
 /* file:3:26 */
 t6 = a1.len;
 t7 = t5;
 t8 = t6;
 t9 = t7 != t8;
 if (t9) {
  /* file:4:9 */
  t6 = t4;
  /* file:4:32 */
  t10 = (*t1);
  t5 = t4;
  /* file:4:38 */
  t11 = (*t3);
  t12 = t11.ptr;
  t12 = (uint8_t const *)(((uintptr_t)t12) + (t5*sizeof(uint8_t)));
  t13 = t11.len;
  t5 = t13 - t5;
  t11.ptr = t12;
  t11.len = t5;
  /* file:4:32 */
  t14 = io_Writer_write__3202(t10, t11);
  if (t14.error) {
   t15 = t14.error;
   /* file:4:18 */
   return t15;
  }
  t5 = t14.payload;
  /* file:4:15 */
  t5 = t6 + t5;
  t4 = t5;
  /* file:5:5 */
  (void)0;
  goto zig_block_1;
 }
 goto zig_block_0;

 zig_block_1:;
 goto zig_loop_13;

 zig_block_0:;
 return 0;
}

static void Thread_Mutex_Recursive_unlock__3468(struct Thread_Mutex_Recursive__2766 *const a0) {
 struct Thread_Mutex_Recursive__2766 *const *t1;
 struct Thread_Mutex_Recursive__2766 *t2;
 struct Thread_Mutex_Recursive__2766 *t0;
 uintptr_t *t3;
 uintptr_t t4;
 uint64_t t5;
 uint64_t *t7;
 struct Thread_Mutex__2764 *t8;
 bool t6;
 t0 = a0;
 t1 = (struct Thread_Mutex_Recursive__2766 *const *)&t0;
 /* file:2:6 */
 t2 = (*t1);
 t3 = (uintptr_t *)&t2->lock_count;
 t4 = (*t3);
 /* file:2:18 */
 t4 = t4 - (uintptr_t)1ul;
 (*t3) = t4;
 /* file:3:9 */
 /* file:3:10 */
 t3 = (uintptr_t *)&a0->lock_count;
 t4 = (*t3);
 t5 = t4;
 t6 = t5 == UINT64_C(0);
 if (t6) {
  /* file:4:39 */
  t2 = (*t1);
  t7 = (uint64_t *)&t2->thread_id;
  t5 = UINT64_MAX;
  zig_atomic_store((zig_atomic(uint64_t) *)t7, t5, zig_memory_order_relaxed, u64, uint64_t);
  /* file:5:10 */
  t2 = (*t1);
  t8 = (struct Thread_Mutex__2764 *)&t2->mutex;
  /* file:5:23 */
  Thread_Mutex_unlock__3449(t8);
  goto zig_block_0;
 }
 goto zig_block_0;

 zig_block_0:;
 return;
}

static uint64_t Thread_getCurrentId__3308(void) {
 uint64_t t0;
 /* file:2:29 */
 t0 = Thread_PosixThreadImpl_getCurrentId__3378();
 /* file:2:5 */
 return t0;
}

static void Thread_Mutex_lock__3448(struct Thread_Mutex__2764 *const a0) {
 struct Thread_Mutex__2764 *const *t1;
 struct Thread_Mutex__2764 *t2;
 struct Thread_Mutex__2764 *t0;
 struct Thread_Mutex_DarwinImpl__2775 *t3;
 t0 = a0;
 t1 = (struct Thread_Mutex__2764 *const *)&t0;
 /* file:2:9 */
 t2 = (*t1);
 t3 = (struct Thread_Mutex_DarwinImpl__2775 *)&t2->impl;
 /* file:2:19 */
 Thread_Mutex_DarwinImpl_lock__3471(t3);
 return;
}

static void debug_assert__179(bool const a0) {
 bool t0;
 /* file:2:9 */
 t0 = !a0;
 if (t0) {
  /* file:2:14 */
  zig_unreachable();
 }
 goto zig_block_0;

 zig_block_0:;
 return;
}

static uint16_t Progress_write__3270(nav__3270_39 const a0) {
 struct fs_File__2581 t0;
 uint16_t t1;
 /* file:2:42 */
 t0 = (*&(((struct Progress__2662 *)&Progress_global_progress__3226))->terminal);
 /* file:2:42 */
 t1 = fs_File_writeAll__3142(t0, a0);
 if (t1) {
  /* file:2:5 */
  return t1;
 }
 return 0;
}

static uint16_t posix_errno__anon_2965__3477(intptr_t const a0) {
 int64_t t1;
 int *t3;
 int t4;
 uint16_t t0;
 uint16_t t5;
 bool t2;
 /* file:2:9 */
 /* file:3:20 */
 t1 = a0;
 t2 = t1 == -INT64_C(1);
 if (t2) {
  /* file:3:55 */
  t3 = zig_e___error();
  t4 = (*t3);
  /* file:3:30 */
  t5 = (uint16_t)t4;
  t0 = t5;
  goto zig_block_0;
 }
 t0 = UINT16_C(0);
 goto zig_block_0;

 zig_block_0:;
 /* file:3:9 */
 return t0;
}

static uint16_t posix_unexpectedErrno__1835(uint16_t const a0) {
 (void)a0;
 /* file:6:5 */
 return zig_error_Unexpected;
}

static nav__3202_38 io_Writer_write__3202(struct io_Writer__2628 const a0, nav__3202_41 const a1) {
 struct io_Writer__2628 const *t1;
 nav__3202_38 (*const *t2)(void const *, nav__3202_41);
 nav__3202_38 (*t3)(void const *, nav__3202_41);
 void const *t4;
 nav__3202_38 t5;
 struct io_Writer__2628 t0;
 t0 = a0;
 t1 = (struct io_Writer__2628 const *)&t0;
 /* file:2:24 */
 t2 = (nav__3202_38 (*const *)(void const *, nav__3202_41))&t1->writeFn;
 t3 = (*t2);
 /* file:2:29 */
 t4 = a0.context;
 /* file:2:24 */
 t5 = t3(t4, a1);
 /* file:2:5 */
 return t5;
}

static void Thread_Mutex_unlock__3449(struct Thread_Mutex__2764 *const a0) {
 struct Thread_Mutex__2764 *const *t1;
 struct Thread_Mutex__2764 *t2;
 struct Thread_Mutex__2764 *t0;
 struct Thread_Mutex_DarwinImpl__2775 *t3;
 t0 = a0;
 t1 = (struct Thread_Mutex__2764 *const *)&t0;
 /* file:2:9 */
 t2 = (*t1);
 t3 = (struct Thread_Mutex_DarwinImpl__2775 *)&t2->impl;
 /* file:2:21 */
 Thread_Mutex_DarwinImpl_unlock__3472(t3);
 return;
}

static uint64_t Thread_PosixThreadImpl_getCurrentId__3378(void) {
 uint64_t t4;
 uint64_t t0;
 int t1;
 int32_t t2;
 bool t3;
 /* file:2:17 */
 /* file:7:17 */
 /* dbg_var_ptr:thread_id */
 /* file:9:45 */
 t1 = pthread_threadid_np(NULL, &t0);
 t2 = t1;
 t3 = t2 == INT32_C(0);
 /* file:9:23 */
 debug_assert__179(t3);
 /* file:10:17 */
 t4 = t0;
 /* file:10:17 */
 return t4;
}

static void Thread_Mutex_DarwinImpl_lock__3471(struct Thread_Mutex_DarwinImpl__2775 *const a0) {
 struct Thread_Mutex_DarwinImpl__2775 *const *t1;
 struct Thread_Mutex_DarwinImpl__2775 *t2;
 struct Thread_Mutex_DarwinImpl__2775 *t0;
 struct c_darwin_os_unfair_lock__2781 *t3;
 t0 = a0;
 t1 = (struct Thread_Mutex_DarwinImpl__2775 *const *)&t0;
 /* file:2:36 */
 t2 = (*t1);
 t3 = (struct c_darwin_os_unfair_lock__2781 *)&t2->oul;
 /* file:2:30 */
 os_unfair_lock_lock(t3);
 return;
}

static uint16_t fs_File_writeAll__3142(struct fs_File__2581 const a0, nav__3142_40 const a1) {
 struct fs_File__2581 const *t1;
 nav__3142_40 const *t3;
 uintptr_t t5;
 uintptr_t t6;
 uintptr_t t13;
 uintptr_t t4;
 uint64_t t7;
 uint64_t t8;
 nav__3142_40 t11;
 nav__3142_40 t2;
 uint8_t const *t12;
 nav__3142_47 t14;
 struct fs_File__2581 t10;
 struct fs_File__2581 t0;
 uint16_t t15;
 bool t9;
 t0 = a0;
 t1 = (struct fs_File__2581 const *)&t0;
 t2 = a1;
 t3 = (nav__3142_40 const *)&t2;
 /* file:2:5 */
 t4 = (uintptr_t)0ul;
 /* dbg_var_ptr:index */
 zig_loop_13:
 /* file:3:12 */
 t5 = t4;
 /* file:3:25 */
 t6 = a1.len;
 t7 = t5;
 t8 = t6;
 t9 = t7 < t8;
 if (t9) {
  /* file:4:9 */
  t6 = t4;
  /* file:4:32 */
  t10 = (*t1);
  t5 = t4;
  /* file:4:38 */
  t11 = (*t3);
  t12 = t11.ptr;
  t12 = (uint8_t const *)(((uintptr_t)t12) + (t5*sizeof(uint8_t)));
  t13 = t11.len;
  t5 = t13 - t5;
  t11.ptr = t12;
  t11.len = t5;
  /* file:4:32 */
  t14 = fs_File_write__3141(t10, t11);
  if (t14.error) {
   t15 = t14.error;
   /* file:4:18 */
   return t15;
  }
  t5 = t14.payload;
  /* file:4:15 */
  t5 = t6 + t5;
  t4 = t5;
  /* file:5:5 */
  (void)0;
  goto zig_block_1;
 }
 goto zig_block_0;

 zig_block_1:;
 goto zig_loop_13;

 zig_block_0:;
 return 0;
}

static void Thread_Mutex_DarwinImpl_unlock__3472(struct Thread_Mutex_DarwinImpl__2775 *const a0) {
 struct Thread_Mutex_DarwinImpl__2775 *const *t1;
 struct Thread_Mutex_DarwinImpl__2775 *t2;
 struct Thread_Mutex_DarwinImpl__2775 *t0;
 struct c_darwin_os_unfair_lock__2781 *t3;
 t0 = a0;
 t1 = (struct Thread_Mutex_DarwinImpl__2775 *const *)&t0;
 /* file:2:38 */
 t2 = (*t1);
 t3 = (struct c_darwin_os_unfair_lock__2781 *)&t2->oul;
 /* file:2:32 */
 os_unfair_lock_unlock(t3);
 return;
}

static uint64_t const builtin_zig_backend__230 = UINT64_C(3);

static bool const start_simplified_logic__109 = false;

static uint8_t const builtin_output_mode__231 = UINT8_C(0);

static bool const builtin_link_libc__242 = true;

static struct Target_Cpu_Feature_Set__268 const Target_Cpu_Feature_Set_empty__399 = {{0ul,0ul,0ul,0ul,0ul}};

static struct Target_Cpu__180 const builtin_cpu__237 = {((struct Target_Cpu_Model__263 const *)&Target_aarch64_cpu_apple_m3__438),{{4778387673096168410ul,7483071344772087ul,4647719625810214912ul,746622913ul,0ul}},UINT8_C(6)};

static uint8_t const start_native_arch__106 = UINT8_C(6);

static struct Target_Os__1419 const builtin_os__238 = {{ .semver = {{15ul,0ul,1ul,{NULL,0xaaaaaaaaaaaaaaaaul},{NULL,0xaaaaaaaaaaaaaaaaul}},{15ul,0ul,1ul,{NULL,0xaaaaaaaaaaaaaaaaul},{NULL,0xaaaaaaaaaaaaaaaaul}}} },UINT8_C(20)};

static uint8_t const builtin_abi__236 = UINT8_C(0);

static uint8_t const builtin_object_format__240 = UINT8_C(0);

static struct Target_DynamicLinker__1434 const Target_DynamicLinker_none__859 = {"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252",UINT8_C(0)};

static struct Target__178 const builtin_target__239 = {{((struct Target_Cpu_Model__263 const *)&Target_aarch64_cpu_apple_m3__438),{{4778387673096168410ul,7483071344772087ul,4647719625810214912ul,746622913ul,0ul}},UINT8_C(6)},{{ .semver = {{15ul,0ul,1ul,{NULL,0xaaaaaaaaaaaaaaaaul},{NULL,0xaaaaaaaaaaaaaaaaul}},{15ul,0ul,1ul,{NULL,0xaaaaaaaaaaaaaaaaul},{NULL,0xaaaaaaaaaaaaaaaaul}}} },UINT8_C(20)},UINT8_C(0),UINT8_C(0),{"/usr/lib/dyld\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252",UINT8_C(13)}};

static struct builtin_CallingConvention__832 const builtin_CallingConvention_c__780 = {{ .aarch64_aapcs_darwin = {{UINT64_C(0xaaaaaaaaaaaaaaaa),true}} },UINT8_C(21)};

static uint8_t const builtin_mode__241 = UINT8_C(2);

static bool const debug_runtime_safety__159 = false;

static bool const debug_default_enable_segfault_handler__204 = false;

static uint8_t const log_default_level__1032 = UINT8_C(0);

static struct std_Options__2244 const std_options__97 = {{0xaaaaaaaaaaaaaaaaul,true},{0xaaaaaaaaaaaaaaaaul,true},3ul,false,UINT8_C(0),false,true,false,false,false,UINT8_C(2)};

static bool const debug_enable_segfault_handler__203 = false;

static bool const posix_use_libc__1404 = true;

static uint8_t const c_native_os__1846 = UINT8_C(20);

static uint32_t const c_empty_sigset__1944 = UINT32_C(0);

static uint32_t const posix_empty_sigset__1480 = UINT32_C(0);

static bool const Progress_is_windows__3222 = false;

static uint8_t const Thread_native_os__3287 = UINT8_C(20);

static bool const Thread_use_pthreads__3298 = true;

static bool const builtin_single_threaded__235 = false;

static uint64_t const Thread_Mutex_Recursive_invalid_thread_id__3469 = UINT64_MAX;

static struct Thread_Mutex_Recursive__2766 const Thread_Mutex_Recursive_init__3465 = {UINT64_MAX,0ul,{{{UINT32_C(0)}}}};

static struct Thread_Mutex_Recursive__2766 Progress_stderr_mutex__3277 = {UINT64_MAX,0ul,{{{UINT32_C(0)}}}};

static bool const io_is_windows__3013 = false;

static bool const fs_File_is_windows__3182 = false;

static uint16_t const fmt_max_format_args__1236 = UINT16_C(32);

static struct Progress__2662 Progress_global_progress__3226 = {{{{((void *)(uintptr_t)0xaaaaaaaaaaaaaaaaul)}},true},UINT64_C(0xaaaaaaaaaaaaaaaa),UINT64_C(0xaaaaaaaaaaaaaaaa),{(uint8_t *)(uintptr_t)0xaaaaaaaaaaaaaaaaul, (uintptr_t)0xaaaaaaaaaaaaaaaaul},{(uint8_t *)&Progress_node_parents_buffer__3228,83ul},{(struct Progress_Node_Storage__2711 *)&Progress_node_storage_buffer__3229,83ul},{(uint8_t *)&Progress_node_freelist_buffer__3230,83ul},{-INT32_C(0x55555556)},{{{UINT32_C(0)}}},UINT32_C(0),UINT16_C(0),UINT16_C(0),{UINT8_C(0)},false,false,UINT8_MAX};

static uint8_t const (*const Progress_clear__3245)[4] = &__anon_2943;

static uint8_t const posix_native_os__1402 = UINT8_C(20);

static bool const posix_unexpected_error_tracing__1833 = false;

static struct Target_Cpu_Model__263 const Target_aarch64_cpu_apple_m3__438 = {{(uint8_t const *)&__anon_3089,8ul},{(uint8_t const *)&__anon_3092,8ul},{{144115462953763594ul,4398046544884ul,4398046773248ul,201328640ul,0ul}}};

static nav__924_40 os_argv__924 = {(uint8_t **)(uintptr_t)0xaaaaaaaaaaaaaaaaul, (uintptr_t)0xaaaaaaaaaaaaaaaaul};

static nav__923_40 os_environ__923 = {(uint8_t **)(uintptr_t)0xaaaaaaaaaaaaaaaaul, (uintptr_t)0xaaaaaaaaaaaaaaaaul};

struct macho_mach_header_64__3150 c_dummy_execute_header__1864 = {UINT32_C(0xaaaaaaaa),-0x55555556,-0x55555556,UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa)};

static uint8_t Progress_node_parents_buffer__3228[83] = {UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa)};

static struct Progress_Node_Storage__2711 Progress_node_storage_buffer__3229[83] = {{UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}, {UINT32_C(0xaaaaaaaa),UINT32_C(0xaaaaaaaa),"\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252\252"}};

static uint8_t Progress_node_freelist_buffer__3230[83] = {UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa), UINT8_C(0xaa)};
