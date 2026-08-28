# GLM-5.3-Flash in your terminal agent

Drive a terminal coding agent with your own self-hosted **GLM-5.3-Flash** endpoint.
Two paths are supported:

- **Codex CLI** — connects **directly** to your endpoint, no proxy. Simpler and, for a
  self-hosted model, usually the more reliable of the two.
- **Claude Code** — needs a small local proxy in between, because it speaks a different API.

Works on **Linux, macOS and Windows**. Nothing here is specific to one server — anything
serving an OpenAI-compatible API will connect.

---

## Which one?

| | Codex CLI | Claude Code |
|---|---|---|
| API your server needs | Responses API (`/v1/responses`) | Anthropic Messages (via proxy) |
| Proxy required | **No** | Yes (LiteLLM) |
| Extra install | `codex` | `codex` not needed; Python + LiteLLM |
| Prompting tuned for | model-neutral | Claude specifically |
| Setup below | **Path A** | **Path B** |

Codex talks the Responses API, which vLLM implements natively — so there is no translation
layer to misbehave. Claude Code speaks the Anthropic Messages API, which no OpenAI server
speaks, so a proxy has to translate every call. Fewer moving parts is why Codex is listed
first.

> **A note on the model.** Both agents are only as good as the model behind them.
> GLM-5.3-Flash handles chat well but can be unreliable at long agentic tool-use — expect
> the occasional stuck loop or malformed tool call regardless of which agent you pick. That
> is the model and its tool-call parser, not the agent. Switching agents may help; it will
> not make a marginal model into a strong one.

---

## Requirements (both paths)

- A **running GLM endpoint** with an OpenAI-compatible API — RunPod, a local vLLM, anything
- The endpoint started with tool calling enabled, or agentic use will not work:

  ```
  --enable-auto-tool-choice --tool-call-parser glm47 --reasoning-parser glm45
  ```

- **Node.js** (for the `codex` CLI) and/or **Python 3.10+** (for the Claude Code proxy)

Copy the config template and fill in **two values** — your endpoint URL and key:

```bash
cp .env.example .env      # Windows: Copy-Item .env.example .env
```

```ini
GLM_BASE_URL=https://YOUR-POD-ID-8000.proxy.runpod.net/v1
GLM_API_KEY=REPLACE_WITH_YOUR_ENDPOINT_KEY
```

Leave everything else as-is. Both paths read from this one `.env`.

**Where the scripts look for `.env`:** every launcher resolves it in this order —

1. an explicit `-e <path>` (or `--env <path>`) flag, if you pass one;
2. otherwise the nearest `.env` searching from your current directory **upward**;
3. otherwise the repo's own `.env` (the one beside these scripts).

Step 3 means you can run a launcher from an unrelated working directory — your actual
project — and it still finds the endpoint config that lives with the repo, no flag needed.
You can also keep a single shared `.env` in a parent directory, or point at any file
explicitly:

```bash
./scripts/codex-glm.sh -e ~/secrets/glm.env
```
```powershell
.\scripts\codex-glm.ps1 -e C:\secrets\glm.env
```

---

## Path A — Codex CLI (recommended, no proxy)

### 1. Install Codex

```bash
npm install -g @openai/codex
```

### 2. Run

**Linux / macOS**
```bash
./scripts/codex-glm.sh
```

**Windows**
```powershell
.\scripts\codex-glm.ps1
```

That's it — no proxy, no second terminal. The launcher reads `.env`, writes a Codex config
into a **scoped `CODEX_HOME`** inside the repo (so your global `~/.codex` is never touched),
and starts Codex pointed at your endpoint.

The generated config uses `wire_api = "responses"` because vLLM implements the OpenAI
Responses API natively. See `codex/config.example.toml` for what it produces.

If your server's `--served-model-name` is not `glm53-uncensored`, set `GLM_MODEL_NAME` in
`.env`.

### What to expect

Two warnings print at startup. Both are harmless:

