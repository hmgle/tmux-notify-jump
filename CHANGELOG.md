# Changelog

Notable changes to tmux-notify-jump are documented in this file.

## [Unreleased]

### Added

- Searchable tmux Inbox via `--inbox-pick`: optional fzf popup, bounded pane
  preview, kind/source/session/recency filters and paginated menu fallback.
  The installed `prefix+N` quick-jump binding is retained.
- Read-only `--doctor` diagnostics for dependencies, tmux capabilities,
  configuration/socket paths, Inbox permissions, hooks, status and key binding.
- Pane target resolution through process ancestry when a wrapper lacks
  `TMUX_PANE`, using one pane inventory and one optional process inventory.
- `TMUX_NOTIFY_TARGET_ANCESTRY=0` disables ancestry targeting for shared
  services; inherited `TMUX_PANE` still takes priority and must be accurate.
- Doctor checks all eight wrapper executables, agent configuration text
  references and required fzf options. Repeat `--agent-config <agent=path>`
  for custom profile/project files; references do not prove hook registration.

### Changed

- Ambient/current-client pane fallback now requires an explicit
  `*_NOTIFY_FALLBACK_TARGET` setting; `TMUX` alone identifies a server.
- All Agent wrappers share priority normalization through the library.
- Inbox next skips the invoking client's current pane without consuming its
  notices. The picker marks that pane, limits menu labels and falls back to
  menus when fzf lacks required options.

### Fixed

- Inbox selection follows moved panes using live session/window IDs and refuses
  to redirect a detached sender's jump to another terminal. Outside tmux,
  ambiguous picker ownership requires an explicit sender TTY.
- Claude, Kimi and Grok focus-only default-message rewrites preserve source
  and priority metadata.
- Inbox selection verifies the receiving client's location before clearing
  both priorities for a pane, including without focus hooks. Failed navigation
  retains notices; completely missing targets clear both stale entries.
- Configuration loading, picker callbacks and doctor use one path resolver.
- Relative configuration paths stay absolute across popup/menu working
  directories. Explicitly empty configuration disables loading, so callbacks
  cannot adopt another HOME's defaults when the caller had no config path.
- Target metadata preserves session names containing pipe characters.
- Inbox selection retains notices when target inventory queries fail or are
  incomplete, and follows a closed pane's window across session moves/links.

## [1.3.0] - 2026-09-23

### Added

- Step Code integration: `step-extension/tmux-notify-jump.ts` extension bridge
  and `notify-step.sh` wrapper, plus `--configure-step` /
  `--step-extension-path` installer support. Step Code is built on the Pi
  coding agent and keeps its extension API, so the bridge forwards the same
  `agent_settled` / `agent_end` / `turn_end` events and the wrapper keeps Pi's
  policy, renamed into the `STEP_NOTIFY_*` namespace. The installer resolves the
  extension directory with step's own rules (`STEP_CODING_AGENT_DIR` with
  tilde expansion, then `~/.stepcode/agent/extensions`, with
  `STEPCODE_CONFIG_DIR` replacing `.stepcode`); step has no profiles, unlike
  Pi and omp.
- Step Code approval-prompt notifications: the bridge also forwards
  `ui_prompt_start` together with the prompt title, and `notify-step.sh` maps it
  to a "Waiting For You" notification with `--notify-kind attention`. Step's
  built-in `Approve <tool>` prompt is an extension dialog, so the extension
  runner broadcasts the event to every extension. The event stays opt-in via
  `STEP_NOTIFY_EVENTS` (`agent_settled,ui_prompt_start`) and only fires when a
  UI is available — print and JSON modes fail closed instead of prompting.

### Fixed

- `--uninstall --configure-step` now removes an extension installed with
  `--copy`. Removal previously required the installed file to resolve to the
  repository source, which a copy never does, so a copied extension survived
  uninstallation and kept loading. Ownership is now decided without assuming
  an install mode.
- Step Code extension-directory resolution no longer depends on GNU
  `readlink -f` or python3 for the direct symlink the installer creates: the
  raw link target is compared first, so a repository symlink is recognized on
  hosts that provide neither tool.
- A repeated `--configure-step` install recognizes the repository's direct
  symlink without optional path-resolution tools, avoiding unnecessary backup
  and recreation of an identical extension.
- `STEP_CODING_AGENT_DIR` and `STEPCODE_CONFIG_DIR` are trimmed before use,
  matching step. A whitespace-only value previously produced a path such as
  `/extensions` or `~//  /agent/extensions`; step ignores such values and falls
  back to its defaults.

### Tests

- New `tests/notify_step_smoke.bats`, `tests/step_bridge.bats`, and
  `tests/install_step.bats`, including `ui_prompt_start` coverage for the
  bridge payload and the wrapper's attention routing. The smoke tests isolate
  `HOME` and Step policy settings from the host, and the suite now contains
  368 tests.

## [1.2.2] - 2026-09-16

### Fixed

- The entry point no longer re-execs itself forever when
  `TMUX_NOTIFY_JUMP_SH` points back at `tmux-notify-jump` itself —
  directly, via a symlink or hardlink, or through a custom wrapper that
  calls the entrypoint again. Such overrides previously looped under the
  same PID at roughly 90 execs per second, burning a full core without
  ever reaching platform dispatch; an orphaned instance was observed
  holding ~85% CPU for over four days. Self-references now fall back to
  normal platform dispatch, custom overrides apply exactly once per
  chain, and arguments are forwarded unchanged. Fixes #1.
- New entry dispatch smoke tests cover path aliases, config-loaded
  overrides, indirect loops, argument forwarding, and failing overrides
  with bounded runtimes; the suite now contains 336 tests.

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
