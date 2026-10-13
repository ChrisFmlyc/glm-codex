# GLM-5.3-Flash in Codex

Use Codex CLI with a private, self-hosted GLM-5.3-Flash endpoint. The launcher connects
straight to the endpoint's OpenAI-compatible Responses API; it needs no local server.

## Team setup

Your teammate needs **this repository, the endpoint `.env`, and Codex CLI**. They do not
need the RunPod deployment repository, RunPod credentials, SSH keys, downloaded weights,
or a ChatGPT/OpenAI login. The endpoint owner keeps the pod running and gives them access
to this GitHub repository and the endpoint settings separately.

1. Clone the repository:

   ```bash
   git clone https://github.com/ChrisFmlyc/glm-codex.git
   cd glm-codex
   ```

2. Install [Node.js LTS](https://nodejs.org/en/download) and
   [Codex CLI](https://developers.openai.com/codex/cli/), then check the install:

   ```bash
   npm install -g @openai/codex
   codex --version
   ```

   Bash also needs `curl` and Node.js to check and parse the endpoint response. Use Bash
   on Linux/macOS or Git Bash on Windows. The Windows launcher uses PowerShell 5.1 or newer.
   This setup was tested with Codex CLI **0.162.1**.

3. Save the `.env` supplied by the endpoint owner in the cloned `glm-codex` directory.
   If you received the URL and key instead, copy `.env.example` to `.env` and fill in:

   ```ini
   GLM_BASE_URL=https://YOUR-POD-ID-8000.proxy.runpod.net/v1
   GLM_API_KEY=REPLACE_WITH_YOUR_ENDPOINT_KEY
   ```

   These are the only required values. You can paste the full `/v1/models` URL, the `/v1`
   base URL, or the server URL; the launcher normalizes it. It reads the served model name
   and context window from `/v1/models` and saves them in `.env`. For our endpoint, the
   context window is **1,048,576 tokens**. If multiple models are served, set
   `GLM_MODEL_NAME` to the one you want.

4. Launch from the repository:

   **Linux/macOS/Git Bash**

   ```bash
   bash scripts/codex-glm.sh -e .env
   ```

   **Windows PowerShell**

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-glm.ps1 -e .\.env
   ```

   If the saved URL or key is missing or rejected, the launcher asks for replacements and
   saves them. A failed check in a noninteractive session stops with an error. An endpoint
   that is still starting must become ready before Codex can connect.

You can now type your task into Codex. Keep using the launcher so it selects the GLM
provider and the private scoped configuration. A plain `codex` command uses your usual
Codex configuration.

## Work on another project

Run the launcher from the project you want Codex to edit. Specify the shared `.env`
explicitly so the project's own `.env` cannot select a different endpoint.

**Linux/macOS/Git Bash**

```bash
cd /path/to/your-project
bash /path/to/glm-codex/scripts/codex-glm.sh -e /path/to/glm-codex/.env
```

**Windows PowerShell**

```powershell
cd C:\path\to\your-project
powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\glm-codex\scripts\codex-glm.ps1 -e C:\path\to\glm-codex\.env
```

Replace these paths with your own clone and project paths. The launcher trusts the current
project and its own repository, and preserves directories trusted in earlier launches.
It generates `.codex-home/config.toml` inside `glm-codex` without changing global
`~/.codex` settings. No generated configuration or session files need to be shared.

Without `-e`, it uses the nearest `.env` from the current directory upward, then the
launcher repository's `.env`. Both launchers accept unquoted or matching single/double
quoted values and LF or CRLF line endings. Use one `KEY=value` per line; omit inline
comments and shell substitutions. Only `GLM_*`, `CODEX_APPROVAL`, and `CODEX_SANDBOX`
settings are loaded.

## Verify the connection

This command verifies a model response through the launcher:

```bash
bash scripts/codex-glm.sh -e .env --strict-config exec --skip-git-repo-check "Reply with: it works"
```

Windows equivalent:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-glm.ps1 -e .\.env --strict-config exec --skip-git-repo-check "Reply with: it works"
```

To check interactive permissions and context, launch normally and run `/status`. Codex
0.162.1 showed **Full Access** and **1.05M** context with this endpoint. That verifies the
advertised configuration; it is not a benchmark of processing a full million-token input.
Older Codex versions have had custom-provider context limits, so update Codex if `/status`
shows a smaller window. Headless `codex exec` verifies connectivity and tool execution;
it cannot establish whether the interactive UI will prompt.

## Permissions

The default is **no approval prompts and full filesystem access**. Use it for trusted
projects. Both settings are intentionally generated together:

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

The current project also gets a `trust_level = "trusted"` entry. Preserve both the
permission pair and existing trust entries when changing the launchers; see `AGENTS.md`.

To use the workspace sandbox with approvals when needed, pass `--auto-mode`:

```bash
bash scripts/codex-glm.sh -e .env --auto-mode
```

The PowerShell launcher accepts the same switch. A machine's managed Codex policy can
restrict these choices. The launcher warns when `requirements.toml` omits the selected
approval policy or sandbox mode; it does not modify machine policy.

## Endpoint requirements and troubleshooting

The endpoint must implement `/v1/models` and `/v1/responses`. Chat Completions support
alone is insufficient. For this GLM build, the deployment owner enables tool calling with:

```text
--enable-auto-tool-choice --tool-call-parser glm47 --reasoning-parser glm45
```

The intended weights are `orcarouter/GLM-5.3-Flash-Uncensored-FP8`. A served model name is
an alias; the `/v1/models` `root` field identifies the actual weights directory. The
launcher does not deploy or restart pods.

| Symptom | What to do |
|---|---|
| `codex`, `node`, or `curl` not installed | Install the prerequisites above and reopen your terminal. |
| API key rejected (401/403) | Ask the endpoint owner for the current endpoint key; a RunPod management key is a different credential. |
| Unreachable, 404, or server not ready (5xx) | Check with the endpoint owner that the pod is running and ready; update URL/key if it was redeployed. |
| Multiple models and model not served | Set `GLM_MODEL_NAME` to one of the IDs listed by the launcher. |
| Invalid `/v1/models` response | Check the URL points to an inference endpoint, not a website or a Chat Completions-only service. |
| Context smaller than expected | Check the server's `max_model_len`, update Codex, and read `/status`. The launcher adopts the server limit. |
| Prompts still appear | Check `.env` permission overrides and machine policy; relaunch after changing settings. |
| Requests hit an old endpoint | Exit the existing Codex session and relaunch; sessions retain their startup configuration. |
| Tool calls fail or loop | Ask the endpoint owner to check the model's tool parser and server logs. |

`.env` and `.codex-home/` are gitignored. Give teammates only the endpoint settings they
need, and keep the real key out of commits. `GLM_MAX_OUTPUT` remains a legacy setting;
current Codex has no supported `model_max_output_tokens` config key, so the launcher does
not generate it.

## Development checks

The regression suite uses a local mock endpoint and a stub Codex executable; it needs
Python 3.11+ and Node.js, and does not need a real endpoint key:

```bash
python3 -m unittest discover -s tests -v
```

Set `GLM_TEST_PWSH` to a PowerShell executable to test both launchers locally. On Windows,
run the suite with `GLM_TEST_PWSH=powershell` for Windows PowerShell 5.1 and
`GLM_TEST_PWSH=pwsh` for PowerShell 7. Local checks covered Bash and PowerShell 7 on Linux;
Windows PowerShell 5.1 and macOS still need native runs.

## Layout

```text
.env.example              endpoint settings template
codex/config.example.toml generated configuration reference
scripts/codex-glm.sh      Bash launcher
scripts/codex-glm.ps1     PowerShell launcher
scripts/read-models.cjs   JSON model-list parser for Bash
.codex-home/              private generated Codex config and sessions
```

MIT licensed.
