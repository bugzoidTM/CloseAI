#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/app"
VENV_PYTHON="/opt/venv/bin/python"
LLAMA_SERVER_EXE="/opt/llama.cpp/build/bin/llama-server"

export MODEL_PATH="${MODEL_PATH:-/models/modelo_python.gguf}"
export LLAMA_SERVER_MODEL="${LLAMA_SERVER_MODEL:-$(basename "$MODEL_PATH")}"
export LLAMA_SERVER_URL="${LLAMA_SERVER_URL:-http://127.0.0.1:8080}"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-8000}"
export N_CTX="${N_CTX:-4096}"
export N_THREADS="${N_THREADS:-2}"
export N_BATCH="${N_BATCH:-512}"

if [[ ! -f "$MODEL_PATH" ]]; then
    echo "Modelo GGUF nao encontrado em $MODEL_PATH" >&2
    exit 1
fi

mkdir -p "$APP_DIR/build/runtime-logs"
"$LLAMA_SERVER_EXE" \
    -m "$MODEL_PATH" \
    --host 127.0.0.1 \
    --port 8080 \
    -t "$N_THREADS" \
    -c "$N_CTX" \
    -b "$N_BATCH" \
    --jinja \
    >"$APP_DIR/build/runtime-logs/llama-server.out.log" \
    2>"$APP_DIR/build/runtime-logs/llama-server.err.log" &

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
