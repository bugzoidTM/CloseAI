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

read_state_field() {
    local field_name="$1"
    "$VENV_PYTHON" - "$TRAINING_STATE_FILE" "$field_name" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
field = sys.argv[2]
if not path.exists():
    raise SystemExit(0)

data = json.loads(path.read_text(encoding="utf-8"))
value = data.get(field, "")
if value is None:
    value = ""
print(value)
PY
}

compute_training_signature() {
    "$VENV_PYTHON" - <<'PY'
import hashlib
import json
import os
from pathlib import Path

payload = {}

for key in [
    "KAGGLE_BASE_MODEL_SOURCE",
    "KAGGLE_ACCELERATOR",
    "MODEL_NAME",
    "MAX_SEQ_LENGTH",
    "NUM_EPOCHS",
    "LEARNING_RATE",
    "ALLOW_PIP_INSTALL",
    "TRAINING_REVISION",
]:
    payload[key] = os.getenv(key, "")

for key in ["DATASET_SOURCE_PATH", "REMOTE_SCRIPT_PATH"]:
    file_path = Path(os.getenv(key, ""))
    if file_path.exists() and file_path.is_file():
        payload[key] = {
            "path": str(file_path),
            "sha256": hashlib.sha256(file_path.read_bytes()).hexdigest(),
        }
    else:
        payload[key] = {"path": str(file_path), "missing": True}

normalized = json.dumps(payload, sort_keys=True, ensure_ascii=False).encode("utf-8")
print(hashlib.sha256(normalized).hexdigest())
PY
}

write_training_state() {
    local trigger="$1"
    "$VENV_PYTHON" - "$TRAINING_STATE_FILE" "$CURRENT_SIGNATURE" "$trigger" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path = Path(sys.argv[1])
signature = sys.argv[2]
trigger = sys.argv[3]
state_path.parent.mkdir(parents=True, exist_ok=True)

payload = {
    "training_signature": signature,
    "force_consumed_signature": signature,
    "updated_at": datetime.now(timezone.utc).isoformat(),
    "trigger": trigger,
    "model_path": os.getenv("MODEL_PATH", ""),
    "model_output_dir": os.getenv("MODEL_OUTPUT_DIR", ""),
    "dataset_source_path": os.getenv("DATASET_SOURCE_PATH", ""),
    "remote_script_path": os.getenv("REMOTE_SCRIPT_PATH", ""),
    "kaggle_base_model_source": os.getenv("KAGGLE_BASE_MODEL_SOURCE", ""),
    "training_revision": os.getenv("TRAINING_REVISION", ""),
}

state_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
PY
}

export CLOSEAI_DATA_DIR="${CLOSEAI_DATA_DIR:-/data}"
export MODEL_OUTPUT_DIR="${MODEL_OUTPUT_DIR:-$CLOSEAI_DATA_DIR/modelo_python_fundido}"
export KAGGLE_OUTPUT_ROOT="${KAGGLE_OUTPUT_ROOT:-$CLOSEAI_DATA_DIR/kaggle-output}"
export KAGGLE_BUILD_ROOT="${KAGGLE_BUILD_ROOT:-$CLOSEAI_DATA_DIR/build/kaggle}"
export DATASET_SOURCE_PATH="${DATASET_SOURCE_PATH:-$APP_DIR/dataset_python.json}"
export REMOTE_SCRIPT_PATH="${REMOTE_SCRIPT_PATH:-$APP_DIR/kaggle_remote_finetune.py}"
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
export TRAINING_REVISION="${TRAINING_REVISION:-default}"
export KAGGLE_DATASET_SLUG="${KAGGLE_DATASET_SLUG:-closeai-python-dataset}"
export KAGGLE_KERNEL_SLUG="${KAGGLE_KERNEL_SLUG:-closeai-fine-tune}"
export KAGGLE_BASE_MODEL_SOURCE="${KAGGLE_BASE_MODEL_SOURCE:-qwen-lm/qwen2.5-coder/transformers/1.5b-instruct/1}"
export KAGGLE_ACCELERATOR="${KAGGLE_ACCELERATOR:-NvidiaTeslaT4}"
export KAGGLE_POLL_INTERVAL="${KAGGLE_POLL_INTERVAL:-30}"
export KAGGLE_TIMEOUT_MINUTES="${KAGGLE_TIMEOUT_MINUTES:-180}"
export RUNTIME_LOG_DIR="${RUNTIME_LOG_DIR:-$CLOSEAI_DATA_DIR/runtime-logs}"
export TRAINING_STATE_FILE="${TRAINING_STATE_FILE:-$CLOSEAI_DATA_DIR/training-state.json}"

