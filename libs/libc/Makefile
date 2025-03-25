CC = tcc 
CFLAGS = -std=c11 -Wall -Iinclude -Ilibs -g -fPIC -pedantic -nostdinc -I../../source/sys/include
LDFLAGS_STATIC = -nostdlib
LDFLAGS = -shared -fPIC ${LDFLAGS_STATIC} 

SRCS = $(wildcard *.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))

TARGET_SHARED = build/libc.so
TARGET_STATIC = build/libc.a

# Rules
all: $(TARGET_SHARED) ${TARGET_STATIC}

build/%.o: %.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET_SHARED): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(TARGET_STATIC): $(OBJS)
	ar rcs $@ $^

clean:
	rm -rf build