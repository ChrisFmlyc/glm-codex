#!/usr/bin/env bash
# Launches OpenAI Codex CLI against your GLM endpoint - NO proxy needed.
# vLLM serves the Responses API natively, which is what Codex speaks.
#
# Usage: codex-glm.sh [-e /path/to/.env] [--auto-mode] [codex args...]
#   -e/--env      path to the .env to use (else: nearest .env from cwd upward,
#                 else the repo's own .env)
#   --auto-mode   least prompting a managed policy allows: edit/run in the
#     (-y,--yes)  workspace AND reach the network without asking; only
#                 out-of-workspace actions still prompt.
#   --yolo        no approval prompts, no sandbox (approval=never,
#                 danger-full-access). Requires the machine policy to permit
#                 it, or Codex refuses. Unsafe with untrusted code.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_FILE=""
AUTO=0
YOLO=0
FWD=()
while [ $# -gt 0 ]; do
  case "$1" in
    -e|--env)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "ERROR: $1 requires an env file path." >&2; exit 1; }
      ENV_FILE="$2"; shift 2 ;;
    --auto-mode|-y|--yes) AUTO=1; shift ;;
    --yolo) YOLO=1; shift ;;
    *) FWD+=("$1"); shift ;;
  esac
done
if [ "${#FWD[@]}" -gt 0 ]; then set -- "${FWD[@]}"; else set --; fi

# Check local prerequisites before any prompts or network calls.
for dep in codex curl node; do
  command -v "$dep" >/dev/null 2>&1 || {
    echo "ERROR: $dep not installed. See README.md for setup instructions." >&2; exit 1; }
done

if [ -n "$ENV_FILE" ]; then
  [ -f "$ENV_FILE" ] || { echo "ERROR: --env file not found: $ENV_FILE"; exit 1; }
else
  d="$PWD"
  while :; do
    if [ -f "$d/.env" ]; then ENV_FILE="$d/.env"; break; fi
    parent="$(dirname "$d")"; [ "$parent" = "$d" ] && break; d="$parent"
  done
  # No .env anywhere -> create one at the repo root and prompt for values below.
  [ -n "$ENV_FILE" ] || ENV_FILE="$ROOT/.env"
fi
if [ -f "$ENV_FILE" ]; then
  echo "using env: $ENV_FILE" >&2
  # Parse settings as data, including Windows CRLF and matching outer quotes.
  # Ignore unrelated project settings and never execute shell code from .env.
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*(GLM_[A-Z0-9_]+|CODEX_APPROVAL|CODEX_SANDBOX)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="$(printf '%s' "${BASH_REMATCH[2]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
      export "$key=$value"
    fi
  done < "$ENV_FILE"
else
  echo "no .env found - will create $ENV_FILE" >&2
fi

# Upsert one KEY=value line in an env file (create the file if needed).
save_env() {
  f="$1"; k="$2"; v="$3"
  [ -f "$f" ] || : > "$f"
  if grep -qE "^[[:space:]]*$k[[:space:]]*=" "$f"; then
    tmp="$(mktemp "${f}.XXXXXX")"
    awk -v k="$k" '$0 !~ "^[[:space:]]*" k "[[:space:]]*="' "$f" > "$tmp"
    mv "$tmp" "$f"
  fi
  printf '%s=%s\n' "$k" "$v" >> "$f"
}

# Prompt (from the terminal) until a non-empty value is given.
read_required() {
  _v=""
  while [ -z "$_v" ]; do
    printf '%s' "$1" >&2
    IFS= read -r _v < /dev/tty || { echo >&2; echo "ERROR: no terminal to prompt on." >&2; exit 1; }
    _v="$(printf '%s' "$_v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$_v" ] && echo "  a value is required." >&2
  done
  printf '%s' "$_v"
}

# Prompt for a value. Enter keeps the current value ($2, shown as $3) unless it
# is unset or a placeholder.
read_value() {
  if is_placeholder "$2"; then read_required "$1: "; return; fi
  printf '%s [Enter keeps %s]: ' "$1" "$3" >&2
  IFS= read -r _v < /dev/tty || { echo >&2; echo "ERROR: no terminal to prompt on." >&2; exit 1; }
  _v="$(printf '%s' "$_v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "${_v:-$2}"
}

# True for an unset value or one still holding the .env.example placeholder.
is_placeholder() {
  case "$1" in ""|*YOUR-POD-ID*|*"<POD_ID>"*|REPLACE_WITH_*) return 0 ;; *) return 1 ;; esac
}

