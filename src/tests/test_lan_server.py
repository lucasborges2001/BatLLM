from __future__ import annotations

import json
from types import SimpleNamespace
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

from network.lan_server import LanServer, MAX_PROMPT_LENGTH


class FakeBoard:
    def __init__(self):
        self.bots = [
            SimpleNamespace(
                id=1, x=0.2, y=0.3, rot=0.0, health=30, shield=True,
                ready_for_next_round=False, last_cmd="",
            ),
            SimpleNamespace(
                id=2, x=0.8, y=0.7, rot=180.0, health=30, shield=False,
                ready_for_next_round=False, last_cmd="",
            ),
        ]
        self.games_started = 1
        self.current_round = 0
        self.current_turn = 0
        self.current_round_settings = SimpleNamespace(turns_per_round=8, total_rounds=2)
        self.history_manager = SimpleNamespace(current_round=None)
        self.ollama_connector = SimpleNamespace(model="smollm2")

    def get_bot_by_id(self, bot_id):
        return next((bot for bot in self.bots if bot.id == bot_id), None)

    def submit_prompt_to_bot(self, bot_id, prompt):
        if self.history_manager.current_round is not None:
            return False
        bot = self.get_bot_by_id(bot_id)
        if bot.ready_for_next_round:
            return False
        bot.current_prompt = prompt
        bot.ready_for_next_round = True
        if all(item.ready_for_next_round for item in self.bots):
            self.current_round += 1
            self.history_manager.current_round = {"round": self.current_round}
        return True


def immediate_schedule(callback, _timeout):
    callback(0)


@pytest.fixture
def lan_server():
    board = FakeBoard()
    server = LanServer(
        board_provider=lambda: board,
        host="127.0.0.1",
        port=0,
        advertise_host="127.0.0.1",
        schedule_once=immediate_schedule,
    ).start()
    try:
        yield server, board
    finally:
        server.stop()


def read_json(url, *, method="GET", payload=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if data is not None else {},
    )
    with urlopen(request, timeout=3) as response:
        return response.status, json.loads(response.read().decode("utf-8"))


def test_invitation_links_serve_web_client_and_player_state(lan_server):
    server, _board = lan_server
    player_url = server.invitation_urls[1]

    with urlopen(player_url, timeout=3) as response:
        page = response.read().decode("utf-8")
        assert response.status == 200
        assert "BatLLM Online" in page

    status, state = read_json(
        f"http://127.0.0.1:{server.port}/api/v1/state/{server._tokens[1]}"
    )
    assert status == 200
    assert state["player_id"] == 1
    assert state["phase"] == "waiting_prompts"
    assert len(state["bots"]) == 2

    with pytest.raises(HTTPError) as error:
        urlopen(f"http://127.0.0.1:{server.port}/play/not-a-token", timeout=3)
    assert error.value.code == 403


def test_two_player_prompts_start_one_shared_round(lan_server):
    server, board = lan_server
    player_one = server._tokens[1]
    player_two = server._tokens[2]

    status, first = read_json(
        f"http://127.0.0.1:{server.port}/api/v1/prompts/{player_one}",
        method="POST",
        payload={"prompt": "Move forward."},
    )
    assert status == 200
    assert first == {"accepted": True, "waiting_for_opponent": True}
    assert board.history_manager.current_round is None

    with pytest.raises(HTTPError) as duplicate:
        read_json(
            f"http://127.0.0.1:{server.port}/api/v1/prompts/{player_one}",
            method="POST",
            payload={"prompt": "A second prompt."},
        )
    assert duplicate.value.code == 409

    status, second = read_json(
        f"http://127.0.0.1:{server.port}/api/v1/prompts/{player_two}",
        method="POST",
        payload={"prompt": "Keep the shield up."},
    )
    assert status == 200
    assert second == {"accepted": True, "waiting_for_opponent": False}
    assert board.history_manager.current_round == {"round": 1}


def test_prompt_validation_rejects_empty_and_oversized_content(lan_server):
    server, _board = lan_server
    token = server._tokens[1]
    endpoint = f"http://127.0.0.1:{server.port}/api/v1/prompts/{token}"

    with pytest.raises(HTTPError) as empty:
        read_json(endpoint, method="POST", payload={"prompt": "  "})
    assert empty.value.code == 400

    with pytest.raises(HTTPError) as oversized:
        read_json(
            endpoint,
            method="POST",
            payload={"prompt": "x" * (MAX_PROMPT_LENGTH + 1)},
        )
    assert oversized.value.code == 413
