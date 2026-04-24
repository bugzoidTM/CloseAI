from __future__ import annotations

import importlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path

MODEL_NAME = os.getenv("MODEL_NAME", "Qwen/Qwen2.5-Coder-1.5B-Instruct")
MAX_SEQ_LENGTH = int(os.getenv("MAX_SEQ_LENGTH", "4096"))
NUM_EPOCHS = int(os.getenv("NUM_EPOCHS", "2"))
LEARNING_RATE = float(os.getenv("LEARNING_RATE", "2e-4"))
ALLOW_PIP_INSTALL = os.getenv("ALLOW_PIP_INSTALL", "0").strip().lower() in {"1", "true", "yes", "on"}
WORK_DIR = Path("/kaggle/working")
INPUT_DIR = Path("/kaggle/input")
OUTPUT_DIR = WORK_DIR / "modelo_python_fundido"
ADAPTER_DIR = WORK_DIR / "codigo_python_adapter"
ZIP_PATH = WORK_DIR / "modelo_python_fundido.zip"
MANIFEST_PATH = WORK_DIR / "training_manifest.json"


def run(command: list[str]) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, check=True)


def ensure_module(module_name: str, pip_spec: str) -> None:
    try:
        importlib.import_module(module_name)
    except ImportError as exc:
        if not ALLOW_PIP_INSTALL:
            raise RuntimeError(
                f"Modulo obrigatorio ausente no ambiente Kaggle: {module_name}. "
                "Defina ALLOW_PIP_INSTALL=1 para tentar instalar via pip."
            ) from exc
        run([sys.executable, "-m", "pip", "install", "-q", pip_spec])


def print_runtime_versions(packages: list[str]) -> None:
    info: dict[str, str] = {}
    for package in packages:
        try:
            info[package] = version(package)
        except PackageNotFoundError:
            info[package] = "missing"
    print(json.dumps({"runtime_versions": info}, indent=2), flush=True)


def find_dataset_file() -> Path:
    for candidate in INPUT_DIR.rglob("dataset_python.json"):
        if candidate.is_file():
            return candidate
    raise FileNotFoundError("dataset_python.json nao encontrado em /kaggle/input.")


def find_local_model_dir() -> Path | None:
    preferred = INPUT_DIR / "qwen2.5-coder" / "transformers" / "1.5b-instruct" / "1"
    if (preferred / "config.json").exists():
        return preferred

    for config_file in INPUT_DIR.rglob("config.json"):
        parent = config_file.parent
        parts = {part.lower() for part in parent.parts}
        if "transformers" in parts and "1.5b-instruct" in parts and "qwen2.5-coder" in parts:
            return parent
    return None


def zip_directory(source_dir: Path, zip_path: Path) -> None:
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file_path in sorted(source_dir.rglob("*")):
            if file_path.is_file():
                archive.write(file_path, file_path.relative_to(source_dir.parent))


