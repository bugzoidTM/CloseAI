#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TOKEN="${KAGGLE_API_TOKEN:-}"
DATASET_SLUG="codigo-llm-api-python-dataset"
KERNEL_SLUG="codigo-llm-api-fine-tune"
ACCELERATOR="NvidiaTeslaT4"
POLL_INTERVAL="30"
TIMEOUT_MINUTES="180"
SKIP_DOWNLOAD="0"

usage() {
    cat <<'EOF'
Uso: ./run_kaggle_finetune.sh [opcoes]

Opcoes:
  --token TOKEN
  --dataset-slug SLUG
  --kernel-slug SLUG
  --accelerator NOME
  --poll-interval SEGUNDOS
  --timeout-minutes MINUTOS
  --skip-download
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)
            TOKEN="${2:?Valor ausente para --token}"
            shift 2
            ;;
        --dataset-slug)
            DATASET_SLUG="${2:?Valor ausente para --dataset-slug}"
            shift 2
            ;;
        --kernel-slug)
            KERNEL_SLUG="${2:?Valor ausente para --kernel-slug}"
            shift 2
            ;;
        --accelerator)
            ACCELERATOR="${2:?Valor ausente para --accelerator}"
            shift 2
            ;;
        --poll-interval)
            POLL_INTERVAL="${2:?Valor ausente para --poll-interval}"
            shift 2
            ;;
        --timeout-minutes)
            TIMEOUT_MINUTES="${2:?Valor ausente para --timeout-minutes}"
            shift 2
            ;;
        --skip-download)
            SKIP_DOWNLOAD="1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Argumento desconhecido: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

resolve_python() {
    if command -v python3.12 >/dev/null 2>&1; then
        command -v python3.12
        return
    fi
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return
    fi
    if command -v python >/dev/null 2>&1; then
        command -v python
        return
    fi
    echo "Python 3 nao encontrado." >&2
    exit 1
}

PYTHON_LAUNCHER="$(resolve_python)"

if [[ ! -x "$SCRIPT_DIR/.venv-kaggle/bin/python" ]]; then
    "$PYTHON_LAUNCHER" -m venv "$SCRIPT_DIR/.venv-kaggle"
fi

PYTHON="$SCRIPT_DIR/.venv-kaggle/bin/python"
"$PYTHON" -m pip install --upgrade pip
"$PYTHON" -m pip install kaggle

if [[ -n "$TOKEN" ]]; then
    export KAGGLE_API_TOKEN="$TOKEN"
fi

ARGS=(
    "$SCRIPT_DIR/kaggle_pipeline.py"
    --dataset-slug "$DATASET_SLUG"
    --kernel-slug "$KERNEL_SLUG"
    --accelerator "$ACCELERATOR"
    --poll-interval "$POLL_INTERVAL"
    --timeout-minutes "$TIMEOUT_MINUTES"
)

if [[ -n "$TOKEN" ]]; then
    ARGS+=(--token "$TOKEN")
fi

if [[ "$SKIP_DOWNLOAD" == "1" ]]; then
    ARGS+=(--skip-download)
fi

exec "$PYTHON" "${ARGS[@]}"
