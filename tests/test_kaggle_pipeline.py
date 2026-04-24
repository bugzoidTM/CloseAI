from __future__ import annotations

import unittest

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


if __name__ == "__main__":
    unittest.main()
