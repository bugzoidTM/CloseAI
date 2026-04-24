from __future__ import annotations

"""Run this file in Google Colab with a T4 GPU.

Install dependencies in a notebook cell before running:

!pip install unsloth transformers bitsandbytes trl peft datasets accelerate
"""

from datasets import load_dataset
from transformers import TrainingArguments
from trl import SFTTrainer
from unsloth import FastLanguageModel
import torch

MODEL_NAME = "Qwen/Qwen2.5-Coder-1.5B-Instruct"
MAX_SEQ_LENGTH = 4096
DATASET_FILE = "dataset_python.json"


def main() -> None:
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=MODEL_NAME,
        max_seq_length=MAX_SEQ_LENGTH,
        dtype=torch.float16,
        load_in_4bit=True,
    )

    model = FastLanguageModel.get_peft_model(
        model,
        r=16,
        lora_alpha=32,
        lora_dropout=0.05,
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

    dataset = load_dataset("json", data_files=DATASET_FILE, split="train")

    def format_row(row: dict) -> dict[str, str]:
        text = tokenizer.apply_chat_template(
            row["messages"],
            tokenize=False,
            add_generation_prompt=False,
        )
        return {"text": text}

    dataset = dataset.map(format_row, remove_columns=dataset.column_names)

    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=dataset,
        dataset_text_field="text",
        max_seq_length=MAX_SEQ_LENGTH,
        args=TrainingArguments(
            per_device_train_batch_size=2,
            gradient_accumulation_steps=4,
            learning_rate=2e-4,
            num_train_epochs=2,
            fp16=True,
            logging_steps=10,
            optim="adamw_8bit",
            output_dir="./output_model",
            save_strategy="epoch",
            report_to="none",
        ),
    )

    trainer.train()
    model.save_pretrained("./codigo_python_adapter")
    model.save_pretrained_merged(
        "./modelo_python_fundido",
        tokenizer,
        save_method="merged_16bit",
    )
    print("Modelo salvo. Baixe a pasta 'modelo_python_fundido' para o PC.")


if __name__ == "__main__":
    main()
