# tmux-notify-jump

[![Syntax](https://github.com/hmgle/tmux-notify-jump/actions/workflows/syntax.yml/badge.svg)](https://github.com/hmgle/tmux-notify-jump/actions/workflows/syntax.yml)
[![Lint](https://github.com/hmgle/tmux-notify-jump/actions/workflows/lint.yml/badge.svg)](https://github.com/hmgle/tmux-notify-jump/actions/workflows/lint.yml)
[![Test](https://github.com/hmgle/tmux-notify-jump/actions/workflows/test.yml/badge.svg)](https://github.com/hmgle/tmux-notify-jump/actions/workflows/test.yml)
[![Quality Gate](https://github.com/hmgle/tmux-notify-jump/actions/workflows/quality-gate.yml/badge.svg)](https://github.com/hmgle/tmux-notify-jump/actions/workflows/quality-gate.yml)

Send a tmux-native or desktop notification on Linux and macOS.

- If tmux is available, you can jump to a target tmux pane when you click an action button.
- If tmux is not available, you can still use it as a notification + “focus my terminal” helper (`--focus-only`).

In other words: it’s tmux-aware, but not tmux-only.

## Demo

https://github.com/user-attachments/assets/9717e123-f016-4c22-b112-eff8ce22f804

This repo contains:

- `tmux-notify-jump`: cross-platform entry point (auto-selects Linux/macOS implementation)
- `tmux-notify-jump-linux.sh`: Linux/X11 implementation (notify-send + xdotool)
- `tmux-notify-jump-macos.sh`: macOS implementation (terminal-notifier + osascript)
- `tmux-notify-jump-hook.sh`: helper for tmux hooks (uses `#{hook_pane}` pane id)
- `notify-codex.sh`: Codex CLI wrapper (reads JSON from `$1`)
- `notify-claude-code.sh`: Claude Code wrapper (reads JSON from stdin)
- `notify-kimi-code.sh`: Kimi Code CLI wrapper (reads hook JSON from stdin)
- `notify-grok.sh`: Grok Build wrapper (reads native hook JSON from stdin)
- `notify-opencode.sh`: OpenCode wrapper (reads JSON from stdin)
- `opencode-plugin/tmux-notify-jump.ts`: OpenCode plugin (bridges events to `notify-opencode.sh`)
- `pi-extension/tmux-notify-jump.ts`: Pi coding agent extension (bridges events to `notify-pi.sh`)
- `notify-pi.sh`: Pi wrapper (reads JSON from stdin)

## Requirements

### Runtime

- Linux + X11 (Wayland is not supported by the focusing path)
  - `tmux` (required for `--target`/`--list`; optional for `--focus-only`)
  - `notify-send` (libnotify) with action support for desktop routing; it is not
    needed for the tmux-native SSH path
  - Optional “dialog” UI mode: `zenity` (GNOME/GTK) or `kdialog` (KDE/Qt) or `yad`
- macOS
  - `tmux` (required for `--target`/`--list`; optional for `--focus-only`)
  - `terminal-notifier` and `osascript` for desktop routing; neither is needed
    for the tmux-native SSH path

### Optional

- `xdotool` for focusing the terminal window before jumping (the script auto-disables focusing if missing)
- `python3` for safer Unicode truncation

### Wrappers (Codex/Claude/Kimi/Grok/OpenCode/Pi hooks)

- `jq` (required by the Codex, Claude, Kimi, Grok, OpenCode, and Pi wrappers; if missing, the wrappers no-op)

## Install

Recommended (install scripts into your PATH):

```bash
./install.sh --prefix "$HOME/.local" --symlink
```

Optional: configure hooks (makes backups; won’t overwrite existing `notify=` / incompatible schemas):

```bash
./install.sh --prefix "$HOME/.local" --symlink --configure-codex
./install.sh --prefix "$HOME/.local" --symlink --configure-claude
./install.sh --prefix "$HOME/.local" --symlink --configure-kimi
./install.sh --prefix "$HOME/.local" --symlink --configure-grok
./install.sh --prefix "$HOME/.local" --symlink --configure-opencode
./install.sh --prefix "$HOME/.local" --symlink --configure-pi
./install.sh --prefix "$HOME/.local" --symlink --configure-tmux
```

Uninstall:

```bash
./install.sh --prefix "$HOME/.local" --uninstall
```

Or run from the repo (no install):

```bash
chmod +x tmux-notify-jump tmux-notify-jump-linux.sh tmux-notify-jump-macos.sh tmux-notify-jump-hook.sh notify-codex.sh notify-claude-code.sh notify-kimi-code.sh notify-grok.sh notify-opencode.sh notify-pi.sh
```

## Usage

There are two main modes:

- **Jump mode**: pass `--target` (or a positional target). Requires a running tmux server.
- **Focus-only mode**: pass `--focus-only`. Does not require tmux; clicking just focuses your terminal window/app.

Jump mode inventories tmux clients and treats only
`client_control_mode=0` rows as user-visible terminals. On click it selects an
explicit client (the propagated sender client first, otherwise an ordinary
client already viewing the target session, otherwise the server's sole
ordinary client), runs `switch-client -c`, and verifies that exact client
reached the target pane. A persistent control-mode client is never a jump
target, even if tmux reports a TTY for it. Set
`TMUX_NOTIFY_UNATTACHED_FALLBACK=none` to disable the sole-client fallback.

tmux 2.1 or newer exposes `client_control_mode` and provides this exact
classification. On older tmux releases the format expands empty, so the script
falls back to accepting only clients with a non-empty TTY. That keeps ordinary
terminal jumps working and excludes pipe-backed background control clients,
but an ancient tmux cannot distinguish a control client that itself owns a TTY;
upgrade tmux when exact isolation is required. Releases without
`#{client_name}` identify each client by its TTY (which `switch-client -c`
accepts), and releases that do not expand `#{pane_id}` in client context verify
the jump by session alone.

```bash
./tmux-notify-jump <session>:<window>.<pane> [title] [body]
./tmux-notify-jump --target <session:window.pane> [--title <title>] [--body <body>]
./tmux-notify-jump --target <%pane_id> [--title <title>] [--body <body>]   # e.g. %1
./tmux-notify-jump --focus-only [--title <title>] [--body <body>]
./tmux-notify-jump --list

./tmux-notify-jump-linux.sh <session>:<window>.<pane> [title] [body]
./tmux-notify-jump-linux.sh --target <session:window.pane> [--title <title>] [--body <body>]
./tmux-notify-jump-linux.sh --target <%pane_id> [--title <title>] [--body <body>]
./tmux-notify-jump-linux.sh --focus-only [--title <title>] [--body <body>]
./tmux-notify-jump-linux.sh --list

./tmux-notify-jump-macos.sh <session>:<window>.<pane> [title] [body]
./tmux-notify-jump-macos.sh --target <session:window.pane> [--title <title>] [--body <body>]
./tmux-notify-jump-macos.sh --target <%pane_id> [--title <title>] [--body <body>]
./tmux-notify-jump-macos.sh --focus-only [--title <title>] [--body <body>]
./tmux-notify-jump-macos.sh --list
```

Common options:

- `--list`: list available panes (`*` means active)
- `--focus-only`: on click, only focus the terminal window/app (no tmux required)
- `--no-activate`: do not focus terminal window
- `--sender-pid <PID>`: best-effort focus by walking the sender process tree (useful outside tmux)
- `--class <CLASS>` / `--classes <A,B>`: fallback terminal window class(es) to focus (default: `org.wezfurlong.wezterm,Alacritty`)
- `--timeout <ms>`: notification timeout in milliseconds (default: `10000`; `0` may be sticky depending on daemon)
- `--dedupe-ms <ms>`: suppress duplicate notifications within this window (default: `2000`; `0` disables). Uses a small cache under `XDG_CACHE_HOME`/`~/.cache` and prunes old entries automatically.
- Linux/macOS: `--ui <notification|dialog>`: UI mode (`dialog` always waits for click; can also set `TMUX_NOTIFY_UI`, but `--ui` wins)
- `--detach`: run in background (recommended for hook/callback use)
- `--dry-run`: print what would happen and exit
- `--wrap-cols <n>`: wrap body text to `<n>` columns (default: `80`; `0` disables wrapping)
- `--notify-kind <attention|complete>`: classify an Inbox item. Attention items
  are selected first by the tmux Inbox key.
- `--notify-source <name>`: source label shown in remote tmux messages and the
  Inbox metadata.

## tmux Inbox

When `TMUX_NOTIFY_REMOTE_MODE=tmux` (the default), a notification whose target
pane is not currently visible is recorded in a small persistent Inbox. The
status-right segment shows `?N` for attention items and `!N` for completed work.
Run `./install.sh --configure-tmux` once to install the status segment, focus
hooks, and the `prefix+N` binding, then reload the configured file with
`tmux source-file ~/.tmux.conf` (or restart the server). Pressing the binding
selects the oldest attention item first, then the oldest completion, and clears
that exact pane as soon as it is visited. Repeated events for the same pane and
priority collapse into one item with an updated count.
Inbox cache directories and metadata files are restricted to the current user.
Notification bodies are used for immediate delivery but are not persisted.
Inbox routing is active even before `--configure-tmux` installs its status,
hooks, and binding. Set `TMUX_NOTIFY_REMOTE_MODE=desktop` to disable tmux Inbox
storage and use desktop delivery only.

Initialization pins the resolved Inbox directory in the tmux server so agent
processes and `run-shell` hooks use the same location. To customize
`XDG_CACHE_HOME`, set it in `~/.config/tmux-notify-jump/env` (or the file named by
`TMUX_NOTIFY_CONFIG`) and reload the tmux configuration. An override set only in
an interactive shell rc file may not be visible to the tmux server.

The default mode still sends desktop notifications when any ordinary local
client is attached to the tmux server, even if that client is viewing another
session. With no attached clients, desktop delivery is retained for local
processes and skipped when the notification process has an SSH environment.
Remote clients viewing the target session also receive a transient tmux
message. Automatic acknowledgement on manual pane visits requires tmux 3.0 or
newer; older releases keep the status and `prefix+N` workflow but warn during
initialization that acknowledgement hooks are unavailable.

The configuration block is marked and idempotent. Use
`./install.sh --configure-tmux --uninstall` to remove only that block while
leaving the rest of the tmux configuration intact. The same command also clears
a running server's Inbox, status segment, hooks, and tool-owned key binding
before removing the executable, and reports which socket it changed. That
server is the one `$TMUX` points at, otherwise the default socket; pass
`--tmux-socket <path>` to name a different one when you run several servers. If
`prefix+N` is already bound, initialization warns and preserves the existing
binding; pass `--tmux-key <key>` to choose another key. Set
`TMUX_NOTIFY_TMUX_STATUS=0` to keep the hooks and binding without appending the
Inbox counts to `status-right`.

macOS note: in `--ui notification` mode, if the script is detached (or `terminal-notifier` doesn’t support `-wait`), it falls back to `terminal-notifier -execute`, where any click triggers the jump (no separate “Dismiss” action). Use `--ui dialog` for explicit buttons.

## Environment variables

CLI flags override environment variables where applicable.

- `TMUX_NOTIFY_CONFIG`: optional env file to load before running (default: `~/.config/tmux-notify-jump/env`)
- `TMUX_NOTIFY_DEBUG`: write diagnostic details, including failures from detached
  notification processes, when set to `1`.
- `TMUX_NOTIFY_DEBUG_LOG`: debug log path (default:
  `$XDG_CACHE_HOME/tmux-notify-jump/debug.log` or
  `~/.cache/tmux-notify-jump/debug.log`).
- `TMUX_NOTIFY_WINDOW_ID`: explicit X11 window id to focus (overrides auto-detection)
- `TMUX_NOTIFY_TMUX_SOCKET`: tmux server socket path (passed to `tmux -S`; useful if you run multiple tmux servers)
- `TMUX_NOTIFY_FALLBACK_TARGET`: if not running inside tmux, fall back to the most recently active tmux client pane as the jump target (`0` disables; default: `0`)
- `TMUX_NOTIFY_FOCUS_ONLY_FALLBACK`: when hooks run without tmux (missing or no server/target), fall back to `--focus-only` instead of no-op (`0` disables; default: `1`)
- `TMUX_NOTIFY_UNATTACHED_FALLBACK`: policy when the target session has no identifiable ordinary client. The default `single` switches the server's sole ordinary client; it still refuses when there are zero or multiple ordinary clients. Set `none` for strict mode, which reports that the target is not visible instead of moving a terminal. Unknown values warn and fall back to `single`. On macOS the selected policy is forwarded to the notification click callback.
- `TMUX_NOTIFY_REMOTE_MODE`: `tmux` (Inbox/status/remote `display-message`,
  plus desktop delivery when a local client is present; default), `desktop`
  (desktop only), `both` (tmux and desktop routing), or `suppress`. The legacy
  `TMUX_NOTIFY_REMOTE=1` value maps to `desktop` for compatibility.
- `TMUX_NOTIFY_INBOX_TTL_MS`: remove Inbox items older than this value (default:
  `604800000`, seven days).
- `TMUX_NOTIFY_INBOX_MAX`: maximum number of Inbox entries (default: `100`).
- `TMUX_NOTIFY_INBOX_LOCK_RETRIES`: number of 10 ms retries when concurrent
  events update the same Inbox entry (default: `20`).
- `TMUX_NOTIFY_TMUX_STATUS`: append Inbox counts to tmux `status-right`
  (`0` disables; default: `1`).
- `TMUX_NOTIFY_CLASS` / `TMUX_NOTIFY_CLASSES`: terminal window class(es) used by `xdotool search --class`
- `TMUX_NOTIFY_WEZTERM_TAB`: on Linux, after focusing the terminal window, also switch to the wezterm tab/pane that hosts the tmux client (matched via `wezterm cli list` by tty; `0` disables; default: `1`). Requires `python3` or `jq` for JSON parsing; silently skipped when neither is available, when `--no-activate` is set, or when the terminal is not wezterm.
- `TMUX_NOTIFY_BUNDLE_ID` / `TMUX_NOTIFY_BUNDLE_IDS`: macOS terminal bundle id(s) for `osascript` activation (overrides auto-detection; e.g. kitty is `net.kovidgoyal.kitty`)
- `TMUX_NOTIFY_UI`: default for `--ui` (`notification` or `dialog`)
- `TMUX_NOTIFY_TIMEOUT`: default notification timeout in ms
- `TMUX_NOTIFY_DEDUPE_MS`: suppress duplicate notifications within this window (default: `2000`; `0` disables; cached under `$XDG_CACHE_HOME` or `~/.cache`)
- `TMUX_NOTIFY_MAX_TITLE` / `TMUX_NOTIFY_MAX_BODY`: truncate limits (`0` = no truncation)
- `TMUX_NOTIFY_WRAP_COLS`: wrap body text to this many columns (`0` = no wrapping)
- `TMUX_NOTIFY_ACTION_GOTO_LABEL`: label for the "goto" action (default: `Jump`)
- `TMUX_NOTIFY_ACTION_DISMISS_LABEL`: label for the "dismiss" action (default: `Dismiss`)

To switch modes without changing your Codex/Claude/Kimi/OpenCode hook config, create `~/.config/tmux-notify-jump/env`:

```bash
TMUX_NOTIFY_UI=dialog
```

## Examples

```bash
./tmux-notify-jump "2:1.0" "Build finished" "Click to jump to the pane"
./tmux-notify-jump "%1" "Build finished" "Click to jump to this pane"
./tmux-notify-jump --target "work:0.1" --no-activate
./tmux-notify-jump --target "work:0.1" --classes "org.wezfurlong.wezterm,Alacritty"

# Works without tmux: focuses terminal on click
./tmux-notify-jump --focus-only --title "Build finished" --body "Click to focus your terminal"

# Linux dialog mode (requires zenity/kdialog/yad)
TMUX_NOTIFY_UI=dialog ./tmux-notify-jump --target "%1" --detach

./tmux-notify-jump-macos.sh "2:1.0" "Build finished" "Click to jump to the pane"
./tmux-notify-jump-macos.sh --target "work:0.1" --no-activate
./tmux-notify-jump-macos.sh --target "work:0.1" --bundle-ids "com.github.wez.wezterm,com.googlecode.iterm2"
TMUX_NOTIFY_UI=dialog ./tmux-notify-jump-macos.sh --target "work:0.1" --detach
```

## tmux hooks integration

tmux exposes an event/hook system (implemented in tmux’s `notify.c`). You can attach `tmux-notify-jump` to those events so tmux itself triggers desktop notifications.

Recommended: use pane ids (`#{hook_pane}` like `%1`). This is more stable than `session:window.pane` because the pane id uniquely identifies the pane; the script resolves session/window/pane at jump time.

Example `~/.tmux.conf`:

```tmux
# Notify when a bell/activity happens in any window
set-hook -g alert-bell     "run-shell -b 'tmux-notify-jump-hook.sh --event alert-bell --pane-id #{hook_pane} --tmux-socket \"#{socket_path}\" --timeout 0'"
set-hook -g alert-activity "run-shell -b 'tmux-notify-jump-hook.sh --event alert-activity --pane-id #{hook_pane} --tmux-socket \"#{socket_path}\" --timeout 0'"

# Notify when a pane's command exits (useful for long-running commands).
# Note: jumping only makes sense if the pane still exists (e.g. `set -g remain-on-exit on`).
set-hook -g pane-exited "run-shell -b 'tmux-notify-jump-hook.sh --event pane-exited --pane-id #{hook_pane} --tmux-socket \"#{socket_path}\"'"
```

Notes:

- Prefer `run-shell -b` (or pass `--detach`) so tmux isn’t blocked waiting for clicks.
- If you run multiple tmux servers, pass `--tmux-socket <path>` (or set `TMUX_NOTIFY_TMUX_SOCKET`) to pin the correct server.
- If you attach multiple clients to the same tmux server, passing `--sender-tty`/`--sender-pid` helps the script switch/focus the same client that triggered the hook (the helper attempts to auto-detect and pass these when possible).

## Codex CLI integration

Use `notify-codex.sh` as your Codex `notify` hook; it triggers on `agent-turn-complete` and calls `tmux-notify-jump` (or `TMUX_NOTIFY_JUMP_SH` if set).

`~/.codex/config.toml`:

```toml
notify = ["/path/to/notify-codex.sh"]
```

Optional event filtering (comma-separated lists; `*` = all):

- `CODEX_NOTIFY_EVENTS`: whitelist (empty = default: `agent-turn-complete`)
- `CODEX_NOTIFY_EXCLUDE_EVENTS`: blacklist (set to `*` to disable all)
- `CODEX_NOTIFY_SHOW_EVENT_TYPE`: include `[event]` in title (`1`/`0`; default: `1`)

Notes:

- `notify` must be top-level (i.e. placed before any `[table]` / `[[array-of-tables]]` sections), otherwise TOML will scope it under the last table.
- Run Codex inside tmux so `TMUX_PANE` is available.
- If you can’t run Codex inside tmux, set `CODEX_NOTIFY_FALLBACK_TARGET=1` (or `TMUX_NOTIFY_FALLBACK_TARGET=1`) to target the most recently active tmux pane.
- SSH-attached clients use the tmux Inbox by default, so no desktop notification
  daemon is required on the remote host. Use `TMUX_NOTIFY_REMOTE_MODE` to change
  the routing policy.
- If tmux isn’t available/running, the wrapper falls back to `--focus-only` by default (set `CODEX_NOTIFY_FOCUS_ONLY_FALLBACK=0` or `TMUX_NOTIFY_FOCUS_ONLY_FALLBACK=0` to restore no-op).
- Set `--detach` (already enabled by the wrapper) to avoid blocking on `notify-send --wait`.
- The wrapper sets `--timeout 0` by default (via `CODEX_NOTIFY_TIMEOUT_MS`) so the notification stays until you click an action (daemon-dependent).
- On macOS (and on Linux if you have `zenity`/`kdialog`/`yad`), set `TMUX_NOTIFY_UI=dialog` to use a modal "Jump/Dismiss" dialog that stays until clicked.
- Requires `jq` (otherwise the wrapper no-ops; set `CODEX_NOTIFY_DEBUG=1` to see why in logs).
  - On macOS, tmux-launched processes sometimes inherit a restricted `PATH`; the wrapper adds common Homebrew paths (`/opt/homebrew/bin:/usr/local/bin`).
- The wrapper prefers `tmux-notify-jump` on your `PATH`. To override, set `TMUX_NOTIFY_JUMP_SH` to an executable (e.g. `tmux-notify-jump-macos.sh`).
- If you installed via `./install.sh`, you can auto-configure with `./install.sh --prefix "$HOME/.local" --configure-codex` (it creates a timestamped `config.toml.bak.*` before editing).

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

Notes:

- The wrapper sets `--timeout 0` by default (via `CLAUDE_NOTIFY_TIMEOUT_MS`) so the notification stays until you click an action (daemon-dependent).
- On macOS (and on Linux if you have `zenity`/`kdialog`/`yad`), set `TMUX_NOTIFY_UI=dialog` to use a modal "Jump/Dismiss" dialog that stays until clicked.
- Requires `jq` (otherwise the wrapper no-ops; set `CLAUDE_NOTIFY_DEBUG=1` to see why in logs).
  - On macOS, tmux-launched processes sometimes inherit a restricted `PATH`; the wrapper adds common Homebrew paths (`/opt/homebrew/bin:/usr/local/bin`).
- If Claude hooks run without tmux env but a tmux server is running, set `CLAUDE_NOTIFY_FALLBACK_TARGET=1` (or `TMUX_NOTIFY_FALLBACK_TARGET=1`) to target the most recently active tmux client pane.
- If tmux isn’t available/running, the wrapper falls back to `--focus-only` by default (set `CLAUDE_NOTIFY_FOCUS_ONLY_FALLBACK=0` or `TMUX_NOTIFY_FOCUS_ONLY_FALLBACK=0` to restore no-op).
- The wrapper prefers `tmux-notify-jump` on your `PATH`. To override, set `TMUX_NOTIFY_JUMP_SH` to an executable (e.g. `tmux-notify-jump-macos.sh`).
- If you installed via `./install.sh`, you can auto-configure with `./install.sh --prefix "$HOME/.local" --configure-claude` (it creates a timestamped `settings.json.bak.*` before editing; requires `python3`).

## Kimi Code CLI integration

Kimi Code CLI sends hook payloads as JSON on stdin. Use `notify-kimi-code.sh` to translate those payloads into notification titles and bodies while preserving tmux targeting, SSH suppression, and focus-only fallback behavior.

Recommended installation and configuration:

```bash
./install.sh --prefix "$HOME/.local" --symlink --configure-kimi
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

- Run Kimi inside tmux so `TMUX_PANE` identifies the originating pane.
- If the hook lacks tmux environment variables, set `KIMI_NOTIFY_FALLBACK_TARGET=1` (or `TMUX_NOTIFY_FALLBACK_TARGET=1`) to use the most recently active tmux pane.
- If tmux is unavailable, focus-only fallback is enabled by default. Disable it with `KIMI_NOTIFY_FOCUS_ONLY_FALLBACK=0` or `TMUX_NOTIFY_FOCUS_ONLY_FALLBACK=0`.
- Set `KIMI_NOTIFY_DEBUG=1` to log wrapper diagnostics under `$KIMI_CODE_HOME/logs/notify-kimi-code.log` (default root: `~/.kimi-code`).
- The wrapper requires `jq` and otherwise exits successfully without affecting Kimi's workflow.
- See the [official Kimi Hooks documentation](https://www.kimi.com/code/docs/kimi-code-cli/customization/hooks.html) for the event contract and payload format.

## Grok Build integration

Grok Build sends native hook payloads as camelCase JSON on stdin. Use `notify-grok.sh` to translate those payloads into notifications while preserving the shared tmux targeting, SSH suppression, and focus-only fallback behavior.

Recommended installation and configuration:

```bash
./install.sh --prefix "$HOME/.local" --symlink --configure-grok
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
- `GROK_NOTIFY_FALLBACK_TARGET`: allow resolving the most recently active tmux pane when hook environment lacks `TMUX_PANE`
- `GROK_NOTIFY_FOCUS_ONLY_FALLBACK`: focus the terminal when no tmux target is available (`1` by default)
- `GROK_NOTIFY_DEBUG`: log diagnostics under `$GROK_HOME/logs/notify-grok.log`; override with `GROK_NOTIFY_DEBUG_LOG`

Notes:

- Grok's native payload uses fields such as `hookEventName`, `notificationType`, `toolName`, and `errorDetails`; the Claude wrapper expects snake_case and should not be used as the native Grok parser.
- Global hooks under `~/.grok/hooks` are trusted automatically. Project hooks under `.grok/hooks` require `/hooks-trust` or launching Grok with `--trust`.
- Grok can also discover Claude settings through its compatibility layer. Keep only one Grok notification registration active to avoid duplicate notifications.
- The wrapper requires `jq` and otherwise exits successfully without affecting Grok.
- Verify discovery with `grok inspect --json` or open the Hooks tab with `/hooks`.
- See the [official Grok Build Hooks documentation](https://docs.x.ai/build/features/hooks) for the complete event contract.

## OpenCode integration

Use the `opencode-plugin/tmux-notify-jump.ts` plugin to bridge OpenCode events to `notify-opencode.sh`, which calls `tmux-notify-jump` (or `TMUX_NOTIFY_JUMP_SH` if set).

Install the plugin:

```bash
./install.sh --prefix "$HOME/.local" --symlink --configure-opencode
```

Or manually:

```bash
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
- The wrapper sets `--timeout 0` by default (via `OPENCODE_NOTIFY_TIMEOUT_MS`) so the notification stays until you click an action (daemon-dependent).
- On macOS (and on Linux if you have `zenity`/`kdialog`/`yad`), set `TMUX_NOTIFY_UI=dialog` to use a modal "Jump/Dismiss" dialog that stays until clicked.
- Requires `jq` (otherwise the wrapper no-ops; set `OPENCODE_NOTIFY_DEBUG=1` to see why in logs).
  - On macOS, tmux-launched processes sometimes inherit a restricted `PATH`; the wrapper adds common Homebrew paths (`/opt/homebrew/bin:/usr/local/bin`).
- Run OpenCode inside tmux so `TMUX_PANE` is available.
- If OpenCode runs without tmux env but a tmux server is running, set `OPENCODE_NOTIFY_FALLBACK_TARGET=1` (or `TMUX_NOTIFY_FALLBACK_TARGET=1`) to target the most recently active tmux client pane.
- If tmux isn't available/running, the wrapper falls back to `--focus-only` by default (set `OPENCODE_NOTIFY_FOCUS_ONLY_FALLBACK=0` or `TMUX_NOTIFY_FOCUS_ONLY_FALLBACK=0` to restore no-op).
- The wrapper prefers `tmux-notify-jump` on your `PATH`. To override, set `TMUX_NOTIFY_JUMP_SH` to an executable.
- Override the shell wrapper path in the plugin with `OPENCODE_NOTIFY_CMD` (default: `notify-opencode.sh` on PATH).

## Pi integration

[Pi](https://pi.dev/docs/latest) has no shell-command hook system; its integration point is TypeScript extensions. Use `pi-extension/tmux-notify-jump.ts`, a thin bridge that forwards Pi lifecycle events as JSON on stdin to `notify-pi.sh`, which calls `tmux-notify-jump` (or `TMUX_NOTIFY_JUMP_SH` if set) — same pattern as the OpenCode integration, with the same tmux targeting, SSH suppression, and focus-only fallback behavior as the other wrappers.

Install the scripts and the extension:

```bash
./install.sh --prefix "$HOME/.local" --symlink --configure-pi
```

Or manually:

```bash
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

- Run Pi inside tmux so `TMUX_PANE` identifies the originating pane.
- SSH-attached clients use the tmux Inbox by default, so no desktop notification
  daemon is required on the remote host. Use `TMUX_NOTIFY_REMOTE_MODE` to change
  the routing policy.
- If the extension runs without tmux env but a tmux server is running, set `PI_NOTIFY_FALLBACK_TARGET=1` (or `TMUX_NOTIFY_FALLBACK_TARGET=1`) to target the most recently active tmux client pane.
- If tmux isn't available/running, the wrapper falls back to `--focus-only` by default (set `PI_NOTIFY_FOCUS_ONLY_FALLBACK=0` or `TMUX_NOTIFY_FOCUS_ONLY_FALLBACK=0` to restore no-op).
- On macOS (and on Linux if you have `zenity`/`kdialog`/`yad`), set `PI_NOTIFY_UI=dialog` (or `TMUX_NOTIFY_UI=dialog`) to use a modal "Jump/Dismiss" dialog that stays until clicked.
- Requires `jq` (otherwise the wrapper no-ops; set `PI_NOTIFY_DEBUG=1` to see why in logs).
- Set `PI_NOTIFY_DEBUG=1` to log diagnostics to `~/.pi/agent/logs/notify-pi.log` (override with `PI_NOTIFY_DEBUG_LOG`).
- If you enable multiple events (e.g. `agent_end,agent_settled`), a settled run may emit two notifications back-to-back; their titles differ, so the built-in dedupe does not merge them.
- See the [official Pi extensions documentation](https://pi.dev/docs/latest/extensions) for the event contract.

## Tests

- Install `bats-core` (macOS: `brew install bats-core`).
- Run: `./tests/run_all.sh` (or `make -C tests test`).
- The suite includes shared-lib unit tests plus entry-script smoke tests (`tests/entry_smoke.bats`) for Linux/macOS dry-run and common validation paths.

## Quality checks

- Install `shellcheck` (macOS: `brew install shellcheck`; Linux: `apt install shellcheck`).
- Run `make syntax` for shell syntax checks.
- Run `make lint` for shellcheck.
- Run `make test` for the bats suite.
- Run `make check` to execute syntax + lint + tests in one command.

## Troubleshooting

- Actions not available: your `notify-send`/notification daemon may not support `-A` or `--wait`; the script falls back to a plain notification (no jump).
- macOS click does nothing: `terminal-notifier -execute` runs the callback without inheriting your shell environment; ensure `tmux-notify-jump-macos.sh` is up to date (it passes callback args explicitly and adds common Homebrew paths to `PATH`).
- Target session is reported as not visible: inspect `tmux list-clients -F 'name=#{client_name} tty=#{client_tty} control=#{client_control_mode} session=#{session_name}'`. A session with only `control=1` clients has no terminal to activate. By default, a click switches the server's sole ordinary client; the error remains when there are zero or multiple ordinary clients, or when `TMUX_NOTIFY_UNATTACHED_FALLBACK=none` enables strict mode. Attach a real terminal or propagate `--sender-tty` from the originating client to make the destination explicit.
- Jump stays in the wrong session: make sure the notification was sent from inside tmux (`TMUX_PANE` set) and that its sender TTY still names an ordinary client. Successful jumps now verify the explicit client's session and pane; enable `TMUX_NOTIFY_DEBUG=1` to inspect selection details.
- Focus goes to the wrong terminal:
  - macOS: the script tries to detect the terminal hosting the tmux client that triggered the notification; override with `TMUX_NOTIFY_BUNDLE_ID(S)` / `--bundle-id(s)` (or use `--no-activate`).
  - Linux/X11: set `TMUX_NOTIFY_WINDOW_ID`, pass `--class/--classes`, or use `--no-activate`.
- No terminal window found: set `TMUX_NOTIFY_WINDOW_ID`, pass `--class/--classes`, or use `--no-activate`.
- Find the right terminal class: run `xprop | rg WM_CLASS` and click your terminal window; use the second string as the class (e.g. `org.wezfurlong.wezterm`).
- Wayland session: terminal focusing is auto-disabled; use X11 if you need focus behavior.
- tmux server not running: start tmux or run the script from within an existing tmux session (or use `--focus-only` to just focus the terminal).
