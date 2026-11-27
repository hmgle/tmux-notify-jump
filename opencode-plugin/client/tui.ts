import type { Plugin } from "@opencode/plugin/tui"
import { createEffect, createRoot } from "solid-js"
import { lstatSync, mkdirSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { isAbsolute, join } from "node:path"

export default {
  id: "tmux-notify-jump-client",
  setup(ctx) {
    const pane = process.env.TMUX_PANE
    const tmux = /^(\/.*),([0-9]+),[0-9]+$/.exec(process.env.TMUX ?? "")
    const cache = process.env.XDG_CACHE_HOME || (process.env.HOME && join(process.env.HOME, ".cache"))
    if (!pane || !/^%[0-9]+$/.test(pane) || !tmux || !cache || !isAbsolute(cache)) return

    const [, socket, serverPID] = tmux
    const directory = join(cache, "tmux-notify-jump", "opencode")
    const file = join(directory, `${process.pid}.json`)
    const temporary = join(directory, `.${process.pid}.tmp`)
    try {
      mkdirSync(directory, { recursive: true, mode: 0o700 })
      const stat = lstatSync(directory)
      if (!stat.isDirectory() || stat.uid !== process.getuid?.() || (stat.mode & 0o077) !== 0) return
      for (const name of readdirSync(directory)) {
        const match = /^([0-9]+)\.json$/.exec(name)
        if (!match || Number(match[1]) <= 1) continue
        try {
          process.kill(Number(match[1]), 0)
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code === "ESRCH") rmSync(join(directory, name), { force: true })
        }
      }
    } catch {
      return
    }

    let previous: string | undefined
    return createRoot((dispose) => {
      createEffect(() => {
        const route = ctx.ui.router.current()
        const sessionID = route.type === "session" ? route.sessionID : undefined
        if (sessionID === previous) return
        try {
          if (!sessionID) {
            rmSync(file, { force: true })
          } else {
            writeFileSync(temporary, JSON.stringify({ socket, serverPID, pane, sessionID }), { mode: 0o600, flag: "wx" })
            renameSync(temporary, file)
          }
          previous = sessionID
        } catch {
          // A cache failure must not interrupt the TUI.
          try { rmSync(temporary, { force: true }) } catch {}
        }
      })
      return () => {
        dispose()
        try { rmSync(file, { force: true }) } catch {}
      }
    })
  },
} satisfies Plugin.Definition
