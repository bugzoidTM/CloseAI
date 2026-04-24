param(
    [string]$Token = $env:KAGGLE_API_TOKEN,
    [string]$DatasetSlug = "codigo-llm-api-python-dataset",
    [string]$KernelSlug = "codigo-llm-api-fine-tune",
    [string]$Accelerator = "NvidiaTeslaT4",
    [int]$PollInterval = 30,
    [int]$TimeoutMinutes = 180,
    [switch]$SkipDownload
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Test-Path ".\.venv-kaggle\Scripts\python.exe")) {
    py -3.12 -m venv .venv-kaggle
}

$Python = ".\.venv-kaggle\Scripts\python.exe"
& $Python -m pip install --upgrade pip
& $Python -m pip install kaggle

if ($Token) {
    $env:KAGGLE_API_TOKEN = $Token
}

$args = @(
    ".\kaggle_pipeline.py",
    "--dataset-slug", $DatasetSlug,
    "--kernel-slug", $KernelSlug,
    "--accelerator", $Accelerator,
    "--poll-interval", "$PollInterval",
    "--timeout-minutes", "$TimeoutMinutes"
)

if ($Token) {
    $args += @("--token", $Token)
}

if ($SkipDownload) {
    $args += "--skip-download"
}

& $Python @args
