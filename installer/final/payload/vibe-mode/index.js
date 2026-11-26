import { Plugin } from "@opencode/plugin"
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const CONFIG_DIR = process.env.XDG_CONFIG_HOME
  ? join(process.env.XDG_CONFIG_HOME, "opencode")
  : join(homedir(), ".config", "opencode")
export const STATE_PATH = join(CONFIG_DIR, "vibe-mode.json")
const HEARTBEAT_PATH = join(CONFIG_DIR, "vibe-bridge-heartbeat.json")
const SYNC_PATH = join(CONFIG_DIR, "vibe-key-sync.json")
const BRIDGE_PORT = Number(process.env.VIBE_BRIDGE_PORT ?? 8917)
const BRIDGE_DIR = dirname(fileURLToPath(import.meta.url))
const BRIDGE_ENTRY = join(BRIDGE_DIR, "bridge.mjs")
const MISTRAL_HOSTS = ["api.mistral.ai", "api.eu.mistral.ai", "api.us.mistral.ai"]

function vibePython() {
  const candidates = []
  if (process.env.UV_TOOL_DIR) candidates.push(join(process.env.UV_TOOL_DIR, "mistral-vibe", "Scripts", "python.exe"))
  if (process.env.APPDATA) candidates.push(join(process.env.APPDATA, "uv", "tools", "mistral-vibe", "Scripts", "python.exe"))
  candidates.push(join(homedir(), "AppData", "Roaming", "uv", "tools", "mistral-vibe", "Scripts", "python.exe"))
  return candidates.find((path) => existsSync(path)) ?? candidates[candidates.length - 1]
}

export function readState() {
  try {
    const raw = JSON.parse(readFileSync(STATE_PATH, "utf8"))
    return {
      apiChange: raw.apiChange !== false,
      background: raw.background === true,
      syncKey: raw.syncKey !== false,
    }
  } catch {
    return { apiChange: true, background: false, syncKey: true }
  }
}

export function writeState(next) {
  mkdirSync(dirname(STATE_PATH), { recursive: true })
  writeFileSync(STATE_PATH, JSON.stringify(next, null, 2))
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"))
  } catch {
    return null
  }
}

function heartbeat() {
  const beat = readJson(HEARTBEAT_PATH)
  if (!beat || Date.now() - Number(beat.at) > 15000) return null
  return beat
}

function stopBridge() {
  const beat = heartbeat()
  if (!beat?.pid) return
  try {
    process.kill(beat.pid)
  } catch {}
}

async function ensureBridge() {
  if (heartbeat()) return true
  if (!existsSync(BRIDGE_ENTRY)) return false
  const child = spawn("node", [BRIDGE_ENTRY], {
    cwd: BRIDGE_DIR,
    detached: true,
    stdio: "ignore",
    windowsHide: true,
    env: { ...process.env },
  })
  child.unref()
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 250))
    if (heartbeat()) return true
  }
  return false
}

function stableUUID(seed) {
  const h = createHash("sha256").update(String(seed)).digest()
  h[6] = (h[6] & 0x0f) | 0x40
  h[8] = (h[8] & 0x3f) | 0x80
  const hex = h.toString("hex")
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`
}

function isMistral(event) {
  const provider = String(event.model?.providerID ?? event.model?.provider ?? "")
  if (provider === "mistral" || provider.startsWith("mistral-")) return true
  try {
    return MISTRAL_HOSTS.includes(new URL(event.request.url).hostname)
  } catch {
    return false
  }
}

async function resolveMistralKey(ctx) {
  for (const id of ["mistral", "mistral-openai"]) {
    try {
      const connection = await ctx.integration?.connection?.active?.(id)
      if (!connection) continue
      const value = await ctx.integration.connection.resolve(connection)
      if (value?.type === "key" && value.key) return { key: value.key, source: `integration:${id}` }
    } catch {}
  }
  try {
    const key = readFileSync(join(CONFIG_DIR, "secrets", "mistral.key"), "utf8").trim()
    if (key) return { key, source: "file" }
  } catch {}
  return null
}

function setVibeKey(key) {
  return new Promise((resolve) => {
    const python = vibePython()
    if (!existsSync(python)) return resolve(false)
    const script =
      "import keyring,sys;keyring.set_password('ai.mistral.vibe','MISTRAL_API_KEY',sys.stdin.read().strip())"
    const child = spawn(python, ["-c", script], { stdio: ["pipe", "ignore", "ignore"], windowsHide: true })
    child.on("error", () => resolve(false))
    child.on("close", (code) => resolve(code === 0))
    child.stdin.end(key)
  })
}

export default Plugin.define({
  id: "vibe-mode",
  setup(ctx) {
    const sync = async () => {
      if (!readState().syncKey) return
      const found = await resolveMistralKey(ctx)
      if (!found || found.key.length < 20) return
      const hash = createHash("sha256").update(found.key).digest("hex").slice(0, 16)
      const previous = readJson(SYNC_PATH)
      if (previous?.hash === hash) return
      const keyring = await setVibeKey(found.key)
      try {
        mkdirSync(join(CONFIG_DIR, "secrets"), { recursive: true })
        writeFileSync(join(CONFIG_DIR, "secrets", "mistral.key"), found.key)
      } catch {}
      writeFileSync(SYNC_PATH, JSON.stringify({ hash, source: found.source, keyring, at: Date.now() }, null, 2))
    }
    sync().catch(() => undefined)
    const syncTimer = setInterval(() => sync().catch(() => undefined), 10000)

    const tick = () => {
      const state = readState()
      if (state.background) {
        if (!heartbeat()) ensureBridge().catch(() => undefined)
      } else if (heartbeat()) {
        stopBridge()
      }
    }
    tick()
    const timer = setInterval(tick, 3000)

    const hooks = ["mistral", "mistral-openai"].map((providerID) =>
      ctx.session.hook(
        "http.request",
        async (event) => {
          const state = readState()
          if (!isMistral(event)) return
          if (state.background) {
            await ensureBridge()
            const raw = await event.request.clone().text()
            event.request = new Request(`http://127.0.0.1:${BRIDGE_PORT}/v1/chat/completions`, {
              method: "POST",
              headers: new Headers(event.request.headers),
              body: raw,
            })
            return
          }
          if (!state.apiChange) return
          const request = event.request
          const type = request.headers.get("content-type") ?? ""
          if (!type.includes("application/json")) return
          let body
          try {
            body = await request.clone().json()
          } catch {
            return
          }
          if (!body || typeof body !== "object" || Array.isArray(body)) return
          if (!Array.isArray(body.messages)) return

          const existing = body.metadata && typeof body.metadata === "object" && !Array.isArray(body.metadata) ? body.metadata : {}
          body.metadata = {
            ...existing,
            call_source: "vibe_code",
            call_type: event.kind === "primary" ? "main_call" : "utility_call",
            client_name: "vibe_programmatic",
            agent_entrypoint: "programmatic",
            host_kind: "local",
            session_id: stableUUID(event.sessionID),
          }
          const headers = new Headers(request.headers)
          if (!headers.has("x-affinity")) headers.set("x-affinity", stableUUID(`${event.sessionID}:affinity`))
          event.request = new Request(request.url, {
            method: request.method,
            headers,
            body: JSON.stringify(body),
          })
        },
        { providerID },
      ),
    )

    return async () => {
      clearInterval(timer)
      clearInterval(syncTimer)
      stopBridge()
      for (const hook of hooks) {
        try {
          await hook?.dispose?.()
        } catch {}
      }
    }
  },
})