# Cut anything after /v1 (e.g. a pasted .../v1/models), else append /v1.
normalize_url() {
  _u="${1%/}"
  case "$_u" in
    */v1/*) _u="${_u%%/v1/*}/v1" ;;
    */v1) ;;
    *) _u="$_u/v1" ;;
  esac
  printf '%s' "$_u"
}

mask_key() {
  if [ "${#1}" -gt 12 ]; then printf '%s...%s' "${1:0:6}" "${1: -4}"; else printf '***'; fi
}

# GET <base>/models with the key. Sets CHECK_CODE (000 = unreachable) and
# CHECK_BODY. The header goes in on stdin so the key is not on the command line.
check_endpoint() {
  CHECK_BODY="$(printf 'Authorization: Bearer %s\n' "$GLM_API_KEY" |
    curl -sS -m 20 -H @- -w '\n%{http_code}' "$GLM_BASE_URL/models" 2>/dev/null)" || true
  case "$CHECK_BODY" in
    *$'\n'*) CHECK_CODE="${CHECK_BODY##*$'\n'}"; CHECK_BODY="${CHECK_BODY%$'\n'*}" ;;
    *) CHECK_CODE="000"; CHECK_BODY="" ;;
  esac
}

# GLM_BASE_URL and GLM_API_KEY are both required, and the pod must accept them.
# Pods are redeployed with a new URL (and often a new key), so a stale .env is
# the usual way a launch breaks. Check before writing the config; on failure ask
# for both, save them, and check again. (Testing tool - the key is entered in
# plain text on purpose.)
MODEL="${GLM_MODEL_NAME:-glm53-uncensored}"
CTX="${GLM_MAX_CONTEXT:-1048576}"
FAILURE=""
if ! is_placeholder "${GLM_BASE_URL:-}"; then
  NORMALIZED="$(normalize_url "$GLM_BASE_URL")"
  if [ "$NORMALIZED" != "$GLM_BASE_URL" ]; then
    GLM_BASE_URL="$NORMALIZED"; export GLM_BASE_URL
    save_env "$ENV_FILE" GLM_BASE_URL "$GLM_BASE_URL"
    echo "endpoint base URL normalized to $GLM_BASE_URL" >&2
  fi
fi
if is_placeholder "${GLM_BASE_URL:-}" || is_placeholder "${GLM_API_KEY:-}"; then
  FAILURE="GLM_BASE_URL and GLM_API_KEY must both be set"
