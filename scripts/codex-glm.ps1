# Launches OpenAI Codex CLI against your GLM endpoint - NO proxy needed.
# vLLM serves the Responses API natively, which is what Codex speaks.
#
# Usage: codex-glm.ps1 [-e C:\path\to\.env] [--auto-mode] [codex args...]
#   -e / --env    path to the .env (else: nearest .env from cwd upward, else
#                 the repo's own .env)
#   --auto-mode   least prompting a managed policy allows: edit/run in the
#     (-y,--yes)  workspace AND reach the network without asking; only
#                 out-of-workspace actions still prompt.
#   --yolo        no approval prompts, no sandbox (approval=never,
#                 danger-full-access). Requires the machine policy to permit
#                 it, or Codex refuses. Unsafe with untrusted code.
param(
  [Alias("e", "env")][string]$EnvFile,
  [Parameter(Position=0, ValueFromRemainingArguments=$true)]$Rest
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$isWindowsHost = $env:OS -eq "Windows_NT"
if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
  throw "codex not installed. See README.md for setup instructions."
}

# Pull the auto-mode / yolo switches out of the forwarded args.
$auto = $false
$yolo = $false
$fwd = @()
foreach ($a in $Rest) {
  if ($a -eq "--auto-mode" -or $a -eq "-y" -or $a -eq "--yes") { $auto = $true }
  elseif ($a -eq "--yolo") { $yolo = $true }
  else { $fwd += $a }
}

function Resolve-EnvFile([string]$explicit, [string]$repoRoot) {
  # Returns the .env path to use. If none exists yet, returns the repo's own
  # .env path as the place to CREATE one - the script prompts and writes it.
  if ($explicit) {
    if (-not (Test-Path $explicit)) { throw "--env file not found: $explicit" }
    return (Resolve-Path $explicit).Path
  }
  $d = (Get-Location).Path
  while ($d) {
    $c = Join-Path $d ".env"
    if (Test-Path $c) { return $c }
    $parent = Split-Path $d -Parent
    if (-not $parent -or $parent -eq $d) { break }
    $d = $parent
  }
  return (Join-Path $repoRoot ".env")
}

# Upsert one KEY=value line in an env file (create the file if needed).
function Save-EnvValue([string]$file, [string]$key, [string]$value) {
  $line = "$key=$value"
  $pat  = "^\s*$([regex]::Escape($key))\s*="
  if (Test-Path $file) {
    $lines = @(Get-Content -LiteralPath $file)
    if (@($lines | Where-Object { $_ -match $pat }).Count -gt 0) {
      $lines = $lines | ForEach-Object { if ($_ -match $pat) { $line } else { $_ } }
    } else {
      $lines += $line
    }
  } else {
    $lines = @($line)
  }
  Set-Content -LiteralPath $file -Value $lines -Encoding ascii
}

# Prompt until the user gives a non-empty value.
function Read-Required([string]$prompt) {
  while ($true) {
    $v = (Read-Host $prompt)
    if ($null -ne $v) { $v = $v.Trim() }
    if ($v) { return $v }
    Write-Host "  a value is required." -ForegroundColor Yellow
  }
}

$envFilePath = Resolve-EnvFile $EnvFile $root
if (Test-Path $envFilePath) {
  Write-Host "using env: $envFilePath" -ForegroundColor DarkGray
  Get-Content $envFilePath | ForEach-Object {
    if ($_ -match '^\s*(GLM_[A-Z0-9_]+|CODEX_APPROVAL|CODEX_SANDBOX)\s*=\s*(.*)$') {
      $key = $Matches[1]
      $value = $Matches[2].Trim()
      if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      [Environment]::SetEnvironmentVariable($key, $value, "Process")
    }
  }
} else {
  Write-Host "no .env found - will create $envFilePath" -ForegroundColor DarkGray
}

