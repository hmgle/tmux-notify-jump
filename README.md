# tmux-notify-jump

Send a desktop notification on Linux/X11 or macOS, and jump to a target tmux pane when you click an action button.

## Demo

https://github.com/user-attachments/assets/9717e123-f016-4c22-b112-eff8ce22f804

This repo contains:

- `tmux-notify-jump`: cross-platform entry point (auto-selects Linux/macOS implementation)
- `tmux-notify-jump-linux.sh`: Linux/X11 implementation (notify-send + xdotool)
- `tmux-notify-jump-macos.sh`: macOS implementation (terminal-notifier + osascript)
- `notify-codex.sh`: Codex CLI wrapper (reads JSON from `$1`)
- `notify-claude-code.sh`: Claude Code wrapper (reads JSON from stdin)

## Requirements

### Runtime

- Linux + X11 (Wayland is not supported by the focusing path)
  - `tmux`
  - `notify-send` (libnotify) with action support (`notify-send -A ... --wait`)
- macOS
  - `tmux`
  - `terminal-notifier`
  - `osascript` (built-in)

### Optional

- `xdotool` for focusing the terminal window before jumping (the script auto-disables focusing if missing)
- `python3` for safer Unicode truncation

### Wrappers (Codex/Claude hooks)

- `jq` (required by `notify-codex.sh` and `notify-claude-code.sh`; if missing, the wrappers no-op)

## Install

Recommended (install scripts into your PATH):

```bash
./install.sh --prefix "$HOME/.local" --symlink
```

Optional: configure hooks (makes backups; won’t overwrite existing `notify=` / incompatible schemas):

```bash
./install.sh --prefix "$HOME/.local" --symlink --configure-codex
./install.sh --prefix "$HOME/.local" --symlink --configure-claude
```

Uninstall:

```bash
./install.sh --prefix "$HOME/.local" --uninstall
```

Or run from the repo (no install):

```bash
chmod +x tmux-notify-jump tmux-notify-jump-linux.sh tmux-notify-jump-macos.sh notify-codex.sh notify-claude-code.sh
```

## Usage

```bash
./tmux-notify-jump <session>:<window>.<pane> [title] [body]
./tmux-notify-jump --target <session:window.pane> [--title <title>] [--body <body>]
./tmux-notify-jump --list

./tmux-notify-jump-linux.sh <session>:<window>.<pane> [title] [body]
./tmux-notify-jump-linux.sh --target <session:window.pane> [--title <title>] [--body <body>]
./tmux-notify-jump-linux.sh --list

./tmux-notify-jump-macos.sh <session>:<window>.<pane> [title] [body]
./tmux-notify-jump-macos.sh --target <session:window.pane> [--title <title>] [--body <body>]
./tmux-notify-jump-macos.sh --list
```

Common options:

- `--list`: list available panes (`*` means active)
- `--no-activate`: do not focus terminal window
- `--class <CLASS>` / `--classes <A,B>`: fallback terminal window class(es) to focus (default: `org.wezfurlong.wezterm,Alacritty`)
- `--timeout <ms>`: notification timeout in milliseconds (default: `10000`; `0` may be sticky depending on daemon)
- macOS: `--ui <notification|dialog>`: UI mode (`dialog` always waits for click; can also set `TMUX_NOTIFY_UI`, but `--ui` wins)
- `--detach`: run in background (recommended for hook/callback use)
- `--dry-run`: print what would happen and exit
- `--wrap-cols <n>`: wrap body text to `<n>` columns (default: `80`; `0` disables wrapping)

## Environment variables

CLI flags override environment variables where applicable.

- `TMUX_NOTIFY_CONFIG`: optional env file to load before running (default: `~/.config/tmux-notify-jump/env`)
- `TMUX_NOTIFY_WINDOW_ID`: explicit X11 window id to focus (overrides auto-detection)
- `TMUX_NOTIFY_CLASS` / `TMUX_NOTIFY_CLASSES`: terminal window class(es) used by `xdotool search --class`
- `TMUX_NOTIFY_BUNDLE_ID` / `TMUX_NOTIFY_BUNDLE_IDS`: macOS terminal bundle id(s) for `osascript` activation
- `TMUX_NOTIFY_UI` (macOS): default for `--ui` (`notification` or `dialog`)
- `TMUX_NOTIFY_TIMEOUT`: default notification timeout in ms
- `TMUX_NOTIFY_MAX_TITLE` / `TMUX_NOTIFY_MAX_BODY`: truncate limits (`0` = no truncation)
- `TMUX_NOTIFY_WRAP_COLS`: wrap body text to this many columns (`0` = no wrapping)
- `TMUX_NOTIFY_ACTION_GOTO_LABEL`: label for the "goto" action (default: `Jump`)
- `TMUX_NOTIFY_ACTION_DISMISS_LABEL`: label for the "dismiss" action (default: `Dismiss`)

