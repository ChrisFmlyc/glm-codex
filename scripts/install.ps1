# One-time setup: creates a virtualenv and installs LiteLLM.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { throw "Python not found. Install Python 3.10 or newer." }

Write-Host "Checking the LiteLLM release before installing..."
$latest = (Invoke-RestMethod -Uri "https://pypi.org/pypi/litellm/json").info.version
if ($latest -in @("1.82.7","1.82.8")) {
  Write-Host "REFUSING: litellm $latest is a known-compromised release." -ForegroundColor Red
  exit 1
}
Write-Host "  latest is $latest - proceeding."

python -m venv .venv
& "$root\.venv\Scripts\python.exe" -m pip install --upgrade pip
& "$root\.venv\Scripts\python.exe" -m pip install "litellm[proxy]"

Write-Host ""
Write-Host "Installed. Next:" -ForegroundColor Green
Write-Host "  1. Copy .env.example to .env and fill in your endpoint URL + key"
Write-Host "  2. .\scripts\start-proxy.ps1"
Write-Host "  3. .\scripts\claude-glm.ps1"
