from __future__ import annotations

from copy import deepcopy
import json
from types import SimpleNamespace

import pytest

from configs.app_config import config
from game.ollama_connector import LLMRequestError, OllamaConnector


def _build_connector(
    monkeypatch: pytest.MonkeyPatch,
    *,
    independent_contexts: bool = False,
    augmenting_prompt: bool = False,
):
    """Create a connector whose client captures requests without network access."""
    config.set_temporary("game", "independent_contexts", independent_contexts)
    config.set_temporary("game", "prompt_augmentation", augmenting_prompt)

    calls = []

    def fake_chat(**kwargs):
        calls.append(deepcopy(kwargs))
        return SimpleNamespace(
            message=SimpleNamespace(content=f"assistant-{len(calls)}")
        )

    monkeypatch.setattr(
        "game.ollama_connector.Client",
        lambda *_args, **_kwargs: SimpleNamespace(chat=fake_chat),
    )
    connector = OllamaConnector()
    monkeypatch.setattr(
        connector,
        "_get_system_instructions_text",
        lambda: "AUDIT SYSTEM",
    )
    return connector, calls


def _system_message():
    return {"role": "system", "content": "AUDIT SYSTEM"}


def _user_message(content: str):
    return {"role": "user", "content": content}


def _assistant_message(content: str):
    return {"role": "assistant", "content": content}


def test_shared_context_payload_contains_both_bots_in_call_order(monkeypatch):
    connector, calls = _build_connector(monkeypatch, independent_contexts=False)

    assert connector.send_prompt_to_llm_sync(
        1, user_text="bot-1 first", game_state={}
    ) == "assistant-1"
    assert connector.send_prompt_to_llm_sync(
        2, user_text="bot-2 first", game_state={}
    ) == "assistant-2"
    assert connector.send_prompt_to_llm_sync(
        1, user_text="bot-1 second", game_state={}
    ) == "assistant-3"

    assert calls[0]["messages"] == [
        _system_message(),
        _user_message("bot-1 first"),
    ]
    assert calls[1]["messages"] == [
        _system_message(),
        _user_message("bot-1 first"),
        _assistant_message("assistant-1"),
        _user_message("bot-2 first"),
    ]
    assert calls[2]["messages"] == [
        _system_message(),
        _user_message("bot-1 first"),
        _assistant_message("assistant-1"),
        _user_message("bot-2 first"),
        _assistant_message("assistant-2"),
        _user_message("bot-1 second"),
    ]

    for call in calls:
        assert call["model"] == connector.model
        assert call["stream"] is False
        assert isinstance(call["options"], dict)
        assert all(set(message) == {"role", "content"} for message in call["messages"])


def test_independent_context_payload_does_not_cross_between_bots(monkeypatch):
    connector, calls = _build_connector(monkeypatch, independent_contexts=True)

    connector.send_prompt_to_llm_sync(1, user_text="bot-1 first", game_state={})
    connector.send_prompt_to_llm_sync(2, user_text="bot-2 first", game_state={})
    connector.send_prompt_to_llm_sync(1, user_text="bot-1 second", game_state={})

    assert calls[0]["messages"] == [
        _system_message(),
        _user_message("bot-1 first"),
    ]
    assert calls[1]["messages"] == [
        _system_message(),
        _user_message("bot-2 first"),
    ]
    assert calls[2]["messages"] == [
        _system_message(),
        _user_message("bot-1 first"),
        _assistant_message("assistant-1"),
        _user_message("bot-1 second"),
    ]
    assert set(connector._history_by_bot) == {1, 2}
    assert connector._history_by_bot[1] is not connector._history_by_bot[2]


def test_augmented_prompt_serializes_state_and_player_input_exactly(monkeypatch):
    connector, calls = _build_connector(
        monkeypatch,
        independent_contexts=True,
        augmenting_prompt=True,
    )
    state = {"round": 2, "label": "niño", "players": [1, 2]}

    connector.send_prompt_to_llm_sync(
        1,
        user_text="Move to C90",
        game_state=state,
    )

    expected_state = json.dumps(
        state,
        separators=(",", ":"),
        ensure_ascii=False,
    )
    assert calls[0]["messages"][-1] == _user_message(
        f"[GAME_STATE]\n{expected_state}\n[PLAYER_INPUT]\nMove to C90"
    )


def test_explicit_reset_discards_previous_shared_conversation(monkeypatch):
    connector, calls = _build_connector(monkeypatch, independent_contexts=False)

    connector.send_prompt_to_llm_sync(1, user_text="old prompt", game_state={})
    connector.send_prompt_to_llm_sync(
        2,
        user_text="new prompt",
        game_state={},
        reset=True,
    )

    assert calls[1]["messages"] == [
        _system_message(),
        _user_message("new prompt"),
    ]


def test_non_timeout_request_failure_removes_unanswered_user_message(monkeypatch):
    config.set_temporary("game", "independent_contexts", False)
    config.set_temporary("game", "prompt_augmentation", False)
    captured = []

    def fail_chat(**kwargs):
        captured.append(deepcopy(kwargs))
        raise ValueError("simulated transport failure")

    monkeypatch.setattr(
        "game.ollama_connector.Client",
        lambda *_args, **_kwargs: SimpleNamespace(chat=fail_chat),
    )
    connector = OllamaConnector()
    monkeypatch.setattr(
        connector,
        "_get_system_instructions_text",
        lambda: "AUDIT SYSTEM",
    )

    with pytest.raises(LLMRequestError) as error:
        connector.send_prompt_to_llm_sync(
            1,
            user_text="must be rolled back",
            game_state={},
        )

    assert isinstance(error.value.original_exception, ValueError)
    assert captured[0]["messages"] == [
        _system_message(),
        _user_message("must be rolled back"),
    ]
    history = connector._get_history_ref(1)
    assert history == [_system_message()]


def test_timeout_retry_reuses_same_payload_without_duplicate_user_message(monkeypatch):
    config.set_temporary("game", "independent_contexts", False)
    config.set_temporary("game", "prompt_augmentation", False)
    payloads = []

    def retry_chat(**kwargs):
        payloads.append(deepcopy(kwargs["messages"]))
        if len(payloads) == 1:
            raise TimeoutError("simulated timeout")
        return SimpleNamespace(message=SimpleNamespace(content="M"))

    monkeypatch.setattr(
        "game.ollama_connector.Client",
        lambda *_args, **_kwargs: SimpleNamespace(chat=retry_chat),
    )
    connector = OllamaConnector()
    monkeypatch.setattr(
        connector,
        "_get_system_instructions_text",
        lambda: "AUDIT SYSTEM",
    )

    assert connector.send_prompt_to_llm_sync(
        1,
        user_text="Reply with exactly M",
        game_state={},
    ) == "M"

    assert len(payloads) == 2
    assert payloads[0] == payloads[1]
    assert [message["role"] for message in payloads[1]].count("user") == 1
    assert connector._get_history_ref(1)[-1] == _assistant_message("M")
