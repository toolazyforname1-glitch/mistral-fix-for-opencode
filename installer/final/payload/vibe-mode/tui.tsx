/** @jsxImportSource solid-js */
import { Plugin } from "@opencode/plugin/tui"
import { createSignal, onCleanup } from "solid-js"
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

const CONFIG_DIR = process.env.XDG_CONFIG_HOME
  ? join(process.env.XDG_CONFIG_HOME, "opencode")
  : join(homedir(), ".config", "opencode")
const STATE_PATH = join(CONFIG_DIR, "vibe-mode.json")
const HEARTBEAT_PATH = join(CONFIG_DIR, "vibe-bridge-heartbeat.json")

function read() {
  let state = { apiChange: true, background: false }
  try {
    const raw = JSON.parse(readFileSync(STATE_PATH, "utf8"))
    state = { apiChange: raw.apiChange !== false, background: raw.background === true }
  } catch {}
  let bridge = "off"
  if (state.background) {
    bridge = "booting up"
    try {
      const beat = JSON.parse(readFileSync(HEARTBEAT_PATH, "utf8"))
      if (Date.now() - Number(beat.at) < 15000) bridge = "background server alive"
    } catch {}
  }
  return { ...state, bridge }
}

function save(next) {
  mkdirSync(dirname(STATE_PATH), { recursive: true })
  writeFileSync(STATE_PATH, JSON.stringify(next, null, 2))
}

export default Plugin.define({
  id: "vibe-mode.tui",
  setup(context) {
    const [state, setState] = createSignal(read())
    const timer = setInterval(() => setState(read()), 2000)
    onCleanup(() => clearInterval(timer))

    const toggleApi = () => {
      const current = read()
      const next = { apiChange: !current.apiChange, background: current.background }
      save(next)
      setState(read())
      context.ui.toast.show({
        message: next.apiChange ? "Vibe API change ON - Mistral requests carry Vibe metadata" : "Vibe API change OFF - requests unchanged",
        variant: "success",
      })
    }

    const toggleBackground = () => {
      const current = read()
      const next = { apiChange: current.apiChange, background: !current.background }
      save(next)
      setState(read())
      context.ui.toast.show({
        message: next.background ? "Vibe background ON - starting bridge" : "Vibe background OFF",
        variant: "success",
      })
    }

    return context.ui.slot({
      append: "sidebar.content",
      render: () => (
        <box flexDirection="column" paddingTop={1}>
          <text fg={context.theme.text.base}>Mistral transport</text>
          <box onMouseDown={toggleApi}>
            <text fg={context.theme.text.base}>{state().apiChange ? "[x] API change" : "[ ] API change"}</text>
          </box>
          <box onMouseDown={toggleBackground}>
            <text fg={context.theme.text.base}>{state().background ? "[x] vibe background" : "[ ] vibe background"}</text>
          </box>
          <text fg={context.theme.text.muted}>
            {state().apiChange ? "api: active" : "api: off"} · bg: {state().bridge}
          </text>
        </box>
      ),
    })
  },
})
