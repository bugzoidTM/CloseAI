from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from kaggle_pipeline import KaggleRefs, dataset_metadata, kernel_metadata, slugify


class KagglePipelineTests(unittest.TestCase):
    def test_slugify_normalizes_text(self) -> None:
        self.assertEqual(slugify("Codigo LLM API Fine Tune"), "codigo-llm-api-fine-tune")

    def test_slugify_falls_back_when_empty(self) -> None:
        self.assertEqual(slugify("###"), "modeloai")

    def test_dataset_metadata_uses_private_ref(self) -> None:
        refs = KaggleRefs(
            username="user123",
            dataset_ref="user123/my-dataset",
            kernel_ref="user123/my-kernel",
        )
        metadata = dataset_metadata(refs)
        self.assertEqual(metadata["id"], "user123/my-dataset")
        self.assertEqual(metadata["licenses"][0]["name"], "CC0-1.0")

    def test_kernel_metadata_links_dataset(self) -> None:
        refs = KaggleRefs(
            username="user123",
            dataset_ref="user123/my-dataset",
            kernel_ref="user123/my-kernel",
        )
        metadata = kernel_metadata(refs, "qwen-lm/qwen2.5-coder/transformers/1.5b-instruct/1")
        self.assertEqual(metadata["id"], "user123/my-kernel")
        self.assertEqual(metadata["dataset_sources"], ["user123/my-dataset"])
        self.assertEqual(
            metadata["model_sources"],
            ["qwen-lm/qwen2.5-coder/transformers/1.5b-instruct/1"],
        )
        self.assertEqual(metadata["enable_gpu"], "true")

    def test_dataset_source_path_can_be_overridden_by_env(self) -> None:
        from importlib import reload
        import kaggle_pipeline

        with tempfile.TemporaryDirectory() as temp_dir:
            dataset_path = Path(temp_dir) / "custom_dataset.json"
            dataset_path.write_text("[]", encoding="utf-8")

            with patch.dict(os.environ, {"DATASET_SOURCE_PATH": str(dataset_path)}, clear=False):
                reloaded = reload(kaggle_pipeline)
                self.assertEqual(reloaded.DATASET_SOURCE_PATH, dataset_path.resolve())

            reload(kaggle_pipeline)


if __name__ == "__main__":
    unittest.main()