read_secret_if_present KAGGLE_API_TOKEN
mkdir -p "$CLOSEAI_DATA_DIR" "$RUNTIME_LOG_DIR"

CURRENT_SIGNATURE="$(compute_training_signature)"
SAVED_SIGNATURE="$(read_state_field training_signature || true)"
FORCE_CONSUMED_SIGNATURE="$(read_state_field force_consumed_signature || true)"
NEEDS_REMOTE_TRAIN="0"
STATE_TRIGGER="adopted"

if bool_true "$AUTO_TRAIN_FORCE" && [[ "$FORCE_CONSUMED_SIGNATURE" != "$CURRENT_SIGNATURE" ]]; then
    NEEDS_REMOTE_TRAIN="1"
    STATE_TRIGGER="force"
elif [[ ! -f "$MODEL_PATH" && ! -d "$MODEL_OUTPUT_DIR" ]]; then
    if bool_true "$AUTO_TRAIN"; then
        NEEDS_REMOTE_TRAIN="1"
        STATE_TRIGGER="missing-model"
    else
        echo "Modelo GGUF nao encontrado em $MODEL_PATH e AUTO_TRAIN esta desativado." >&2
        exit 1
    fi
elif bool_true "$AUTO_TRAIN" && [[ -n "$SAVED_SIGNATURE" ]] && [[ "$SAVED_SIGNATURE" != "$CURRENT_SIGNATURE" ]]; then
    NEEDS_REMOTE_TRAIN="1"
    STATE_TRIGGER="signature-change"
fi

if [[ "$NEEDS_REMOTE_TRAIN" == "1" ]]; then
    echo "Recriando artefatos locais para novo ciclo de treino ($STATE_TRIGGER)." >&2
    rm -rf "$MODEL_OUTPUT_DIR" "$MODEL_PATH" "$KAGGLE_OUTPUT_ROOT" "$KAGGLE_BUILD_ROOT"
fi

if [[ ! -f "$MODEL_PATH" ]]; then
    if [[ ! -d "$MODEL_OUTPUT_DIR" ]]; then
        if [[ "$NEEDS_REMOTE_TRAIN" == "1" ]] || bool_true "$AUTO_TRAIN"; then
            if [[ -z "${KAGGLE_API_TOKEN:-}" ]]; then
                echo "KAGGLE_API_TOKEN ausente; nao e possivel treinar automaticamente." >&2
                exit 1
            fi
            echo "Modelo GGUF ausente; iniciando fine-tune remoto via Kaggle API..." >&2
            "$VENV_PYTHON" -u "$APP_DIR/kaggle_pipeline.py" \
                --dataset-slug "$KAGGLE_DATASET_SLUG" \
                --kernel-slug "$KAGGLE_KERNEL_SLUG" \
                --base-model-source "$KAGGLE_BASE_MODEL_SOURCE" \
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

if [[ "$NEEDS_REMOTE_TRAIN" == "1" ]]; then
    write_training_state "$STATE_TRIGGER"
elif [[ -z "$SAVED_SIGNATURE" ]] || [[ "$SAVED_SIGNATURE" != "$CURRENT_SIGNATURE" ]]; then
    write_training_state "$STATE_TRIGGER"
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
