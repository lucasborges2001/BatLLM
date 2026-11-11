"""Opt-in live integration smoke for the real gameplay OllamaConnector.

This test uses an already-running Ollama endpoint and an already-installed model.
It never starts/stops the service, downloads/deletes models, or persists settings.
"""
from __future__ import annotations

import os

import pytest

from configs.app_config import config
from game.ollama_connector import OllamaConnector
from llm import service as ollama_service


RUN_LIVE = os.environ.get("BATLLM_RUN_OLLAMA_CONNECTOR_LIVE") == "1"
pytestmark = pytest.mark.skipif(
    not RUN_LIVE,
    reason="Set BATLLM_RUN_OLLAMA_CONNECTOR_LIVE=1 to run the live Connector smoke test.",
)


def _model_is_installed(requested: str, installed: list[str]) -> bool:
    if requested in installed:
        return True
    return ":" not in requested and f"{requested}:latest" in installed


def test_live_connector_sends_two_messages_and_retains_conversation() -> None:
    model = str(
        os.environ.get("BATLLM_LIVE_MODEL") or config.get("llm", "model") or ""
    ).strip()
    url = str(
        os.environ.get("BATLLM_LIVE_URL") or config.get("llm", "url") or "http://localhost"
    ).rstrip("/")
    port_value = os.environ.get("BATLLM_LIVE_PORT") or config.get("llm", "port") or 11434

    if not model:
        pytest.fail("No model configured. Pass -Model or configure llm.model.")

    try:
        port = int(port_value)
    except (TypeError, ValueError):
        pytest.fail(f"Invalid Ollama port: {port_value!r}")

    if not 1 <= port <= 65535:
        pytest.fail(f"Ollama port is outside the valid TCP range: {port}")

    timeout_value = os.environ.get("BATLLM_LIVE_TIMEOUT")
    if timeout_value:
        try:
            timeout = float(timeout_value)
        except ValueError:
            pytest.fail(f"Invalid request timeout: {timeout_value!r}")
        if timeout <= 0:
            pytest.fail("Request timeout must be positive.")
        config.set_temporary("llm", "timeout", timeout)

    try:
        installed_models = ollama_service.list_local_models(url=url, port=port)
    except Exception as exc:
        pytest.fail(
            f"Cannot query the existing Ollama endpoint {url}:{port}: "
            f"{type(exc).__name__}: {exc}",
            pytrace=False,
        )

    if not _model_is_installed(model, installed_models):
        pytest.fail(
            f"Model {model!r} is not installed at {url}:{port}. "
            f"Installed models: {installed_models}. No download was attempted."
        )

    # All changes are execution-only overrides. The test conftest also isolates
    # BATLLM_HOME, so this smoke test cannot write into the user's preferences.
    config.set_temporary("llm", "model", model)
    config.set_temporary("llm", "url", url)
    config.set_temporary("llm", "port", port)
    config.set_temporary("llm", "last_served_model", model)
    config.set_temporary("game", "independent_contexts", True)
    config.set_temporary("game", "prompt_augmentation", False)

    connector = OllamaConnector()
    first_prompt = "Reply with exactly M"
    second_prompt = "Reply with exactly S0"

    first_response = connector.send_prompt_to_llm_sync(
        1, user_text=first_prompt, game_state={}
    )
    assert isinstance(first_response, str) and first_response.strip()

    history = connector._get_history_ref(1)
    assert [message["role"] for message in history] == [
        "system", "user", "assistant"
    ]
    assert history[1]["content"] == first_prompt
    assert history[2]["content"] == first_response

    second_response = connector.send_prompt_to_llm_sync(
        1, user_text=second_prompt, game_state={}
    )
    assert isinstance(second_response, str) and second_response.strip()

    history = connector._get_history_ref(1)
    assert [message["role"] for message in history] == [
        "system", "user", "assistant", "user", "assistant"
    ]
    assert history[1]["content"] == first_prompt
    assert history[2]["content"] == first_response
    assert history[3]["content"] == second_prompt
    assert history[4]["content"] == second_response

    print(
        "OllamaConnector live smoke: "
        f"model={model} endpoint={url}:{port} "
        f"response_lengths={len(first_response)},{len(second_response)}"
    )
