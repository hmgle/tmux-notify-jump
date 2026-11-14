# tmux-notify-jump

[![Syntax](https://github.com/hmgle/tmux-notify-jump/actions/workflows/syntax.yml/badge.svg)](https://github.com/hmgle/tmux-notify-jump/actions/workflows/syntax.yml)
[![Lint](https://github.com/hmgle/tmux-notify-jump/actions/workflows/lint.yml/badge.svg)](https://github.com/hmgle/tmux-notify-jump/actions/workflows/lint.yml)
[![Test](https://github.com/hmgle/tmux-notify-jump/actions/workflows/test.yml/badge.svg)](https://github.com/hmgle/tmux-notify-jump/actions/workflows/test.yml)
[![Quality Gate](https://github.com/hmgle/tmux-notify-jump/actions/workflows/quality-gate.yml/badge.svg)](https://github.com/hmgle/tmux-notify-jump/actions/workflows/quality-gate.yml)
[![Release](https://img.shields.io/github/v/release/hmgle/tmux-notify-jump)](https://github.com/hmgle/tmux-notify-jump/releases/latest)

**English** | [简体中文](README.zh-CN.md)

Get notified when your coding agent finishes or needs attention, then return to
the right tmux pane. Works on Linux and macOS with Codex, Claude Code, Kimi Code,
Grok Build, OpenCode, Pi, Step Code, and omp. You can also send notifications from
your own commands.

- **Local desktop:** click **Jump** to return to the task's pane.
- **Over SSH:** see pending tasks in the tmux Inbox and jump back with a key.
- **Without tmux:** use `--focus-only` to bring your terminal forward.

## Demo

https://github.com/user-attachments/assets/9717e123-f016-4c22-b112-eff8ce22f804

## Contents

[Choose your setup](#choose-your-setup) · [Install](#install) ·
[Connect your agent](#connect-your-agent) · [Test it](#test-it) ·
[tmux Inbox](#tmux-inbox) · [Configuration](#configuration) ·
[Troubleshooting](#troubleshooting) · [Update and uninstall](#update-and-uninstall) ·
[More documentation](#more-documentation)

## Choose your setup

Install on the machine **where the agent or task runs**. For SSH, this usually
means the remote host; the basic Inbox workflow needs no desktop daemon there.

| Your setup | Default behavior | What to install |
| --- | --- | --- |
| Local Linux/X11 + tmux | Desktop notification with a Jump action; pending background panes also enter the Inbox | `tmux`, `notify-send`; `xdotool` for terminal focus |
| Local macOS + tmux | Desktop notification; clicking returns to the pane | `tmux`, `terminal-notifier`, built-in `osascript` |
| Agent in tmux over SSH | tmux message and Inbox; no remote desktop popup by default | `tmux`; configure the Inbox UI below |
| Linux/Wayland | Notifications and tmux pane switching; bringing the terminal window forward is disabled | Same notification tools as Linux; `xdotool` does not enable Wayland focus |
| No tmux | Desktop notification; clicking focuses the terminal, without selecting a pane | Platform desktop tools; use `--focus-only` |

All agent integrations also need **`jq`**. Without it, wrappers quietly skip
notifications so they do not interrupt the agent.

If local and SSH clients share the target session, SSH routing takes precedence.
Use `TMUX_NOTIFY_REMOTE_MODE=both` to also deliver to the task host's desktop.

Desktop Jump actions depend on the notification service. On macOS, detached
notifications may use a single click to jump, with no separate Dismiss button.
Use `--ui dialog` for explicit Jump/Dismiss buttons. Optional terminal-generated
popups over SSH require a compatible local terminal; their clicks do **not**
select a tmux pane. See [SSH terminal notifications](docs/reference.md#terminal-notifications-over-ssh).

## Install

### 1. Install dependencies

Examples for common systems (use your distribution's equivalent packages).
These commands assume `apt` or Homebrew is already available.

```bash
# Debian / Ubuntu: local desktop
sudo apt install git tmux jq libnotify-bin xdotool

# Debian / Ubuntu: remote host, Inbox only
sudo apt install git tmux jq

# macOS: local desktop
brew install git tmux jq terminal-notifier
```

Choose **one** matching your setup. A running desktop notification service is
also required for local popups. Add `fzf` if you want a searchable Inbox picker.
Automatic Claude/Grok configuration needs Python 3. Codex approval-hook setup
needs Python 3.11+ when inspecting existing TOML; it is not required for runtime
notifications. [Full dependency notes](docs/reference.md#dependencies).

### 2. Get the code and install

```bash
git clone https://github.com/hmgle/tmux-notify-jump.git
cd tmux-notify-jump
./install.sh --prefix "$HOME/.local" --copy
export PATH="$HOME/.local/bin:$PATH"
command -v tmux-notify-jump
tmux-notify-jump --focus-only --dry-run --title "Install check" --body "Ready"
```

The default install location is `~/.local/bin`. **The installer does not edit your
PATH.** Add the `export PATH=...` line to your shell startup file (for example,
`~/.bashrc` or `~/.zshrc`) if that directory is not already on PATH. Start agents
from a shell with the updated PATH.

`--copy` lets the installed scripts work after you move or remove the checkout.
Keep a checkout available for updates and uninstall. For development, use
`--symlink` instead (the installer's default): the installed commands point into
the checkout, so it must stay in place. Run all later `./install.sh` commands
from that checkout, using the same install mode and prefix.

The dry run prints settings without sending a notification. Next, select your
agent integration or go straight to [Test it](#test-it) for standalone use.

## Connect your agent

Choose only the integrations you use. Each command also installs the scripts;
you can combine configuration flags in one invocation. Existing files are backed
up before supported edits; read the installer output for skipped or refused
changes. For existing hook configurations, follow the linked integration guide.
The commands below use `~/.local/bin`; append your original `--prefix` or
`--bindir` if you installed elsewhere.

| Agent | Configure from the checkout | Notifications enabled by this setup |
| --- | --- | --- |
| [Codex](docs/integrations.md#codex-cli-integration) | `./install.sh --copy --configure-codex` | Turn completed |
| [Codex approvals](docs/integrations.md#native-codex-lifecycle-hooks) | `./install.sh --copy --configure-codex --configure-codex-hooks` | Completion + approval requested; review trust in `/hooks` |
| [Claude Code](docs/integrations.md#claude-code-integration) | `./install.sh --copy --configure-claude` | Stop + permission/idle prompts |
| [Kimi Code](docs/integrations.md#kimi-code-cli-integration) | `./install.sh --copy --configure-kimi` | Completion, approval request, failed turn, background task terminal states |
| [Grok Build](docs/integrations.md#grok-build-integration) | `./install.sh --copy --configure-grok` | Completion, permission/idle prompts, failed tool calls |
| [OpenCode](docs/integrations.md#opencode-integration) | `./install.sh --copy --configure-opencode` | Session idle + permission asked |
| [Pi](docs/integrations.md#pi-integration) | `./install.sh --copy --configure-pi` | Agent fully settled |
| [Step Code](docs/integrations.md#step-code-integration) | `./install.sh --copy --configure-step` | Agent fully settled; prompt notifications are opt-in |
| [omp](docs/integrations.md#omp-integration) | `./install.sh --copy --configure-omp` | Main session stopped / idle |

Launch a **new agent session inside the intended tmux pane** after setup. Enable
the [Inbox UI](#tmux-inbox) too if using SSH. Finish a short agent request to
verify the integration; standalone CLI tests alone do not prove the hook runs.

For Codex, `--configure-codex` keeps an existing top-level `notify` command rather
than replacing it. Approval hooks need registration and trust review in `/hooks`.
An approval-request event can precede automatic approval; it does not always mean
a human is required. Avoid registering both legacy completion and native `Stop`
notifications for the same task. See the guide for native Codex terminal
notifications and duplicate-reminder settings.

## Test it

### From inside tmux (local or SSH)

Run this in the pane you want to return to:

```bash
(sleep 5; tmux-notify-jump --target "$TMUX_PANE" \
    --title "Test complete" --body "Return to the original pane" --detach) &
```

Within five seconds, switch to another tmux window, for example with your
**tmux prefix, then `c`** (default prefix: `Ctrl+b`; `c` creates a window).

- **Local desktop:** a notification should appear. Click Jump (or the notification
  itself on macOS) and confirm you return to the original pane. Also test Dismiss
  if the backend offers it: it should leave your current pane unchanged.
- **SSH:** expect a tmux message and a pending Inbox item, rather than a desktop
  popup. With the [Inbox configured](#tmux-inbox), press **prefix, then uppercase
  `N`** to return. Without the UI, `tmux-notify-jump --inbox-list` shows stored items.

An item is not kept pending when its pane is already the current pane of an
ordinary client. Switch away before the delayed test fires.

### Without tmux

```bash
tmux-notify-jump --focus-only --sender-pid "$$" \
    --title "Focus test" --body "Click to focus this terminal" --detach
```

Bring another app forward, then click the notification. Your terminal should
come forward where platform focus support is available; no pane jump occurs.

### Check configuration

```bash
tmux-notify-jump --doctor
```

Run inside tmux for server checks. `WARN` may concern optional tools or agents
you do not use. `FAIL` exits with status 1; if the server is unreachable, later
checks stop. Doctor does not send a notification or confirm real click behavior.
For focus-only use without a tmux server, use the desktop test above instead.

## tmux Inbox

The Inbox keeps pending completion and attention events for panes you are not
currently viewing. It works locally and over SSH, and starts recording even
before you install its status display and shortcut.

From the checkout, configure the UI:

```bash
./install.sh --copy --configure-tmux
```

Then, **inside the tmux server you want to configure**, reload its configuration:

```bash
tmux source-file ~/.tmux.conf
```

Use your actual config path if customized (`--tmux-config /path/to/tmux.conf`).
You do not need to restart the server.

- The status bar shows `?N` pending attention items and `!N` completed items,
  where `N` is the count.
- Press your tmux prefix, release it, then press **uppercase `N`** (`Shift+n`).
  With the default prefix, this is `Ctrl+b`, then `Shift+n`. Lowercase `n` normally
  means “next window”.
- This jumps to the oldest attention item first, then the oldest completion,
  skipping your current pane. Visiting a pane acknowledges its notices when
  acknowledgement hooks are available (tmux 3.0+).
- Run `tmux-notify-jump --inbox-pick` to choose an item. Install `fzf` for search
  and pane preview; popups need tmux 3.2+, with menu/list fallbacks on older versions.

Existing key bindings are preserved. If uppercase `N` is taken, rerun the
installer with `--tmux-key M` (or another free alphanumeric key), reload the
config, and check `--doctor`. The installer adds an Inbox block, not general
activity/bell notifications; those are [separate tmux event hooks](docs/reference.md#tmux-hooks-integration).
[Advanced Inbox behavior](docs/reference.md#tmux-inbox).

## Configuration

Create the shared shell configuration file:

```bash
mkdir -p ~/.config/tmux-notify-jump
# Edit ~/.config/tmux-notify-jump/env with your preferred editor.
```

For example, add only the settings you want:

```bash
TMUX_NOTIFY_BELL=1                  # Optional terminal bell, including over SSH
TMUX_NOTIFY_TERMINAL_METHOD=osc777   # Optional popup from a compatible terminal
CODEX_NOTIFY_TERMINAL_METHOD=none    # Avoid adding OSC if Codex already sends it
```

Both bell and OSC delivery are **off by default**. OSC requires a local terminal
that supports and enables OSC 777. Its popup cannot jump to the originating
pane; use the Inbox for that. Bell/OSC need an attached ordinary tmux client,
and do not work in focus-only mode. They are additional channels: even
`TMUX_NOTIFY_REMOTE_MODE=suppress` does not turn them off.

| Want to… | Setting or command |
| --- | --- |
| Keep default local desktop + SSH Inbox routing | `TMUX_NOTIFY_REMOTE_MODE=tmux` (default) |
| Add host desktop delivery alongside Inbox routing | `TMUX_NOTIFY_REMOTE_MODE=both` (does not forward remote desktop notifications to your local machine) |
| Use host desktop notifications without Inbox storage | `TMUX_NOTIFY_REMOTE_MODE=desktop` |
| Use explicit Jump/Dismiss dialogs | `TMUX_NOTIFY_UI=dialog` (Linux needs `zenity`, `kdialog` or `yad`) |
| Switch panes without raising the terminal | Pass `--no-activate` |
| Disable one agent's notifications | For example, `CLAUDE_NOTIFY_EXCLUDE_EVENTS='*'` |

Configuration has different scopes:

| Where | Used by | When it takes effect |
| --- | --- | --- |
| `~/.config/tmux-notify-jump/env` | Shell notification commands and wrappers | Next invocation; reload tmux config after changing Inbox initialization settings |
| Agent's own config / plugin files | The agent's hook or extension loader | Start a new agent session; complete any required trust review |
| Agent process environment | TypeScript bridge options such as `PI_NOTIFY_CMD`, `PI_NOTIFY_HEADLESS` and corresponding omp/Step options | Export before launching the agent; these bridges do not load the shared env file |
| Command-line flags | The invoked notification command | This invocation; explicit flags override corresponding settings |

`TMUX_NOTIFY_CONFIG` selects another shared file; an explicitly empty value skips
file loading. The shared file is sourced as Bash; assignments there can replace
inherited environment values. Keep shell syntax valid and quote values with
spaces. [All variables and precedence details](docs/reference.md#environment-variables).

## Troubleshooting

| Symptom | Start here |
| --- | --- |
| `command not found` | Check `command -v tmux-notify-jump` and PATH; restart the agent from that shell. For symlink installs, keep the checkout in place. |
| No notification over SSH | Default behavior is tmux message/Inbox, not a local desktop popup. Configure the Inbox UI and test from a background pane. |
| CLI test works, agent does not notify | Check `jq`, selected events, agent restart and hook registration/trust. Enable the wrapper's debug log (for example, `CODEX_NOTIFY_DEBUG=1` in the shared env file). |
| No local desktop notification | Check the platform notification tool, desktop notification permissions / Do Not Disturb, and `--doctor`; then run the focus-only test. |
| Notification appears but has no Jump button | Linux needs notification action support (`notify-send -A` / `--wait` and daemon support). Dialog mode provides explicit buttons. macOS may jump on the notification click itself. |
| Terminal does not come forward | Wayland disables focus. Linux/X11 needs `xdotool` or the supported awesome-client fallback; macOS may need a terminal bundle-ID override. |
| Inbox shortcut does nothing | Reload the correct tmux config and check `--doctor` for an occupied key. Use uppercase `N`, not lowercase `n`. |
| Wrong pane or duplicate reminders | Launch the agent in the intended pane. Keep one notification registration per event; review native agent notifications as well. |

Logs for the notification command can be enabled with `TMUX_NOTIFY_DEBUG=1`;
the default is `~/.cache/tmux-notify-jump/debug.log` (or under `XDG_CACHE_HOME`).
Wrapper log locations differ; see the [integration guide](docs/integrations.md).
For multiple tmux servers, specify `TMUX_NOTIFY_TMUX_SOCKET` or the supported
`--tmux-socket` option rather than inspecting a different server by accident.
[Detailed diagnostics and focus troubleshooting](docs/reference.md#diagnostics).

## Update and uninstall

### Update

From your checkout:

```bash
git pull --ff-only
./install.sh --prefix "$HOME/.local" --copy
```

Reuse your original prefix, install mode and integration flags (for example,
`--configure-pi`) to update installed plugin/extension copies too. Symlink installs
read the updated checkout directly, but rerun configuration when hooks or paths
change. Reload tmux config if its block changes, start a new agent session, and
review changed Codex hooks again in `/hooks`.

### Uninstall

First remove this tool's agent registrations while keeping unrelated hooks:

| Integration | What to remove |
| --- | --- |
| Codex | This wrapper's top-level `notify` entry and its handlers in `hooks.json` or inline hooks, if configured |
| Claude / Kimi | Only the hook entries calling this tool's wrapper |
| Grok | This tool's `tmux-notify-jump.json` in the configured hooks directory |
| OpenCode / Pi / omp | This tool's `tmux-notify-jump.ts` in the configured plugin/extension directory |
| Step | Remove its extension manually, or add `--configure-step` to the uninstall command |

See [integration paths](docs/integrations.md) for default and custom locations.
Automatic removal of Codex/Claude/Kimi/Grok/OpenCode/Pi/omp configuration is **not**
provided by `--uninstall`.

If you configured the Inbox UI, clean it up from the checkout **before removing
the installed scripts**. If several servers have been configured, first run
`tmux-notify-jump --tmux-uninit --tmux-socket /path/to/other.sock` for each
additional server while the executable is still installed. Then, inside the
final server, run:

```bash
./install.sh --prefix "$HOME/.local" --uninstall --configure-tmux
```

This removes the marked tmux config block, the running server's tool-owned Inbox,
status, hooks and shortcut, **and the installed scripts**. With multiple servers,
pass `--tmux-socket /path/to/socket` deliberately; cleanup affects the selected
server. Supply your original `--tmux-config` / `--bindir` if customized. See
[cleanup details](docs/reference.md#tmux-inbox).

If you did not configure tmux, remove just the installed scripts:

```bash
./install.sh --prefix "$HOME/.local" --uninstall
```

The shared env file, backup files and caches are not removed by this basic
uninstall. Keep them if reinstalling, or remove only this tool's files after
checking the locations you customized.

## More documentation

- [Agent integrations](docs/integrations.md): manual setup, event filters, approval prompts, profiles and per-agent logs.
- [Technical reference](docs/reference.md): full CLI/environment options, Inbox, BEL/OSC, tmux compatibility and targeting.
- [Tests and development](docs/reference.md#tests): `make check`, test dependencies and repository layout.
- Run `tmux-notify-jump --help` or `./install.sh --help` for command-line help.
