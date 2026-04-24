#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODEL_DIR="./modelo_python_fundido"
OUT_FILE="./modelo_python.gguf"
LLAMA_CPP_DIR="./llama.cpp"

usage() {
    cat <<'EOF'
Uso: ./convert_to_gguf.sh [opcoes]

Opcoes:
  --model-dir CAMINHO
  --out-file CAMINHO
  --llama-cpp-dir CAMINHO
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model-dir)
            MODEL_DIR="${2:?Valor ausente para --model-dir}"
            shift 2
            ;;
        --out-file)
            OUT_FILE="${2:?Valor ausente para --out-file}"
            shift 2
            ;;
        --llama-cpp-dir)
            LLAMA_CPP_DIR="${2:?Valor ausente para --llama-cpp-dir}"
            shift 2
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

abspath() {
    "$PYTHON" - "$1" <<'PY'
from pathlib import Path
import sys

value = Path(sys.argv[1]).expanduser()
if value.is_absolute():
    print(value.resolve())
else:
    print((Path.cwd() / value).resolve())
PY
}

PYTHON_LAUNCHER="$(resolve_python)"
require_command git "No Ubuntu: sudo apt-get install -y git"
require_command cmake "No Ubuntu: sudo apt-get install -y cmake build-essential"

VENV_DIR="$(resolve_app_venv)"
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    "$PYTHON_LAUNCHER" -m venv "$VENV_DIR"
fi
PYTHON="$VENV_DIR/bin/python"

MODEL_PATH="$(abspath "$MODEL_DIR")"
OUT_PATH="$(abspath "$OUT_FILE")"
LLAMA_CPP_PATH="$(abspath "$LLAMA_CPP_DIR")"

if [[ ! -d "$MODEL_PATH" ]]; then
    echo "Pasta do modelo nao encontrada: $MODEL_PATH" >&2
    exit 1
fi

"$PYTHON" - "$MODEL_PATH/tokenizer_config.json" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(0)

data = json.loads(path.read_text(encoding="utf-8"))
if isinstance(data.get("extra_special_tokens"), list):
    data.pop("extra_special_tokens", None)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    print("tokenizer_config.json normalizado para conversao GGUF.")
PY

if [[ ! -d "$LLAMA_CPP_PATH" ]]; then
    git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_CPP_PATH"
fi

pushd "$LLAMA_CPP_PATH" >/dev/null
"$PYTHON" -m pip install --upgrade pip
"$PYTHON" -m pip install -r requirements.txt

TEMP_F16="$SCRIPT_DIR/modelo_python-f16.gguf"

"$PYTHON" ./convert_hf_to_gguf.py "$MODEL_PATH" --outtype f16 --outfile "$TEMP_F16"

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release --parallel

QUANTIZE_BIN=""
for candidate in \
    "$LLAMA_CPP_PATH/build/bin/llama-quantize" \
    "$LLAMA_CPP_PATH/build/bin/Release/llama-quantize" \
    "$LLAMA_CPP_PATH/llama-quantize"; do
    if [[ -x "$candidate" ]]; then
        QUANTIZE_BIN="$candidate"
        break
    fi
done

if [[ -z "$QUANTIZE_BIN" ]]; then
    echo "Nao foi possivel localizar o binario llama-quantize apos a compilacao." >&2
    exit 1
fi

"$QUANTIZE_BIN" "$TEMP_F16" "$OUT_PATH" Q4_K_M
rm -f "$TEMP_F16"
popd >/dev/null

echo "Conversao concluida: $OUT_PATH"
