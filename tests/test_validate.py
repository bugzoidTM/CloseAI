from __future__ import annotations

import unittest

from validate import check_python_syntax, extract_python_code


class ValidateTests(unittest.TestCase):
    def test_extracts_fenced_python_code(self) -> None:
        text = "Resposta:\n```python\nprint('ok')\n```"
        self.assertEqual(extract_python_code(text), "print('ok')")

    def test_accepts_valid_code(self) -> None:
        is_valid, error = check_python_syntax("```python\nx = 1\n```")
        self.assertTrue(is_valid)
        self.assertEqual(error, "")

    def test_rejects_invalid_code(self) -> None:
        is_valid, error = check_python_syntax("def broken(:\n    pass")
        self.assertFalse(is_valid)
        self.assertIn("linha 1", error)


if __name__ == "__main__":
    unittest.main()