fi
CHECK_CODE=""
CHECK_BODY=""
while :; do
  if [ -z "$FAILURE" ]; then
    check_endpoint
    case "$CHECK_CODE" in
      200) break ;;
      000) FAILURE="could not reach $GLM_BASE_URL" ;;
      401|403) FAILURE="the API key was rejected (HTTP $CHECK_CODE)" ;;
      404) FAILURE="nothing at $GLM_BASE_URL (HTTP 404) - pod gone or wrong URL" ;;
      5??) FAILURE="the server is not ready (HTTP $CHECK_CODE) - press Enter twice to retry once it is up" ;;
      *) FAILURE="unexpected HTTP $CHECK_CODE from $GLM_BASE_URL/models" ;;
    esac
  fi
  echo "endpoint check failed: $FAILURE" >&2
  echo "Enter the endpoint URL and API key for the pod." >&2
  IN="$(read_value "  endpoint base URL (e.g. https://<POD_ID>-8000.proxy.runpod.net/v1)" "${GLM_BASE_URL:-}" "${GLM_BASE_URL:-}")"
  URL="$(normalize_url "$IN")"
  [ "$URL" = "$IN" ] || echo "  normalized to $URL" >&2
  KEY="$(read_value "  endpoint API key (the vLLM --api-key)" "${GLM_API_KEY:-}" "$(mask_key "${GLM_API_KEY:-}")")"
  GLM_BASE_URL="$URL"; GLM_API_KEY="$KEY"; export GLM_BASE_URL GLM_API_KEY
  save_env "$ENV_FILE" GLM_BASE_URL "$URL"
  save_env "$ENV_FILE" GLM_API_KEY "$KEY"
  echo "  saved GLM_BASE_URL and GLM_API_KEY to $ENV_FILE" >&2
  FAILURE=""
done

# The pod decides the model name and context length, and both have changed
# between deploys. A wrong name 404s on the first request. Use what it serves.
if [ "$CHECK_CODE" = "200" ]; then
  # Parse JSON independently of field order, whitespace or multiple models.
  SERVED="$(printf '%s' "$CHECK_BODY" | node "$ROOT/scripts/read-models.cjs")" || exit 1
  HIT="$(printf '%s\n' "$SERVED" | GLM_SELECTED_MODEL="$MODEL" awk -F'\t' '$1 == ENVIRON["GLM_SELECTED_MODEL"]' | head -1)"
  if [ -z "$HIT" ]; then
    if [ "$(printf '%s\n' "$SERVED" | wc -l | tr -d ' ')" = "1" ]; then
      HIT="$SERVED"
      echo "model $MODEL is not served here - using ${HIT%%$'\t'*}" >&2
      save_env "$ENV_FILE" GLM_MODEL_NAME "${HIT%%$'\t'*}"
    else
      echo "ERROR: model $MODEL is not served. Set GLM_MODEL_NAME in $ENV_FILE to one of: $(printf '%s\n' "$SERVED" | cut -f1 | paste -sd' ' -)" >&2
      exit 1
    fi
  fi
  MODEL="${HIT%%$'\t'*}"
  SERVER_CTX="${HIT##*$'\t'}"
  if [ "$SERVER_CTX" != "0" ] && [ "$SERVER_CTX" != "$CTX" ]; then
    CTX="$SERVER_CTX"
    echo "context window set to $CTX (the pod's max_model_len)" >&2
    save_env "$ENV_FILE" GLM_MAX_CONTEXT "$CTX"
  fi
fi
[[ "$CTX" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: GLM_MAX_CONTEXT must be a positive integer." >&2; exit 1; }
# ---------------------------------------------------------------------------
# TWO settings make Codex run without prompting. Both are required; neither
# works alone. Established by bisecting every other candidate - see AGENTS.md.
#
#   1. approval_policy = "never" + sandbox_mode = "danger-full-access"
#      How much Codex asks about commands. These only work as a pair: under any
#      sandboxed mode Codex needs to escalate out of the sandbox, escalation
#      exists only under "on-request", so it quietly upgrades "never" and asks.
#
#   2. [projects.<dir>] trust_level = "trusted"
#      Whether Codex may work in the directory at all. Checked BEFORE and
#      INDEPENDENTLY of the approval settings - an untrusted directory prompts
#      before every command no matter what approval_policy says.
#
# Codex writes the trust entry itself once you approve a folder, but this
# launcher regenerates config.toml on every run, so any entry it does not
# re-emit is destroyed. That is why prompting used to come back at random.
# existing_trust below preserves what Codex has already trusted.
# ---------------------------------------------------------------------------

# Approval + sandbox. Default is no prompts. Override in .env (CODEX_APPROVAL /
# CODEX_SANDBOX) or soften per-run with --auto-mode.
APPROVAL="${CODEX_APPROVAL:-never}"
SANDBOX="${CODEX_SANDBOX:-danger-full-access}"
[ "$AUTO" = "1" ] && { APPROVAL="on-request"; SANDBOX="workspace-write"; }
[ "$YOLO" = "1" ] && { APPROVAL="never"; SANDBOX="danger-full-access"; }

export CODEX_HOME="$ROOT/.codex-home"
mkdir -p "$CODEX_HOME"
CONFIG="$CODEX_HOME/config.toml"

# Trust entries already in config.toml, so regenerating does not throw away
# trust Codex persisted itself. Emits "<path>\t<level>" lines.
existing_trust() {
  [ -f "$CONFIG" ] || return 0
  awk "
    /^[[:space:]]*\[projects\.'/ {
      line = \$0
      sub(/^[[:space:]]*\[projects\.'/, \"\", line)
      sub(/'\][[:space:]]*\$/, \"\", line)
      cur = line; next
    }
    /^[[:space:]]*\[/ { cur = \"\"; next }
    cur != \"\" && /^[[:space:]]*trust_level[[:space:]]*=/ {
      lvl = \$0
      sub(/^[^\"]*\"/, \"\", lvl); sub(/\".*\$/, \"\", lvl)
      print cur \"\t\" lvl
    }
  " "$CONFIG"
}

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) IS_WIN=1 ;;
  *) IS_WIN=0 ;;
esac

# Codex matches project keys against native paths. Under Git Bash / MSYS the
# shell reports a /c/users/... style path, which never matches the Windows form
# Codex uses, so the trust entry would silently do nothing. Convert first.
native_path() {
  if [ "$IS_WIN" = "1" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1" | tr 'A-Z' 'a-z'
  else
    printf '%s' "$1"
  fi
}

toml_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'
}

# Current directory and the repo root are always trusted; merge with the rest.
TRUST_FILE="$(mktemp)"
trap 'rm -f "$TRUST_FILE"' EXIT
existing_trust > "$TRUST_FILE"
printf '%s\ttrusted\n' "$(native_path "$PWD")" "$(native_path "$ROOT")" >> "$TRUST_FILE"

{
cat <<TOML
# Generated by scripts/codex-glm.sh - do not edit by hand.
model = "$(toml_string "$MODEL")"
model_provider = "glm"

# Required pair - see the comment block in this script before changing either.
approval_policy = "$APPROVAL"
sandbox_mode = "$SANDBOX"

# The context advertised by the server, or GLM_MAX_CONTEXT if not advertised.
model_context_window = $CTX

[model_providers.glm]
name = "GLM (self-hosted)"
env_key = "GLM_API_KEY"
base_url = "$(toml_string "$GLM_BASE_URL")"
wire_api = "responses"
TOML

# Required: an untrusted directory prompts before every command regardless of
# approval_policy. Existing entries are carried over, not overwritten.
sort -u "$TRUST_FILE" | awk -F'\t' 'NF==2 && $1 != "" && !seen[$1]++ {
  printf "\n[projects.%c%s%c]\ntrust_level = \"%s\"\n", 39, $1, 39, $2
}'

if [ "$AUTO" = "1" ] && [ "$YOLO" != "1" ]; then
cat <<TOML

# --auto-mode: allow network from inside the workspace sandbox without prompting.
[sandbox_workspace_write]
network_access = true
TOML
fi

# On Windows a real sandbox needs a mode, and Codex normally writes this key
# itself. We regenerate config.toml every launch, so it must be re-emitted or
# workspace-write silently degrades to read-only.
if [ "$IS_WIN" = "1" ] && [ "$SANDBOX" != "danger-full-access" ]; then
cat <<TOML

[windows]
sandbox = "unelevated"
TOML
fi
} > "$CONFIG"

# The machine fence (requirements.toml) must permit these values or Codex clamps
# them and prompts anyway. Detect and warn - editing it needs admin.
for REQ in "/c/ProgramData/OpenAI/Codex/requirements.toml" "/etc/codex/requirements.toml"; do
  [ -f "$REQ" ] || continue
  for pair in "allowed_approval_policies:$APPROVAL" "allowed_sandbox_modes:$SANDBOX"; do
    key="${pair%%:*}"; val="${pair#*:}"
    line=$(grep "$key" "$REQ" 2>/dev/null | head -1)
    if [ -n "$line" ] && ! printf '%s' "$line" | grep -q "\"$val\""; then
      echo "WARN: $REQ does not list \"$val\" in $key." >&2
      echo "      Codex will clamp and keep prompting. Add it as admin (needs elevation)." >&2
    fi
  done
  break
done

echo "codex prompting: approval=$APPROVAL sandbox=$SANDBOX" >&2
echo "trusted dirs: $(sort -u "$TRUST_FILE" | cut -f1 | paste -sd'; ' -)" >&2
if [ "$AUTO" = "1" ]; then
  echo "auto-mode: on (prompts are expected outside the workspace)" >&2
else
  echo "no-prompt mode: no approvals, no sandbox. Do not run untrusted code under this." >&2
fi
echo "Codex -> GLM at $GLM_BASE_URL (model $MODEL)"
exec codex -m "$MODEL" "$@"
