from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import requests

DEFAULT_API_URL = "http://127.0.0.1:8000"
DEFAULT_OUTPUT = "generated_code.py"
TASK_LABEL = "Codigo LLM: gerar Python"


def request_code(api_url: str, prompt: str, max_tokens: int) -> str:
    response = requests.post(
        f"{api_url.rstrip('/')}/generate",
        json={"prompt": prompt, "max_tokens": max_tokens, "validate": True},
        timeout=300,
    )
    response.raise_for_status()
    data = response.json()

    if data.get("syntax_valid") is False:
        raise RuntimeError(f"Codigo gerado com sintaxe invalida: {data.get('error')}")

    return str(data["code"])


def install_vscode_task(workspace: Path) -> Path:
    vscode_dir = workspace / ".vscode"
    vscode_dir.mkdir(exist_ok=True)
    tasks_path = vscode_dir / "tasks.json"

    if tasks_path.exists():
        try:
            tasks = json.loads(tasks_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            backup = tasks_path.with_suffix(".json.bak")
            tasks_path.replace(backup)
            tasks = {"version": "2.0.0", "tasks": []}
    else:
        tasks = {"version": "2.0.0", "tasks": []}

    task_list = tasks.setdefault("tasks", [])
    task_list = [task for task in task_list if task.get("label") != TASK_LABEL]
    task_list.append(
        {
            "label": TASK_LABEL,
            "type": "shell",
            "command": "python",
            "args": [
                "${workspaceFolder}/integrate_vscode.py",
                "--prompt",
                "${input:codigoLlmPrompt}",
                "--output",
                "${workspaceFolder}/generated_code.py",
            ],
            "problemMatcher": [],
            "presentation": {"reveal": "always", "panel": "shared"},
        }
    )
    tasks["tasks"] = task_list

    inputs = tasks.setdefault("inputs", [])
    inputs = [item for item in inputs if item.get("id") != "codigoLlmPrompt"]
    inputs.append(
        {
            "id": "codigoLlmPrompt",
            "type": "promptString",
            "description": "Prompt para a API local de codigo Python",
        }
    )
    tasks["inputs"] = inputs

    tasks_path.write_text(json.dumps(tasks, indent=2, ensure_ascii=False), encoding="utf-8")
    return tasks_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Cliente CLI para integrar a API ao VS Code.")
    parser.add_argument("prompt_arg", nargs="?", help="Prompt direto para a API.")
    parser.add_argument("--prompt", help="Prompt direto para a API.")
    parser.add_argument("--api-url", default=DEFAULT_API_URL)
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    parser.add_argument("--install-vscode", action="store_true")
    parser.add_argument("--workspace", default=".")
    args = parser.parse_args(argv)

    workspace = Path(args.workspace).resolve()

    if args.install_vscode:
        path = install_vscode_task(workspace)
        print(f"Tarefa do VS Code instalada em {path}")
        return 0

    prompt = args.prompt or args.prompt_arg
    if not prompt and not sys.stdin.isatty():
        prompt = sys.stdin.read().strip()

    if not prompt:
        print("Informe um prompt por argumento, --prompt ou stdin.", file=sys.stderr)
        return 2

    try:
        code = request_code(args.api_url, prompt, args.max_tokens)
    except (requests.RequestException, RuntimeError) as exc:
        print(f"Erro ao gerar codigo: {exc}", file=sys.stderr)
        return 1

    output_path = Path(args.output).resolve()
    output_path.write_text(code, encoding="utf-8")
    print(code)
    print(f"\nArquivo atualizado: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
