"""Regression tests for maintained-document discovery."""

from __future__ import annotations

import importlib.util
from pathlib import Path


def test_markdown_files_skips_virtualenv_and_generated_docs(tmp_path, monkeypatch):
    """Installed package READMEs must never be mistaken for project docs."""
    path = Path(__file__).resolve().parents[2] / "tools" / "check_docs.py"
    spec = importlib.util.spec_from_file_location("batllm_check_docs_test", path)
    assert spec is not None and spec.loader is not None
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    monkeypatch.setattr(checker, "ROOT", tmp_path)

    kept = tmp_path / "docs" / "WINDOWS_APPLY.md"
    ignored_venv = tmp_path / ".venv_BatLLM" / "Lib" / "site-packages" / "pkg" / "NOTICE.md"
    ignored_generated = tmp_path / "docs" / "code" / "api.md"
    for item in (kept, ignored_venv, ignored_generated):
        item.parent.mkdir(parents=True, exist_ok=True)
        item.write_text("Example", encoding="utf-8")

    assert checker.markdown_files() == [kept]
