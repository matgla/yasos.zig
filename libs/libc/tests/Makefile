CC = gcc
CFLAGS = -Wall -g
SRCS = $(wildcard *.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))
TARGET = build/libc_tests

# Rules
all: $(TARGET)

build/%.o: %.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) $^ -o $@

clean:
	rm -rf build
