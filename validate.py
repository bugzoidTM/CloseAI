from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

CODE_BLOCK_RE = re.compile(
    r"```(?:python|py)?\s*(.*?)```",
    flags=re.IGNORECASE | re.DOTALL,
)


def extract_python_code(text: str) -> str:
    """Extract the first fenced Python block or return the raw text."""
    match = CODE_BLOCK_RE.search(text)
    if match:
        return match.group(1).strip()
    return text.replace("```python", "").replace("```py", "").replace("```", "").strip()


def check_python_syntax(code: str) -> tuple[bool, str]:
    """Remove Markdown fences and validate Python syntax with ast.parse."""
    clean_code = extract_python_code(code)
    if not clean_code:
        return False, "Codigo vazio."

    try:
        ast.parse(clean_code)
        return True, ""
    except SyntaxError as exc:
        return False, f"{exc.msg} (linha {exc.lineno}, coluna {exc.offset})"
    except Exception as exc:
        return False, f"Codigo invalido ou estrutura nao reconhecida: {exc}"


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if not args:
        print("Uso: python validate.py <arquivo.py|resposta.md>")
        return 2

    path = Path(args[0])
    code = path.read_text(encoding="utf-8")
    is_valid, error = check_python_syntax(code)

    if is_valid:
        print("Sintaxe valida.")
        return 0

    print(f"Sintaxe invalida: {error}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