- **`Model metadata for <model> not found`** — Codex has no built-in card for a self-hosted
  model. The launcher sets `model_context_window` from `.env`, but the warning stays and,
  because of an [upstream bug](https://github.com/openai/codex/issues/19185), Codex caps a
  custom provider's context near **258K** regardless of the value. Fine for most work;
  don't rely on the full window here.
- **`approval_policy ... disallowed by requirements`** — only on machines with a managed
  Codex policy (`ProgramData/OpenAI/Codex/requirements.toml`). Codex falls back to prompting
  for approval, which is the safe default.

### Too many approval prompts?

Codex asks before running commands. By default the launcher already sets the least-naggy
combination most policies allow:

```
approval_policy = on-request      # only prompt for risky / out-of-workspace actions
sandbox_mode    = workspace-write # edit files and run commands in the workspace freely
```

For even fewer prompts, add **`--auto-mode`** (aliases `-y`, `--yes`):

```bash
./scripts/codex-glm.sh --auto-mode
```
```powershell
.\scripts\codex-glm.ps1 --auto-mode
```

That also lets Codex reach the **network** from inside the workspace without asking. Only
actions *outside* the workspace still prompt.

**You may not be able to silence it completely.** Managed installs can enforce an outer
policy (`ProgramData/OpenAI/Codex/requirements.toml` on Windows) that forbids fully-silent
mode - `--dangerously-bypass-approvals-and-sandbox` and `--full-auto` are blocked there. On
such a machine `on-request` + `workspace-write` is the floor, and `--auto-mode` takes you
exactly to it. On an unmanaged machine you can go further by setting `CODEX_APPROVAL` /
`CODEX_SANDBOX` in `.env`.

Override the defaults per-machine in `.env`:

```ini
CODEX_APPROVAL=on-request       # or 'untrusted' (more prompts), or 'never' if allowed
CODEX_SANDBOX=workspace-write    # or 'read-only', or 'danger-full-access' if allowed
```

### Interactive vs headless

Run Codex **interactively** (the launcher does this). On a machine with a managed approval
policy, `codex exec` (headless) cannot run shell commands — it has no way to prompt, so tool
calls are rejected. The interactive launcher prompts you to approve out-of-workspace actions
and works normally; with `--auto-mode`, workspace and network actions do not prompt at all.

---

## Path B — Claude Code (via LiteLLM proxy)

Claude Code cannot talk to your endpoint directly. It speaks the **Anthropic Messages
API**; vLLM speaks **OpenAI**. [LiteLLM](https://github.com/BerriAI/litellm) sits between
them and translates.

```
Claude Code  ──Anthropic /v1/messages──▶  LiteLLM :4000  ──OpenAI /v1──▶  your GLM server
```

The proxy runs locally; nothing leaves your machine except calls to your own endpoint.

### 1. Clone and install

```bash
git clone <this-repo> glm-claude-code
cd glm-claude-code
```

**Linux / macOS**
```bash
./scripts/install.sh
```

**Windows (PowerShell)**
```powershell
.\scripts\install.ps1
```

This creates a `.venv` and installs LiteLLM. It takes a few minutes — it pulls a large
dependency tree. The installer **checks the release version first** and refuses to install
`1.82.7` or `1.82.8`, which were [compromised with credential-stealing malware](https://github.com/BerriAI/litellm/issues).

You already filled in `.env` above. The proxy reads the same file — no extra config. Full
reference of what it contains:

| Variable | What it is | Who sets it |
|---|---|---|
| `GLM_BASE_URL` | Your endpoint, **ending in `/v1`** | **you** |
| `GLM_API_KEY` | The key your server expects (vLLM's `--api-key`) | **you** |
| `GLM_MODEL_NAME` | Your server's `--served-model-name` | default `glm53-uncensored` |
| `LITELLM_MASTER_KEY` | Local proxy credential | **auto-generated on first run** |
| `GLM_MAX_CONTEXT` | Must match your server's `--max-model-len` | default 1048576 |
| `GLM_MAX_OUTPUT` | Max tokens in a single response | default 16384 |
| `LITELLM_PORT` | Local proxy port | default 4000 |

`LITELLM_MASTER_KEY` only authenticates Claude Code to the proxy running on
**your own machine**. It never crosses the network and your endpoint never sees it,
so `start-proxy` generates one on first run and writes it back to `.env`. Leave it alone.

### 2. Run

Two terminals.

**Linux / macOS**
```bash
./scripts/start-proxy.sh     # terminal 1, leave running
./scripts/claude-glm.sh      # terminal 2
```

**Windows**
```powershell
.\scripts\start-proxy.ps1    # terminal 1, leave running
.\scripts\claude-glm.ps1     # terminal 2
```

`claude-glm` health-checks the proxy first, so you get a clear message rather than a
failure inside Claude Code.

---

## The context window trap (Claude Code / Path B only)

**If you use Path B, this is the single most important thing in this repo.** Codex reads
the context window from your endpoint's `/v1/models`, so Path A does not have this problem.

Setting the context window in LiteLLM is **not enough**. Claude Code resolves the context
window from its own internal model list and never asks the proxy. For a model it does not
recognise — which includes yours — it assumes a small window and **auto-compacts
aggressively to stay inside it**.

There is no error. Sessions simply run out of context far sooner than they should, as if
the large window did not exist. Claude Code says as much internally:

> `"glm53" is not a model this version of Claude Code recognizes, so auto-compact will
> keep this session within [N] tokens (the context window it assumes).`

The launcher scripts fix this by exporting:

```bash
CLAUDE_CODE_MAX_CONTEXT_TOKENS=1048576
CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384
```

**Four values must agree**, and nothing reconciles them:

| Layer | Setting |
|---|---|
| Your server | `--max-model-len` — the only one actually enforced |
| LiteLLM | `model_info.max_input_tokens` in `litellm/config.yaml` |
| Claude Code | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` |
| Any other client | its own setting |

Set them **lower** than the server and you silently waste the window. Set them **higher**
and requests fail mid-conversation once context accumulates — which reads as intermittent
and is miserable to diagnose.

Verify the override exists in your build, since these change between versions:

```bash
# Linux / macOS
grep -aoE "CLAUDE_CODE_MAX_[A-Z_]+" ~/.local/share/claude/versions/* | sort -u
```

Related switches in the same builds:

- `CLAUDE_CODE_AUTO_COMPACT_WINDOW` — when compaction triggers
- `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1` — drop assumed-window
  enforcement entirely, if setting a number is not enough

---

## Verifying it works

Test each hop separately so a failure tells you **where** it broke.

**Hop 1 — is your server up?**

```bash
curl -s "$GLM_BASE_URL/models" -H "Authorization: Bearer $GLM_API_KEY"
```

Check `max_model_len` in the response. This is the only enforced limit.

**Hop 2 — is the proxy translating?**

```bash
curl -s "http://127.0.0.1:4000/v1/messages" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"glm53","max_tokens":64,
       "messages":[{"role":"user","content":"Reply with exactly: it works"}]}'
```

An Anthropic-shaped response proves the translation works. If hop 1 passes and hop 2 fails,
the fault is the proxy or config — not your server.

**Check the advertised limits:**

```bash
curl -s "http://127.0.0.1:4000/model/info" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `litellm: command not found` / `is not recognized` | Install has not finished. It takes several minutes; the venv exists long before the entry point does |
| Connection refused on `:4000` | Proxy not running, or it crashed on startup. A missing `.env` value throws immediately |
| Proxy says it started, but `:4000` refuses | **It bound a different port.** If 4000 is taken, LiteLLM silently falls back to a random free one. Check its `Uvicorn running on` line — usually means an old instance is still alive |
| Config changes have no effect | A stale proxy is holding the port with the old config. Kill it: `pkill -f litellm` (Linux/macOS) or `Get-Process -Name litellm \| Stop-Process -Force` (Windows) |
| 401 from the proxy | `ANTHROPIC_AUTH_TOKEN` does not match `LITELLM_MASTER_KEY`. These are the *proxy's* credentials, not your endpoint key |
| 502 / connection error from the proxy | Proxy is up, your server is not. Test hop 1 |
| `model not found` | `ANTHROPIC_MODEL`, the `model_name` in config.yaml, and your server's `--served-model-name` must all agree |
| Chat works, titles/summaries fail | `ANTHROPIC_SMALL_FAST_MODEL` unmapped. `glm53-small` must exist in config.yaml |
| Runs out of context very quickly | See **The context window trap** above |
| Tool calls ignored or malformed | Server-side. Start vLLM with `--enable-auto-tool-choice --tool-call-parser glm47` |
| Your *normal* Claude Code broke | You set `ANTHROPIC_BASE_URL` globally. The scripts here set it per-process for exactly this reason. Clear the global value and open a new terminal |
| `UnicodeEncodeError: 'charmap'` on Windows | LiteLLM's Unicode banner vs cp1252. The scripts set `PYTHONUTF8=1`; if launching manually, set it yourself |
| `UnicodeDecodeError: byte 0x97` | A non-ASCII character in `config.yaml` — usually an em-dash or smart quote pasted into a comment. **Keep it pure ASCII** |
| PowerShell: `The string is missing the terminator` | A non-ASCII character in a `.ps1`. PowerShell reads scripts without a BOM as cp1252. **The reported line is not where the bad byte is** — scan for bytes > 127 |

---

## Security notes

- **`.env` is gitignored.** Never commit it.
- **Your endpoint key ends up in several places**: `.env`, your server's start command, its
  logs, and the proxy's memory. vLLM prints `--api-key` in plaintext at startup — treat the
  key as visible to anyone who can read those logs.
- **The proxy binds `127.0.0.1`**, so it is not reachable from your network.
- **Check the LiteLLM version on every fresh install**, not just the first. The installer
  does this for you.

---

## Notes and honest limitations

**Claude Code is tuned for Claude.** Its prompts, tool-use patterns and long-horizon
behaviour assume a specific model. This *works* — but expect agentic reliability to be
rougher than a client that makes no such assumptions ([OpenCode](https://opencode.ai),
Crush, goose, Aider all speak OpenAI natively and need no proxy at all).

**The proxy is another moving part.** It can stall or die independently of both ends.

**One config to update per redeploy.** If your endpoint URL changes, only `.env` changes.
That is the real argument for a proxy once you have more than one client — otherwise each
client needs updating separately.

---

## Layout

```
.env.example              copy to .env; fill in two values
codex/
  config.example.toml     reference for what codex-glm generates
litellm/config.yaml       proxy config (Claude Code path); reads from .env
scripts/
  codex-glm.sh   / .ps1   Path A: launch Codex CLI          (no proxy)
  install.sh     / .ps1   Path B: one-time LiteLLM setup
  start-proxy.sh / .ps1   Path B: run the proxy
  claude-glm.sh  / .ps1   Path B: launch Claude Code
```

Path A (Codex) uses only `codex-glm`. Path B (Claude Code) uses the other three.

## Licence

MIT
