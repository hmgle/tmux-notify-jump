.PHONY: all test test-verbose install-deps clean help

BATS := $(shell command -v bats 2>/dev/null)
TEST_FILES := $(wildcard *.bats)

# Default target
all: test

# Run all tests
test:
ifndef BATS
	@echo "Error: bats-core is not installed."
	@echo "Install it with: brew install bats-core (macOS) or apt install bats (Linux)"
	@exit 1
endif
	@echo "Running tests..."
	@bats $(TEST_FILES)

# Run tests with verbose output
test-verbose:
ifndef BATS
	@echo "Error: bats-core is not installed."
	@echo "Install it with: brew install bats-core (macOS) or apt install bats (Linux)"
	@exit 1
endif
	@echo "Running tests (verbose)..."
	@bats --verbose-run $(TEST_FILES)

# Run a specific test file
# Usage: make test-file FILE=lib_validators.bats
test-file:
ifndef BATS
	@echo "Error: bats-core is not installed."
	@exit 1
endif
ifndef FILE
	@echo "Usage: make test-file FILE=<test_file.bats>"
	@exit 1
endif
	@bats $(FILE)

# Run tests matching a filter
# Usage: make test-filter FILTER="is_integer"
test-filter:
ifndef BATS
	@echo "Error: bats-core is not installed."
	@exit 1
endif
ifndef FILTER
	@echo "Usage: make test-filter FILTER=<pattern>"
	@exit 1
endif
	@bats --filter "$(FILTER)" $(TEST_FILES)

# Run tests with TAP output (for CI)
test-tap:
ifndef BATS
	@echo "Error: bats-core is not installed."
	@exit 1
endif
	@bats --tap $(TEST_FILES)

# Install dependencies (macOS)
install-deps-macos:
	@echo "Installing bats-core via Homebrew..."
	brew install bats-core

# Install dependencies (Linux/Debian)
install-deps-linux:
	@echo "Installing bats-core..."
	@if command -v apt-get >/dev/null 2>&1; then \
		sudo apt-get update && sudo apt-get install -y bats; \
	elif command -v dnf >/dev/null 2>&1; then \
		sudo dnf install -y bats; \
	elif command -v pacman >/dev/null 2>&1; then \
		sudo pacman -S --noconfirm bash-bats; \
	else \
		echo "Please install bats-core manually: https://github.com/bats-core/bats-core"; \
		exit 1; \
	fi

# Auto-detect OS and install
install-deps:
	@if [ "$$(uname)" = "Darwin" ]; then \
		$(MAKE) install-deps-macos; \
	else \
		$(MAKE) install-deps-linux; \
	fi

# List available tests
list:
	@echo "Available test files:"
	@for f in $(TEST_FILES); do echo "  $$f"; done
	@echo ""
	@echo "Test counts:"
	@for f in $(TEST_FILES); do \
		count=$$(grep -c '^@test' "$$f" 2>/dev/null || echo 0); \
		echo "  $$f: $$count tests"; \
	done
	@total=$$(grep -h '^@test' $(TEST_FILES) 2>/dev/null | wc -l | tr -d ' '); \
	echo ""; \
	echo "Total: $$total tests"

# Clean up temporary files
clean:
	@echo "Cleaning up..."
	@rm -rf /tmp/tmux-notify-test.*

# Show help
help:
	@echo "tmux-notify-jump Test Suite"
	@echo ""
	@echo "Targets:"
	@echo "  make test          - Run all tests"
	@echo "  make test-verbose  - Run tests with verbose output"
	@echo "  make test-file FILE=<file>  - Run a specific test file"
	@echo "  make test-filter FILTER=<pattern>  - Run tests matching pattern"
	@echo "  make test-tap      - Run tests with TAP output (for CI)"
	@echo "  make list          - List available tests and counts"
	@echo "  make install-deps  - Install bats-core"
	@echo "  make clean         - Clean up temporary files"
	@echo "  make help          - Show this help"
