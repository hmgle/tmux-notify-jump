#!/usr/bin/env bash
# Run all tests for tmux-notify-jump
# Usage: ./run_all.sh [bats options...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bats >/dev/null 2>&1; then
    echo "Error: bats-core is not installed."
    echo ""
    echo "Install it with:"
    echo "  macOS:  brew install bats-core"
    echo "  Linux:  apt install bats  (or equivalent for your distro)"
    echo ""
    echo "Or run: make -C '$SCRIPT_DIR' install-deps"
    exit 1
fi

cd "$SCRIPT_DIR"

echo "=== tmux-notify-jump Test Suite ==="
echo ""

# Count tests
total_tests=0
for f in *.bats; do
    [ -f "$f" ] || continue
    count=$(grep -c '^@test' "$f" 2>/dev/null || echo 0)
    total_tests=$((total_tests + count))
done
echo "Running $total_tests tests across $(ls -1 *.bats 2>/dev/null | wc -l | tr -d ' ') test files..."
echo ""

# Run bats with any additional arguments passed to this script
bats "$@" *.bats
