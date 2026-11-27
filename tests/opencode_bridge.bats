#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    command -v node >/dev/null 2>&1 || skip "node is not installed"
    node --experimental-strip-types -e '' 2>/dev/null || skip "node needs TypeScript stripping support"
    command -v jq >/dev/null 2>&1 || skip "jq is not installed"

    export OPENCODE_PLUGIN="$PROJECT_ROOT/opencode-plugin/tmux-notify-jump.ts"
    export OPENCODE_NOTIFY_CMD="$TEST_TEMP_DIR/capture notify"
    export CAPTURE_FILE="$TEST_TEMP_DIR/events"
    export RELEASE_FILE="$TEST_TEMP_DIR/release"
    cat >"$OPENCODE_NOTIFY_CMD" <<'WRAPPER'
#!/usr/bin/env bash
event=$(cat)
# The harness must exit while the wrapper is still running.
for _ in {1..100}; do
    if [ -f "$RELEASE_FILE" ]; then
        printf '%s\n' "$event" >>"$CAPTURE_FILE"
        exit 0
    fi
    sleep 0.05
done
exit 1
WRAPPER
    chmod +x "$OPENCODE_NOTIFY_CMD"
}

teardown() {
    teardown_temp_dir
}

release_and_wait_for_captures() {
    local expected="$1"
    : >"$RELEASE_FILE"
    for _ in {1..50}; do
        if [ -f "$CAPTURE_FILE" ] &&
            jq -es --argjson expected "$expected" 'length >= $expected' "$CAPTURE_FILE" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    printf 'Timed out waiting for %s wrapper payloads\n' "$expected" >&2
    return 1
}

@test "OpenCode 2 bridge forwards server events using the shell event names" {
    cat >"$TEST_TEMP_DIR/harness.mts" <<'TS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const { default: plugin } = await import(pathToFileURL(process.env.OPENCODE_PLUGIN).href)
assert.equal(plugin.id, "tmux-notify-jump")

const succeed = (sessionID) => ({ type: "session.execution.succeeded", data: { sessionID } })
const fail = (sessionID, error) => ({ type: "session.execution.failed", data: { sessionID, error } })
const events = [
  succeed("parent"),
  succeed("child"),
  succeed("unavailable"),
  fail("failed", { message: "provider failed" }),
  fail("child", { message: "subagent failed" }),
  fail("missing-error"),
  fail("invalid-message", { message: 42 }),
  { type: "session.created", data: { sessionID: "new" } },
  { type: "session.deleted", data: { sessionID: "old" } },
  { type: "permission.asked", data: { sessionID: "parent", message: 'Allow "read"?\n/path' } },
  { type: "permission.replied", data: { sessionID: "parent", reply: "once" } },
]

let toolAfter
let cleanup
let subscriptionSignal
const { promise: finished, resolve } = Promise.withResolvers()
cleanup = await plugin.setup({
  tool: { async hook(name, fn) {
    assert.equal(name, "execute.after")
    toolAfter = fn
  } },
  event: { async *subscribe({ types, signal }) {
    subscriptionSignal = signal
    try {
      assert.deepEqual(new Set(types), new Set(events.map(({ type }) => type)))
      for (const event of events) yield event
      cleanup()
      yield succeed("stopped")
    } finally {
      resolve()
    }
  } },
  session: {
    async get({ sessionID }) {
      return sessionID === "child" ? { parentID: "parent" } : {}
    },
    async context({ sessionID }) {
      if (sessionID === "unavailable") throw new Error("history unavailable")
      assert.equal(sessionID, "parent")
      return [
        { type: "assistant", content: [{ type: "text", text: "older reply" }] },
        { type: "assistant", content: [
          { type: "reasoning", text: "internal" },
          { type: "text", text: "line one" },
          { type: "text", text: "x".repeat(250) },
        ] },
      ]
    },
  },
})

toolAfter({ tool: "read", sessionID: "parent" })
await finished
assert.equal(subscriptionSignal.aborted, true)

process.env.OPENCODE_NOTIFY_CMD += ".missing"
toolAfter({ tool: "read", sessionID: "parent" })
TS

    run node --experimental-strip-types --no-warnings "$TEST_TEMP_DIR/harness.mts"
    [ "$status" -eq 0 ]

    release_and_wait_for_captures 14
    jq -es '
        . as $events |
        length == 14
        and any(.[]; .event_type == "session.idle" and .properties.sessionID == "parent"
            and .message == ("line one\n" + ("x" * 191)))
        and any(.[]; .event_type == "session.idle" and .properties.sessionID == "unavailable" and .message == null)
        and any(.[]; .event_type == "session.error" and .properties == {sessionID:"failed", error:"provider failed"})
        and any(.[]; .event_type == "session.idle" and .properties.sessionID == "failed" and .message == "provider failed")
        and any(.[]; .event_type == "session.error" and .properties == {sessionID:"child", error:"subagent failed"})
        and all(.[]; .event_type != "session.idle" or .properties.sessionID != "child")
        and all(["missing-error", "invalid-message"][]; . as $session |
            any($events[]; .event_type == "session.error" and .properties == {sessionID:$session})
            and any($events[]; .event_type == "session.idle" and .properties.sessionID == $session and .message == null))
        and any(.[]; .event_type == "session.created" and .properties.sessionID == "new")
        and any(.[]; .event_type == "session.deleted" and .properties.sessionID == "old")
        and any(.[]; .event_type == "permission.asked" and .message == "Allow \"read\"?\n/path")
        and any(.[]; .event_type == "permission.replied" and .properties.reply == "once")
        and any(.[]; .event_type == "tool.execute.after" and .properties.name == "read")
    ' "$CAPTURE_FILE"
}

@test "OpenCode 1 bridge exposes the server entry point and forwards legacy hooks" {
    cat >"$TEST_TEMP_DIR/harness.mts" <<'TS'
import { pathToFileURL } from "node:url"
const { default: plugin } = await import(pathToFileURL(process.env.OPENCODE_PLUGIN).href)
const hooks = await plugin.server({
  client: { session: {
    async get() { return { data: {} } },
    async messages() { return { data: [
      { info: { role: "assistant" }, parts: [{ type: "text", text: "legacy reply" }] },
    ] } },
  } },
})

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "legacy" } } })
await hooks.event({ event: { type: "session.created", properties: { info: { id: "legacy" } } } })
await hooks.event({ event: { type: "permission.asked", properties: { sessionID: "legacy", message: "Approve?" } } })
await hooks["tool.execute.after"]({ tool: "read", sessionID: "legacy" })
TS

    run node --experimental-strip-types --no-warnings "$TEST_TEMP_DIR/harness.mts"
    [ "$status" -eq 0 ]

    release_and_wait_for_captures 4
    jq -es '
        length == 4
        and all(.[]; .properties.sessionID == "legacy")
        and any(.[]; .event_type == "session.idle" and .message == "legacy reply")
        and any(.[]; .event_type == "session.created")
        and any(.[]; .event_type == "permission.asked" and .message == "Approve?")
        and any(.[]; .event_type == "tool.execute.after" and .properties.name == "read")
    ' "$CAPTURE_FILE"
}
