import type { Plugin } from "@opencode-ai/plugin"

/**
 * tmux-notify-jump plugin for OpenCode.
 *
 * Bridges OpenCode events to notify-opencode.sh, which handles all
 * notification logic (event filtering, message formatting, tmux integration).
 *
 * Install:
 *   Copy this file to ~/.config/opencode/plugins/tmux-notify-jump.ts
 *   Ensure notify-opencode.sh is on your PATH
 */

const HANDLED_EVENTS = new Set([
  "session.idle",
  "session.error",
  "session.created",
  "session.deleted",
  "permission.asked",
  "permission.replied",
  "tool.execute.after",
])

export const TmuxNotifyJumpPlugin: Plugin = async ({ client, $ }) => {
  const cmd =
    process.env.OPENCODE_NOTIFY_CMD || "notify-opencode.sh"

  return {
    event: async ({ event }) => {
      try {
        if (!HANDLED_EVENTS.has(event.type)) return

        let message: string | undefined

        // For session.idle, try to fetch the last assistant message
        if (event.type === "session.idle") {
          const sessionID =
            (event.properties as Record<string, unknown>)?.sessionID as
              | string
              | undefined

          // Skip sub-agent sessions
          const parentID =
            (event.properties as Record<string, unknown>)?.parentID as
              | string
              | undefined
          if (parentID) return

          if (sessionID) {
            try {
              const msgs = await client.session.messages(sessionID)
              const last = [...msgs].reverse().find(
                (m: { role: string }) => m.role === "assistant",
              )
              if (last) {
                const content =
                  typeof (last as { content?: unknown }).content === "string"
                    ? ((last as { content: string }).content)
                    : undefined
                if (content) {
                  message = content.slice(0, 200)
                }
              }
            } catch {
              // Non-critical; shell script has its own fallback
            }
          }
        }

        // For permission.asked, extract message from properties
        if (event.type === "permission.asked") {
          message =
            ((event.properties as Record<string, unknown>)?.message as
              | string
              | undefined) ?? undefined
        }

        const payload = JSON.stringify({
          event_type: event.type,
          properties: event.properties ?? {},
          ...(message !== undefined && { message }),
        })

        await $`echo ${payload} | ${cmd}`.quiet()
      } catch {
        // Silently ignore errors — don't crash on missing script or transient issues
      }
    },
  }
}
