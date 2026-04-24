from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import server


class ServerProxyTests(unittest.TestCase):
    def test_generate_request_accepts_validate_alias(self) -> None:
        payload = server.GenerateRequest(prompt="teste", validate=False)
        self.assertFalse(payload.validate_syntax)

    def test_health_reports_llama_server_backend(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            model_path = Path(temp_dir) / "modelo_python.gguf"
            model_path.touch()

            with patch.dict(
                os.environ,
                {
                    "MODEL_PATH": str(model_path),
                    "LLAMA_SERVER_URL": "http://127.0.0.1:8080",
                },
                clear=False,
            ):
                with patch("server._llama_server_health", return_value=True):
                    data = server.health()

        self.assertEqual(data["backend"], "llama-server")
        self.assertTrue(data["ready"])
        self.assertEqual(data["llama_server_url"], "http://127.0.0.1:8080")

    def test_generate_code_uses_llama_server(self) -> None:
        payload = server.GenerateRequest(prompt="gere uma soma", max_tokens=32)
        response = Mock()
        response.raise_for_status.return_value = None
        response.json.return_value = {
            "choices": [
                {
                    "message": {
                        "content": "```python\ndef soma(a, b):\n    return a + b\n```"
                    }
                }
            ]
        }

        with patch.dict(
            os.environ,
            {
                "LLAMA_SERVER_URL": "http://127.0.0.1:8080",
                "LLAMA_SERVER_MODEL": "modelo_python.gguf",
            },
            clear=False,
        ):
            with patch("server.requests.post", return_value=response) as mock_post:
                code = server._generate_code(payload)

        self.assertIn("def soma", code)
        mock_post.assert_called_once()
        self.assertEqual(
            mock_post.call_args.args[0],
            "http://127.0.0.1:8080/v1/chat/completions",
        )
        self.assertEqual(
            mock_post.call_args.kwargs["json"]["model"],
            "modelo_python.gguf",
        )


if __name__ == "__main__":
    unittest.main()
