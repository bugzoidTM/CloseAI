#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

API_URL="http://127.0.0.1:8000"
SKIP_API="0"

usage() {
    cat <<'EOF'
Uso: ./ci_local.sh [opcoes]

Opcoes:
  --api-url URL
  --skip-api
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-url)
            API_URL="${2:?Valor ausente para --api-url}"
            shift 2
            ;;
        --skip-api)
            SKIP_API="1"
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

if ! command -v curl >/dev/null 2>&1; then
    echo "curl nao encontrado. No Ubuntu: sudo apt-get install -y curl" >&2
    exit 1
fi

if [[ -x "$SCRIPT_DIR/.venv312/bin/python" ]]; then
    PYTHON="$SCRIPT_DIR/.venv312/bin/python"
elif [[ -x "$SCRIPT_DIR/.venv/bin/python" ]]; then
    PYTHON="$SCRIPT_DIR/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON="$(command -v python3)"
else
    PYTHON="$(command -v python)"
fi

echo "1/3 Compilando arquivos Python..."
"$PYTHON" -m compileall -q .

echo "2/3 Rodando testes unitarios..."
"$PYTHON" -m unittest discover -s tests

if [[ "$SKIP_API" == "1" ]]; then
    echo "3/3 Smoke test da API ignorado por parametro."
    exit 0
fi

echo "3/3 Verificando API local..."
if curl --silent --fail "$API_URL/health" >/dev/null 2>&1; then
    "$PYTHON" ./test_api.py --api-url "$API_URL"
else
    echo "API nao esta disponivel ou modelo ausente. Rode ./deploy.sh depois de gerar modelo_python.gguf." >&2
fi
