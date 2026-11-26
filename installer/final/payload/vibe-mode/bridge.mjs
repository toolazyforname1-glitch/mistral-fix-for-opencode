import http from "node:http"
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

const CONFIG_DIR = process.env.XDG_CONFIG_HOME
  ? join(process.env.XDG_CONFIG_HOME, "opencode")
  : join(homedir(), ".config", "opencode")
const PORT = Number(process.env.VIBE_BRIDGE_PORT ?? 8917)
const MODEL = process.env.VIBE_BG_MODEL ?? "deepseek-v4-1-flash-1017"
const STATE_PATH = join(CONFIG_DIR, "vibe-bg-sessions.json")
const HEARTBEAT = join(CONFIG_DIR, "vibe-bridge-heartbeat.json")
const TIMEOUT_MS = 180000

function readSessions() {
  try {
    return JSON.parse(readFileSync(STATE_PATH, "utf8"))
  } catch {
    return {}
  }
}
const sessions = readSessions()
function saveSessions() {
  mkdirSync(dirname(STATE_PATH), { recursive: true })
  writeFileSync(STATE_PATH, JSON.stringify(sessions, null, 2))
}

function textOf(content) {
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return ""
  return content
    .map((p) => (p?.type === "text" ? p.text : p?.type ? `[${p.type}]` : ""))
    .filter(Boolean)
    .join("\n")
}

function toolSpec(tools) {
  return (tools ?? [])
    .map((t) => {
      const f = t.function ?? {}
      const desc = String(f.description ?? "").replace(/\s+/g, " ").slice(0, 280)
      const params = JSON.stringify(f.parameters ?? {}).slice(0, 2200)
      return `- ${f.name}: ${desc}\n  parameters: ${params}`
    })
    .join("\n")
}

function systemPrompt(tools) {
  return [
    "You are the language engine behind OpenCode, another coding agent.",
    "You have no tools of your own and must not use tools directly.",
    "Reply with exactly one JSON object, no markdown fence and no prose:",
    '{"action":"tool","name":"<tool name>","arguments":{...}} to ask the host to run a tool,',
    'or {"action":"final","text":"<your answer>"} when you can answer without a tool.',
    "Rules: one action per reply; arguments must match the tool schema; never invent tools.",
    "The host runs the tool and sends you its result as the next message.",
    "",
    "Available tools:",
    toolSpec(tools),
  ].join("\n")
}

function promptFile(text) {
  const hash = createHash("sha256").update(text).digest("hex").slice(0, 12)
  const path = join(CONFIG_DIR, `vibe-bg-prompt-${hash}.txt`)
  try {
    readFileSync(path)
  } catch {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, text)
  }
  return path
}

function runVibe({ prompt, vibeSession, systemFile, model }) {
  return new Promise((resolve) => {
    const args = ["-p", prompt, "--output", "json", "--trust", "--enabled-tools", "__none__"]
    if (vibeSession) args.push("--resume", vibeSession)
    else args.push("--model", model)
    args.push("--system-prompt-file", systemFile)
    const child = spawn(process.env.VIBE_BIN ?? "vibe", args, {
      cwd: process.cwd(),
      windowsHide: true,
      env: { ...process.env, NO_COLOR: "1" },
    })
    let out = ""
    let err = ""
    child.stdout.on("data", (d) => (out += d))
    child.stderr.on("data", (d) => (err += d))
    const timer = setTimeout(() => child.kill(), TIMEOUT_MS)
    child.on("error", (e) => {
      clearTimeout(timer)
      resolve({ error: String(e) })
    })
    child.on("close", (code) => {
      clearTimeout(timer)
      resolve({ out, err, code })
    })
  })
}

function parseReply(out) {
  const start = out.indexOf("[")
  let entries
  try {
    entries = JSON.parse(start >= 0 ? out.slice(start) : out)
  } catch {
    return { text: out.trim() }
  }
  const assistant = entries.filter((e) => e?.role === "assistant" && Array.isArray(e.content))
  const last = assistant[assistant.length - 1]
  const raw = (last?.content ?? [])
    .filter((c) => c?.type === "text")
    .map((c) => c.text)
    .join("")
    .trim()
  try {
    const parsed = JSON.parse(raw)
    if (parsed && typeof parsed === "object" && parsed.action) {
      return { ...parsed, sessionId: entries[0]?.sessionId }
    }
  } catch {}
  return { text: raw, sessionId: entries[0]?.sessionId }
}

