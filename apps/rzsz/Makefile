CC ?= armv8m-tcc
CFLAGS = -g -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib
LDFLAGS = -fvisibility=hidden -g
SRCS = $(wildcard *.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))
LDFLAGS_ELF = $(LDFLAGS) 

TARGET = build/rz

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
INCLUDEDIR ?= $(PREFIX)/include

ifeq ($(CC), armv8m-tcc)
    LDFLAGS_ELF += -Wl,-oformat=elf32-littlearm
endif


# Rules
all: $(TARGET) $(TARGET).elf

build/%.o: %.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(TARGET).elf: $(OBJS)
	$(CC) $(LDFLAGS_ELF) $^ -o $@

install: $(TARGET) 
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

clean:
	rm -rf build