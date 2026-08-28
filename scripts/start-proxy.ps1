# Starts the LiteLLM proxy. Leave this running in its own terminal.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path "$root\.env")) {
  Write-Host "ERROR: .env not found. Copy .env.example to .env and fill it in." -ForegroundColor Red
  exit 1
}

# load .env into THIS process only
Get-Content "$root\.env" | ForEach-Object {
  if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
    [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim(), "Process")
  }
}

foreach ($v in @("GLM_BASE_URL","GLM_API_KEY","LITELLM_MASTER_KEY")) {
  if (-not [Environment]::GetEnvironmentVariable($v)) { throw "$v missing from .env" }
}
$port = if ($env:LITELLM_PORT) { $env:LITELLM_PORT } else { "4000" }

$exe = "$root\.venv\Scripts\litellm.exe"
if (-not (Test-Path $exe)) {
  Write-Host "ERROR: litellm not installed. Run: .\scripts\install.ps1" -ForegroundColor Red
  exit 1
}

# LiteLLM prints a Unicode banner; the default cp1252 console encoding kills
# startup with UnicodeEncodeError. Force UTF-8.
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

Write-Host "LiteLLM proxy  -> http://127.0.0.1:$port" -ForegroundColor Green
Write-Host "backend        -> $env:GLM_BASE_URL" -ForegroundColor DarkGray
Write-Host "Ctrl+C to stop.`n"

& $exe --config "$root\litellm\config.yaml" --host 127.0.0.1 --port $port
