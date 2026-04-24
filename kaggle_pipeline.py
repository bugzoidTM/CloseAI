from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PROJECT_DIR = Path(__file__).resolve().parent
BUILD_ROOT = PROJECT_DIR / "build" / "kaggle"
DATASET_BUILD_DIR = BUILD_ROOT / "dataset"
KERNEL_BUILD_DIR = BUILD_ROOT / "kernel"
OUTPUT_ROOT = PROJECT_DIR / "kaggle-output"
REMOTE_SCRIPT_PATH = PROJECT_DIR / "kaggle_remote_finetune.py"
DATASET_SOURCE_PATH = PROJECT_DIR / "dataset_python.json"
MODEL_OUTPUT_DIR = PROJECT_DIR / "modelo_python_fundido"
ACCESS_TOKEN_FILE = Path.home() / ".kaggle" / "access_token"
DEFAULT_MODEL_SOURCE = "qwen-lm/qwen2.5-coder/transformers/1.5b-instruct/1"
OUTPUT_FILE_PATTERN = r"(^|/)(modelo_python_fundido\.zip|training_manifest\.json)$"


@dataclass(frozen=True)
class KaggleRefs:
    username: str
    dataset_ref: str
    kernel_ref: str


def slugify(value: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return normalized or "modeloai"


def ensure_token_available(token: str | None) -> None:
    if token:
        os.environ["KAGGLE_API_TOKEN"] = token
        ACCESS_TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
        ACCESS_TOKEN_FILE.write_text(token.strip(), encoding="utf-8")
    elif ACCESS_TOKEN_FILE.exists():
        os.environ.setdefault("KAGGLE_API_TOKEN", ACCESS_TOKEN_FILE.read_text(encoding="utf-8").strip())


def get_api():
    try:
        from kaggle.api.kaggle_api_extended import KaggleApi
    except ImportError as exc:
        raise RuntimeError(
            "Kaggle CLI nao instalada neste Python. Use .venv-kaggle\\Scripts\\python.exe ou rode kaggle_setup primeiro."
        ) from exc

    api = KaggleApi()
    api.authenticate()
    return api


def build_refs(api: Any, dataset_slug: str, kernel_slug: str) -> KaggleRefs:
    username = api.config_values["username"]
    return KaggleRefs(
        username=username,
        dataset_ref=f"{username}/{dataset_slug}",
        kernel_ref=f"{username}/{kernel_slug}",
    )


def reset_directory(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def dataset_metadata(refs: KaggleRefs) -> dict[str, Any]:
    return {
        "title": "codigo llm api python dataset",
        "id": refs.dataset_ref,
        "subtitle": "Dataset privado para fine-tune remoto do projeto codigo-llm-api",
        "description": "Dataset base do projeto para fine-tune remoto via Kaggle API.",
        "licenses": [{"name": "CC0-1.0"}],
    }


def kernel_metadata(refs: KaggleRefs, model_source: str) -> dict[str, Any]:
    return {
        "id": refs.kernel_ref,
        "title": "codigo llm api fine tune",
        "code_file": "train_remote.py",
        "language": "python",
        "kernel_type": "script",
        "is_private": "true",
        "enable_gpu": "true",
        "enable_internet": "true",
        "dataset_sources": [refs.dataset_ref],
        "competition_sources": [],
        "kernel_sources": [],
        "model_sources": [model_source],
    }


def prepare_dataset_package(refs: KaggleRefs) -> Path:
    reset_directory(DATASET_BUILD_DIR)
    shutil.copy2(DATASET_SOURCE_PATH, DATASET_BUILD_DIR / DATASET_SOURCE_PATH.name)
    (DATASET_BUILD_DIR / "dataset-metadata.json").write_text(
        json.dumps(dataset_metadata(refs), indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return DATASET_BUILD_DIR


def prepare_kernel_package(refs: KaggleRefs, model_source: str) -> Path:
    reset_directory(KERNEL_BUILD_DIR)
    shutil.copy2(REMOTE_SCRIPT_PATH, KERNEL_BUILD_DIR / "train_remote.py")
    (KERNEL_BUILD_DIR / "kernel-metadata.json").write_text(
        json.dumps(kernel_metadata(refs, model_source), indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return KERNEL_BUILD_DIR


def upload_dataset(api: Any, folder: Path, refs: KaggleRefs) -> None:
    response = api.dataset_create_new(str(folder), public=False, quiet=False)
    if getattr(response, "error", ""):
        message = str(response.error)
        lower_message = message.lower()
        if "already in use" in lower_message or "already exists" in lower_message:
            api.dataset_create_version(
                str(folder),
                version_notes=f"Atualizacao automatica em {time.strftime('%Y-%m-%d %H:%M:%S')}",
                quiet=False,
            )
            return
        raise RuntimeError(message)


def resolve_kernel_ref(push_response: Any, fallback_ref: str) -> str:
    url = str(getattr(push_response, "url", "")).strip()
    ref = str(getattr(push_response, "ref", "")).strip()

    candidates = [url, ref]
    for candidate in candidates:
        match = re.search(r"/code/([^/]+)/([^/]+)$", candidate)
        if match:
            return f"{match.group(1)}/{match.group(2)}"

    return fallback_ref


def push_kernel(api: Any, folder: Path, accelerator: str) -> Any:
    response = api.kernels_push(str(folder), acc=accelerator)
    if response is None:
        raise RuntimeError("Falha ao criar/atualizar o kernel no Kaggle.")
    if getattr(response, "error", ""):
        raise RuntimeError(str(response.error))
    return response


def get_status_name(status: Any) -> str:
    if hasattr(status, "name"):
        return str(status.name).lower()
    return str(status).lower()


def poll_kernel(api: Any, kernel_ref: str, poll_interval: int, timeout_minutes: int) -> Any:
    deadline = time.time() + timeout_minutes * 60
    last_status = None

    while time.time() < deadline:
        response = api.kernels_status(kernel_ref)
        status = get_status_name(response.status)

        if status != last_status:
            print(f"Status do kernel {kernel_ref}: {status}", flush=True)
            last_status = status

        if status == "complete":
            return response

        if status in {"error", "cancel_requested", "cancel_acknowledged"}:
            try:
                logs = api.kernels_logs(kernel_ref)
            except Exception:
                logs = ""
            failure_message = getattr(response, "failure_message", "")
            raise RuntimeError(
                f"Kernel finalizou com status '{status}'. {failure_message}\n{logs}".strip()
            )

        time.sleep(poll_interval)

    raise TimeoutError(f"Tempo limite excedido ao aguardar o kernel {kernel_ref}.")


def download_outputs(api: Any, kernel_ref: str, kernel_slug: str) -> Path:
    target_dir = OUTPUT_ROOT / kernel_slug
    target_dir.mkdir(parents=True, exist_ok=True)
    api.kernels_output(
        kernel_ref,
        path=str(target_dir),
        file_pattern=OUTPUT_FILE_PATTERN,
        force=True,
        quiet=False,
    )
    return target_dir


def extract_model(output_dir: Path) -> Path:
    zip_candidates = sorted(output_dir.glob("**/modelo_python_fundido.zip"))
    if not zip_candidates:
        raise FileNotFoundError("modelo_python_fundido.zip nao encontrado nos outputs do kernel.")

    zip_path = zip_candidates[0]

    if MODEL_OUTPUT_DIR.exists():
        shutil.rmtree(MODEL_OUTPUT_DIR)

    with zipfile.ZipFile(zip_path, "r") as archive:
        archive.extractall(PROJECT_DIR)

    extracted = PROJECT_DIR / "modelo_python_fundido"
    if not extracted.exists():
        raise FileNotFoundError("O zip foi baixado, mas a pasta modelo_python_fundido nao apareceu apos extracao.")
    return extracted


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Orquestra fine-tune remoto via Kaggle API.")
    parser.add_argument("--token", help="Kaggle API token. Se omitido, usa KAGGLE_API_TOKEN ou ~/.kaggle/access_token.")
    parser.add_argument("--dataset-slug", default="codigo-llm-api-python-dataset")
    parser.add_argument("--kernel-slug", default="codigo-llm-api-fine-tune")
    parser.add_argument("--base-model-source", default=DEFAULT_MODEL_SOURCE)
    parser.add_argument("--accelerator", default="NvidiaTeslaT4")
    parser.add_argument("--poll-interval", type=int, default=30)
    parser.add_argument("--timeout-minutes", type=int, default=180)
    parser.add_argument("--skip-download", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    ensure_token_available(args.token)
    api = get_api()

    refs = build_refs(
        api,
        dataset_slug=slugify(args.dataset_slug),
        kernel_slug=slugify(args.kernel_slug),
    )

    print(f"Conta Kaggle autenticada: {refs.username}", flush=True)
    print(f"Dataset: {refs.dataset_ref}", flush=True)
    print(f"Kernel: {refs.kernel_ref}", flush=True)

    dataset_folder = prepare_dataset_package(refs)
    kernel_folder = prepare_kernel_package(refs, args.base_model_source)

    upload_dataset(api, dataset_folder, refs)
    push_response = push_kernel(api, kernel_folder, args.accelerator)
    actual_kernel_ref = resolve_kernel_ref(push_response, refs.kernel_ref)
    print(f"Kernel enviado: ref={push_response.ref} url={push_response.url}", flush=True)
    print(f"Kernel efetivo: {actual_kernel_ref}", flush=True)

    poll_kernel(api, actual_kernel_ref, args.poll_interval, args.timeout_minutes)

    if args.skip_download:
        return 0

    output_dir = download_outputs(api, actual_kernel_ref, actual_kernel_ref.split("/")[-1])
    model_dir = extract_model(output_dir)
    print(f"Modelo fundido baixado para: {model_dir}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
