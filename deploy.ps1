param(
    [string]$HostAddress = "127.0.0.1",
    [int]$Port = 8000,
    [int]$LlamaPort = 8080,
    [switch]$SkipInstall,
    [switch]$PreloadModel,
    [switch]$UsePythonBackend
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Write-Step($Message) {
    Write-Host $Message -ForegroundColor Cyan
}

function Resolve-PythonLauncher {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        try {
            py -3.12 -c "import sys; print(sys.version)" 2>$null | Out-Null
            return "py -3.12"
        }
        catch {
        }
    }
    return "python"
}

function Resolve-AppVenv {
    $candidates = @(".\.venv", ".\.venv312")

    foreach ($candidate in $candidates) {
        $pythonPath = Join-Path $candidate "Scripts\python.exe"
        if (Test-Path $pythonPath) {
            $version = & $pythonPath -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
            if ($version -eq "3.12") {
                return $candidate
            }
        }
    }

    return ".\.venv312"
}

function Resolve-LlamaServerExe {
    $candidates = @(
        ".\build\llama-prebuilt\llama-b8902-bin-win-cpu-x64\llama-server.exe",
        ".\llama.cpp\build\bin\Release\llama-server.exe",
        ".\llama.cpp\build\bin\llama-server.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    $found = Get-ChildItem ".\build\llama-prebuilt" -Recurse -Filter "llama-server.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ($found) {
        return $found
    }

    return $null
}

Write-Step "Aplicando otimizacoes de CPU..."
try {
    powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
}
catch {
    Write-Warning "Nao foi possivel alterar o plano de energia. Execute como administrador se quiser aplicar esta otimizacao."
}

try {
    (Get-Process -Id $PID).PriorityClass = "High"
}
catch {
    Write-Warning "Nao foi possivel alterar a prioridade do processo."
}

$env:OMP_NUM_THREADS = "2"
$env:LLAMA_NO_MMAP = "1"
$env:HOST = $HostAddress
$env:PORT = [string]$Port
$env:MODEL_PATH = Join-Path $PSScriptRoot "modelo_python.gguf"
if ($PreloadModel) {
    $env:PRELOAD_MODEL = "1"
}

$VenvDir = Resolve-AppVenv

if (-not (Test-Path (Join-Path $VenvDir "Scripts\python.exe"))) {
    Write-Step "Criando ambiente virtual $VenvDir..."
    $PythonLauncher = Resolve-PythonLauncher
    Invoke-Expression "$PythonLauncher -m venv $VenvDir"
}

$Python = Join-Path $VenvDir "Scripts\python.exe"
$Version = & $Python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
Write-Step "Python do ambiente: $Version"

if (-not $SkipInstall) {
    Write-Step "Instalando dependencias..."
    & $Python -m pip install --upgrade pip
    & $Python -m pip install fastapi uvicorn requests

    if ($UsePythonBackend) {
        & $Python -m pip install https://github.com/abetlen/llama-cpp-python/releases/download/v0.3.19/llama_cpp_python-0.3.19-cp312-cp312-win_amd64.whl
    }
}

if (-not (Test-Path $env:MODEL_PATH)) {
    Write-Warning "modelo_python.gguf nao encontrado. A API vai iniciar, mas /generate retornara 503 ate a conversao ser feita."
}

if (-not $UsePythonBackend) {
    $LlamaServerExe = Resolve-LlamaServerExe
    if (-not $LlamaServerExe) {
        throw "llama-server.exe nao encontrado. Rode convert_to_gguf.ps1 primeiro para baixar o binario oficial do llama.cpp."
    }

    $env:LLAMA_SERVER_URL = "http://127.0.0.1:$LlamaPort"
    $env:LLAMA_SERVER_MODEL = "modelo_python.gguf"

    Write-Step "Iniciando llama-server em http://127.0.0.1:$LlamaPort ..."
    $llamaLogDir = Join-Path $PSScriptRoot "build\runtime-logs"
    New-Item -ItemType Directory -Force -Path $llamaLogDir | Out-Null
    $llamaOut = Join-Path $llamaLogDir "llama-server.out.log"
    $llamaErr = Join-Path $llamaLogDir "llama-server.err.log"

    Start-Process -FilePath $LlamaServerExe -ArgumentList @(
        "-m", $env:MODEL_PATH,
        "--host", "127.0.0.1",
        "--port", "$LlamaPort",
        "-t", "2",
        "-c", "4096",
        "-b", "512",
        "--jinja"
    ) -WorkingDirectory $PSScriptRoot -RedirectStandardOutput $llamaOut -RedirectStandardError $llamaErr -WindowStyle Hidden | Out-Null

    $llamaReady = $false
    for ($i = 0; $i -lt 90; $i++) {
        try {
            Invoke-RestMethod -Uri "$($env:LLAMA_SERVER_URL)/health" -Method Get -TimeoutSec 2 | Out-Null
            $llamaReady = $true
            break
        }
        catch {
            Start-Sleep -Seconds 2
        }
    }

    if (-not $llamaReady) {
        throw "llama-server nao respondeu ao health check em $($env:LLAMA_SERVER_URL)."
    }
}

Write-Host "Iniciando API em http://$HostAddress`:$Port" -ForegroundColor Green
Write-Host "Docs: http://$HostAddress`:$Port/docs" -ForegroundColor Cyan
& $Python -m uvicorn server:app --host $HostAddress --port $Port --log-level info