To switch modes without changing your Codex/Claude hook config, create `~/.config/tmux-notify-jump/env`:

```bash
TMUX_NOTIFY_UI=dialog
```

## Examples

```bash
./tmux-notify-jump "2:1.0" "Build finished" "Click to jump to the pane"
./tmux-notify-jump --target "work:0.1" --no-activate
./tmux-notify-jump --target "work:0.1" --classes "org.wezfurlong.wezterm,Alacritty"

./tmux-notify-jump-macos.sh "2:1.0" "Build finished" "Click to jump to the pane"
./tmux-notify-jump-macos.sh --target "work:0.1" --no-activate
./tmux-notify-jump-macos.sh --target "work:0.1" --bundle-ids "com.github.wez.wezterm,com.googlecode.iterm2"
TMUX_NOTIFY_UI=dialog ./tmux-notify-jump-macos.sh --target "work:0.1" --detach
```

## Codex CLI integration

Use `notify-codex.sh` as your Codex `notify` hook; it triggers on `agent-turn-complete` and calls `tmux-notify-jump` (or `TMUX_NOTIFY_JUMP_SH` if set).

`~/.codex/config.toml`:

```toml
notify = ["/path/to/notify-codex.sh"]
```

Notes:

- `notify` must be top-level (i.e. placed before any `[table]` / `[[array-of-tables]]` sections), otherwise TOML will scope it under the last table.
- Run Codex inside tmux so `TMUX_PANE` is available.
- Set `--detach` (already enabled by the wrapper) to avoid blocking on `notify-send --wait`.
- The wrapper sets `--timeout 0` by default (via `CODEX_NOTIFY_TIMEOUT_MS`) so the notification stays until you click an action (daemon-dependent).
- On macOS, set `TMUX_NOTIFY_UI=dialog` to use a modal "Jump/Dismiss" dialog that stays until clicked.
- Requires `jq` (otherwise the wrapper no-ops; set `CODEX_NOTIFY_DEBUG=1` to see why in logs).
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

Notes:

- The wrapper sets `--timeout 0` by default (via `CLAUDE_NOTIFY_TIMEOUT_MS`) so the notification stays until you click an action (daemon-dependent).
- On macOS, set `TMUX_NOTIFY_UI=dialog` to use a modal "Jump/Dismiss" dialog that stays until clicked.
- Requires `jq` (otherwise the wrapper no-ops; set `CLAUDE_NOTIFY_DEBUG=1` to see why in logs).
- The wrapper prefers `tmux-notify-jump` on your `PATH`. To override, set `TMUX_NOTIFY_JUMP_SH` to an executable (e.g. `tmux-notify-jump-macos.sh`).
- If you installed via `./install.sh`, you can auto-configure with `./install.sh --prefix "$HOME/.local" --configure-claude` (it creates a timestamped `settings.json.bak.*` before editing; requires `python3`).

## Troubleshooting

- Actions not available: your `notify-send`/notification daemon may not support `-A` or `--wait`; the script falls back to a plain notification (no jump).
- macOS click does nothing: `terminal-notifier -execute` runs the callback without inheriting your shell environment; ensure `tmux-notify-jump-macos.sh` is up to date (it passes callback args explicitly and prefixes common Homebrew PATHs).
- Jump stays in the wrong session: make sure the notification was sent from inside tmux (`TMUX_PANE` set); the script captures the originating tmux client when sending so it can switch that same client on click.
- Focus goes to the wrong terminal: the script focuses the terminal hosting the tmux client that triggered the notification (captured when sending); if that fails, set `TMUX_NOTIFY_WINDOW_ID` or pass `--class/--classes` (or use `--no-activate`).
- No terminal window found: set `TMUX_NOTIFY_WINDOW_ID`, pass `--class/--classes`, or use `--no-activate`.
- Find the right terminal class: run `xprop | rg WM_CLASS` and click your terminal window; use the second string as the class (e.g. `org.wezfurlong.wezterm`).
- Wayland session: terminal focusing is auto-disabled; use X11 if you need focus behavior.
- tmux server not running: start tmux or run the script from within an existing tmux session.
