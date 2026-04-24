from __future__ import annotations

import argparse
import json
import sys
from typing import Any

import requests


def post_generate(api_url: str, prompt: str, max_tokens: int) -> dict[str, Any]:
    url = f"{api_url.rstrip('/')}/generate"
    payload = {"prompt": prompt, "max_tokens": max_tokens, "validate": True}
    response = requests.post(url, json=payload, timeout=300)
    response.raise_for_status()
    return response.json()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Smoke test da API local.")
    parser.add_argument("--api-url", default="http://127.0.0.1:8000")
    parser.add_argument(
        "--prompt",
        default="Escreva uma funcao Python soma(a: float, b: float) -> float com docstring.",
    )
    parser.add_argument("--max-tokens", type=int, default=128)
    args = parser.parse_args(argv)

    print("Gerando codigo...")
    try:
        data = post_generate(args.api_url, args.prompt, args.max_tokens)
    except requests.HTTPError as exc:
        print(f"Erro HTTP: {exc}", file=sys.stderr)
        if exc.response is not None:
            print(exc.response.text, file=sys.stderr)
        return 1
    except requests.RequestException as exc:
        print(f"Falha de conexao: {exc}", file=sys.stderr)
        return 1

    print("Resposta:")
    print(json.dumps(data, indent=2, ensure_ascii=False))
    return 0 if data.get("syntax_valid", True) else 1


if __name__ == "__main__":
    raise SystemExit(main())
