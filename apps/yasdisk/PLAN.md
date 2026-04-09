# yasdisk - Plan

## Overview
yasdisk is an fdisk clone that supports MBR (Master Boot Record) partition table creation on block devices with a simple ncurses-based terminal GUI.

## Architecture

### File Structure
```
yasdisk/
├── main.c          # Entry point, command line parsing, main loop
├── mbr.c/h         # MBR data structures and operations
├── disk.c/h        # Block device I/O operations
├── ui.c/h          # ncurses UI components and screens
├── utils.c/h       # Helper functions (CHS calculations, etc.)
├── Makefile        # Build configuration
└── tests/
    ├── Makefile           # Test build configuration
    ├── acutest.h          # Test framework
    ├── mbr_tests.c        # MBR unit tests
    ├── disk_tests.c       # Disk I/O unit tests
    ├── ui_tests.c         # UI unit tests (with mocks)
    ├── mock_ncurses.c/h   # Mock ncurses for testing
    └── integration/
        ├── conftest.py          # pytest configuration
        ├── requirements.txt     # Python test dependencies
        ├── yasdisk_session.py   # Test session helper
        └── test_cases/
            └── test_basic.py    # Basic integration tests
```

## Components

### 1. mbr.h / mbr.c
**Purpose:** MBR data structures and operations

**Data Structures:**
```c
typedef struct {
    uint8_t boot_flag;        // 0x80 = bootable, 0x00 = not bootable
    uint8_t start_chs[3];     // CHS start address
    uint8_t type;             // Partition type (0x83 = Linux, etc.)
    uint8_t end_chs[3];       // CHS end address
    uint32_t start_lba;       // LBA start sector
    uint32_t sector_count;    // Number of sectors
} PartitionEntry;

typedef struct {
    uint8_t boot_code[446];           // Boot loader code
    PartitionEntry partitions[4];     // 4 partition entries
    uint16_t signature;               // 0xAA55 (little endian: 0x55, 0xAA)
} MBR;

typedef struct {
    MBR mbr;
    char device_path[256];
    uint64_t device_size;
    uint32_t sector_size;
    int dirty;                // Flag: 1 if modified, 0 if clean
} Disk;
```

**Functions:**
- `mbr_init(Disk* disk)` - Initialize empty MBR
- `mbr_load(Disk* disk, const char* path)` - Load MBR from device
- `mbr_save(Disk* disk)` - Write MBR to device
- `mbr_is_valid(MBR* mbr)` - Check MBR signature
- `partition_is_empty(PartitionEntry* pe)` - Check if partition entry is unused
- `partition_set_chs(PartitionEntry* pe, ...)` - Set CHS values from LBA
- `partition_get_type_name(uint8_t type)` - Get human-readable type name
- `partition_create(...)` - Create new partition
- `partition_delete(Disk* disk, int index)` - Delete partition

### 2. disk.h / disk.c
**Purpose:** Block device I/O operations

**Functions:**
- `disk_open(Disk* disk, const char* path)` - Open block device, get size
- `disk_close(Disk* disk)` - Close device
- `disk_read_sector(Disk* disk, uint64_t sector, void* buffer)` - Read sector
- `disk_write_sector(Disk* disk, uint64_t sector, const void* buffer)` - Write sector
- `disk_get_size(const char* path, uint64_t* size)` - Get device size in bytes
- `disk_get_sector_size(const char* path, uint32_t* size)` - Get sector size (usually 512)

### 3. ui.h / ui.c
**Purpose:** ncurses-based terminal GUI

**Screens:**
1. **Main Screen** - List all 4 partitions with details
2. **Partition Edit Screen** - Edit partition parameters
3. **Confirm Screen** - Confirm write to disk
4. **Help Screen** - Show available commands

**UI Elements:**
- Header with device info
- Partition list table (4 rows)
- Status bar with commands
- Message/dialog windows

