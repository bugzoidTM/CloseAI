param(
    [string]$ApiUrl = "http://127.0.0.1:8000",
    [switch]$SkipApi
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$Python = ".\.venv312\Scripts\python.exe"
if (-not (Test-Path $Python)) {
    $Python = ".\.venv\Scripts\python.exe"
}
if (-not (Test-Path $Python)) {
    $Python = "python"
}

Write-Host "1/3 Compilando arquivos Python..." -ForegroundColor Cyan
& $Python -m compileall -q .

Write-Host "2/3 Rodando testes unitarios..." -ForegroundColor Cyan
& $Python -m unittest discover -s tests

if ($SkipApi) {
    Write-Host "3/3 Smoke test da API ignorado por parametro." -ForegroundColor Yellow
    exit 0
}

Write-Host "3/3 Verificando API local..." -ForegroundColor Cyan
try {
    Invoke-RestMethod -Uri "$ApiUrl/health" -Method Get -TimeoutSec 5 | Out-Null
    & $Python .\test_api.py --api-url $ApiUrl
}
catch {
    Write-Warning "API nao esta disponivel ou modelo ausente. Rode deploy.ps1 depois de gerar modelo_python.gguf."
}