function deltaText(messages, from, pending) {
  const parts = []
  for (const m of messages.slice(from)) {
    if (m.role === "user") parts.push(`User: ${textOf(m.content)}`)
    else if (m.role === "tool") {
      const call = pending[m.tool_call_id]
      const name = call?.name ?? m.name ?? "tool"
      parts.push(`Result of ${name}: ${textOf(m.content)}`)
    }
  }
  return parts.join("\n\n")
}

function sseHead(res) {
  res.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive",
  })
}
function frame(res, obj) {
  res.write(`data: ${JSON.stringify(obj)}\n\n`)
}

function reply(res, body, id, model, content, toolCall) {
  const created = Math.floor(Date.now() / 1000)
  const base = { id, object: "chat.completion.chunk", created, model }
  if (body.stream === false) {
    const message = toolCall
      ? { role: "assistant", content: null, tool_calls: [{ id: toolCall.id, type: "function", function: { name: toolCall.name, arguments: JSON.stringify(toolCall.arguments) } }] }
      : { role: "assistant", content }
    res.writeHead(200, { "content-type": "application/json" })
    res.end(JSON.stringify({ ...base, object: "chat.completion", choices: [{ index: 0, message, finish_reason: toolCall ? "tool_calls" : "stop" }], usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 } }))
    return
  }
  sseHead(res)
  if (toolCall) {
    frame(res, { ...base, choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: toolCall.id, type: "function", function: { name: toolCall.name, arguments: JSON.stringify(toolCall.arguments) } }] }, finish_reason: null }] })
    frame(res, { ...base, choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] })
  } else {
    frame(res, { ...base, choices: [{ index: 0, delta: { role: "assistant", content }, finish_reason: null }] })
    frame(res, { ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })
  }
  frame(res, { ...base, choices: [], usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 } })
  res.write("data: [DONE]\n\n")
  res.end()
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url.includes("/models")) {
    res.writeHead(200, { "content-type": "application/json" })
    res.end(JSON.stringify({ object: "list", data: [{ id: MODEL, object: "model" }] }))
    return
  }
  if (req.method === "GET") {
    res.writeHead(200, { "content-type": "application/json" })
    res.end(JSON.stringify({ ok: true, model: MODEL }))
    return
  }
  let raw = ""
  req.on("data", (d) => (raw += d))
  req.on("end", async () => {
    let body
    try {
      body = JSON.parse(raw)
    } catch {
      res.writeHead(400).end('{"error":"bad json"}')
      return
    }
    const key = String(req.headers["x-session-affinity"] ?? body.user ?? "default")
    const state = sessions[key] ??= { vibe: null, count: 0, pending: {} }
    const messages = Array.isArray(body.messages) ? body.messages : []
    let from = state.count
    if (!state.vibe || messages.length < state.count) {
      from = Math.max(0, messages.length - 1)
      state.vibe = null
      state.pending = {}
    }
    const delta = deltaText(messages, from, state.pending)
    const prompt = delta || "Continue."
    const model = body.model || MODEL
    const result = await runVibe({ prompt, vibeSession: state.vibe, systemFile: promptFile(systemPrompt(body.tools)), model })
    if (result.error || !result.out) {
      reply(res, body, `chatcmpl-${Date.now()}`, model, `Vibe bridge error: ${result.error ?? result.err ?? "no output"}`, null)
      return
    }
    const parsed = parseReply(result.out)
    if (parsed.sessionId) state.vibe = parsed.sessionId
    state.count = messages.length
    const id = `chatcmpl-${Date.now()}`
    if (parsed.action === "tool" && parsed.name) {
      const callId = `call_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`
      state.pending[callId] = { name: parsed.name, arguments: parsed.arguments ?? {} }
      saveSessions()
      reply(res, body, id, model, null, { id: callId, name: parsed.name, arguments: parsed.arguments ?? {} })
      return
    }
    saveSessions()
    reply(res, body, id, model, String(parsed.text ?? parsed.content ?? ""), null)
  })
})

server.listen(PORT, "127.0.0.1", () => {
  console.log(`vibe bridge on ${PORT} model=${MODEL}`)
})
setInterval(() => {
  mkdirSync(dirname(HEARTBEAT), { recursive: true })
  writeFileSync(HEARTBEAT, JSON.stringify({ pid: process.pid, at: Date.now(), port: PORT, model: MODEL }))
}, 5000)
