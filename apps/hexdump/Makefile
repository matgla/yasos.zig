CC ?= armv8m-tcc
CFLAGS = -g -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib
LDFLAGS = -g -fvisibility=hidden -g 
SRCS = $(wildcard *.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))

TARGET = build/hexdump

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
INCLUDEDIR ?= $(PREFIX)/include

# Rules
all: $(TARGET)

build/%.o: %.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

install: $(TARGET) 
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

clean:
	rm -rf build