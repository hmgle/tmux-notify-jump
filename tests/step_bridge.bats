#!/usr/bin/env bats
# Bridge smoke tests for step-extension/tmux-notify-jump.ts (requires bun).

load 'test_helper'

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

@test "step bridge: registers lifecycle events and forwards payloads to notify-step.sh" {
    command -v bun >/dev/null 2>&1 || skip "bun is not installed"

    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/fake-notify-step.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$(cat)" >>"$CAPTURE_FILE"
FAKE
    chmod +x "$fake_bin/fake-notify-step.sh"

    export CAPTURE_FILE="$TEST_TEMP_DIR/captured_events"
    : >"$CAPTURE_FILE"

    harness="$TEST_TEMP_DIR/harness.ts"
    cat >"$harness" <<HARNESS
import bridge from "$PROJECT_ROOT/step-extension/tmux-notify-jump.ts";

const handlers: Record<string, (event: unknown, ctx: unknown) => void> = {};
const pi = {
  on(event: string, handler: (event: unknown, ctx: unknown) => void) {
    handlers[event] = handler;
  },
};

bridge(pi as never);

console.log("registered=" + Object.keys(handlers).sort().join(","));

for (const event of ["agent_settled", "agent_end", "turn_end"]) {
  handlers[event]({}, { hasUI: true });
}

// ui_prompt_start carries the prompt title, which the wrapper surfaces in the
// notification body.
handlers["ui_prompt_start"](
  { type: "ui_prompt_start", reason: "ui_prompt", kind: "confirm", title: "Approve run_command [abcd1234]" },
  { hasUI: true },
);

// Without UI and without STEP_NOTIFY_HEADLESS the forward must be suppressed.
handlers["agent_settled"]({}, { hasUI: false });
console.log("done");
HARNESS

    run env \
        CAPTURE_FILE="$CAPTURE_FILE" \
        STEP_NOTIFY_CMD="$fake_bin/fake-notify-step.sh" \
        bun "$harness"

    [ "$status" -eq 0 ]
    [[ "$output" == *"registered=agent_end,agent_settled,turn_end,ui_prompt_start"* ]]

    # Forwarded children are detached; poll briefly for their payloads.
    for _ in $(seq 1 50); do
        [ "$(wc -l <"$CAPTURE_FILE")" -ge 4 ] && break
        sleep 0.1
    done

    [ "$(wc -l <"$CAPTURE_FILE")" -eq 4 ]
    captured="$(cat "$CAPTURE_FILE")"
    [[ "$captured" == *'{"event":"agent_settled"}'* ]]
    [[ "$captured" == *'{"event":"agent_end"}'* ]]
    [[ "$captured" == *'{"event":"turn_end"}'* ]]
    [[ "$captured" == *'{"event":"ui_prompt_start","title":"Approve run_command [abcd1234]"}'* ]]
}

@test "step bridge: STEP_NOTIFY_HEADLESS forwards events without a UI" {
    command -v bun >/dev/null 2>&1 || skip "bun is not installed"

    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/fake-notify-step.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$(cat)" >>"$CAPTURE_FILE"
FAKE
    chmod +x "$fake_bin/fake-notify-step.sh"

    export CAPTURE_FILE="$TEST_TEMP_DIR/captured_headless"
    : >"$CAPTURE_FILE"

    harness="$TEST_TEMP_DIR/harness.ts"
    cat >"$harness" <<HARNESS
import bridge from "$PROJECT_ROOT/step-extension/tmux-notify-jump.ts";

const pi = {
  on(_event: string, handler: (event: unknown, ctx: unknown) => void) {
    handler({}, { hasUI: false });
  },
};

bridge(pi as never);
HARNESS

    run env \
        CAPTURE_FILE="$CAPTURE_FILE" \
        STEP_NOTIFY_CMD="$fake_bin/fake-notify-step.sh" \
        STEP_NOTIFY_HEADLESS=1 \
        bun "$harness"

    [ "$status" -eq 0 ]

    for _ in $(seq 1 50); do
        [ "$(wc -l <"$CAPTURE_FILE")" -ge 4 ] && break
        sleep 0.1
    done

    [ "$(wc -l <"$CAPTURE_FILE")" -eq 4 ]
}
