#!/usr/bin/env bats
# Bridge smoke tests for omp-extension/tmux-notify-jump.ts (requires bun).

load 'test_helper'

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

@test "omp bridge: registers lifecycle events and forwards payloads to notify-omp.sh" {
    command -v bun >/dev/null 2>&1 || skip "bun is not installed"

    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/fake-notify-omp.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$(cat)" >>"$CAPTURE_FILE"
FAKE
    chmod +x "$fake_bin/fake-notify-omp.sh"

    export CAPTURE_FILE="$TEST_TEMP_DIR/captured_events"
    : >"$CAPTURE_FILE"

    harness="$TEST_TEMP_DIR/harness.ts"
    cat >"$harness" <<HARNESS
import bridge from "$PROJECT_ROOT/omp-extension/tmux-notify-jump.ts";

const handlers: Record<string, (event: unknown, ctx: unknown) => void> = {};
const pi = {
  on(event: string, handler: (event: unknown, ctx: unknown) => void) {
    handlers[event] = handler;
  },
};

bridge(pi as never);

console.log("registered=" + Object.keys(handlers).sort().join(","));

for (const event of ["session_stop", "agent_end", "turn_end"]) {
  handlers[event]({}, { hasUI: true });
}

// Without UI and without OMP_NOTIFY_HEADLESS the forward must be suppressed.
handlers["session_stop"]({}, { hasUI: false });
console.log("done");
HARNESS

    run env \
        CAPTURE_FILE="$CAPTURE_FILE" \
        OMP_NOTIFY_CMD="$fake_bin/fake-notify-omp.sh" \
        bun "$harness"

    [ "$status" -eq 0 ]
    [[ "$output" == *"registered=agent_end,session_stop,turn_end"* ]]

    # Forwarded children are detached; poll briefly for their payloads.
    for _ in $(seq 1 50); do
        [ "$(wc -l <"$CAPTURE_FILE")" -ge 3 ] && break
        sleep 0.1
    done

    [ "$(wc -l <"$CAPTURE_FILE")" -eq 3 ]
    captured="$(cat "$CAPTURE_FILE")"
    [[ "$captured" == *'{"event":"session_stop"}'* ]]
    [[ "$captured" == *'{"event":"agent_end"}'* ]]
    [[ "$captured" == *'{"event":"turn_end"}'* ]]
}

@test "omp bridge: OMP_NOTIFY_HEADLESS forwards events without a UI" {
    command -v bun >/dev/null 2>&1 || skip "bun is not installed"

    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/fake-notify-omp.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$(cat)" >>"$CAPTURE_FILE"
FAKE
    chmod +x "$fake_bin/fake-notify-omp.sh"

    export CAPTURE_FILE="$TEST_TEMP_DIR/captured_headless"
    : >"$CAPTURE_FILE"

    harness="$TEST_TEMP_DIR/harness.ts"
    cat >"$harness" <<HARNESS
import bridge from "$PROJECT_ROOT/omp-extension/tmux-notify-jump.ts";

const pi = {
  on(_event: string, handler: (event: unknown, ctx: unknown) => void) {
    handler({}, { hasUI: false });
  },
};

bridge(pi as never);
HARNESS

    run env \
        CAPTURE_FILE="$CAPTURE_FILE" \
        OMP_NOTIFY_CMD="$fake_bin/fake-notify-omp.sh" \
        OMP_NOTIFY_HEADLESS=1 \
        bun "$harness"

    [ "$status" -eq 0 ]

    for _ in $(seq 1 50); do
        [ "$(wc -l <"$CAPTURE_FILE")" -ge 3 ] && break
        sleep 0.1
    done

    [ "$(wc -l <"$CAPTURE_FILE")" -eq 3 ]
}
