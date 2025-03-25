CC = tcc 
CFLAGS = -Wall -pedantic -g -std=c11 -I../../../source/sys/include

SRCS = $(wildcard *.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))


TARGET = build/libc_tests
LIBC_STATIC = ../build/libc.a
LIBC_TEST_STATIC = build/libc_sut.a
SYMBOLS_REDEFINES = symbols_redefines.txt 
LIBC_SRCS = $(wildcard ../*.c)

# Rules
all: $(TARGET)

build/%.o: %.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(LIBC_STATIC): $(LIBC_SRCS)
	$(MAKE) -C ..

$(LIBC_TEST_STATIC): $(LIBC_STATIC)
	cp $(LIBC_STATIC) $(LIBC_TEST_STATIC)
	objcopy --redefine-syms=$(SYMBOLS_REDEFINES) $(LIBC_TEST_STATIC)

$(TARGET): $(OBJS) $(LIBC_TEST_STATIC)
	$(CC) $(CFLAGS) $^ -o $@ 

test: $(TARGET)
	./$(TARGET)

clean:
	rm -rf build
	$(MAKE) -C .. clean
