# Changelog

Notable changes to tmux-notify-jump are documented in this file.

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
