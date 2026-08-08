#
# yasdisk Tests Makefile
#

CC = gcc
CFLAGS = -Wall -Wextra -Werror -std=c11 -I. -I..
LDFLAGS =

ifeq ($(CC), gcc)
CFLAGS += -fsanitize=address
LDFLAGS += -fsanitize=address
endif

# System Under Test sources
SUT_SRCS = ../mbr.c

# Test sources
TEST_NAMES = mbr_tests disk_tests

TEST_BINS = $(patsubst %,build/%,$(TEST_NAMES))

all: $(TEST_BINS) run

build:
	mkdir -p build

build/mbr_tests: mbr_tests.c $(SUT_SRCS) acutest.h | build
	$(CC) $(CFLAGS) -o $@ mbr_tests.c $(SUT_SRCS) $(LDFLAGS)

build/disk_tests: disk_tests.c $(SUT_SRCS) acutest.h | build
	$(CC) $(CFLAGS) -o $@ disk_tests.c $(SUT_SRCS) $(LDFLAGS)

run: $(TEST_BINS)
	@for test in $(TEST_NAMES); do \
		echo "Running build/$$test..."; \
		./build/$$test || exit 1; \
	done

# Integration test settings
INTEGRATION_DIR := integration
VENV_DIR := $(INTEGRATION_DIR)/venv
PYTHON := $(VENV_DIR)/bin/python
PIP := $(VENV_DIR)/bin/pip
PYTEST := $(VENV_DIR)/bin/pytest

# Setup integration test environment
.PHONY: integration-setup
integration-setup:
	@echo "Setting up integration test environment..."
	@test -d $(VENV_DIR) || python3 -m venv $(VENV_DIR)
	$(PIP) install -q -r $(INTEGRATION_DIR)/requirements.txt
	@echo "Integration test environment ready!"

# Run integration tests
.PHONY: integration
integration: integration-setup
	@echo "Running integration tests..."
	cd $(INTEGRATION_DIR) && ../$(PYTEST) test_cases/ -v --tb=short

# Run integration tests verbose
.PHONY: integration-verbose
integration-verbose: integration-setup
	cd $(INTEGRATION_DIR) && ../$(PYTEST) test_cases/ -v -s --tb=long

clean:
	rm -rf build
	rm -rf $(VENV_DIR)
	rm -rf $(INTEGRATION_DIR)/__pycache__
	find $(INTEGRATION_DIR) -name "*.pyc" -delete 2>/dev/null || true

.PHONY: all clean run integration integration-setup
