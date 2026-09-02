# AGENTS.md — glm-codex

Launcher that points the **Codex CLI** at a self-hosted **GLM-5.3-Flash** endpoint over the
OpenAI Responses API. No proxy, no translation layer.

Read this before changing `scripts/codex-glm.ps1` or `scripts/codex-glm.sh`.

---

## Non-negotiable: the two settings that stop Codex prompting

**Codex will ask permission before every single command unless BOTH of these are set.
Neither works on its own. Do not remove either one, and do not "simplify" the config by
dropping one of them.**

They both live in one generated file: `.codex-home/config.toml` (the launcher points
`CODEX_HOME` there — it is *not* `~/.codex`, and *not* the directory you launch from).

### 1. Approval and sandbox — as a pair

```toml
approval_policy = "never"
sandbox_mode    = "danger-full-access"
```

`approval_policy` alone is not enough. Codex derives a **permission profile** from the
sandbox:

| `sandbox_mode` | resulting profile | interactive TUI |
|---|---|---|
| `danger-full-access` | `disabled` | honours `never` — no prompts |
| `workspace-write` | `managed` | promotes `never` to `on-request` |
| `read-only` | `managed` | promotes `never` to `on-request` |

Under a managed profile Codex must be able to escalate out of the sandbox, and escalation
only exists under `on-request` — so it quietly upgrades the policy and asks anyway.
Setting `never` next to `workspace-write` looks correct and silently does nothing.

### 2. Directory trust

```toml
[projects.'c:\path\to\your\project']
trust_level = "trusted"
```

This is the *"do you want to allow Codex to work in this folder?"* gate. It is checked
**before and independently of** the approval settings. An untrusted directory prompts
before every command no matter what `approval_policy` says.

**The key must be the native path.** Codex matches project keys literally, so under Git
Bash a `/c/users/...` key never matches and silently does nothing. `codex-glm.sh` runs
`cygpath -w` for this reason.

### Why this used to break at random

Codex writes the trust entry itself once you approve a folder — but this launcher
**regenerates `config.toml` from scratch on every run**. Any entry it does not re-emit is
destroyed. So you would approve a folder, Codex would persist it, the next launch would
wipe it, and the prompts came back looking unrelated to anything you changed.

Both launchers now **merge** existing `[projects.…]` entries instead of overwriting them.
If you touch the config generation, preserve that behaviour.

This is also why plain `codex` never prompts on a machine where the launcher does: a
normal `~/.codex/config.toml` usually has a trust entry covering the whole home tree. The
scoped `CODEX_HOME` starts empty and inherits nothing.

---

## Things that look like the cause and are not

All of these were tested by enabling every lever at once and removing them one at a time.
Only the two above changed the outcome. **Do not re-add these** — they are noise, and one
of them prints a warning on every launch.

| Ruled out | Why |
|---|---|
| `default_permissions = ":danger-full-access"` | No effect once the pair above is set |
| `[features] guardian_approval = false` | No effect; Guardian was not the prompter |
| `~/.codex/managed_config.toml` | Ignored by current Codex |
| `$CODEX_HOME/managed_config.toml` | Ignored, and prints *"no longer supported on Windows"* |
| `CODEX_PERMISSION_PROFILE` env var | No effect |
| `--dangerously-bypass-approvals-and-sandbox` | Not needed. Also **cannot** be combined with `-a`/`-s` — Codex rejects it |
| `-a never -s danger-full-access` on the CLI | Not needed |
| `-c default_permissions=…` / `-c features.…` | Not needed |
| ChatGPT Enterprise / cloud policy | Not signed in; the cloud bundle only enforces `chronicle = false` |
| `%ProgramData%\OpenAI\Codex\requirements.toml` | Already permits `never` and `danger-full-access` here. It *can* clamp on a locked-down machine — the launchers warn if it would |
| The custom model / `glm53-uncensored` | Unrelated. The `Model metadata … not found` warning is cosmetic |

---

## Diagnosing it properly

Do not guess from the banner — it reads the config, not the resolved state. The TUI can
show **"YOLO mode"** while actually running `on-request`.

**Read what the session actually resolved** from the rollout log:

```bash
python -c "
import json,sys
for line in open(sys.argv[1],encoding='utf-8'):
    d=json.loads(line)
    if d.get('type')=='turn_context':
        p=d['payload']
        print('approval:', p.get('approval_policy'))
        print('sandbox :', p.get('sandbox_policy',{}).get('type'))
        print('profile :', (p.get('permission_profile') or {}).get('type'))
        break
" .codex-home/sessions/<year>/<month>/<day>/rollout-*.jsonl
```

Healthy: `never` / `danger-full-access` / `disabled`.

Or run `/debug-config` inside the TUI — it prints the config layer stack and the effective
requirements. It is a slash command, not a CLI subcommand.

**`codex exec` is not a valid test.** Exec has no way to prompt, so it reports `never`
under any sandbox and passes even when the TUI is broken. Always verify interactively.

---

## Other things that bite

- **The served name is `glm53-uncensored`.** Requesting `glm53` returns
  `The model 'glm53' does not exist` (404). The launcher passes `-m` explicitly.
- **A running Codex session holds its old config.** Relaunch after changing `.env` or the
  endpoint, or it keeps hitting the previous pod.
- **Context is capped near 258K** for a custom provider regardless of
  `model_context_window` (upstream `openai/codex#19185`).
- **`model_max_output_tokens` is not a valid key** in current Codex — it fails under
  `--strict-config`. Do not re-add it.
- **`.ps1` must be pure ASCII.** PowerShell reads a BOM-less script as cp1252; one
  em-dash gives `The string is missing the terminator` pointing at a line that is fine —
  the reported line is where the parser gave up, not where the bad byte is.
- **Only `.env` changes between deploys.** `GLM_BASE_URL` embeds the pod ID.

---

## Layout

```
.env.example              copy to .env, or let the launcher prompt and write it
codex/config.example.toml reference for what the launcher generates
scripts/codex-glm.ps1     Windows launcher
scripts/codex-glm.sh      Linux/macOS/Git-Bash launcher
.codex-home/              generated scoped CODEX_HOME (gitignored)
```

Both launchers must stay behaviourally identical. If you change one, change the other.
