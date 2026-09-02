# GLM-5.3-Flash in Codex

Drive the **Codex CLI** with your own self-hosted **GLM-5.3-Flash** endpoint — no proxy,
no translation layer. Codex speaks the OpenAI **Responses API** (`/v1/responses`), which
vLLM implements natively, so it connects straight to your server.

Works on **Linux, macOS and Windows**. Nothing here is specific to one server — anything
serving an OpenAI-compatible API will connect.

> **A note on the model.** Codex is only as good as the model behind it. GLM-5.3-Flash
> handles chat well but can be unreliable at long agentic tool-use — expect the occasional
> stuck loop or malformed tool call. That is the model and its tool-call parser, not the
> launcher.

---

## Requirements

- A **running GLM endpoint** with an OpenAI-compatible API — RunPod, a local vLLM, anything
- The endpoint started with tool calling enabled, or agentic use will not work:

  ```
  --enable-auto-tool-choice --tool-call-parser glm47 --reasoning-parser glm45
  ```

- **Node.js**, for the `codex` CLI

Copy the config template and fill in **two values** — your endpoint URL and key:

```bash
cp .env.example .env      # Windows: Copy-Item .env.example .env
```

```ini
GLM_BASE_URL=https://YOUR-POD-ID-8000.proxy.runpod.net/v1
GLM_API_KEY=REPLACE_WITH_YOUR_ENDPOINT_KEY
```

Leave everything else as-is.

**Where the launcher looks for `.env`:** it resolves in this order —

1. an explicit `-e <path>` (or `--env <path>`) flag, if you pass one;
2. otherwise the nearest `.env` searching from your current directory **upward**;
3. otherwise the repo's own `.env` (the one beside these scripts).

Step 3 means you can run the launcher from an unrelated working directory — your actual
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

## Run

### 1. Install Codex

```bash
npm install -g @openai/codex
```

### 2. Launch

**Linux / macOS**
```bash
./scripts/codex-glm.sh
```

**Windows**
```powershell
.\scripts\codex-glm.ps1
```

No proxy, no second terminal. The launcher reads `.env`, writes a Codex config into a
**scoped `CODEX_HOME`** inside the repo (so your global `~/.codex` is never touched), and
starts Codex pointed at your endpoint.

The generated config uses `wire_api = "responses"` because vLLM implements the OpenAI
Responses API natively. See `codex/config.example.toml` for what it produces.

If your server's `--served-model-name` is not `glm53-uncensored`, set `GLM_MODEL_NAME` in
`.env`.

---

## What to expect

Two warnings can print at startup. Both are harmless:

- **`Model metadata for <model> not found`** — Codex has no built-in card for a self-hosted
  model. The launcher sets `model_context_window` from `.env`, but the warning stays and,
  because of an [upstream bug](https://github.com/openai/codex/issues/19185), Codex caps a
  custom provider's context near **258K** regardless of the value. Fine for most work; don't
  rely on the full window here.
- **`approval_policy ... disallowed by requirements`** — only on machines with a managed
  Codex policy (`ProgramData/OpenAI/Codex/requirements.toml`). Codex falls back to prompting
  for approval, which is the safe default.

---

## Controlling prompts

**By default the launcher runs with no approval prompts** — it just does the work. If you
want confirmations back, you have three levels:

| Launch | approval / sandbox | Prompts |
|---|---|---|
| `codex-glm` (default) | `never` / `danger-full-access` | none |
| `codex-glm --auto-mode` | `on-request` / `workspace-write` | only outside the workspace |
| `CODEX_APPROVAL=untrusted` in `.env` | `untrusted` / `read-only` | before most commands |

> **No prompts means no safety net.** With `never` + `danger-full-access`, a malicious
> instruction in any repo, web page, or tool output Codex reads can run commands on your
> machine with zero confirmation. Only point it at code you trust.

**How it actually works (the mechanism that matters):**

Codex reads *managed defaults* from a fixed path — `~/.codex/managed_config.toml` — and those
**override per-session config and CLI flags**. Setting approval only in the launcher's own
config, or via a `--yolo`-style flag, does **not** work: the managed default clamps it back.
So the launcher writes `approval_policy` / `sandbox_mode` into that managed file on every run.

Two consequences:

1. **It is global.** `managed_config.toml` is not per-project or per-provider — it changes
   prompting for *every* Codex session on the machine, not just this launcher. The launcher
   backs up any existing file to `managed_config.toml.bak` the first time.
2. **A machine fence can still block it.** If `%ProgramData%\OpenAI\Codex\requirements.toml`
   (Windows) or `/etc/codex/requirements.toml` (Unix) exists and its `allowed_approval_policies`
   doesn't include your value, Codex ignores the default and keeps prompting. The launcher
   detects this and prints a warning telling you to add the value there (needs admin). It does
   **not** edit that file for you — it's a machine-level security control.

---

## Interactive vs headless

Run Codex **interactively** (the launcher does this). On a machine with a managed approval
policy, `codex exec` (headless) cannot run shell commands — it has no way to prompt, so tool
calls are rejected. The interactive launcher prompts you to approve out-of-workspace actions
and works normally; with `--auto-mode`, workspace and network actions do not prompt at all.

---

## Verifying it works

**Is your server up?**

```bash
curl -s "$GLM_BASE_URL/models" -H "Authorization: Bearer $GLM_API_KEY"
```

Check `max_model_len` in the response — this is the only enforced limit — and confirm the
`id` matches your `GLM_MODEL_NAME`. Requesting a name the server does not serve returns
`The model '<name>' does not exist`.

**End to end through the launcher:**

```bash
./scripts/codex-glm.sh exec --skip-git-repo-check "Reply with exactly: it works"
```

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `codex: command not found` / not recognized | Codex not installed: `npm install -g @openai/codex` |
| `The model '<name>' does not exist` | `GLM_MODEL_NAME` does not match the server's `--served-model-name`. Check `/v1/models` |
| `404 ... /v1/responses` | `GLM_BASE_URL` points at a dead or wrong endpoint. Update `.env` and relaunch |
| Wrong model shown in the TUI | A stale per-project model remembered by Codex. Relaunch, or `/model` to switch. The launcher passes the model explicitly to avoid this |
| Runs out of context sooner than expected | The 258K custom-provider cap (upstream bug above), not your `.env` value |
| `approval_policy disallowed by requirements` | A machine policy fences it. Add your value to `allowed_approval_policies` in `requirements.toml` as admin |
| Tool calls ignored or malformed | Server-side. Start vLLM with `--enable-auto-tool-choice --tool-call-parser glm47` |
| PowerShell: `The string is missing the terminator` | A non-ASCII character in a `.ps1`. PowerShell reads scripts without a BOM as cp1252. **The reported line is not where the bad byte is** — scan for bytes > 127 |

---

## Security notes

- **`.env` is gitignored.** Never commit it.
- **Your endpoint key ends up in several places**: `.env`, your server's start command, and
  its logs. vLLM prints `--api-key` in plaintext at startup — treat the key as visible to
  anyone who can read those logs.
- **One config to update per redeploy.** If your endpoint URL changes, only `.env` changes.

---

## Layout

```
.env.example              copy to .env; fill in two values
codex/
  config.example.toml     reference for what codex-glm generates
scripts/
  codex-glm.sh   / .ps1   launch Codex CLI against your endpoint
```

## Licence

MIT
