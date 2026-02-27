.PHONY: help syntax lint test check

SCRIPTS := \
	tmux-notify-jump \
	tmux-notify-jump-lib.sh \
	tmux-notify-jump-linux.sh \
	tmux-notify-jump-macos.sh \
	tmux-notify-jump-hook.sh \
	notify-codex.sh \
	notify-claude-code.sh \
	notify-opencode.sh \
	install.sh

help:
	@echo "tmux-notify-jump quality targets"
	@echo ""
	@echo "  make syntax  - Run bash -n syntax checks"
	@echo "  make lint    - Run shellcheck on shell scripts"
	@echo "  make test    - Run bats test suite"
	@echo "  make check   - Run syntax + lint + test"

syntax:
	@echo "Running bash -n syntax checks..."
	@bash -n $(SCRIPTS)

lint:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "Error: shellcheck is not installed."; \
		echo "Install it with: brew install shellcheck (macOS) or apt install shellcheck (Linux)"; \
		exit 1; \
	fi
	@echo "Running shellcheck..."
	@shellcheck $(SCRIPTS)

test:
	@if ! command -v bats >/dev/null 2>&1; then \
		echo "Error: bats-core is not installed."; \
		echo "Install it with: brew install bats-core (macOS) or apt install bats (Linux)"; \
		exit 1; \
	fi
	@echo "Running bats tests..."
	@cd tests && bats *.bats

check: syntax lint test
	@echo "All checks passed."

