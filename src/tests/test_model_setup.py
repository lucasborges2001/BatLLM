from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

import pytest

from configs.app_config import AppConfig, SHIPPED_CONFIG_PATH, config
from llm import model_setup


def test_configured_exact_model_is_preserved() -> None:
    selection = model_setup.resolve_model(
        ["smollm2:360m", "llama3:latest"], "smollm2:360m", ""
    )
    assert selection == model_setup.ModelSelection("smollm2:360m", "configured model")


def test_untagged_config_uses_one_installed_family_variant() -> None:
    selection = model_setup.resolve_model(
        ["smollm2:360m", "llama3:latest"], "smollm2", ""
    )
    assert selection == model_setup.ModelSelection("smollm2:360m", "configured model family")


def test_ambiguous_configured_family_requires_a_choice() -> None:
    selection = model_setup.resolve_model(
        ["smollm2:360m", "smollm2:1.7b", "llama3:latest"], "smollm2", ""
    )
    assert selection is None


def test_last_served_model_is_used_when_configured_model_is_missing() -> None:
    selection = model_setup.resolve_model(
        ["llama3:latest", "qwen3:8b"], "missing-model", "qwen3:8b"
    )
    assert selection == model_setup.ModelSelection("qwen3:8b", "last served model")


def test_single_installed_model_is_selected_automatically() -> None:
    selection = model_setup.resolve_model(["smollm2:360m"], "smollm2", "")
    assert selection == model_setup.ModelSelection("smollm2:360m", "configured model family")


def test_single_installed_model_is_fallback_when_preferences_are_missing() -> None:
    selection = model_setup.resolve_model(["smollm2:360m"], "missing", "")
    assert selection == model_setup.ModelSelection("smollm2:360m", "only installed model")


def test_multiple_unmatched_models_are_not_guessed() -> None:
    assert model_setup.resolve_model(
        ["llama3:latest", "qwen3:8b"], "missing", ""
    ) is None


def test_explicit_model_requires_an_installed_exact_name() -> None:
    with pytest.raises(model_setup.ModelSetupError, match="not installed"):
        model_setup.resolve_model(["smollm2:360m"], requested_model="smollm2")


def test_explicit_model_accepts_exact_installed_tag() -> None:
    selection = model_setup.resolve_model(
        ["smollm2:360m"], requested_model="smollm2:360m"
    )
    assert selection == model_setup.ModelSelection("smollm2:360m", "explicit")


def test_empty_inventory_fails_without_guessing() -> None:
    with pytest.raises(model_setup.ModelSetupError, match="No local Ollama models"):
        model_setup.resolve_model([], "smollm2", "")


def test_inventory_is_deduplicated_without_changing_model_names() -> None:
    selection = model_setup.resolve_model(
        ["smollm2:360m", " smollm2:360m ", "SMOLLM2:360M"], "missing", ""
    )
    assert selection == model_setup.ModelSelection("smollm2:360m", "only installed model")


def test_persist_updates_only_user_model_preference_and_preserves_other_values() -> None:
    shipped_before = SHIPPED_CONFIG_PATH.read_bytes()
    config.set("llm", "last_served_model", "previous:latest")
    config.set("custom", "keep", "value")

    changed = model_setup.persist_model("smollm2:360m", config)

    saved = AppConfig(path=config._path)
    assert changed is True
    assert saved.get("llm", "model") == "smollm2:360m"
    assert saved.get("llm", "last_served_model") == "previous:latest"
    assert saved.get("custom", "keep") == "value"
    assert SHIPPED_CONFIG_PATH.read_bytes() == shipped_before


def test_persist_does_not_write_when_model_is_already_configured(monkeypatch) -> None:
    config.set("llm", "model", "smollm2:360m")
    monkeypatch.setattr(config, "save", lambda: pytest.fail("unexpected config write"))
    assert model_setup.persist_model("smollm2:360m", config) is False


def test_non_interactive_main_auto_selects_single_model(monkeypatch, capsys) -> None:
    config.set("llm", "model", "smollm2")
    config.set("llm", "last_served_model", "")
    monkeypatch.setattr(model_setup.ollama_service, "list_local_models", lambda: ["smollm2:360m"])

    assert model_setup.main(["--non-interactive"]) == 0
    assert config.get("llm", "model") == "smollm2:360m"
    output = capsys.readouterr().out
    assert "Selected model: smollm2:360m" in output
    assert "Configuration: updated" in output
    assert "No model was downloaded" in output


def test_non_interactive_main_does_not_guess_between_multiple_models(monkeypatch, capsys) -> None:
    config.set("llm", "model", "missing-model")
    config.set("llm", "last_served_model", "")
    monkeypatch.setattr(
        model_setup.ollama_service,
        "list_local_models",
        lambda: ["llama3:latest", "qwen3:8b"],
    )

    assert model_setup.main(["--non-interactive"]) == 2
    assert config.get("llm", "model") == "missing-model"
    assert "Choose one with -Model / --model" in capsys.readouterr().err


def test_api_failure_does_not_change_configuration(monkeypatch, capsys) -> None:
    config.set("llm", "model", "smollm2")
    monkeypatch.setattr(
        model_setup.ollama_service,
        "list_local_models",
        lambda: (_ for _ in ()).throw(ConnectionError("offline")),
    )

    assert model_setup.main(["--non-interactive"]) == 2
    assert config.get("llm", "model") == "smollm2"
    assert "offline" in capsys.readouterr().err


def test_module_cli_accepts_explicit_model_without_inherited_kivy_no_args() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env.pop("KIVY_NO_ARGS", None)
    env["KIVY_WINDOW"] = "mock"
    env["KIVY_NO_CONSOLELOG"] = "1"
    source_path = str(repo_root / "src")
    env["PYTHONPATH"] = os.pathsep.join(
        item for item in (source_path, env.get("PYTHONPATH", "")) if item
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "llm.model_setup",
            "--model",
            "smollm2:360m",
            "--help",
        ],
        cwd=repo_root,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Select an installed Ollama model" in result.stdout
    assert "--model" in result.stdout
