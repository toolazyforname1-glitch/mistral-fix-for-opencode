# Vibe → OpenCode port (build #1 + build #2)

## Summary

Stock OpenCode using the Mistral API key returns **402 API budget exhausted**.
The same key through Vibe returns **200**. The difference is one field:
`metadata.call_source` in the JSON body. The gateway grants the Vibe quota when
that key is present; the value is irrelevant (`vibe_code`, `opencode`, anything).
OpenCode never sent it.

`plugins/vibe-mode` now provides both transports, switchable from the right
sidebar, Mistral only.

## Evidence

All captures are under `vibe-bridge/.capture/exchanges/` (gitignored) and were
taken through a local plain-HTTP proxy in front of `https://api.mistral.ai`.

| Capture | What | Result |
|---|---|---|
| `r2-003` | Vibe 3.1.5, deepseek-v4-1-flash-1017, 10 tools | 200, cached 3200/9791 |
| `r2-005` | OpenCode 2.4.1, same model, 14 tools | **402** |
| `r2-028` | OpenCode + build #1 plugin | 200, cached 8704/8786 |

Same Bearer token length (45) in all three. User-Agent does not matter.

### Isolation matrix

| Body | Status |
|---|---|
| Vibe body | 200 |
| Vibe body minus metadata | 402 |
| OpenCode body | 402 |
| OpenCode body + Vibe metadata | 200 |
| OpenCode body + only `{"call_source":"vibe_code"}` | 200 |
| only `client_name` / only `agent_entrypoint` | 402 |
| `{"call_source":"opencode"}` (wrong value) | 200 |
| `{}` metadata | 402 |

## Request differences (before the fix)

| Field | Vibe | OpenCode |
|---|---|---|
| `metadata` | 14 keys, `call_source=vibe_code` | absent |
| `x-affinity` | session UUID | absent (`x-session-affinity: ses_…`) |
| `temperature` | 1.0 | omitted |
| `parallel_tool_calls` | true | omitted |
| `reasoning_effort` | per model (`max`/`low`/`none`) | omitted unless thinking is on |
| `max_completion_tokens` | absent | 131072 |
| `stream_options` | absent | `{include_usage:true}` |
| tools | 10 (Vibe tool architecture) | 14 (OpenCode tools) |
| system prompt | 24,205 chars, imports Codex skills | 17,610 chars, OpenCode prompt |
| User-Agent | `mistral-client-python/Mistral-Vibe/3.1.5` | `opencode/latest/2.4.1/cli` |

Only `metadata` changed the 402. The rest is cosmetic for quota purposes.

## Build #1 — API change

`plugins/vibe-mode/index.js` registers `http.request` for `mistral` and
`mistral-openai`. It replaces the outgoing `Request` with the same body plus:

- `metadata.call_source = "vibe_code"` (plus client/session fields)
- `x-affinity` = stable UUID derived from the OpenCode session ID

No model, tool or prompt changes. Verified with a real completion (200, cached
tokens) on the same key that 402s in stock OpenCode. Default: **ON**.

## Build #2 — Vibe background

`plugins/vibe-mode/bridge.mjs` is a local OpenAI-compatible server on
`127.0.0.1:8917`. When background mode is on, the same `http.request` hook
redirects the Mistral request to it instead of the internet.

- The bridge keeps one Vibe session per OpenCode session
  (`vibe-bg-sessions.json`) and sends Vibe only the **delta** since the last
  request: new user text and tool results. OpenCode's full 400k context stays
  local; it never crosses the wire.
- Vibe runs headless with `--enabled-tools __none__`, a generated
  `--system-prompt-file` that lists OpenCode's tools, and `--resume <id>` after
  the first turn. `--model` is only passed on new sessions (Vibe rejects it on
  resume).
- Vibe replies with one JSON action:
  `{"action":"tool","name":"read","arguments":{...}}` or
  `{"action":"final","text":"..."}`. The bridge converts tool actions into
  OpenAI `tool_calls`, OpenCode executes them, and the result is fed back to the
  same Vibe session as the next delta.

Verified live: Vibe chose `read hello.txt`, OpenCode executed it, Vibe received
the result and replied `VIBE_BRIDGE_OK`.

## UI

`plugins/vibe-mode/tui.tsx` appends to `sidebar.content`:

```
Mistral transport
[x] API change
[ ] vibe background
api: active · bg: off
```

The status line polls once per 2 s: `bg: booting up`, `bg: background server
alive` (heartbeat < 15 s), or `bg: off`. Both rows are clickable.

## Limitations

- Build #2 is one Vibe turn per OpenCode step: ~4–5 s of Python startup each
  time, and Vibe sees a replaced system prompt, so its own skills/agents do not
  apply. It is a transport, not Vibe's full agent loop.
- The bridge runs Vibe in the plugin directory; pass `VIBE_BRIDGE_CWD` to change
  it if project context matters.
- Vibe's tool-less JSON protocol can be ignored by weaker models; the bridge
  falls back to returning the raw text as a final answer.
- Using Vibe's billing path for arbitrary OpenCode traffic is a routing
  assumption, not a documented Mistral contract. If Mistral changes it, requests
  return 402 again.

## Rollback

Set `"apiChange": false` and `"background": false` in
`~/.config/opencode/vibe-mode.json`, or remove
`{"package":"./plugins/vibe-mode"}` from `opencode.json`.

## Installer

`Documents\Directories\vibe-installer\final` holds `VibeModeSetup.exe` (20 KB,
payload embedded), `Install.bat`, `install.ps1`, the plugin payload and the C#
launcher source. It detects or installs OpenCode V2/uv/Vibe, asks for the API
key once, writes the provider and plugin config, and writes the key to both
OpenCode and the Vibe keyring. Rebuild with `..\build.ps1`.