def normalize_tokenizer_config(model_dir: Path) -> None:
    tokenizer_config_path = model_dir / "tokenizer_config.json"
    if not tokenizer_config_path.exists():
        return

    config = json.loads(tokenizer_config_path.read_text(encoding="utf-8"))
    extra_special_tokens = config.get("extra_special_tokens")
    if isinstance(extra_special_tokens, list):
        config.pop("extra_special_tokens", None)
        tokenizer_config_path.write_text(
            json.dumps(config, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )


def main() -> None:
    ensure_module("datasets", "datasets>=2.18.0")
    ensure_module("peft", "peft>=0.13.0")
    ensure_module("transformers", "transformers>=4.48.0")
    ensure_module("accelerate", "accelerate>=0.30.0")
    print_runtime_versions(["torch", "transformers", "datasets", "peft", "accelerate", "bitsandbytes"])

    import torch
    from datasets import load_dataset
    from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
    from transformers import (
        AutoModelForCausalLM,
        AutoTokenizer,
        BitsAndBytesConfig,
        DataCollatorForLanguageModeling,
        Trainer,
        TrainingArguments,
    )

    dataset_path = find_dataset_file()
    local_model_dir = find_local_model_dir()
    model_identifier = str(local_model_dir) if local_model_dir else MODEL_NAME
    print(f"Dataset encontrado em: {dataset_path}", flush=True)
    print(f"Modelo base: {model_identifier}", flush=True)

    tokenizer = AutoTokenizer.from_pretrained(
        model_identifier,
        trust_remote_code=True,
        local_files_only=bool(local_model_dir),
    )
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    use_4bit = True
    try:
        importlib.import_module("bitsandbytes")
    except ImportError:
        use_4bit = False

    if use_4bit:
        quantization_config = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_use_double_quant=True,
            bnb_4bit_compute_dtype=torch.float16,
        )
        model = AutoModelForCausalLM.from_pretrained(
            model_identifier,
            trust_remote_code=True,
            device_map="auto",
            quantization_config=quantization_config,
            local_files_only=bool(local_model_dir),
        )
        model = prepare_model_for_kbit_training(model)
    else:
        print("bitsandbytes ausente; usando LoRA em FP16 sem quantizacao 4-bit.", flush=True)
        model = AutoModelForCausalLM.from_pretrained(
            model_identifier,
            trust_remote_code=True,
            device_map="auto",
            torch_dtype=torch.float16 if torch.cuda.is_available() else torch.float32,
            local_files_only=bool(local_model_dir),
        )
        for parameter in model.parameters():
            parameter.requires_grad = False

    model.config.use_cache = False
    model.gradient_checkpointing_enable()

    peft_config = LoraConfig(
        r=16,
        lora_alpha=32,
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=[
            "q_proj",
            "k_proj",
            "v_proj",
            "o_proj",
            "gate_proj",
            "up_proj",
            "down_proj",
        ],
    )
    model = get_peft_model(model, peft_config)
    model.print_trainable_parameters()

    dataset = load_dataset("json", data_files=str(dataset_path), split="train")

    def format_row(row: dict[str, object]) -> dict[str, str]:
        text = tokenizer.apply_chat_template(
            row["messages"],
            tokenize=False,
            add_generation_prompt=False,
        )
        if tokenizer.eos_token and not text.endswith(tokenizer.eos_token):
            text = f"{text}{tokenizer.eos_token}"
        return {"text": text}

    dataset = dataset.map(format_row, remove_columns=dataset.column_names)

    def tokenize_batch(batch: dict[str, list[str]]) -> dict[str, list[list[int]]]:
        return tokenizer(
            batch["text"],
            truncation=True,
            max_length=MAX_SEQ_LENGTH,
            padding=False,
        )

    tokenized_dataset = dataset.map(tokenize_batch, batched=True, remove_columns=["text"])

    training_args = TrainingArguments(
        output_dir=str(WORK_DIR / "output_model"),
        per_device_train_batch_size=1,
        gradient_accumulation_steps=8,
        learning_rate=LEARNING_RATE,
        num_train_epochs=NUM_EPOCHS,
        logging_steps=5,
        save_strategy="epoch",
        fp16=torch.cuda.is_available(),
        report_to="none",
        optim="paged_adamw_8bit" if use_4bit else "adamw_torch",
        lr_scheduler_type="cosine",
        warmup_ratio=0.03,
        remove_unused_columns=False,
    )

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=tokenized_dataset,
        data_collator=DataCollatorForLanguageModeling(tokenizer=tokenizer, mlm=False),
    )

    trainer.train()

    if ADAPTER_DIR.exists():
        shutil.rmtree(ADAPTER_DIR)
    if OUTPUT_DIR.exists():
        shutil.rmtree(OUTPUT_DIR)

    model.save_pretrained(ADAPTER_DIR)
    tokenizer.save_pretrained(ADAPTER_DIR)
    normalize_tokenizer_config(ADAPTER_DIR)

    merged_model = model.merge_and_unload()
    merged_model.save_pretrained(OUTPUT_DIR, safe_serialization=True, max_shard_size="2GB")
    tokenizer.save_pretrained(OUTPUT_DIR)
    normalize_tokenizer_config(OUTPUT_DIR)

    if ZIP_PATH.exists():
        ZIP_PATH.unlink()
    zip_directory(OUTPUT_DIR, ZIP_PATH)

    manifest = {
        "model_name": model_identifier,
        "dataset_path": str(dataset_path),
        "train_rows": len(tokenized_dataset),
        "num_epochs": NUM_EPOCHS,
        "learning_rate": LEARNING_RATE,
        "output_dir": str(OUTPUT_DIR),
        "zip_path": str(ZIP_PATH),
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(manifest, indent=2, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
