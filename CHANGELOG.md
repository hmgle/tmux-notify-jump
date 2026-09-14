# Changelog

Notable changes to tmux-notify-jump are documented in this file.

## [1.2.1] - 2026-09-14

### Fixed

- Linux WezTerm tab switching survives restarting WezTerm. The GUI IPC socket
  path embeds the GUI pid, so a tmux server started inside a previous GUI
  instance keeps exporting a dead `WEZTERM_UNIX_SOCKET` and `wezterm cli list`
  stayed unreachable. Jumping now probes candidate sockets in order —
  `WEZTERM_UNIX_SOCKET`, the `x11-$DISPLAY-org.wezfurlong.wezterm` symlink in
  `XDG_RUNTIME_DIR/wezterm`, then the newest `gui-sock-*` — skips socket files
  that no longer exist before invoking the CLI, and reuses the socket that
  answered for `activate-pane`.
- The wezterm goto smoke test runs against a fake socket under a private
  `XDG_RUNTIME_DIR`, keeping the automated suite independent of host GUI
  state; the suite now contains 324 tests.

## [1.2.0] - 2026-09-11

### Added

- Optional terminal BEL notifications for every supported agent integration.
  Enable `TMUX_NOTIFY_BELL=1` or pass `--bell`; disable with `--no-bell`.
  Each ordinary terminal attached to the target tmux session receives one BEL,
  including SSH clients and clients viewing a different pane. Delivery works
  with redirected hook output and detached notifications, after event filtering
  and deduplication, without additional runtime or desktop dependencies.
- Per-agent bell overrides: `CODEX_NOTIFY_BELL`, `CLAUDE_NOTIFY_BELL`,
  `KIMI_NOTIFY_BELL`, `GROK_NOTIFY_BELL`, `OPENCODE_NOTIFY_BELL`,
  `PI_NOTIFY_BELL`, and `OMP_NOTIFY_BELL`. Set `OMP_NOTIFY_BELL=0` when keeping
  omp's built-in sound to avoid duplicate bells.
- Coverage for terminal byte delivery, detached execution, configuration
  precedence, agent overrides, and ordinary versus control-mode clients.
  The automated suite now contains 322 tests.

### Compatibility

- Bells are disabled by default and operate independently of Inbox and desktop
  routing, including `TMUX_NOTIFY_REMOTE_MODE=suppress`. They require a valid
  tmux target and an attached terminal; focus-only notifications do not ring.
- Direct client TTY delivery bypasses the server's `bell-action` and
  `visual-bell` settings without triggering another `alert-bell` hook. The
  terminal emulator controls the audible or visual effect. The `alert-bell`
  wrapper defaults to no additional bell unless explicitly given `--bell`.

[1.2.1]: https://github.com/hmgle/tmux-notify-jump/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/hmgle/tmux-notify-jump/compare/v1.1.0...v1.2.0

## [1.1.0] - 2026-08-24

### Added

- omp (oh-my-pi) integration: `omp-extension/tmux-notify-jump.ts` extension
  bridge and `notify-omp.sh` wrapper, plus `--configure-omp` /
  `--omp-extension-path` installer support with omp profile-aware extension
  directory resolution (`OMP_PROFILE`/`PI_PROFILE`, `PI_CODING_AGENT_DIR`,
  `PI_CONFIG_DIR`). Profile names are validated with omp's exact rules
  (edge-trimmed, charset, length, Windows-reserved aliases) and
  `PI_CODING_AGENT_DIR` must be absolute, matching omp runtime resolution.
  Bridge and wrapper coverage includes installer path tests and a Bun-based
  extension registration test.

### Fixed

- All agent wrappers now fail open when `HOME` is unset and debug logging is
  enabled: diagnostics are skipped instead of aborting with an unbound
  variable error.

[1.1.0]: https://github.com/hmgle/tmux-notify-jump/compare/v1.0.0...v1.1.0

## [1.0.0] - 2026-08-16

This is the first stable release of tmux-notify-jump.

### Highlights

- Send tmux-aware desktop notifications on Linux/X11 and macOS, then jump to
  the originating pane from the notification action.
- Keep focus-only notifications useful outside tmux and degrade gracefully
  when optional desktop or terminal-integration dependencies are unavailable.
- Route SSH and headless notifications through a persistent tmux Inbox with
  attention and completion counts, priority ordering, deduplication, TTL and
  size limits, and a configurable prefix key.
- Clear Inbox entries when their pane is visited, including normal window and
  pane selection, while preserving user-owned tmux hooks and key bindings.
- Support isolated tmux servers through explicit socket selection and pin each
  server to its resolved Inbox storage root.

### Integrations

- Provide hook adapters for Codex, Claude Code, Kimi Code, Grok Build,
  OpenCode, and Pi.
- Install integrations and tmux configuration through explicit, idempotent
  installer flags, with matching cleanup for tool-owned tmux state.

### Reliability

- Validate and lock Inbox state, keep cache data private to the current user,
  and avoid persisting notification bodies.
- Distinguish ordinary terminal clients from control-mode clients before
  switching panes, including compatibility fallbacks for older tmux releases.
- Cover shared behavior, wrappers, installer flows, and live tmux hook
  semantics with 272 automated tests.

[1.0.0]: https://github.com/hmgle/tmux-notify-jump/releases/tag/v1.0.0
