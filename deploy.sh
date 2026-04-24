#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

HOST_ADDRESS="127.0.0.1"
PORT="8000"
LLAMA_PORT="8080"
SKIP_INSTALL="0"
PRELOAD_MODEL="0"
USE_PYTHON_BACKEND="0"

usage() {
    cat <<'EOF'
Uso: ./deploy.sh [opcoes]

Opcoes:
  --host ENDERECO
  --port PORTA
  --llama-port PORTA
  --skip-install
  --preload-model
  --use-python-backend
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            HOST_ADDRESS="${2:?Valor ausente para --host}"
            shift 2
            ;;
        --port)
            PORT="${2:?Valor ausente para --port}"
            shift 2
            ;;
        --llama-port)
            LLAMA_PORT="${2:?Valor ausente para --llama-port}"
            shift 2
            ;;
        --skip-install)
            SKIP_INSTALL="1"
            shift
            ;;
        --preload-model)
            PRELOAD_MODEL="1"
            shift
            ;;
        --use-python-backend)
            USE_PYTHON_BACKEND="1"
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

require_command() {
    local name="$1"
    local hint="$2"
    if ! command -v "$name" >/dev/null 2>&1; then
        echo "$name nao encontrado. $hint" >&2
        exit 1
    fi
}

resolve_app_venv() {
    for candidate in "$SCRIPT_DIR/.venv312" "$SCRIPT_DIR/.venv"; do
        if [[ -x "$candidate/bin/python" ]]; then
            local version
            version="$("$candidate/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
            if [[ "$version" == "3.12" ]]; then
                echo "$candidate"
                return
            fi
        fi
    done
    echo "$SCRIPT_DIR/.venv312"
}

resolve_llama_server() {
    local candidates=(
        "$SCRIPT_DIR/llama.cpp/build/bin/llama-server"
        "$SCRIPT_DIR/llama.cpp/build/bin/Release/llama-server"
        "$SCRIPT_DIR/build/llama-prebuilt/llama-server"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return
        fi
    done

    if [[ -d "$SCRIPT_DIR/build/llama-prebuilt" ]]; then
        candidate="$(find "$SCRIPT_DIR/build/llama-prebuilt" -type f -name 'llama-server' | head -n 1 || true)"
        if [[ -n "$candidate" ]]; then
            echo "$candidate"
            return
        fi
    fi
}

PYTHON_LAUNCHER="$(resolve_python)"
VENV_DIR="$(resolve_app_venv)"
require_command curl "No Ubuntu: sudo apt-get install -y curl"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    "$PYTHON_LAUNCHER" -m venv "$VENV_DIR"
fi

PYTHON="$VENV_DIR/bin/python"
VERSION="$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
echo "Python do ambiente: $VERSION"

if [[ "$SKIP_INSTALL" != "1" ]]; then
    "$PYTHON" -m pip install --upgrade pip
    "$PYTHON" -m pip install -r requirements.txt

    if [[ "$USE_PYTHON_BACKEND" == "1" ]]; then
        "$PYTHON" -m pip install llama-cpp-python
    fi
fi

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-2}"
export LLAMA_NO_MMAP="${LLAMA_NO_MMAP:-1}"
export HOST="$HOST_ADDRESS"
export PORT
export MODEL_PATH="$SCRIPT_DIR/modelo_python.gguf"

if [[ "$PRELOAD_MODEL" == "1" ]]; then
    export PRELOAD_MODEL="1"
fi

if [[ ! -f "$MODEL_PATH" ]]; then
    echo "Aviso: modelo_python.gguf nao encontrado. /generate retornara 503 ate a conversao ser feita." >&2
fi

LLAMA_PID=""
cleanup() {
    if [[ -n "$LLAMA_PID" ]] && kill -0 "$LLAMA_PID" >/dev/null 2>&1; then
        kill "$LLAMA_PID" >/dev/null 2>&1 || true
        wait "$LLAMA_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

if [[ "$USE_PYTHON_BACKEND" != "1" ]]; then
    LLAMA_SERVER_EXE="$(resolve_llama_server)"
    if [[ -z "$LLAMA_SERVER_EXE" ]]; then
        echo "llama-server nao encontrado. Rode ./convert_to_gguf.sh primeiro." >&2
        exit 1
    fi

    export LLAMA_SERVER_URL="http://127.0.0.1:$LLAMA_PORT"
    export LLAMA_SERVER_MODEL="${LLAMA_SERVER_MODEL:-modelo_python.gguf}"

    LOG_DIR="$SCRIPT_DIR/build/runtime-logs"
    mkdir -p "$LOG_DIR"
    LLAMA_OUT="$LOG_DIR/llama-server.out.log"
    LLAMA_ERR="$LOG_DIR/llama-server.err.log"

    "$LLAMA_SERVER_EXE" \
        -m "$MODEL_PATH" \
        --host 127.0.0.1 \
        --port "$LLAMA_PORT" \
        -t "${N_THREADS:-2}" \
        -c "${N_CTX:-4096}" \
        -b "${N_BATCH:-512}" \
        --jinja \
        >"$LLAMA_OUT" 2>"$LLAMA_ERR" &
    LLAMA_PID="$!"

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
fi

echo "Iniciando API em http://$HOST_ADDRESS:$PORT"
echo "Docs: http://$HOST_ADDRESS:$PORT/docs"
exec "$PYTHON" -m uvicorn server:app --host "$HOST_ADDRESS" --port "$PORT" --log-level info
