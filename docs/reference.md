# Technical reference

[User guide](../README.md) · [中文使用指南](../README.zh-CN.md) · [Agent integrations](integrations.md)

This reference contains advanced options and compatibility details. For a first
installation, follow the user guide instead. Commands below use the installed
`tmux-notify-jump` entry point; installer commands run from the checkout.

- [CLI usage](#usage)
- [Dependencies](#dependencies)
- [Terminal bell](#terminal-bell-over-ssh)
- [Terminal notifications / OSC 777](#terminal-notifications-over-ssh)
- [Inbox and tmux configuration](#tmux-inbox)
- [Desktop clicks and target selection](#desktop-clicks-and-target-selection)
- [Diagnostics](#diagnostics)
- [Environment variables](#environment-variables)
- [tmux event hooks](#tmux-hooks-integration)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)
- [Tests](#tests) and [quality checks](#quality-checks)

## Dependencies

All shipped commands use Bash. Install on the machine running the task.

| Capability | Required tools |
| --- | --- |
| Jump, pane listing, Inbox | `tmux` and a running server |
| Linux desktop notifications | `notify-send` (Debian/Ubuntu: `libnotify-bin`); action support in both the tool and desktop notification service for Jump |
| Linux terminal focus | X11 and `xdotool`, or the supported awesome-client fallback; disabled on Wayland |
| macOS desktop notifications | `terminal-notifier`; `osascript` for activation |
| Dialog UI | Linux: `zenity`, `kdialog` or `yad`; macOS: `osascript` |
| Agent wrappers | `jq`; missing dependencies cause wrappers to skip notifications |
| Automatic Claude/Grok configuration | Python 3 |
| Automatic Codex approval-hook configuration | `jq`; Python 3.11+ (`tomllib`) to inspect existing TOML safely |

Focus-only mode does not require tmux. The tmux-native SSH path does not need
`notify-send`, `terminal-notifier`, or a remote desktop daemon. BEL and OSC
delivery require attached ordinary tmux clients; OSC additionally needs support
and permission in the local terminal.

Optional tools: `python3` improves Unicode truncation; `ps` enables ancestry
target resolution; `fzf` enables Inbox search/preview (menus need tmux 3.0,
popups 3.2, popup titles 3.3). Linux WezTerm tab activation uses the WezTerm CLI
and either Python 3 or `jq` for JSON parsing. Missing optional capabilities do
not prevent other delivery paths.

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

```text
tmux-notify-jump --target TARGET [--title TITLE] [--body BODY]
tmux-notify-jump TARGET [TITLE] [BODY]
tmux-notify-jump --focus-only [--title TITLE] [--body BODY]
tmux-notify-jump --list
tmux-notify-jump --help
```

`TARGET` is a pane ID (for example, `%1`) or `session:window.pane`.
Use `tmux-notify-jump --list` to find real targets. The public entry point selects
Linux/macOS automatically. The platform scripts accept the same shared flags;
Linux adds `--class`/`--classes` and `--wrap-cols`; macOS adds
`--bundle-id`/`--bundle-ids`.

Common options (plus platform focus options where noted):

- `--list`: list available panes (`*` means active)
- `--focus-only`: on click, only focus the terminal window/app (no tmux required)
- `--no-activate`: do not focus terminal window
- `--sender-tty <TTY>`: prefer the ordinary tmux client on this TTY.
- `--tmux-socket <path>`: select a tmux server explicitly (`tmux -S`).
- `--quiet`: suppress non-error output; does not disable BEL or OSC.
- `--max-title <n>` / `--max-body <n>`: truncation limits (`0` disables).
- macOS: `--bundle-id <ID>` / `--bundle-ids <A,B>`: terminal apps to activate.
- `--terminal-method none|osc777`: additional terminal delivery (default `none`).
- `--sender-pid <PID>`: best-effort focus by walking the sender process tree (useful outside tmux)
- Linux: `--class <CLASS>` / `--classes <A,B>`: fallback terminal window class(es) to focus (default: `org.wezfurlong.wezterm,Alacritty`)
- `--timeout <ms>`: notification timeout in milliseconds (default: `10000`; `0` may be sticky depending on daemon)
- `--dedupe-ms <ms>`: suppress duplicate notifications within this window (default: `2000`; `0` disables). Uses a small cache under `XDG_CACHE_HOME`/`~/.cache` and prunes old entries automatically.
- `--bell` / `--no-bell`: enable/disable a terminal BEL for the target tmux session (default: disabled). Override configuration; the last flag wins.
- Linux/macOS: `--ui <notification|dialog>`: UI mode (`dialog` always waits for click; can also set `TMUX_NOTIFY_UI`, but `--ui` wins)
- `--detach`: run in background (recommended for hook/callback use)
- `--dry-run`: print what would happen and exit
- Linux: `--wrap-cols <n>`: wrap body text to `<n>` columns (default: `80`; `0` disables wrapping)
- `--notify-kind <attention|complete>`: classify an Inbox item. Attention items
  are selected first by the tmux Inbox key.
- `--notify-source <name>`: source label shown in remote tmux messages and the
  Inbox metadata.
- `--inbox-pick [options]`: search the tmux Inbox and jump to a selected item.
- `--doctor [--tmux-socket <path>] [--agent-config <agent=path>]`: print dependency and tmux integration
  diagnostics without changing configuration, permissions or Inbox contents.

## Terminal bell over SSH

All supported agent wrappers can add a terminal bell to their notifications.
Enable it in `~/.config/tmux-notify-jump/env` (or `TMUX_NOTIFY_CONFIG`):

```bash
TMUX_NOTIFY_BELL=1
OMP_NOTIFY_BELL=0  # Keep omp's built-in sound without adding another bell
```

Per-agent overrides are `CODEX_NOTIFY_BELL`, `CLAUDE_NOTIFY_BELL`,
`KIMI_NOTIFY_BELL`, `GROK_NOTIFY_BELL`, `OPENCODE_NOTIFY_BELL`, `PI_NOTIFY_BELL`,
`STEP_NOTIFY_BELL`, and `OMP_NOTIFY_BELL`. Unset or empty values inherit the
global setting.
Use `0` to disable, or `1`, `true`, `yes`, or `on` to enable (uppercase words
also work); other values disable. Wrappers forward an explicit per-agent
override as `--bell` or `--no-bell`, taking precedence over the global setting.

For an agent running in Linux tmux over SSH from macOS, the notification writes
one BEL byte (`0x07`) to each distinct ordinary client TTY attached to the
target session. SSH carries it back to your macOS terminal, which controls the
audible or visual effect. The pane may be active or in a background window.
Other sessions and control-mode clients are excluded; without a valid target
and attached terminal, including `--focus-only`, the bell is skipped.

BEL needs no desktop notification daemon, audio tool, or additional runtime
dependency. It works with redirected hook output and `--detach`, after event
filtering and deduplication. `--quiet` does not silence it; `--dry-run` never
rings. The bell is independent of `TMUX_NOTIFY_REMOTE_MODE`, including
`suppress`: use `--no-bell` or `TMUX_NOTIFY_BELL=0` to disable it. Inbox and
desktop delivery continue normally if writing a terminal fails.

The byte goes directly to the client terminal, bypassing this tmux server's
`bell-action` and `visual-bell` settings and avoiding a new `alert-bell` hook.
The `alert-bell` wrapper defaults to `--no-bell` to avoid duplicating an original
pane bell; explicitly passing `--bell` overrides that default. If you hear no
sound, check the terminal emulator's audible bell and mute settings. For
nested terminal multiplexers, their outer bell policies can still apply.

Test from inside the target tmux pane:

```bash
tmux-notify-jump --target "$TMUX_PANE" --bell --title "Bell test" --detach
```

## Terminal notifications over SSH

To request a desktop notification from a compatible local terminal while the
agent runs over SSH, enable OSC 777 in the shared env file:

```bash
TMUX_NOTIFY_TERMINAL_METHOD=osc777  # Default: none
CODEX_NOTIFY_TERMINAL_METHOD=none  # Optional: use Codex's native OSC instead
```

All eight agent wrappers support `<AGENT>_NOTIFY_TERMINAL_METHOD` overrides,
using the same prefixes as the bell settings above. Empty overrides inherit
the global method. The CLI accepts `--terminal-method none|osc777`; an explicit
flag wins over configuration, including after `--detach`.

Like BEL, OSC delivery goes directly to each distinct ordinary client TTY of
the target session, including clients viewing another window. This bypasses
the current tmux server's pane passthrough setting; no DCS wrapper or
`allow-passthrough` change is needed for this path. Outer nested multiplexers
may still filter the sequence. Control clients, other sessions, focus-only
mode and dry runs receive no sequence. Event filtering and deduplication
apply before sending; `--quiet` does not silence it.

OSC is an additional delivery channel, independent of `TMUX_NOTIFY_REMOTE_MODE`
(including `suppress`) and BEL. Inbox and desktop routing continue normally,
even if a terminal write fails. Use `none` to disable OSC. A detached session
with no attached client cannot receive terminal notifications; its Inbox can
still retain events. No desktop daemon is needed on the remote host.

The local terminal must implement and enable OSC 777. Writing the sequence
successfully does not establish that a toast appeared. Notification clicks are
handled by the terminal and do not carry a tmux pane jump callback; use Inbox
or the existing desktop Jump action to select the exact pane. Titles and
bodies are plain UTF-8, with controls removed, ASCII semicolons replaced, and
each field limited to 255 bytes. Avoid enabling native agent notifications,
OSC delivery and desktop delivery for the same events unless multiple
reminders are intended.

```bash
tmux-notify-jump --target "$TMUX_PANE" --terminal-method osc777 --detach
```

## tmux Inbox

When `TMUX_NOTIFY_REMOTE_MODE=tmux` (the default), a notification whose target
pane is not currently visible is recorded in a small persistent Inbox. The
status-right segment shows `?N` for attention items and `!N` for completed work.
Run `./install.sh --configure-tmux` once to install the status segment, focus
hooks, and the `prefix+N` binding, then reload the configured file with
`tmux source-file ~/.tmux.conf`. Use the actual config path if customized;
restarting the server is not required. The binding key must be
free when initialization runs: tmux binds `prefix+n` to `next-window` by
default, and a key your configuration or a plugin already took is reported and
left alone. Pass `--tmux-key <key>` to the installer or to `--tmux-init` (or
edit the `@tmux-notify-jump-key` line the block installs) to pick another one,
and confirm with `tmux-notify-jump --doctor`. Pressing the binding
selects the oldest attention item first, then the oldest completion, and clears
that exact pane as soon as it is visited. Repeated events for the same pane and
priority collapse into one item with an updated count.
The Inbox stores pending attention/completion events. A continuous
`working / needs-input / done` view needs reliable start, resume and exit
events across adapters. These are not consistently available, so lifecycle
state is not inferred from silence between notifications.
Inbox cache directories and metadata files are restricted to the current user.
Notification bodies are used for immediate delivery but are not persisted.
Run `tmux-notify-jump --inbox-pick` for a searchable fzf popup with the selected
pane's last 80 lines as a preview. It shows priority, agent/source, current
session/window/pane, age in seconds and count, sorted attention first and then
oldest first. Session renames and pane moves are read from one live inventory.
Enter jumps; Escape cancels without acknowledging anything.
Successful selection verifies the ordinary client's session and pane before
acknowledging both priorities for that pane, including when focus hooks are not
installed. A failed or unverified jump retains the notices. Closed panes keep
the window/session fallback; successful fallback or an entirely stale target
retires both priorities for the closed pane.
Stale targets are cleared only after a successful pane inventory confirms
their absence; failed or incomplete queries retain the notices. Window fallback
follows a moved window's live session and prefers the recorded session when
the window remains linked there.

Inbox commands:

| Command | Behavior |
| --- | --- |
| `tmux-notify-jump --inbox-list` | Print pending items |
| `tmux-notify-jump --inbox-next` | Jump to the oldest attention item, then completion; skip the invoking client's current pane |
| `tmux-notify-jump --inbox-pick` | Choose an item with fzf, a tmux menu or a list fallback |
| `tmux-notify-jump --inbox-clear-all` | Clear the selected server's pending Inbox items |
| `tmux-notify-jump --tmux-init` | Initialize runtime status, hooks and binding; accepts `--tmux-key` and `--tmux-socket` |
| `tmux-notify-jump --tmux-uninit` | Remove this tool's runtime state; accepts `--tmux-socket`, retains scripts/config |

Set `TMUX_NOTIFY_TMUX_SOCKET` for list/next/clear operations on a specific server.
The installed key binding propagates `TMUX_NOTIFY_SENDER_TTY` so next-item jumps
use the invoking client. The picker also accepts explicit socket/client options.

Picker options:

- `--kind attention|complete`, `--source <name>` and `--session <name-or-id>`:
  exact filters; `--session` accepts the live name or stable `$N` session ID.
- `--since <seconds>`: include items updated within this time (default `0`, all).
- `--query <text>`: initial fzf search across the displayed fields.
- `--menu`: use the numbered tmux menu; `--query` becomes a case-insensitive
  substring filter. `[` and `]` move between pages of up to 35 items. Page size
  adapts to the invoking client's height, reserving borders and navigation rows.
  Labels also fit its width, reserving space for shortcuts and borders. Each
  non-ASCII codepoint uses a conservative two-column budget because tmux and
  system Unicode width tables can disagree. This can shorten accented or
  combining text earlier; menu sizing does not require Python. A client smaller
  than 5 rows or 9 columns, or unavailable dimensions, prints the list.
- `--inline`: run fzf in the current terminal instead of a popup.
- `--sender-tty <tty>` and `--tmux-socket <path>`: identify the invoking client
  and server explicitly. The selected socket takes precedence over configuration
  throughout menu, popup and preview callbacks.

fzf is optional. Popups need tmux 3.2 (popup titles need 3.3). tmux 3.0–3.1,
an unavailable or incompatible fzf, or a failed popup falls back to the menu.
Older tmux prints the filtered list;
`--inline` with fzf and `--inbox-next` remain available. A picker invoked outside a client needs
`--sender-tty` if several ordinary terminals are attached. An explicitly named
client that has detached is never replaced with another terminal.

Examples and an optional second binding (the installed `prefix+N` stays a quick
jump to the oldest item outside the invoking client's current pane):

```bash
tmux-notify-jump --inbox-pick --kind attention --session work --since 3600
tmux-notify-jump --inbox-pick --query Codex
# Add this optional binding only if prefix+P is free.
tmux bind-key P run-shell -b 'TMUX_NOTIFY_SENDER_TTY="#{client_tty}" tmux-notify-jump --inbox-pick'
```

Inbox routing is active even before `--configure-tmux` installs its status,
hooks, and binding. Set `TMUX_NOTIFY_REMOTE_MODE=desktop` to disable tmux Inbox
storage and use desktop delivery only.

`--inbox-next` skips the invoking client's current pane and leaves its entries
pending. The picker marks that pane with `[current]` and lets you select it
explicitly. Inbox list/picker/next operations maintain private permissions,
expire old items and update counts as applicable; `--doctor` only reads state.

Initialization pins the resolved Inbox directory in the tmux server so agent
processes and `run-shell` hooks use the same location. To customize
`XDG_CACHE_HOME`, set it in `~/.config/tmux-notify-jump/env` (or the file named by
`TMUX_NOTIFY_CONFIG`) and reload the tmux configuration. An override set only in
an interactive shell rc file may not be visible to the tmux server.

In the default mode, an SSH client attached to the target session takes
precedence over local clients: feedback stays inside tmux and no desktop
notification is sent. This also covers an old pane whose processes retained a
local graphical environment before an SSH client attached. Set
`TMUX_NOTIFY_REMOTE_MODE=both` to opt into desktop delivery for mixed local and
SSH attachments. With no remote target client, desktop delivery is retained for
local clients and local processes. Remote clients viewing the target session
also receive a transient tmux message. Automatic acknowledgement on manual pane
visits requires tmux 3.0 or newer; older releases keep the status and `prefix+N`
workflow but warn during initialization that acknowledgement hooks are
unavailable.

The configuration block is marked and idempotent. Use
`./install.sh --configure-tmux --uninstall` to remove that block and the installed
scripts while leaving unrelated tmux configuration intact. The same command clears
a running server's Inbox, status segment, hooks, and tool-owned key binding
before removing the executable, and reports the socket it changed together with
how many Inbox entries it removed. Incomplete Inbox cleanup is reported as an
error. That server is the one `$TMUX` points at, otherwise the default socket;
pass `--tmux-socket <path>` to name a different one when you run several
servers. A server that carries none of this tool's state is reported and left
untouched. That check only recognizes servers this tool never configured:
servers sharing a `~/.tmux.conf` all run `--tmux-init` and carry identical
marks, so naming the wrong socket does clear that server's Inbox. Check the
reported socket, and pass `--tmux-socket` deliberately when more than one server
is configured. Before uninstalling scripts shared by several servers, run
`tmux-notify-jump --tmux-uninit --tmux-socket /path/to/socket` for each additional
configured server. For live-state cleanup alone, use `--tmux-uninit`; it retains
the scripts and config file, so a later config reload can initialize the tool again.

If `prefix+N` is already bound to something else — tmux itself
binds `prefix+n` to `next-window` out of the box — initialization warns and
preserves the existing binding. Choose a key that is free: pass `--tmux-key
<key>` to `--tmux-init`, or set `@tmux-notify-jump-key` in the configuration
block, or set `TMUX_NOTIFY_TMUX_KEY` / `TMUX_NOTIFY_KEY` in the environment, in
that order of precedence. The key must be a single alphanumeric character;
`--tmux-key` rejects anything else, and a configured value such as `C-n` is
reported and replaced with `N` rather than being silently ignored. `--tmux-key`
is accepted only by `--tmux-init`, the one subcommand that binds a key.

`--tmux-init --tmux-key <key>` also records the key in
`@tmux-notify-jump-key`, so the binding, the option and `--doctor` agree and a
later `--tmux-init` keeps the key instead of silently migrating the binding
back. An inherited `TMUX_NOTIFY_TMUX_KEY` is not recorded: it may be a one-shot
override for a single command. Reloading your tmux configuration re-applies the
value in the configuration block, which is the durable place to change the key.
Run `tmux-notify-jump --doctor` to confirm: it resolves the key the same way
initialization does and reports the binding actually in effect.
Changing the key or reinstalling under a different `--bindir` migrates the
binding: initialization finds jump bindings by command rather than by key, so it
retires the one an earlier install left behind instead of leaving a second key
bound, or leaving the current key pointing at an install path that no longer
exists. Uninstall removes them the same way. Set
`TMUX_NOTIFY_TMUX_STATUS=0` to keep the hooks and binding without appending the
Inbox counts to `status-right`.

Acknowledgement hooks are installed at array index `900` of `client-attached`,
`client-session-changed`, `after-select-pane`, `after-select-window`, and
`client-focus-in`. That index is only conventionally reserved: a plain
`set-hook -g <hook>` writes index `0` and `set-hook -ga` appends from there, so
nothing but a deliberate `[900]` collides. Initialization warns and keeps a
command it did not install, and uninstall removes only its own. Note that a
plain `set-hook -g` replaces the whole array, including index `900`. If you set
one of these five hooks yourself, use `set-hook -ga` to append; a plain
`set-hook -g` evaluated after `--tmux-init` silently disables automatic
acknowledgement, leaving Inbox entries armed until you visit them via
`prefix+N`.

## Desktop clicks and target selection

macOS note: in `--ui notification` mode, if the script is detached (or `terminal-notifier` doesn’t support `-wait`), it falls back to `terminal-notifier -execute`, where any click triggers the jump (no separate “Dismiss” action). Use `--ui dialog` for explicit buttons.

Agent wrappers first use `TMUX_PANE`. If it is absent, they take one tmux pane
inventory and one optional `ps` process inventory to find the nearest pane root
in the reporter's process ancestry. This works for hooks that lose `TMUX_PANE`
while still running under the originating pane. `TMUX` alone identifies a
server and does not establish pane ownership. Process ancestry identifies the
pane that launched a process, which can differ from the session served by a
persistent/shared daemon such as `codex app-server` or `opencode serve`.
For those services, set `TMUX_NOTIFY_TARGET_ANCESTRY=0`, remove an inherited
`TMUX_PANE` unless it belongs to the reporting session, and leave the agent's
`*_NOTIFY_FALLBACK_TARGET=0`. Disabling ancestry does not override `TMUX_PANE`.
Reliable daemon targeting needs a per-report session-to-pane binding. Session
IDs and shared working directories alone do not establish that binding and
are not used to guess ownership. With no reliable target,
events use the existing focus-only fallback, or become a no-op when it is
disabled. Ambient pane/most-recent-client fallback now requires explicitly
enabling `*_NOTIFY_FALLBACK_TARGET`; upgrading can therefore stop jumps that
previously went to an unrelated pane. Use an explicit `TMUX_NOTIFY_TMUX_SOCKET`
when reporting to a non-default server without `TMUX`.

## Diagnostics

Run `tmux-notify-jump --doctor` to check executable and server versions, optional
dependencies, the effective configuration and socket paths, the pinned Inbox
directory and its permissions, acknowledgement hooks, status segment and
prefix binding. It probes fzf's required options with a noninteractive filter,
checks all eight wrapper files for executability, and looks for wrapper text
references in user-level agent configuration/bridge files. A text reference
can be inactive or commented out; this check does not prove runtime hook
registration or successful notification delivery. It never sends a
notification or repairs state. `WARN` covers
optional tools, older tmux capabilities and integrations that are absent or
customized. `FAIL` means tmux/server access is unavailable or configuration/
Inbox paths or permissions are invalid; the exit status is then `1`. Successful
checks, including warnings, return `0`. Pass `--tmux-socket <path>` to inspect a
specific server. Notification daemon action support and GUI activation still
need a manual click test; installed executables alone do not establish those.
Invalid `--agent-config` specifications fail before any diagnostic output or
tmux queries. Server reachability is checked before optional dependencies and
agent configuration, so an unavailable server stops those further checks.

For Codex, optional Python 3.11+ enables structured checks of the selected TOML
config and adjacent `hooks.json` (override with `CODEX_HOOKS_PATH`, or pass
`--agent-config codex=/path/to/hooks.json` for a hooks-only check). Diagnostics
report possible duplicate completion/approval channels after applying the
current `CODEX_NOTIFY_EVENTS` / `CODEX_NOTIFY_EXCLUDE_EVENTS` filters, and remind
you to review `/hooks`. A selected config with `[features] hooks = false`
(or the old `codex_hooks` alias) suppresses hook-based duplicate warnings;
the canonical `hooks` key takes precedence when both are set. Trust reminders
note that hooks are disabled, while top-level `notify` remains independent.
Explicit native OSC settings also trigger read-only
checks of the current pane's effective `allow-passthrough` and server `focus-events`.
Other panes, config layers, hook trust and local terminal delivery remain
unverified. Hook references still trigger trust-review reminders even when
wrapper filters disable their notifications. Without the optional parser,
these checks warn and skip; wrappers and terminal notifications do not require
Python.

Agent checks use the installer's standard user-level locations and honor
`CODEX_CONFIG_PATH`, `CLAUDE_CONFIG_PATH`, `KIMI_CONFIG_PATH`, `GROK_HOOKS_PATH`,
`OPENCODE_PLUGIN_PATH`, `PI_EXTENSION_PATH`, `STEP_EXTENSION_PATH`, and
`OMP_EXTENSION_PATH` when set. Runtime config precedence and profile selection
are not inferred. Codex defaults to `${CODEX_HOME:-$HOME/.codex}/config.toml`;
`CODEX_CONFIG_PATH` overrides it, and `--agent-config codex=...` takes precedence
for diagnostics. For a custom/profile/project file, repeat `--agent-config
<agent=path>` with `codex`, `claude`, `kimi`, `grok`, `opencode`, `pi`, `step`, or
`omp`, for example:

```bash
tmux-notify-jump --doctor --agent-config omp="$HOME/.omp/profiles/work/agent/extensions/tmux-notify-jump.ts"
```

## Environment variables

CLI flags override environment variables where applicable.

- `CODEX_HOME`: Codex home directory (default: `~/.codex` when unset or empty).
  Codex installation, diagnostics and the wrapper debug log honor it.
- `CODEX_CONFIG_PATH`: Codex config file for installation and diagnostics
  (default: `$CODEX_HOME/config.toml`); `--codex-config` overrides it in the
  installer. The adjacent `hooks.json` is used unless overridden.
- `CODEX_HOOKS_PATH`: Codex hooks JSON file for installation and diagnostics;
  `--codex-hooks-path` overrides it in the installer. This tool-specific override
  does not register the path with Codex; see the discovery requirements below.
- `TMUX_NOTIFY_CONFIG`: env file to load before running (unset defaults to
  `~/.config/tmux-notify-jump/env`; explicitly empty disables file loading).
  Relative paths resolve against the invocation directory and are fixed as
  absolute paths before loading and generating callbacks. A caller without
  `HOME` or an explicit config passes the same absence to popup/menu callbacks.
- `TMUX_NOTIFY_TARGET_ANCESTRY`: resolve missing `TMUX_PANE` through process
  ancestry (default: `1`). Set `0` for shared services whose launch pane does
  not identify the reporting session; explicit `TMUX_PANE` still takes priority.
- `TMUX_NOTIFY_JUMP_SH`: override the notification executable (a path or command
  on `PATH`). Pointing it at `tmux-notify-jump` itself, including a symlink or
  hardlink, uses normal platform dispatch. If a custom executable calls the
  entrypoint again, that invocation uses normal platform dispatch too, preventing
  recursive overrides. Arguments are forwarded unchanged.
- `TMUX_NOTIFY_BELL`: add a terminal BEL for all ordinary clients attached to the target tmux session (`0` by default). See [Terminal bell over SSH](#terminal-bell-over-ssh) for per-agent overrides and terminal settings.
- `TMUX_NOTIFY_TERMINAL_METHOD`: additional terminal notifications (`none`, the
  default, or `osc777`). See [Terminal notifications over SSH](#terminal-notifications-over-ssh)
  for per-agent overrides and terminal compatibility.
- `TMUX_NOTIFY_DEBUG`: write diagnostic details, including failures from detached
  notification processes, when set to `1`.
- `TMUX_NOTIFY_DEBUG_LOG`: debug log path (default:
  `$XDG_CACHE_HOME/tmux-notify-jump/debug.log` or
  `~/.cache/tmux-notify-jump/debug.log`).
- `TMUX_NOTIFY_WINDOW_ID`: explicit X11 window id to focus (overrides auto-detection)
- `TMUX_NOTIFY_TMUX_SOCKET`: tmux server socket path (passed to `tmux -S`; useful if you run multiple tmux servers)
- `TMUX_NOTIFY_FALLBACK_TARGET`: allow using tmux's current pane or the most
  recently active ordinary client pane when the originating pane cannot be
  identified (`0` disables; default: `0`). This may target unrelated work.
- `TMUX_NOTIFY_FOCUS_ONLY_FALLBACK`: when hooks run without tmux (missing or no server/target), fall back to `--focus-only` instead of no-op (`0` disables; default: `1`)
- `TMUX_NOTIFY_UNATTACHED_FALLBACK`: policy when the target session has no identifiable ordinary client. The default `single` switches the server's sole ordinary client; it still refuses when there are zero or multiple ordinary clients. Set `none` for strict mode, which reports that the target is not visible instead of moving a terminal. Unknown values warn and fall back to `single`. On macOS the selected policy is forwarded to the notification click callback.
- `TMUX_NOTIFY_REMOTE_MODE`: `tmux` (Inbox/status/remote `display-message`,
  with remote target clients taking precedence over desktop delivery; default),
  `desktop` (desktop only), `both` (tmux and desktop routing), or `suppress`.
  The legacy `TMUX_NOTIFY_REMOTE=1` value maps to `desktop` for compatibility.
- `TMUX_NOTIFY_INBOX_TTL_MS`: remove Inbox items older than this value (default:
  `604800000`, seven days).
- `TMUX_NOTIFY_INBOX_MAX`: maximum number of Inbox entries (default: `100`).
- `TMUX_NOTIFY_INBOX_LOCK_RETRIES`: number of 10 ms retries when concurrent
  events update the same Inbox entry (default: `20`).
- `TMUX_NOTIFY_TMUX_STATUS`: append Inbox counts to tmux `status-right`
  (`0` disables; default: `1`).
- `TMUX_NOTIFY_CLASS` / `TMUX_NOTIFY_CLASSES`: terminal window class(es) used by `xdotool search --class`
- `TMUX_NOTIFY_WEZTERM_TAB`: on Linux, after focusing the terminal window, also switch to the wezterm tab/pane that hosts the tmux client (matched via `wezterm cli list` by tty; `0` disables; default: `1`). Requires `python3` or `jq` for JSON parsing; silently skipped when neither is available, when `--no-activate` is set, or when the terminal is not wezterm. The GUI IPC socket path embeds the GUI pid; when `WEZTERM_UNIX_SOCKET` is unset or stale, the socket is rediscovered from `XDG_RUNTIME_DIR/wezterm` (the `x11-$DISPLAY-org.wezfurlong.wezterm` symlink, then the newest `gui-sock-*`), so restarting WezTerm does not break tab switching.
- `TMUX_NOTIFY_BUNDLE_ID` / `TMUX_NOTIFY_BUNDLE_IDS`: macOS terminal bundle id(s) for `osascript` activation (overrides auto-detection; e.g. kitty is `net.kovidgoyal.kitty`)
- `TMUX_NOTIFY_UI`: default for `--ui` (`notification` or `dialog`)
- `TMUX_NOTIFY_TIMEOUT`: default notification timeout in ms
- `TMUX_NOTIFY_DEDUPE_MS`: suppress duplicate notifications within this window (default: `2000`; `0` disables; cached under `$XDG_CACHE_HOME` or `~/.cache`)
- `TMUX_NOTIFY_MAX_TITLE` / `TMUX_NOTIFY_MAX_BODY`: truncate limits (`0` = no truncation)
- Linux: `TMUX_NOTIFY_WRAP_COLS`: wrap body text to this many columns (`0` = no wrapping)
- `TMUX_NOTIFY_ACTION_GOTO_LABEL`: label for the "goto" action (default: `Jump`)
- `TMUX_NOTIFY_ACTION_DISMISS_LABEL`: label for the "dismiss" action (default: `Dismiss`)

To switch desktop UI modes without changing agent hook config, create
`~/.config/tmux-notify-jump/env`:

```bash
TMUX_NOTIFY_UI=dialog
```

## tmux hooks integration

tmux exposes an event/hook system. You can attach `tmux-notify-jump` to those events so tmux itself triggers desktop notifications.

Recommended: use pane ids (`#{hook_pane}` like `%1`). This is more stable than `session:window.pane` because the pane id uniquely identifies the pane; the script resolves session/window/pane at jump time.

This is separate from `--configure-tmux`, which installs Inbox UI and
acknowledgement hooks, not these event notifications. Bell/activity alerts
also depend on tmux alert settings (for example, `monitor-activity`). Merge
with existing hooks rather than replacing them; the examples use `-ga` to append.

Example `~/.tmux.conf`:

```tmux
# Notify when a bell/activity happens in any window
set-hook -ga alert-bell     "run-shell -b 'tmux-notify-jump-hook.sh --event alert-bell --pane-id #{hook_pane} --tmux-socket \"#{socket_path}\" --timeout 0'"
set-hook -ga alert-activity "run-shell -b 'tmux-notify-jump-hook.sh --event alert-activity --pane-id #{hook_pane} --tmux-socket \"#{socket_path}\" --timeout 0'"

# Notify when a pane's command exits (useful for long-running commands).
# Note: jumping only makes sense if the pane still exists (e.g. `set -g remain-on-exit on`).
set-hook -ga pane-exited "run-shell -b 'tmux-notify-jump-hook.sh --event pane-exited --pane-id #{hook_pane} --tmux-socket \"#{socket_path}\"'"
```

Notes:

- Prefer `run-shell -b` (or pass `--detach`) so tmux isn’t blocked waiting for clicks.
- If you run multiple tmux servers, pass `--tmux-socket <path>` (or set `TMUX_NOTIFY_TMUX_SOCKET`) to pin the correct server.
- If you attach multiple clients to the same tmux server, passing `--sender-tty`/`--sender-pid` helps the script switch/focus the same client that triggered the hook (the helper attempts to auto-detect and pass these when possible).

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
- WezTerm tab switch stopped working after restarting WezTerm: a tmux server started inside the previous GUI keeps exporting the old (dead) `WEZTERM_UNIX_SOCKET`, which used to make `wezterm cli list` unreachable. tmux-notify-jump now falls back to socket discovery automatically; if clicks still do not switch tabs, check `TMUX_NOTIFY_WEZTERM_TAB` is not `0` and that `wezterm cli list` prints panes from a shell with the same environment.
- Wayland session: terminal focusing is auto-disabled; use X11 if you need focus behavior.
- tmux server not running: start tmux or run the script from within an existing tmux session (or use `--focus-only` to just focus the terminal).

## Repository layout

- `tmux-notify-jump`: cross-platform entry point (auto-selects Linux/macOS implementation)
- `tmux-notify-jump-lib.sh`: shared parsing, configuration, tmux targeting, delivery routing and Inbox logic
- `tmux-notify-jump-linux.sh`: Linux/X11 implementation (notify-send + xdotool)
- `tmux-notify-jump-macos.sh`: macOS implementation (terminal-notifier + osascript)
- `tmux-notify-jump-hook.sh`: helper for tmux hooks (uses `#{hook_pane}` pane id)
- `notify-codex.sh`: Codex CLI wrapper (legacy JSON from `$1`, native hooks from stdin)
- `notify-claude-code.sh`: Claude Code wrapper (reads JSON from stdin)
- `notify-kimi-code.sh`: Kimi Code CLI wrapper (reads hook JSON from stdin)
- `notify-grok.sh`: Grok Build wrapper (reads native hook JSON from stdin)
- `notify-opencode.sh`: OpenCode wrapper (reads JSON from stdin)
- `opencode-plugin/tmux-notify-jump.ts`: OpenCode plugin (bridges events to `notify-opencode.sh`)
- `pi-extension/tmux-notify-jump.ts`: Pi coding agent extension (bridges events to `notify-pi.sh`)
- `notify-pi.sh`: Pi wrapper (reads JSON from stdin)
- `step-extension/tmux-notify-jump.ts`: Step Code (`step`) extension (bridges events to `notify-step.sh`)
- `notify-step.sh`: Step Code wrapper (reads JSON from stdin)
- `omp-extension/tmux-notify-jump.ts`: omp coding agent extension (bridges events to `notify-omp.sh`)
- `notify-omp.sh`: omp wrapper (reads JSON from stdin)
- `install.sh`: script installation and opt-in agent/tmux configuration
- `tests/`: Bats tests, command stubs and isolated tmux integration tests

## Tests

- Install `bats-core` and `ripgrep`; install `tmux` to include the live hook
  integration tests (macOS: `brew install bats-core ripgrep tmux`).
- Run: `./tests/run_all.sh` (or `make -C tests test`).
- The suite includes shared-lib unit tests plus entry-script smoke tests (`tests/entry_smoke.bats`) for Linux/macOS dry-run and common validation paths.
- The isolated BEL byte test uses `uv` and an installed Python 3 interpreter; it is skipped when either is unavailable. It uses temporary pseudo-terminals and does not ring your terminal.

## Quality checks

- Install `shellcheck` (macOS: `brew install shellcheck`; Linux: `apt install shellcheck`).
- Run `make syntax` for shell syntax checks.
- Run `make lint` for shellcheck.
- Run `make test` for the bats suite.
- Run `make check` to execute syntax + lint + tests in one command.

Live tmux integration tests use dedicated temporary sockets.
