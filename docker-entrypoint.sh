#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/app"
VENV_PYTHON="/opt/venv/bin/python"
LLAMA_SERVER_EXE="/opt/llama.cpp/build/bin/llama-server"

bool_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON|sim|SIM) return 0 ;;
        *) return 1 ;;
    esac
}

read_secret_if_present() {
    local target_var="$1"
    local source_file_var="${target_var}_FILE"
    local source_file="${!source_file_var:-}"
    if [[ -n "$source_file" && -f "$source_file" ]]; then
        export "$target_var=$(tr -d '\r\n' < "$source_file")"
    fi
}

export CLOSEAI_DATA_DIR="${CLOSEAI_DATA_DIR:-/data}"
export MODEL_OUTPUT_DIR="${MODEL_OUTPUT_DIR:-$CLOSEAI_DATA_DIR/modelo_python_fundido}"
export KAGGLE_OUTPUT_ROOT="${KAGGLE_OUTPUT_ROOT:-$CLOSEAI_DATA_DIR/kaggle-output}"
export KAGGLE_BUILD_ROOT="${KAGGLE_BUILD_ROOT:-$CLOSEAI_DATA_DIR/build/kaggle}"
export DATASET_SOURCE_PATH="${DATASET_SOURCE_PATH:-$APP_DIR/dataset_python.json}"
export MODEL_PATH="${MODEL_PATH:-$CLOSEAI_DATA_DIR/modelo_python.gguf}"
export LLAMA_SERVER_MODEL="${LLAMA_SERVER_MODEL:-$(basename "$MODEL_PATH")}"
export LLAMA_SERVER_URL="${LLAMA_SERVER_URL:-http://127.0.0.1:8080}"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-8000}"
export N_CTX="${N_CTX:-4096}"
export N_THREADS="${N_THREADS:-2}"
export N_BATCH="${N_BATCH:-512}"
export AUTO_TRAIN="${AUTO_TRAIN:-0}"
export AUTO_TRAIN_FORCE="${AUTO_TRAIN_FORCE:-0}"
export KAGGLE_DATASET_SLUG="${KAGGLE_DATASET_SLUG:-closeai-python-dataset}"
export KAGGLE_KERNEL_SLUG="${KAGGLE_KERNEL_SLUG:-closeai-fine-tune}"
export KAGGLE_ACCELERATOR="${KAGGLE_ACCELERATOR:-NvidiaTeslaT4}"
export KAGGLE_POLL_INTERVAL="${KAGGLE_POLL_INTERVAL:-30}"
export KAGGLE_TIMEOUT_MINUTES="${KAGGLE_TIMEOUT_MINUTES:-180}"
export RUNTIME_LOG_DIR="${RUNTIME_LOG_DIR:-$CLOSEAI_DATA_DIR/runtime-logs}"

read_secret_if_present KAGGLE_API_TOKEN
mkdir -p "$CLOSEAI_DATA_DIR" "$RUNTIME_LOG_DIR"

if bool_true "$AUTO_TRAIN_FORCE"; then
    echo "AUTO_TRAIN_FORCE ativado; limpando artefatos anteriores." >&2
    rm -rf "$MODEL_OUTPUT_DIR" "$MODEL_PATH" "$KAGGLE_OUTPUT_ROOT" "$KAGGLE_BUILD_ROOT"
fi

if [[ ! -f "$MODEL_PATH" ]]; then
    if [[ ! -d "$MODEL_OUTPUT_DIR" ]]; then
        if bool_true "$AUTO_TRAIN"; then
            if [[ -z "${KAGGLE_API_TOKEN:-}" ]]; then
                echo "KAGGLE_API_TOKEN ausente; nao e possivel treinar automaticamente." >&2
                exit 1
            fi
            echo "Modelo GGUF ausente; iniciando fine-tune remoto via Kaggle API..." >&2
            "$VENV_PYTHON" -u "$APP_DIR/kaggle_pipeline.py" \
                --dataset-slug "$KAGGLE_DATASET_SLUG" \
                --kernel-slug "$KAGGLE_KERNEL_SLUG" \
                --accelerator "$KAGGLE_ACCELERATOR" \
                --poll-interval "$KAGGLE_POLL_INTERVAL" \
                --timeout-minutes "$KAGGLE_TIMEOUT_MINUTES"
        else
            echo "Modelo GGUF nao encontrado em $MODEL_PATH e AUTO_TRAIN esta desativado." >&2
            exit 1
        fi
    fi

    if [[ ! -d "$MODEL_OUTPUT_DIR" ]]; then
        echo "Modelo fundido nao encontrado em $MODEL_OUTPUT_DIR apos o pipeline remoto." >&2
        exit 1
    fi

    echo "Convertendo modelo fundido para GGUF..." >&2
    /bin/bash "$APP_DIR/convert_to_gguf.sh" \
        --model-dir "$MODEL_OUTPUT_DIR" \
        --out-file "$MODEL_PATH" \
        --llama-cpp-dir /opt/llama.cpp
fi

if [[ ! -f "$MODEL_PATH" ]]; then
    echo "Falha ao preparar o GGUF em $MODEL_PATH" >&2
    exit 1
fi

mkdir -p "$RUNTIME_LOG_DIR"
"$LLAMA_SERVER_EXE" \
    -m "$MODEL_PATH" \
    --host 127.0.0.1 \
    --port 8080 \
    -t "$N_THREADS" \
    -c "$N_CTX" \
    -b "$N_BATCH" \
    --jinja \
    >"$RUNTIME_LOG_DIR/llama-server.out.log" \
    2>"$RUNTIME_LOG_DIR/llama-server.err.log" &

LLAMA_PID="$!"
cleanup() {
    if kill -0 "$LLAMA_PID" >/dev/null 2>&1; then
        kill "$LLAMA_PID" >/dev/null 2>&1 || true
        wait "$LLAMA_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 90); do
    if curl --silent --fail "$LLAMA_SERVER_URL/health" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! curl --silent --fail "$LLAMA_SERVER_URL/health" >/dev/null 2>&1; then
    echo "llama-server nao respondeu em $LLAMA_SERVER_URL" >&2
    exit 1
fi

cd "$APP_DIR"
exec "$VENV_PYTHON" -m uvicorn server:app --host "$HOST" --port "$PORT" --log-level info