# Prompt for a value. Enter keeps the current value (shown as $shown) unless it
# is unset or a placeholder.
function Read-Value([string]$prompt, [string]$current, [string]$shown) {
  if (Test-Placeholder $current) { return (Read-Required $prompt) }
  $v = (Read-Host "$prompt [Enter keeps $shown]")
  if ($null -ne $v) { $v = $v.Trim() }
  if ($v) { return $v } else { return $current }
}

# True for an unset value or one still holding the .env.example placeholder.
function Test-Placeholder([string]$v) {
  return ((-not $v) -or ($v -cmatch 'YOUR-POD-ID|<POD_ID>|^REPLACE_WITH_'))
}

# Cut anything after /v1 (e.g. a pasted .../v1/models), else append /v1.
function ConvertTo-BaseUrl([string]$u) {
  $u = $u.TrimEnd('/')
  if ($u -match '^(.*?/v1)/') { return $Matches[1] }
  if ($u -notmatch '/v1$') { return "$u/v1" }
  return $u
}

function Hide-Key([string]$k) {
  if ($k.Length -gt 12) { return $k.Substring(0, 6) + "..." + $k.Substring($k.Length - 4) }
  return "***"
}

# GET <base>/models with the key. Returns @{ Code = <0 if unreachable>; Body }.
function Invoke-EndpointCheck {
  # Windows PowerShell 5.1 may not offer TLS 1.2 by default; the proxy needs it.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  try {
    $r = Invoke-WebRequest -Uri "$($env:GLM_BASE_URL)/models" -UseBasicParsing -TimeoutSec 20 `
      -Headers @{ Authorization = "Bearer $($env:GLM_API_KEY)" }
    return @{ Code = [int]$r.StatusCode; Body = [string]$r.Content }
  } catch {
    $resp = $_.Exception.Response
    if ($resp) { return @{ Code = [int]$resp.StatusCode; Body = "" } }
    return @{ Code = 0; Body = "" }
  }
}

# GLM_BASE_URL and GLM_API_KEY are both required, and the pod must accept them.
# Pods are redeployed with a new URL (and often a new key), so a stale .env is
# the usual way a launch breaks. Check before writing the config; on failure ask
# for both, save them, and check again. (Testing tool - the key is entered in
# plain text on purpose.)
$model    = if ($env:GLM_MODEL_NAME) { $env:GLM_MODEL_NAME } else { "glm53-uncensored" }
$ctx      = if ($env:GLM_MAX_CONTEXT) { $env:GLM_MAX_CONTEXT } else { "1048576" }
$failure = $null
if (-not (Test-Placeholder $env:GLM_BASE_URL)) {
  $normalized = ConvertTo-BaseUrl $env:GLM_BASE_URL
  if ($normalized -ne $env:GLM_BASE_URL) {
    $env:GLM_BASE_URL = $normalized
    Save-EnvValue $envFilePath "GLM_BASE_URL" $normalized
    Write-Host "endpoint base URL normalized to $normalized" -ForegroundColor DarkGray
  }
}
if ((Test-Placeholder $env:GLM_BASE_URL) -or (Test-Placeholder $env:GLM_API_KEY)) {
  $failure = "GLM_BASE_URL and GLM_API_KEY must both be set"
}
$check = $null
while ($true) {
  if (-not $failure) {
    $check = Invoke-EndpointCheck
    $code = $check.Code
    if ($code -eq 200) { break }
    elseif ($code -eq 0) { $failure = "could not reach $($env:GLM_BASE_URL)" }
    elseif ($code -eq 401 -or $code -eq 403) { $failure = "the API key was rejected (HTTP $code)" }
    elseif ($code -eq 404) { $failure = "nothing at $($env:GLM_BASE_URL) (HTTP 404) - pod gone or wrong URL" }
    elseif ($code -ge 500 -and $code -le 599) { $failure = "the server is not ready (HTTP $code) - press Enter twice to retry once it is up" }
    else { $failure = "unexpected HTTP $code from $($env:GLM_BASE_URL)/models" }
  }
  Write-Host "endpoint check failed: $failure" -ForegroundColor Yellow
  Write-Host "Enter the endpoint URL and API key for the pod." -ForegroundColor Yellow
  $in = Read-Value "  endpoint base URL (e.g. https://<POD_ID>-8000.proxy.runpod.net/v1)" $env:GLM_BASE_URL $env:GLM_BASE_URL
  $u = ConvertTo-BaseUrl $in
  if ($u -ne $in) { Write-Host "  normalized to $u" -ForegroundColor DarkGray }
  $k = Read-Value "  endpoint API key (the vLLM --api-key)" $env:GLM_API_KEY (Hide-Key $env:GLM_API_KEY)
  $env:GLM_BASE_URL = $u
  $env:GLM_API_KEY = $k
  Save-EnvValue $envFilePath "GLM_BASE_URL" $u
  Save-EnvValue $envFilePath "GLM_API_KEY" $k
  Write-Host "  saved GLM_BASE_URL and GLM_API_KEY to $envFilePath" -ForegroundColor DarkGray
  $failure = $null
}

# The pod decides the model name and context length, and both have changed
# between deploys. A wrong name 404s on the first request. Use what it serves.
try {
  $body = ConvertFrom-Json $check.Body
  if ($null -eq $body.data -or $body.data -isnot [array] -or $body.data.Count -eq 0) { throw "invalid data array" }
  $served = @($body.data)
  foreach ($entry in $served) {
    if ($entry.id -isnot [string] -or -not $entry.id -or $entry.id -match '[\x00-\x1f\x7f]') { throw "invalid model id" }
    if ($null -ne $entry.max_model_len -and ($entry.max_model_len -is [string] -or "$($entry.max_model_len)" -notmatch '^[1-9][0-9]*$' -or [double]$entry.max_model_len -gt 9007199254740991)) { throw "invalid context window" }
  }
} catch {
  throw "invalid /v1/models response. Expected model IDs and optional positive max_model_len values."
}
$hit = $served | Where-Object { $_.id -ceq $model } | Select-Object -First 1
if (-not $hit) {
  if ($served.Count -eq 1) {
    $hit = $served[0]
    Write-Host "model $model is not served here - using $($hit.id)" -ForegroundColor Yellow
    Save-EnvValue $envFilePath "GLM_MODEL_NAME" $hit.id
  } else {
    throw "model $model is not served. Set GLM_MODEL_NAME in $envFilePath to one of: $(($served | ForEach-Object { $_.id }) -join ' ')"
  }
}
$model = $hit.id
if ($null -ne $hit.max_model_len -and "$($hit.max_model_len)" -ne "$ctx") {
  $ctx = "$($hit.max_model_len)"
  Write-Host "context window set to $ctx (the pod's max_model_len)" -ForegroundColor Yellow
  Save-EnvValue $envFilePath "GLM_MAX_CONTEXT" $ctx
}
if ($ctx -notmatch '^[1-9][0-9]*$') { throw "GLM_MAX_CONTEXT must be a positive integer." }
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
# Merge-ExistingTrust below preserves what Codex has already trusted.
# ---------------------------------------------------------------------------

# Approval + sandbox. Default is no prompts. Override in .env (CODEX_APPROVAL /
# CODEX_SANDBOX) or soften per-run with --auto-mode.
$approval = if ($env:CODEX_APPROVAL) { $env:CODEX_APPROVAL } else { "never" }
$sandbox  = if ($env:CODEX_SANDBOX)  { $env:CODEX_SANDBOX }  else { "danger-full-access" }
if ($auto) { $approval = "on-request"; $sandbox = "workspace-write" }
if ($yolo) { $approval = "never"; $sandbox = "danger-full-access" }

$env:CODEX_HOME = Join-Path $root ".codex-home"
New-Item -ItemType Directory -Force -Path $env:CODEX_HOME | Out-Null
$configPath = Join-Path $env:CODEX_HOME "config.toml"

# Collect [projects.'<path>'] trust_level entries already in config.toml so that
# regenerating the file does not throw away trust Codex persisted itself.
function Get-ExistingTrust([string]$path) {
  $trust = @{}
  if (-not (Test-Path $path)) { return $trust }
  $current = $null
  foreach ($line in Get-Content -LiteralPath $path) {
    if ($line -match "^\s*\[projects\.'(.+)'\]\s*$") { $current = $Matches[1]; continue }
    if ($line -match '^\s*\[')                       { $current = $null; continue }
    if ($current -and $line -match '^\s*trust_level\s*=\s*"([^"]+)"') {
      $trust[$current] = $Matches[1]
    }
  }
  return $trust
}
$trust = Get-ExistingTrust $configPath
foreach ($d in @((Get-Location).Path, $root)) {
  if ($isWindowsHost) { $d = $d.ToLowerInvariant() }
  $trust[$d] = "trusted"
}
function ConvertTo-TomlString([string]$value) {
  return $value.Replace('\', '\\').Replace('"', '\"')
}

$config = @"
# Generated by scripts/codex-glm.ps1 - do not edit by hand.
model = "$(ConvertTo-TomlString $model)"
model_provider = "glm"

# Required pair - see the comment block in this script before changing either.
approval_policy = "$approval"
sandbox_mode = "$sandbox"

# The context advertised by the server, or GLM_MAX_CONTEXT if not advertised.
model_context_window = $ctx

[model_providers.glm]
name = "GLM (self-hosted)"
env_key = "GLM_API_KEY"
base_url = "$(ConvertTo-TomlString $env:GLM_BASE_URL)"
wire_api = "responses"
"@

# Required: an untrusted directory prompts before every command regardless of
# approval_policy. Existing entries are carried over, not overwritten.
foreach ($d in ($trust.Keys | Sort-Object)) {
  $config += @"

[projects.'$d']
trust_level = "$($trust[$d])"
"@
}

if ($auto -and -not $yolo) {
  $config += @"

# --auto-mode: allow network from inside the workspace sandbox without prompting.
[sandbox_workspace_write]
network_access = true
"@
}

# On Windows a real sandbox needs a mode, and Codex normally writes this key
# itself. We regenerate config.toml every launch, so it must be re-emitted or
# workspace-write silently degrades to read-only.
if ($isWindowsHost -and $sandbox -ne "danger-full-access") {
  $config += @"

[windows]
sandbox = "unelevated"
"@
}
[IO.File]::WriteAllText($configPath, $config + "`n", (New-Object System.Text.UTF8Encoding($false)))

# The machine fence (requirements.toml) must permit these values or Codex clamps
# them and prompts anyway. Detect and warn - editing it needs admin.
$req = if ($isWindowsHost) { Join-Path $env:ProgramData "OpenAI\Codex\requirements.toml" } else { "/etc/codex/requirements.toml" }
if (Test-Path $req) {
  $reqText = Get-Content $req
  foreach ($pair in @(@("allowed_approval_policies", $approval), @("allowed_sandbox_modes", $sandbox))) {
    $line = $reqText | Where-Object { $_ -match $pair[0] } | Select-Object -First 1
    if ($line -and $line -notmatch [regex]::Escape("`"$($pair[1])`"")) {
      Write-Host "WARN: $req does not list `"$($pair[1])`" in $($pair[0])." -ForegroundColor Yellow
      Write-Host "      Codex will clamp and keep prompting. Add it as admin (needs elevation)." -ForegroundColor Yellow
    }
  }
}

Write-Host "codex prompting: approval=$approval sandbox=$sandbox" -ForegroundColor DarkGray
Write-Host "trusted dirs: $(($trust.Keys | Sort-Object) -join '; ')" -ForegroundColor DarkGray
if ($auto) { Write-Host "auto-mode: on (prompts are expected outside the workspace)" -ForegroundColor DarkGray }
else { Write-Host "no-prompt mode: no approvals, no sandbox. Do not run untrusted code under this." -ForegroundColor Yellow }
Write-Host "Codex -> GLM at $env:GLM_BASE_URL (model $model)" -ForegroundColor Green

codex -m $model @fwd
exit $LASTEXITCODE
