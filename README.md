# tmux-notify-jump

Send a desktop notification on Linux/X11 and jump to a target tmux pane when you click an action button.

This repo contains:

- `tmux-notify-jump.sh`: main entry point (send notification + jump on click)
- `notify-tmux.sh`: Codex CLI wrapper (reads JSON from `$1`)
- `notify-claude.sh`: Claude Code wrapper (reads JSON from stdin)

## Requirements

### Runtime

- Linux + X11 (Wayland is not supported by the focusing path)
- `tmux`
- `notify-send` (libnotify) with action support (`notify-send -A ... --wait`)

### Optional

- `xdotool` for focusing the terminal window before jumping (the script auto-disables focusing if missing)
- `python3` for safer Unicode truncation
- `jq` (required by `notify-tmux.sh` and `notify-claude.sh`)

## Install

```bash
chmod +x tmux-notify-jump.sh notify-tmux.sh notify-claude.sh
```

## Usage

```bash
./tmux-notify-jump.sh <session>:<window>.<pane> [title] [body]
./tmux-notify-jump.sh --target <session:window.pane> [--title <title>] [--body <body>]
./tmux-notify-jump.sh --list
```

Common options:

- `--list`: list available panes (`*` means active)
- `--no-activate`: do not focus terminal window
- `--class <CLASS>` / `--classes <A,B>`: fallback terminal window class(es) to focus (default: `org.wezfurlong.wezterm,Alacritty`)
- `--timeout <ms>`: notification timeout in milliseconds (default: `10000`; `0` may be sticky depending on daemon)
- `--detach`: run in background (recommended for hook/callback use)
- `--dry-run`: print what would happen and exit

## Environment variables

- `TMUX_NOTIFY_WINDOW_ID`: explicit X11 window id to focus (overrides auto-detection)
- `TMUX_NOTIFY_CLASS` / `TMUX_NOTIFY_CLASSES`: terminal window class(es) used by `xdotool search --class`
- `TMUX_NOTIFY_TIMEOUT`: default notification timeout in ms
- `TMUX_NOTIFY_MAX_TITLE` / `TMUX_NOTIFY_MAX_BODY`: truncate limits (`0` = no truncation)
- `TMUX_NOTIFY_ACTION_GOTO_LABEL`: label for the "goto" action (default: `Jump`)
- `TMUX_NOTIFY_ACTION_DISMISS_LABEL`: label for the "dismiss" action (default: `Dismiss`)

## Examples

```bash
./tmux-notify-jump.sh "2:1.0" "Build finished" "Click to jump to the pane"
./tmux-notify-jump.sh --target "work:0.1" --no-activate
./tmux-notify-jump.sh --target "work:0.1" --classes "org.wezfurlong.wezterm,Alacritty"
```

## Codex CLI integration

Use `notify-tmux.sh` as your Codex `notify` hook; it triggers on `agent-turn-complete` and calls `tmux-notify-jump.sh`.

`~/.codex/config.toml`:

```toml
notify = ["/path/to/notify-tmux.sh"]
```

Notes:

- Run Codex inside tmux so `TMUX_PANE` is available.
- Set `--detach` (already enabled by the wrapper) to avoid blocking on `notify-send --wait`.
- The wrapper sets `--timeout 0` by default (via `CODEX_NOTIFY_TIMEOUT_MS`) so the notification stays until you click an action (daemon-dependent).
- Requires `jq`.

## Claude Code integration

Use `notify-claude.sh` as a hook command; it reads JSON from stdin and calls `tmux-notify-jump.sh`.

Example `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": "/path/to/notify-claude.sh" }]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt",
        "hooks": [{ "type": "command", "command": "/path/to/notify-claude.sh" }]
      }
    ]
  }
}
```

Notes:

- The wrapper sets `--timeout 0` by default (via `CLAUDE_NOTIFY_TIMEOUT_MS`) so the notification stays until you click an action (daemon-dependent).

## Troubleshooting

- Actions not available: your `notify-send`/notification daemon may not support `-A` or `--wait`; the script falls back to a plain notification (no jump).
- Focus goes to the wrong terminal: the script focuses the terminal hosting the tmux client that triggered the notification (captured when sending); if that fails, set `TMUX_NOTIFY_WINDOW_ID` or pass `--class/--classes` (or use `--no-activate`).
- No terminal window found: set `TMUX_NOTIFY_WINDOW_ID`, pass `--class/--classes`, or use `--no-activate`.
- Find the right terminal class: run `xprop | rg WM_CLASS` and click your terminal window; use the second string as the class (e.g. `org.wezfurlong.wezterm`).
- Wayland session: terminal focusing is auto-disabled; use X11 if you need focus behavior.
- tmux server not running: start tmux or run the script from within an existing tmux session.
