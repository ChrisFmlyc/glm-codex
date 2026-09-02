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

Only **two values** are required — your endpoint URL and key:

```ini
GLM_BASE_URL=https://YOUR-POD-ID-8000.proxy.runpod.net/v1
GLM_API_KEY=REPLACE_WITH_YOUR_ENDPOINT_KEY
```

You do not have to create `.env` by hand. **If either value is missing, the launcher
prompts for it and writes it to `.env`, then continues** — so the first run just works.
Everything else has a default (`GLM_MODEL_NAME` → `glm53-uncensored`, `GLM_MAX_CONTEXT` →
`1048576`, `GLM_MAX_OUTPUT` → `16384`). To pre-fill instead, copy the template:
`cp .env.example .env` (Windows: `Copy-Item .env.example .env`).

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
  Codex policy (`ProgramData/OpenAI/Codex/requirements.toml`). Codex clamps to a value the
  policy permits and starts prompting again. See *Controlling prompts* below.

---

## Controlling prompts

**By default the launcher runs with no approval prompts at all.** That is deliberate for a
testing tool. Use `--auto-mode` if you want confirmations back.

| Launch | approval / sandbox | Prompts |
|---|---|---|
| `codex-glm` (default) | `never` / `danger-full-access` | **none** |
| `codex-glm --auto-mode` | `on-request` / `workspace-write` | before most commands |

### Two settings are required, and neither works alone

Both are written into `.codex-home/config.toml` beside the launcher. That directory is the
scoped `CODEX_HOME` — **not** `~/.codex`, and **not** the folder you launch from.

**1. Approval and sandbox, as a pair.**

```toml
approval_policy = "never"
sandbox_mode    = "danger-full-access"
```

`approval_policy` on its own is not enough. Codex derives a *permission profile* from the
sandbox: `danger-full-access` gives a `disabled` profile and `never` is honoured, while
`workspace-write` or `read-only` give a `managed` profile, and the interactive TUI then
promotes `never` to `on-request` — because escaping a managed sandbox requires approval to
be possible. `never` alongside `workspace-write` looks right and silently does nothing.

**2. Directory trust.**

```toml
[projects.'c:\path\to\your\project']
trust_level = "trusted"
```

This is the *"allow Codex to work in this folder?"* gate. It is checked **before and
independently of** the approval settings — an untrusted directory prompts before every
command regardless of `approval_policy`. The launcher trusts the directory you run it from
and its own repo root, and **merges** any entries Codex has already written rather than
overwriting them.

That merge matters: Codex persists trust once you approve a folder, but the launcher
rebuilds `config.toml` on every run, so an entry it does not re-emit is destroyed — which
made prompting reappear seemingly at random.

### Checking what a session actually used

The startup banner reflects config, not the resolved state — it can show **YOLO mode**
while the session really runs `on-request`. Read the rollout log instead:

```bash
grep -o '"approval_policy":"[a-z-]*"' .codex-home/sessions/**/rollout-*.jsonl | tail -1
```

Healthy is `never`, with `sandbox_policy` `danger-full-access` and `permission_profile`
`disabled`. Inside the TUI, `/debug-config` shows the config layer stack.

**`codex exec` is not a valid test.** It has no way to prompt, so it reports `never` under
any sandbox and looks fine even when the interactive TUI asks on every command.

### If it still prompts

A machine policy can override everything: if
`%ProgramData%\OpenAI\Codex\requirements.toml` (Windows) or `/etc/codex/requirements.toml`
(Unix) omits your value from `allowed_approval_policies` or `allowed_sandbox_modes`, Codex
clamps to something it permits. The launcher checks both lists and warns; editing that file
needs admin.

> **No prompts means no safety net.** A malicious instruction in any repo, web page, or
> tool output Codex reads can run commands with zero confirmation. Only point it at code
> you trust; use `--auto-mode` for anything you don't.

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
| **Codex asks before every command** | The sandbox is not `danger-full-access`, so Codex builds a managed permission profile and promotes `never` to `on-request`. Relaunch without `--auto-mode`, and check no `CODEX_SANDBOX` / `CODEX_APPROVAL` in `.env` overrides it |
| `--auto-mode` silently runs read-only | On Windows a sandbox needs `[windows] sandbox = "unelevated"`. Codex writes that key itself, but the launcher regenerates `config.toml` each run, so it re-emits it. Check it is present in `.codex-home/config.toml` |
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