**Key Bindings:**
- `↑/↓` or `k/j` - Navigate partitions
- `n` - New partition
- `d` - Delete partition
- `t` - Change partition type
- `a` - Toggle bootable flag
- `w` - Write changes to disk
- `q` - Quit (with confirmation if unsaved)
- `?` - Help

### 4. utils.h / utils.c
**Purpose:** Helper utilities

**Functions:**
- `lba_to_chs(uint32_t lba, ...)` - Convert LBA to CHS
- `chs_to_lba(...)` - Convert CHS to LBA
- `format_size(uint64_t bytes)` - Format bytes to human-readable (KB, MB, GB)
- `align_sector(uint64_t sector)` - Align to 1MiB boundary (2048 sectors)

## Implementation Phases

### Phase 1: Core MBR/Disk Functions
- [ ] Implement mbr.c with all MBR operations
- [ ] Implement disk.c for block device I/O
- [ ] Implement utils.c for CHS conversions
- [ ] Write unit tests for MBR operations
- [ ] Write unit tests for disk operations

### Phase 2: ncurses UI
- [ ] Implement basic ncurses initialization
- [ ] Implement main partition list screen
- [ ] Implement partition edit dialog
- [ ] Implement confirmation dialogs
- [ ] Write mock ncurses for testing
- [ ] Write UI unit tests

### Phase 3: Integration
- [ ] Wire up UI to MBR/Disk functions
- [ ] Implement main event loop
- [ ] Add command line argument parsing
- [ ] Write integration tests

### Phase 4: Polish
- [ ] Error handling
- [ ] Help screen
- [ ] Documentation
- [ ] Code cleanup

## MBR Partition Types (Common)
| Type | Description |
|------|-------------|
| 0x00 | Empty |
| 0x01 | FAT12 |
| 0x04 | FAT16 (<32MB) |
| 0x06 | FAT16 (>=32MB) |
| 0x07 | NTFS/exFAT |
| 0x0B | W95 FAT32 |
| 0x0C | W95 FAT32 (LBA) |
| 0x0E | W95 FAT16 (LBA) |
| 0x82 | Linux swap |
| 0x83 | Linux |
| 0x8E | Linux LVM |
| 0xA5 | FreeBSD |
| 0xA6 | OpenBSD |
| 0xA9 | NetBSD |
| 0xEE | GPT protective |
| 0xEF | EFI System |

## CHS Calculation
- Cylinders: 10 bits (0-1023)
- Heads: 8 bits (0-255)
- Sectors: 6 bits (1-63)
- For modern drives: CHS is mostly ignored, LBA is used

## Safety Considerations
1. Always show warning before writing to disk
2. Verify device is a block device before opening
3. Create backup of original MBR before writing
4. Validate partition bounds (no overlapping, within device size)
5. Require explicit confirmation for destructive operations

## Testing Strategy

### Unit Tests (C + acutest)
- MBR structure packing/unpacking
- CHS/LBA conversions
- Partition validation logic
- Mock disk I/O

### Integration Tests (Python + pexpect)
- Create partition table on loopback device
- Delete and recreate partitions
- Verify written data with dd/hexdump
- Test UI navigation and key bindings

## Build System

### Main Makefile
```makefile
CC ?= armv8m-tcc
CFLAGS = -g -fvisibility=hidden -Wall -Wextra
LDFLAGS = -g -fvisibility=hidden

ifeq ($(CC), armv8m-tcc)
CFLAGS += -I../../rootfs/usr/include
LDFLAGS += -L../../rootfs/lib -lncurses
else
CFLAGS += -I../../libs/yasos_curses/include
LDFLAGS += -L../../libs/yasos_curses/build -Wl,-rpath=$(PWD)/../../libs/yasos_curses/build -lncurses
endif

TARGET = build/yasdisk
```

## Future Enhancements (Out of Scope)
- GPT support
- Extended partitions
- Filesystem detection
- Partition resizing
- LUKS detection
