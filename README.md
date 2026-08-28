# Claude Code on GLM-5.3-Flash

Run **Claude Code** against your own self-hosted **GLM-5.3-Flash** endpoint instead of
Anthropic's models.

Works on **Linux, macOS and Windows**. Nothing here is specific to a particular host —
if your model is served behind an OpenAI-compatible API, this will connect to it.

---

## Why this exists

Claude Code speaks the **Anthropic Messages API**. vLLM (and most self-hosted servers)
speak the **OpenAI Chat Completions API**. They are not interchangeable — different
request shapes, different response shapes, different tool-calling conventions.

[LiteLLM](https://github.com/BerriAI/litellm) sits between them and translates.

```
Claude Code  ──Anthropic /v1/messages──▶  LiteLLM :4000  ──OpenAI /v1──▶  your GLM server
```

You run the proxy locally. Nothing leaves your machine except the calls to your own endpoint.

---

## Requirements

- **Python 3.10+**
- **Claude Code** installed and working
- A **running GLM endpoint** with an OpenAI-compatible API — RunPod, a local vLLM, anything
- Two terminals (the proxy runs in the foreground)

Your server should be started with tool calling enabled, or agentic use will not work:

```
--enable-auto-tool-choice --tool-call-parser glm47 --reasoning-parser glm45
```

---

## Setup

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

### 2. Configure

```bash
cp .env.example .env      # Windows: Copy-Item .env.example .env
```

Edit `.env`:

```ini
GLM_BASE_URL=https://YOUR-POD-ID-8000.proxy.runpod.net/v1
GLM_API_KEY=REPLACE_WITH_YOUR_ENDPOINT_KEY
LITELLM_MASTER_KEY=sk-local-REPLACE_ME
GLM_MAX_CONTEXT=1048576
GLM_MAX_OUTPUT=16384
```

| Variable | What it is |
|---|---|
| `GLM_BASE_URL` | Your endpoint, **ending in `/v1`** |
| `GLM_API_KEY` | The key your server expects (vLLM's `--api-key`) |
| `LITELLM_MASTER_KEY` | A key **you invent** for the local proxy. Not your endpoint key |
| `GLM_MAX_CONTEXT` | Must match your server's `--max-model-len` |
| `GLM_MAX_OUTPUT` | Max tokens in a single response |

Generate a master key:

```bash
python -c "import secrets; print('sk-local-' + secrets.token_urlsafe(24))"
```

If your server uses a different `--served-model-name` than `glm53-uncensored`, change the
two `model:` lines in `litellm/config.yaml`.

### 3. Run

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

## The context window trap

**This is the single most important thing in this repo.**

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
.env.example          copy to .env and fill in
litellm/config.yaml   proxy config; reads everything from .env
scripts/
  install.sh          one-time setup      (Linux/macOS)
  install.ps1         one-time setup      (Windows)
  start-proxy.sh      run the proxy       (Linux/macOS)
  start-proxy.ps1     run the proxy       (Windows)
  claude-glm.sh       launch Claude Code  (Linux/macOS)
  claude-glm.ps1      launch Claude Code  (Windows)
```

## Licence

MIT
