param(
    [string]$ModelDir = ".\modelo_python_fundido",
    [string]$OutFile = ".\modelo_python.gguf",
    [string]$LlamaCppDir = ".\llama.cpp"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Assert-Command($Name, $InstallHint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name nao encontrado. $InstallHint"
    }
}

function Resolve-Tool {
    param(
        [string]$Name,
        [string[]]$Candidates
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($candidate in $Candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Normalize-TokenizerConfig {
    param(
        [string]$TokenizerConfigPath
    )

    if (-not (Test-Path $TokenizerConfigPath)) {
        return
    }

    $json = Get-Content $TokenizerConfigPath -Raw | ConvertFrom-Json
    if ($json.extra_special_tokens -is [System.Array]) {
        $json.PSObject.Properties.Remove("extra_special_tokens")
        $json | ConvertTo-Json -Depth 20 | Set-Content $TokenizerConfigPath -Encoding UTF8
        Write-Host "tokenizer_config.json normalizado para conversao GGUF." -ForegroundColor Cyan
    }
}

function Download-PrebuiltQuantize {
    param(
        [string]$DestinationDir
    )

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -match '^llama-.*-bin-win-cpu-x64\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        throw "Nao encontrei um binario oficial win-cpu-x64 do llama.cpp na release mais recente."
    }

    $zipPath = Join-Path $DestinationDir $asset.name
    $extractDir = Join-Path $DestinationDir ([System.IO.Path]::GetFileNameWithoutExtension($asset.name))

    if (-not (Test-Path $zipPath)) {
        Write-Host "Baixando binario oficial do llama.cpp: $($asset.name)" -ForegroundColor Cyan
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    }

    if (-not (Test-Path $extractDir)) {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
    }

    return Get-ChildItem $extractDir -Recurse -Filter "llama-quantize.exe" | Select-Object -First 1 -ExpandProperty FullName
}

function Resolve-Python {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        try {
            py -3.12 -c "import sys; print(sys.version)" 2>$null | Out-Null
            return "py -3.12"
        }
        catch {
        }
    }
    Assert-Command "python" "Instale Python 3.10+ e tente novamente."
    return "python"
}

$Python = Resolve-Python

if (-not (Test-Path $ModelDir)) {
    throw "Pasta do modelo nao encontrada: $ModelDir. Baixe 'modelo_python_fundido' do Colab para este diretorio."
}

$ModelPath = Join-Path $PSScriptRoot $ModelDir
Normalize-TokenizerConfig -TokenizerConfigPath (Join-Path $ModelPath "tokenizer_config.json")

if (-not (Test-Path $LlamaCppDir)) {
    $Git = Resolve-Tool "git" @(
        "C:\Program Files\Git\cmd\git.exe",
        "C:\Program Files\Git\bin\git.exe"
    )
    if (-not $Git) {
        throw "git nao encontrado. Instale Git ou clone https://github.com/ggml-org/llama.cpp manualmente para $LlamaCppDir."
    }
    Write-Host "Clonando llama.cpp..." -ForegroundColor Cyan
    & $Git clone https://github.com/ggml-org/llama.cpp.git $LlamaCppDir
}

Push-Location $LlamaCppDir
try {
    Write-Host "Instalando requisitos do conversor..." -ForegroundColor Cyan
    Invoke-Expression "$Python -m pip install -r requirements.txt"

    $TempF16 = Join-Path $PSScriptRoot "modelo_python-f16.gguf"
    $OutPath = Join-Path $PSScriptRoot $OutFile

    Write-Host "Convertendo Hugging Face para GGUF F16..." -ForegroundColor Cyan
    Invoke-Expression "$Python .\convert_hf_to_gguf.py `"$ModelPath`" --outtype f16 --outfile `"$TempF16`""

    $QuantizeCandidates = @(
        ".\build\bin\Release\llama-quantize.exe",
        ".\build\bin\llama-quantize.exe",
        ".\llama-quantize.exe",
        ".\quantize.exe"
    )
    $Quantize = $QuantizeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $Quantize) {
        $PrebuiltDir = Join-Path $PSScriptRoot "build\llama-prebuilt"
        New-Item -ItemType Directory -Force -Path $PrebuiltDir | Out-Null
        try {
            $Quantize = Download-PrebuiltQuantize -DestinationDir $PrebuiltDir
        }
        catch {
            $Quantize = $null
        }
    }

    if (-not $Quantize) {
        $CMake = Resolve-Tool "cmake" @(
            "C:\Program Files\CMake\bin\cmake.exe"
        )
        if (-not $CMake) {
            throw "cmake nao encontrado. Instale CMake ou compile o llama.cpp manualmente."
        }
        Write-Host "Compilando llama.cpp para gerar llama-quantize..." -ForegroundColor Cyan
        & $CMake -S . -B build
        & $CMake --build build --config Release -j
        $Quantize = $QuantizeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    if (-not $Quantize) {
        throw "Nao foi possivel localizar llama-quantize.exe apos a compilacao."
    }

    Write-Host "Quantizando para Q4_K_M..." -ForegroundColor Cyan
    & $Quantize $TempF16 $OutPath Q4_K_M

    Remove-Item $TempF16 -ErrorAction SilentlyContinue
    Write-Host "Conversao concluida: $OutPath" -ForegroundColor Green
}
finally {
    Pop-Location
}
