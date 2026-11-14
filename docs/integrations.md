# Agent integrations

[User guide](../README.md#connect-your-agent) · [中文使用指南](../README.zh-CN.md#接入-agent) · [Technical reference](reference.md)

Run installer commands from the repository directory. Examples use `--copy`,
matching the user guide. If you chose symlink installation, replace `--copy`
with `--symlink` and keep the checkout in place. Reuse any custom `--prefix` or
`--bindir`. Choose only the integrations you use.

Start with the [agent setup table](../README.md#connect-your-agent). The shared
requirements are `jq`, a notification backend for desktop delivery, and a
running tmux server for pane jumps. Python 3 is also needed for automatic
Claude/Grok configuration; Codex approval setup needs Python 3.11+ when existing
TOML must be inspected. Read installer output: skipped or refused edits need
manual attention. Launch a new agent session after configuration; review hook
trust/registration where the agent requires it.

Shell-wrapper options such as `<AGENT>_NOTIFY_EVENTS` can go in the shared
`~/.config/tmux-notify-jump/env` file. TypeScript bridge options such as
`PI_NOTIFY_CMD` and `PI_NOTIFY_HEADLESS` must be in the agent process environment
before launch; that bridge does not load the shared env file. See
[configuration scope](../README.md#configuration).

- [Shared wrapper behavior](#shared-wrapper-behavior)
- [Codex](#codex-cli-integration) ([native approval hooks](#native-codex-lifecycle-hooks), [native terminal notifications](#coexisting-with-codex-terminal-notifications))
- [Claude Code](#claude-code-integration)
- [Kimi Code](#kimi-code-cli-integration)
- [Grok Build](#grok-build-integration)
- [OpenCode](#opencode-integration)
- [Pi](#pi-integration)
- [omp](#omp-integration)
- [Step Code](#step-code-integration)

## Shared wrapper behavior

All eight integrations use shell wrappers with the behavior below. Replace
`<AGENT>` in variable names with `CODEX`, `CLAUDE`, `KIMI`, `GROK`, `OPENCODE`,
`PI`, `STEP`, or `OMP`; each section lists its event and UI overrides.

- Start the agent inside the intended tmux pane so `TMUX_PANE` identifies the
  task. If it is missing, wrappers try process ancestry. Shared daemons need
  extra care; see [target selection](reference.md#desktop-clicks-and-target-selection).
- Local tasks use desktop notifications; SSH-attached target clients use the
  tmux Inbox by default, without a remote desktop daemon. Change delivery with
  [`TMUX_NOTIFY_REMOTE_MODE`](reference.md#tmux-inbox).
- If no reliable tmux target is available, wrappers use `--focus-only` by
  default. Set `<AGENT>_NOTIFY_FOCUS_ONLY_FALLBACK=0` or
  `TMUX_NOTIFY_FOCUS_ONLY_FALLBACK=0` to skip the notification instead.
- Guessing a target from tmux's current or most recently active pane is off by
  default. `<AGENT>_NOTIFY_FALLBACK_TARGET=1` or `TMUX_NOTIFY_FALLBACK_TARGET=1`
  enables it, but may select unrelated work. Prefer focus-only fallback.
- Wrappers call `tmux-notify-jump` on PATH, or the executable selected by
  `TMUX_NOTIFY_JUMP_SH`, with `--detach` so click handling does not block the agent.
- All wrappers require `jq`; if it is missing, they skip notifications and
  exit successfully. Set `<AGENT>_NOTIFY_DEBUG=1` for diagnostics; each wrapper
  accepts `<AGENT>_NOTIFY_DEBUG_LOG` for a custom log path. They also add
  `/opt/homebrew/bin` and `/usr/local/bin` to PATH for macOS hook environments.

`<AGENT>_NOTIFY_TIMEOUT_MS` overrides `TMUX_NOTIFY_TIMEOUT`; without either,
wrappers pass `--timeout 0` (whether a notification stays until clicked depends
on the desktop service). Per-event/type overrides are listed below where
supported. Set `TMUX_NOTIFY_UI=dialog` for explicit Jump/Dismiss buttons;
Linux needs `zenity`, `kdialog` or `yad`, while macOS uses `osascript`.

## Codex CLI integration

Use `notify-codex.sh` as your Codex `notify` hook; it triggers on `agent-turn-complete` and calls `tmux-notify-jump` (or `TMUX_NOTIFY_JUMP_SH` if set).

`$CODEX_HOME/config.toml` (default: `~/.codex/config.toml`):

```toml
notify = ["/path/to/notify-codex.sh"]
```

Optional event filtering (comma-separated lists; `*` = all):

- `CODEX_NOTIFY_EVENTS`: whitelist (empty = default:
  `agent-turn-complete,PermissionRequest,Stop`; only registered events arrive)
- `CODEX_NOTIFY_EXCLUDE_EVENTS`: blacklist (set to `*` to disable all)
- `CODEX_NOTIFY_SHOW_EVENT_TYPE`: include `[event]` in title (`1`/`0`; default: `1`)

Notes:

- `notify` must be top-level (i.e. placed before any `[table]` / `[[array-of-tables]]` sections), otherwise TOML will scope it under the last table.
- If you installed via `./install.sh`, you can auto-configure with `./install.sh --prefix "$HOME/.local" --copy --configure-codex` (it creates a timestamped `config.toml.bak.*` before editing).
- `--codex-config` / `CODEX_CONFIG_PATH` only select the file to edit; they do
  not register it with Codex. Both Codex configuration commands report this
  discovery limitation for explicit config paths, including on reinstall.
  A combined installation prints the general notice once, followed by the
  hooks-specific guidance.
  Confirm that Codex actually loads the selected config folder.

### Native Codex lifecycle hooks

Codex v0.168.0 still sends only `agent-turn-complete` through top-level `notify`.
Its native lifecycle hooks use a different stdin JSON schema. The same wrapper
also accepts `PermissionRequest` and `Stop` from that schema.

To add approval-related Inbox/desktop/OSC notifications alongside the legacy
completion integration:

```bash
./install.sh --prefix "$HOME/.local" --copy --configure-codex --configure-codex-hooks
```

`--configure-codex-hooks` adds only `PermissionRequest` to `hooks.json` beside
the selected Codex config. Pass `--codex-hooks-path <file>` (or
`CODEX_HOOKS_PATH`) for another location; `--codex-config` selects the config
directory by default. These overrides select files for this tool; they do not
register a config folder with Codex. Codex v0.168.0 discovers files named
`hooks.json` in active config-layer folders and does not read `CODEX_HOOKS_PATH`.
For another output location, place or symlink the file as `hooks.json` in a
folder Codex actually loads. The installer reports unverified discovery for
explicit config or hook paths and warns about other filenames. It cannot verify
active config layers; check discovery and trust with `/hooks`.

This opt-in operation requires `jq`, backs up changes, preserves existing
hooks and symlinks, and is idempotent. It does not change `[tui]` settings.
Both Codex installers require config paths to be absent or resolve to regular
files. This includes hooks.json and sibling TOML inspected for inline hooks;
directories, FIFOs, sockets, devices and dangling symlinks are rejected before
reading or writing them.
Existing TOML configs also require Python 3.11+ for safe
inspection. The installer checks the selected config and, when hooks.json is
elsewhere, its sibling `config.toml`. If either contains nonempty inline event
arrays, it refuses JSON hook edits and asks you to merge into one source
manually. Trust metadata under `[hooks.state]`, an empty `[hooks]` table and
empty event arrays do not establish a second source, so they permit reinstall
and asynchronous upgrades while keeping the TOML unchanged. Codex
merges inline and JSON hooks, which can execute the same handler twice.
Unreadable/invalid TOML or an unavailable parser also stops automatic hook
configuration; notification delivery still does not require Python.

Before editing, it validates all events, matcher groups and
handler fields against the supported Codex v0.168.0 structure, including
unrelated events. Invalid or unfamiliar fields/handler variants are refused;
configure those files manually. Empty `prompt` and `agent` handlers are valid
and preserved, although Codex v0.168.0 skips their execution with a warning.
Empty or whitespace command strings (including Windows overrides) and MCP
server/tool strings are also preserved. Codex checks the selected platform's
command and MCP names at runtime, skipping empty values with warnings.
This structural check does not establish that matchers, commands or MCP tools
work at runtime. Open `/hooks` in Codex to review
and trust the definition; an installed command alone does not establish that
Codex will run it.

Notification handlers run with `"async": true` so Codex does not wait for
side-channel notification work. Rerunning the installer upgrades this tool's
matching synchronous approval handlers in place, preserving their matchers,
timeouts and other handlers. Changed definitions need review again in `/hooks`.

The selected config defaults to `${CODEX_HOME:-$HOME/.codex}/config.toml`.
Explicit config/hooks paths take precedence over `CODEX_HOME`. The wrapper's
debug log defaults to `$CODEX_HOME/log/notify-codex.log`; set
`CODEX_NOTIFY_DEBUG_LOG` to override it.

Equivalent `hooks.json` entry (merge with existing hooks):

```json
{
  "hooks": {
    "PermissionRequest": [{
      "hooks": [{
        "type": "command",
        "command": "/path/to/notify-codex.sh",
        "async": true,
        "timeout": 10
      }]
    }]
  }
}
```

`PermissionRequest` is labeled **Approval requested** and uses Inbox attention
priority. It runs before automatic or user approval, so it does not prove Codex
is waiting for a human. The wrapper sends no approval decision or hook stdout,
including in debug mode, and notification failures leave Codex running.

For a native completion setup, register `Stop` with the same asynchronous
handler and remove this wrapper's legacy `notify` registration to avoid
duplicate completion notifications. `Stop` uses `last_assistant_message` and
`cwd`; another Stop
hook may still request continuation, so this event is not proof of a settled
run. Plan-mode prompts and async questions remain native TUI events; they are
not emitted by the legacy notify command or these two hook adapters.

### Coexisting with Codex terminal notifications

Codex v0.168.0 adds explicit `tui.notification_method = "osc777"`. Its `auto`
method still chooses OSC 9 or BEL. These native TUI notifications are separate
from top-level `notify` and this tool's `TMUX_NOTIFY_TERMINAL_METHOD`.

For local desktop Jump plus native approval/question notifications, keep the
legacy notify registration and use:

```toml
notify = ["/path/to/notify-codex.sh"] # Top-level, before [tui]

[tui]
notification_method = "osc777"
notifications = ["approval-requested", "plan-mode-prompt", "async-question"]
notification_condition = "unfocused"
```

If you also install our `PermissionRequest` hook, remove `approval-requested`
from the TUI list to avoid duplicate approval reminders. For SSH with native
completion toasts plus our Inbox, use `notifications = true`, retain
`TMUX_NOTIFY_REMOTE_MODE=tmux`, and set `CODEX_NOTIFY_TERMINAL_METHOD=none` and
`CODEX_NOTIFY_BELL=0` in the shared env file to avoid extra OSC/BEL reminders.

Codex emits its OSC through the pane, with a tmux DCS wrapper. On tmux versions
supporting these values, `allow-passthrough on` permits visible panes only;
hidden panes require `allow-passthrough all`. Focus tracking also matters for
the default `unfocused` condition: check `focus-events on` and terminal focus
support, or temporarily use `notification_condition = "always"` to diagnose.
The installer does not modify these tmux settings. Every outer terminal or
multiplexer must permit the sequence. In Windows Terminal, OSC 777 support
depends on the terminal version and `compatibility.allowOSC777` being enabled.
Native toasts do not carry our tmux pane jump action.

Sources: [Codex v0.168.0 OSC implementation](https://github.com/openai/codex/blob/rust-v0.168.0/codex-rs/tui/src/notifications/osc.rs),
[compatibility discussion](https://github.com/openai/codex/issues/58758),
[OpenAI Hooks documentation](https://learn.chatgpt.com/docs/hooks).

## Claude Code integration

Use `notify-claude-code.sh` as a hook command; it reads JSON from stdin and calls `tmux-notify-jump` (or `TMUX_NOTIFY_JUMP_SH` if set).

Example `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "/path/to/notify-claude-code.sh" }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt",
        "hooks": [
          { "type": "command", "command": "/path/to/notify-claude-code.sh" }
        ]
      }
    ]
  }
}
```

Optional event filtering (comma-separated lists; `*` = all):

- `CLAUDE_NOTIFY_EVENTS`: hook event whitelist (empty = default: `Stop,Notification,PostToolUseFailure`)
- `CLAUDE_NOTIFY_EXCLUDE_EVENTS`: hook event blacklist (set to `*` to disable all)
- `CLAUDE_NOTIFY_TYPES`: `Notification.notification_type` whitelist (empty = default: `permission_prompt,idle_prompt`)
- `CLAUDE_NOTIFY_EXCLUDE_TYPES`: `Notification.notification_type` blacklist (set to `*` to disable all)
- `CLAUDE_NOTIFY_SHOW_EVENT_TYPE`: include `[event]` in title (`1`/`0`; default: `1`)

Optional UI routing (values: `notification` or `dialog`):

- `CLAUDE_NOTIFY_UI_BY_TYPE`: per-`Notification.notification_type` UI override (e.g. `idle_prompt:notification,permission_prompt:dialog`)
- `CLAUDE_NOTIFY_UI_BY_EVENT`: per-`hook_event_name` UI override (e.g. `Stop:dialog,PostToolUseFailure:notification`)
- `CLAUDE_NOTIFY_UI`: wrapper default UI override (falls back to `TMUX_NOTIFY_UI` if unset)

UI override precedence: `CLAUDE_NOTIFY_UI_BY_TYPE` → `CLAUDE_NOTIFY_UI_BY_EVENT` → `CLAUDE_NOTIFY_UI` → `TMUX_NOTIFY_UI`/default.

Optional timeout routing (values: non-negative integer milliseconds):

- `CLAUDE_NOTIFY_TIMEOUT_MS_BY_TYPE`: per-`Notification.notification_type` timeout override (e.g. `idle_prompt:10000,permission_prompt:0`)
- `CLAUDE_NOTIFY_TIMEOUT_MS_BY_EVENT`: per-`hook_event_name` timeout override (e.g. `Stop:10000,PostToolUseFailure:0`)

For automatic setup, run
`./install.sh --prefix "$HOME/.local" --copy --configure-claude`.
It creates a timestamped `settings.json.bak.*` before editing and requires Python 3.

## Kimi Code CLI integration

Use `notify-kimi-code.sh` to translate Kimi Code CLI hook JSON from stdin into
notification titles and bodies.

Recommended installation and configuration:

```bash
./install.sh --prefix "$HOME/.local" --copy --configure-kimi
```

The installer backs up an existing config before appending hooks to `~/.kimi-code/config.toml`. To configure them manually, add:

```toml
[[hooks]]
event = "Stop"
command = "/path/to/notify-kimi-code.sh"

[[hooks]]
event = "PermissionRequest"
command = "/path/to/notify-kimi-code.sh"

[[hooks]]
event = "StopFailure"
command = "/path/to/notify-kimi-code.sh"

[[hooks]]
event = "Notification"
command = "/path/to/notify-kimi-code.sh"
```

The default events cover a completed agent turn, an approval request, a failed turn, and background task terminal states. A direct hook command to `tmux-notify-jump` is only suitable for a static notification; the wrapper is needed to read Kimi's JSON fields and select the correct pane or fallback behavior.

Optional filtering (comma-separated lists; `*` = all):

- `KIMI_NOTIFY_EVENTS`: event whitelist (empty = default: `Stop,PermissionRequest,StopFailure,Notification`)
- `KIMI_NOTIFY_EXCLUDE_EVENTS`: event blacklist (set to `*` to disable all)
- `KIMI_NOTIFY_TYPES`: `Notification.notification_type` whitelist (empty = all)
- `KIMI_NOTIFY_EXCLUDE_TYPES`: notification type blacklist
- `KIMI_NOTIFY_SHOW_EVENT_TYPE`: include `[event]` in the title (`1`/`0`; default: `1`)

Optional UI and timeout routing:

- `KIMI_NOTIFY_UI_BY_TYPE`: per-notification type UI (e.g. `task.completed:notification,task.failed:dialog`)
- `KIMI_NOTIFY_UI_BY_EVENT`: per-event UI (e.g. `Stop:notification,PermissionRequest:dialog`)
- `KIMI_NOTIFY_UI`: wrapper default UI (falls back to `TMUX_NOTIFY_UI`)
- `KIMI_NOTIFY_TIMEOUT_MS_BY_TYPE`: per-notification type timeout in milliseconds
- `KIMI_NOTIFY_TIMEOUT_MS_BY_EVENT`: per-event timeout in milliseconds
- `KIMI_NOTIFY_TIMEOUT_MS`: default timeout (default: `0`, daemon-dependent sticky notification)

Notes:

- Set `KIMI_NOTIFY_DEBUG=1` to log wrapper diagnostics under `$KIMI_CODE_HOME/logs/notify-kimi-code.log` (default root: `~/.kimi-code`).
- See the [official Kimi Hooks documentation](https://www.kimi.com/code/docs/kimi-code-cli/customization/hooks.html) for the event contract and payload format.

## Grok Build integration

Use `notify-grok.sh` to translate Grok Build's native camelCase hook JSON from
stdin into notifications.

Recommended installation and configuration:

```bash
./install.sh --prefix "$HOME/.local" --copy --configure-grok
```

The installer creates `tmux-notify-jump.json` under `$GROK_HOME/hooks` or `~/.grok/hooks`. Override the directory with `--grok-hooks-path`. To configure the hooks manually, create `~/.grok/hooks/tmux-notify-jump.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "/path/to/notify-grok.sh" }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt",
        "hooks": [
          { "type": "command", "command": "/path/to/notify-grok.sh" }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "hooks": [
          { "type": "command", "command": "/path/to/notify-grok.sh" }
        ]
      }
    ]
  }
}
```

The wrapper defaults to completed turns, permission and idle prompts, and failed tool calls. Grok also emits `Stop` while closing a session; the wrapper only notifies when `reason` is `end_turn`, avoiding duplicate notifications for `channel_closed` and `shutdown`.

Optional filtering (comma-separated lists; `*` = all):

- `GROK_NOTIFY_EVENTS`: event whitelist (empty = default: `stop,notification,post_tool_use_failure`)
- `GROK_NOTIFY_EXCLUDE_EVENTS`: event blacklist (set to `*` to disable all)
- `GROK_NOTIFY_TYPES`: `notificationType` whitelist (empty = default: `permission_prompt,idle_prompt`)
- `GROK_NOTIFY_EXCLUDE_TYPES`: notification type blacklist
- `GROK_NOTIFY_SHOW_EVENT_TYPE`: include the event in the title (`1`/`0`; default: `1`)

Optional behavior:

- `GROK_NOTIFY_UI`: `notification` or `dialog` (falls back to `TMUX_NOTIFY_UI`)
- `GROK_NOTIFY_TIMEOUT_MS`: timeout in milliseconds (default: `0`, daemon-dependent sticky notification)
- `GROK_NOTIFY_DEBUG`: log diagnostics under `$GROK_HOME/logs/notify-grok.log`; override with `GROK_NOTIFY_DEBUG_LOG`

Notes:

- Grok's native payload uses fields such as `hookEventName`, `notificationType`, `toolName`, and `errorDetails`; the Claude wrapper expects snake_case and should not be used as the native Grok parser.
- Global hooks under `~/.grok/hooks` are trusted automatically. Project hooks under `.grok/hooks` require `/hooks-trust` or launching Grok with `--trust`.
- Grok can also discover Claude settings through its compatibility layer. Keep only one Grok notification registration active to avoid duplicate notifications.
- Verify discovery with `grok inspect --json` or open the Hooks tab with `/hooks`.
- See the [official Grok Build Hooks documentation](https://docs.x.ai/build/features/hooks) for the complete event contract.

## OpenCode integration

Use the `opencode-plugin/tmux-notify-jump.ts` plugin to bridge OpenCode events to `notify-opencode.sh`, which calls `tmux-notify-jump` (or `TMUX_NOTIFY_JUMP_SH` if set).

Install the plugin:

```bash
./install.sh --prefix "$HOME/.local" --copy --configure-opencode
```

Or manually:

```bash
mkdir -p ~/.config/opencode/plugins/
cp opencode-plugin/tmux-notify-jump.ts ~/.config/opencode/plugins/
```

Default events: `session.idle`, `permission.asked`. Additional events (`session.error`, `session.created`, `session.deleted`, `permission.replied`, `tool.execute.after`) can be enabled via filtering.

Optional event filtering (comma-separated lists; `*` = all):

- `OPENCODE_NOTIFY_EVENTS`: whitelist (empty = default: `session.idle,permission.asked`)
- `OPENCODE_NOTIFY_EXCLUDE_EVENTS`: blacklist (set to `*` to disable all)
- `OPENCODE_NOTIFY_SHOW_EVENT_TYPE`: include `[event]` in title (`1`/`0`; default: `1`)

Optional UI/timeout routing (per-event type):

- `OPENCODE_NOTIFY_UI_BY_EVENT`: per-event UI override (e.g. `session.idle:notification,permission.asked:dialog`)
- `OPENCODE_NOTIFY_TIMEOUT_MS_BY_EVENT`: per-event timeout override (e.g. `session.idle:10000,permission.asked:0`)
- `OPENCODE_NOTIFY_UI`: wrapper default UI override (falls back to `TMUX_NOTIFY_UI` if unset)

UI override precedence: `OPENCODE_NOTIFY_UI_BY_EVENT` → `OPENCODE_NOTIFY_UI` → `TMUX_NOTIFY_UI`/default.

Notes:

- The TypeScript plugin pipes JSON via stdin to `notify-opencode.sh` (same pattern as Claude Code).
- Override the shell wrapper path in the plugin with `OPENCODE_NOTIFY_CMD` (default: `notify-opencode.sh` on PATH).

## Pi integration

[Pi](https://pi.dev/docs/latest) integrates through TypeScript extensions.
`pi-extension/tmux-notify-jump.ts` forwards lifecycle events as JSON on stdin
to `notify-pi.sh`.

Install the scripts and the extension:

```bash
./install.sh --prefix "$HOME/.local" --copy --configure-pi
```

Or manually:

```bash
mkdir -p ~/.pi/agent/extensions/
cp pi-extension/tmux-notify-jump.ts ~/.pi/agent/extensions/
# and ensure notify-pi.sh is on your PATH
```

Default events: `agent_settled` (Pi is fully idle — no auto-retry, compaction, or queued follow-up left). Additional events (`agent_end`, `turn_end`) can be enabled via filtering.

Optional event filtering (comma-separated lists; `*` = all):

- `PI_NOTIFY_EVENTS`: whitelist (empty = default: `agent_settled`)
- `PI_NOTIFY_EXCLUDE_EVENTS`: blacklist (set to `*` to disable all)
- `PI_NOTIFY_SHOW_EVENT_TYPE`: include `[event]` in title (`1`/`0`; default: `1`)

Optional UI/timeout routing (per-event):

- `PI_NOTIFY_UI_BY_EVENT`: per-event UI override (e.g. `agent_settled:notification,agent_end:dialog`)
- `PI_NOTIFY_TIMEOUT_MS_BY_EVENT`: per-event timeout override (e.g. `agent_settled:10000,agent_end:0`)
- `PI_NOTIFY_UI`: wrapper default UI override (falls back to `TMUX_NOTIFY_UI` if unset)
- `PI_NOTIFY_TIMEOUT_MS`: default notification timeout (default: `0`, sticky; daemon-dependent)

UI override precedence: `PI_NOTIFY_UI_BY_EVENT` → `PI_NOTIFY_UI` → `TMUX_NOTIFY_UI`/default.

Extension-level options:

- `PI_NOTIFY_CMD`: bridge command (default: `notify-pi.sh` on PATH)
- `PI_NOTIFY_HEADLESS`: also notify when Pi runs without UI, i.e. print (`-p`) and JSON event-stream modes (`1` enables; default: `0`). TUI and RPC (editor-driven) modes always notify — Pi reports `ctx.hasUI` as true there.

Notes:

- Set `PI_NOTIFY_DEBUG=1` to log diagnostics to `~/.pi/agent/logs/notify-pi.log` (override with `PI_NOTIFY_DEBUG_LOG`).
- If you enable multiple events (e.g. `agent_end,agent_settled`), a settled run may emit two notifications back-to-back; their titles differ, so the built-in dedupe does not merge them.
- See the [official Pi extensions documentation](https://pi.dev/docs/latest/extensions) for the event contract.

## omp integration

[omp](https://omp.sh) (oh-my-pi) integrates through TypeScript extensions.
`omp-extension/tmux-notify-jump.ts` forwards lifecycle events as JSON on stdin
to `notify-omp.sh`.

Install the scripts and the extension:

```bash
./install.sh --prefix "$HOME/.local" --copy --configure-omp
```

Or manually:

```bash
mkdir -p ~/.omp/agent/extensions/
cp omp-extension/tmux-notify-jump.ts ~/.omp/agent/extensions/
# and ensure notify-omp.sh is on your PATH
```

Extensions are auto-discovered from `~/.omp/agent/extensions/` (user-level), `<project>/.omp/extensions/` (project-level), or the `extensions:` list in `~/.omp/agent/config.yml`.

Default events: `session_stop` (the main session finished responding and is idle — omp's equivalent of Pi's `agent_settled`; it never fires for task/subagent sessions). Additional events (`agent_end`, `turn_end`) can be enabled via filtering; they may also fire for subagent runs, so keep them opt-in.

Optional event filtering (comma-separated lists; `*` = all):

- `OMP_NOTIFY_EVENTS`: whitelist (empty = default: `session_stop`)
- `OMP_NOTIFY_EXCLUDE_EVENTS`: blacklist (set to `*` to disable all)
- `OMP_NOTIFY_SHOW_EVENT_TYPE`: include `[event]` in title (`1`/`0`; default: `1`)

Optional UI/timeout routing (per-event):

- `OMP_NOTIFY_UI_BY_EVENT`: per-event UI override (e.g. `session_stop:notification,agent_end:dialog`)
- `OMP_NOTIFY_TIMEOUT_MS_BY_EVENT`: per-event timeout override (e.g. `session_stop:10000,agent_end:0`)
- `OMP_NOTIFY_UI`: wrapper default UI override (falls back to `TMUX_NOTIFY_UI` if unset)
- `OMP_NOTIFY_TIMEOUT_MS`: default notification timeout (default: `0`, sticky; daemon-dependent)

UI override precedence: `OMP_NOTIFY_UI_BY_EVENT` → `OMP_NOTIFY_UI` → `TMUX_NOTIFY_UI`/default.

Extension-level options:

- `OMP_NOTIFY_CMD`: bridge command (default: `notify-omp.sh` on PATH)
- `OMP_NOTIFY_HEADLESS`: also notify when omp runs without UI, i.e. print (`-p`) and JSON event-stream modes (`1` enables; default: `0`). TUI and RPC (editor-driven) modes always notify — omp reports `ctx.hasUI` as true there.

Notes:

- Set `OMP_NOTIFY_DEBUG=1` to log diagnostics to `~/.omp/agent/logs/notify-omp.log` (override with `OMP_NOTIFY_DEBUG_LOG`; the default path does not follow profiles or `PI_CODING_AGENT_DIR`).
- The installer derives the extension directory the same way omp does: `--omp-extension-path` wins outright; otherwise a named profile (`OMP_PROFILE`, falling back to `PI_PROFILE`; edge-trimmed, an explicitly empty value or `default` selects the default profile; names must satisfy omp's rules, e.g. lowercase start and no Windows-reserved aliases) targets `~/.omp/profiles/<name>/agent/extensions` and ignores `PI_CODING_AGENT_DIR`, while the default profile honors `PI_CODING_AGENT_DIR` (absolute path required — omp resolves relative values against each session's working directory); `PI_CONFIG_DIR` replaces `.omp` throughout.
- If you enable multiple events (e.g. `agent_end,session_stop`), a settled run may emit two notifications back-to-back; their titles differ, so the built-in dedupe does not merge them.
- See the [official omp extension documentation](https://github.com/can1357/oh-my-pi/blob/main/docs/extensions.md) for the event contract.

## Step Code integration

[Step Code](https://github.com/stepfun-ai/Step-Code) (the `step` CLI) keeps
Pi's TypeScript extension API. `step-extension/tmux-notify-jump.ts` forwards
lifecycle events as JSON on stdin to `notify-step.sh`.

The bridge subscribes to `agent_settled`, `agent_end`, `turn_end`, and Step's
additional `ui_prompt_start` event. For the first three lifecycle events, Step
reuses Pi's event contract, so their payloads and wrapper behavior match the Pi
integration. Step-specific behavior includes `ui_prompt_start`, the notify
source label, the directory layout, and the `STEP_NOTIFY_*` variable names.

Install the scripts and the extension:

```bash
./install.sh --prefix "$HOME/.local" --copy --configure-step
```

Or manually:

```bash
mkdir -p ~/.stepcode/agent/extensions/
cp step-extension/tmux-notify-jump.ts ~/.stepcode/agent/extensions/
# and ensure notify-step.sh is on your PATH
```

Extensions are auto-discovered from `~/.stepcode/agent/extensions/` (user-level) or `<project>/.stepcode/extensions/` (project-level, loaded once the project is trusted). You can also list the file explicitly in the `extensions` array of `~/.stepcode/config.toml` or `<project>/.stepcode/config.toml`.

Default events: `agent_settled` (Step is fully idle — no auto-retry, compaction, or queued follow-up left). Additional events (`agent_end`, `turn_end`) can be enabled via filtering.

Optional event filtering (comma-separated lists; `*` = all):

- `STEP_NOTIFY_EVENTS`: whitelist (empty = default: `agent_settled`)
- `STEP_NOTIFY_EXCLUDE_EVENTS`: blacklist (set to `*` to disable all)
- `STEP_NOTIFY_SHOW_EVENT_TYPE`: include `[event]` in title (`1`/`0`; default: `1`)

Optional UI/timeout routing (per-event):

- `STEP_NOTIFY_UI_BY_EVENT`: per-event UI override (e.g. `agent_settled:notification,agent_end:dialog`)
- `STEP_NOTIFY_TIMEOUT_MS_BY_EVENT`: per-event timeout override (e.g. `agent_settled:10000,agent_end:0`)
- `STEP_NOTIFY_UI`: wrapper default UI override (falls back to `TMUX_NOTIFY_UI` if unset)
- `STEP_NOTIFY_TIMEOUT_MS`: default notification timeout (default: `0`, sticky; daemon-dependent)

UI override precedence: `STEP_NOTIFY_UI_BY_EVENT` → `STEP_NOTIFY_UI` → `TMUX_NOTIFY_UI`/default.

Extension-level options:

- `STEP_NOTIFY_CMD`: bridge command (default: `notify-step.sh` on PATH)
- `STEP_NOTIFY_HEADLESS`: also notify when step runs without UI, i.e. print (`-p`) and JSON event-stream modes (`1` enables; default: `0`). TUI and RPC (editor-driven) modes always notify — step reports `ctx.hasUI` as true there.

Notifying when step waits for approval:

Step's own tool-approval prompt (`Approve run_command [id]`) is implemented as a
built-in extension dialog, so the extension runner broadcasts `ui_prompt_start`
to every extension, including this bridge. Add it to the event list to hear about
it:

```bash
export STEP_NOTIFY_EVENTS="agent_settled,ui_prompt_start"
```

The prompt title is forwarded with the event and becomes the notification body,
so the notification reads `Step [ui_prompt_start]: Waiting For You` /
`Approve run_command [abcd1234]`, and is routed with `--notify-kind attention`.

Notes on this event:

- It only fires when a UI is available (TUI and `--mode rpc`). In print (`-p`)
  and JSON modes step fails closed instead of prompting, so there is nothing to
  report — `STEP_NOTIFY_HEADLESS` cannot enable it there.
- It is a generic "step is waiting for you" signal: any blocking extension
  dialog (`confirm`, `input`, `select`, `editor`, `custom`) emits it, not only
  permission prompts. Disable it again by dropping it from
  `STEP_NOTIFY_EVENTS` if other dialogs are too chatty.
- Step's default approval policy is bypass — tools run without prompts — so in
  practice this only fires for dangerous commands, or after `--approval-mode
  confirm` (or `STEP_APPROVAL_MODE=confirm`) and `/permissions ask`.

Notes:

- Set `STEP_NOTIFY_DEBUG=1` to log diagnostics to `~/.stepcode/agent/logs/notify-step.log` (override with `STEP_NOTIFY_DEBUG_LOG`; the default path does not follow `STEP_CODING_AGENT_DIR` or `STEPCODE_CONFIG_DIR`).
- If you already use Pi, note that the two integrations are independent: `--configure-pi` writes to `~/.pi/agent/extensions/`, which `step` never reads, so a Pi-style install is invisible to `step` and vice versa.
- The installer derives the extension directory the same way step does: `--step-extension-path` wins outright; otherwise `STEP_CODING_AGENT_DIR` (a leading `~` is expanded) overrides the agent directory, and the project directory is `~/.stepcode` unless `STEPCODE_CONFIG_DIR` replaces it — unlike Pi and omp, step has no profiles.
- If you enable multiple events (e.g. `agent_end,agent_settled`), a settled run may emit two notifications back-to-back; their titles differ, so the built-in dedupe does not merge them.
- See the [official Step Code extensions documentation](https://github.com/stepfun-ai/Step-Code/blob/main/packages/coding-agent/docs/extensions.md) for the event contract.
