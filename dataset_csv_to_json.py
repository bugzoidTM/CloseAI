from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

DEFAULT_SYSTEM = (
    "Voce e um especialista em Python. Gere codigo limpo, comentado e seguindo PEP 8. "
    "Use type hints e docstrings."
)


def row_to_chat(row: dict[str, str]) -> dict[str, list[dict[str, str]]]:
    system = row.get("system") or DEFAULT_SYSTEM
    user = row.get("user", "").strip()
    assistant = row.get("assistant", "").strip()

    if not user or not assistant:
        raise ValueError("Cada linha precisa preencher user e assistant.")

    return {
        "messages": [
            {"role": "system", "content": system.strip()},
            {"role": "user", "content": user},
            {"role": "assistant", "content": assistant},
        ]
    }


def convert(csv_path: Path, json_path: Path) -> int:
    with csv_path.open("r", encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source)
        rows = [row_to_chat(row) for row in reader]

    json_path.write_text(
        json.dumps(rows, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return len(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description="Converte dataset CSV seguro para JSON chat.")
    parser.add_argument("--csv", default="dataset_template.csv")
    parser.add_argument("--out", default="dataset_python.json")
    args = parser.parse_args()

    count = convert(Path(args.csv), Path(args.out))
    print(f"{count} exemplos convertidos para {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
