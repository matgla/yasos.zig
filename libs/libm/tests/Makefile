CC = gcc
CFLAGS = -Wall -pedantic -g -std=c11 -I../include
# tcc is safe by default (yasc, -Wall, unsafe C as errors); this code is
# regular C until it is ported, so -ccompat whenever CC is a tcc.
CFLAGS += $(if $(findstring tcc,$(notdir $(firstword $(CC)))),-ccompat)

SRCS = $(wildcard *.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))

TARGET = build/libm_tests
LIBM_SRCS = $(wildcard ../*.c) $(wildcard ../include/*.h)

# Rules
all: $(TARGET) test

build/%.o: %.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

# Build static library directly for testing
build/libm.a: $(LIBM_SRCS)
	mkdir -p build
	$(CC) $(CFLAGS) -c ../math.c -o build/math.o
	ar rcs $@ build/math.o

$(TARGET): $(OBJS) build/libm.a
	$(CC) $(CFLAGS) $^ -o $@ -lm

test: $(TARGET)
	./$(TARGET)

build_tests: $(TARGET)

clean:
	rm -rf build
