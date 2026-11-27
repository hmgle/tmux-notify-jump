import type { Plugin as LegacyPlugin } from "@opencode-ai/plugin"
import type { Plugin } from "@opencode/plugin"
import { spawn } from "node:child_process"

// The shell wrapper owns notification filtering, formatting, and tmux routing.
function forward(eventType: string, properties: object, message?: string, sharedServer?: true, parentSessionID?: string) {
  try {
    const cmd = process.env.OPENCODE_NOTIFY_CMD || "notify-opencode.sh"
    const payload = JSON.stringify({
      event_type: eventType, properties, message, shared_server: sharedServer, parent_session_id: parentSessionID,
    })
    const child = spawn(cmd, [], {
      detached: true,
      stdio: ["pipe", "ignore", "ignore"],
    })
    child.on("error", () => {})
    child.stdin.on("error", () => {})
    child.stdin.end(payload)
    child.unref()
  } catch {
    // Notification failures must not interrupt OpenCode.
  }
}

const server: LegacyPlugin = async ({ client }) => ({
  async event({ event: v1Event }) {
    // The V1 SDK's event type predates the runtime permission.asked event.
    const event = v1Event as typeof v1Event | {
      type: "permission.asked"
      properties: { message?: string }
    }
    switch (event.type) {
      case "session.idle": {
        const sessionID = event.properties.sessionID
        const session = await client.session.get({ path: { id: sessionID } }).catch(() => undefined)
        if (session?.data?.parentID) return
        const messages = await client.session.messages({ path: { id: sessionID } }).catch(() => undefined)
        const last = messages?.data?.findLast(({ info }) => info.role === "assistant")
        const message = last?.parts.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n")
        forward(event.type, event.properties, message?.slice(0, 200))
        break
      }
      case "permission.asked":
        forward(event.type, event.properties, event.properties.message)
        break
      case "session.error":
      case "permission.replied":
        forward(event.type, event.properties)
        break
      case "session.created":
      case "session.deleted":
        forward(event.type, { ...event.properties, sessionID: event.properties.info.id })
        break
    }
  },
  async "tool.execute.after"({ tool, sessionID }) {
    forward("tool.execute.after", { name: tool, sessionID })
  },
})

const plugin = {
  id: "tmux-notify-jump",
  server,
  async setup(ctx) {
    // OpenCode 2 launches a private server as `serve --stdio`. Other servers
    // can report sessions from clients in panes unrelated to the server.
    const args = process.argv.slice(2)
    const sharedServer = args.includes("serve") && args.includes("--stdio") ? undefined : true
    const report = (eventType: string, properties: object, message?: string, parentSessionID?: string) =>
      forward(eventType, properties, message, sharedServer, parentSessionID)

    await ctx.tool.hook("execute.after", ({ tool, sessionID }) => {
      report("tool.execute.after", { name: tool, sessionID })
    })

    const controller = new AbortController()
    const { signal } = controller
    const events = ctx.event.subscribe({
      signal,
      types: [
        "session.execution.succeeded",
        "session.execution.failed",
        "session.created",
        "session.deleted",
        "permission.asked",
        "permission.replied",
      ],
    })

    void (async () => {
      for await (const event of events) {
        if (signal.aborted) break
        switch (event.type) {
          case "session.execution.succeeded":
          case "session.execution.failed": {
            const { sessionID } = event.data
            let message: string | undefined
            if (event.type === "session.execution.failed") {
              const errorMessage = event.data.error?.message
              if (typeof errorMessage === "string") message = errorMessage
              report("session.error", { sessionID, error: message })
            }
            // V1 also reported idle after a failed turn. Keep that notification
            // for users whose event filter only enables session.idle.
            const session = await ctx.session.get({ sessionID }).catch(() => undefined)
            if (session?.parentID || signal.aborted) break
            if (event.type === "session.execution.succeeded") {
              const messages = await ctx.session.context({ sessionID }).catch(() => undefined)
              const last = messages?.findLast((item) => item.type === "assistant")
              message = last?.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n")
            }
            if (!signal.aborted) report("session.idle", { sessionID }, message?.slice(0, 200))
            break
          }
          case "permission.asked": {
            const session = sharedServer
              ? await ctx.session.get({ sessionID: event.data.sessionID }).catch(() => undefined)
              : undefined
            if (!signal.aborted) report(event.type, event.data, event.data.message, session?.parentID)
            break
          }
          default:
            report(event.type, event.data)
        }
      }
    })().catch(() => {
      // The stream can close during plugin unload or server shutdown.
    })

    return () => controller.abort()
  },
} satisfies Plugin.Plugin & { server: LegacyPlugin }

export default plugin
