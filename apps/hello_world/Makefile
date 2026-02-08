CC ?= armv8m-tcc
CFLAGS = -g -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib
LDFLAGS = -g -fvisibility=hidden -g -L../../rootfs/lib
SRCS = $(wildcard *.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))

TARGET = build/hello

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
INCLUDEDIR ?= $(PREFIX)/include

# Rules
all: $(TARGET) $(TARGET).elf

build/%.o: %.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -Wl,-oformat=yaff $^ -o $@


$(TARGET).elf: $(OBJS)
	$(CC) $(LDFLAGS) -Wl,-oformat=elf32-littlearm $^ -o $@



install: $(TARGET)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

clean:
	rm -rf build