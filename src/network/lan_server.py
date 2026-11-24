"""Small two-player HTTP server for local-network BatLLM games."""

from __future__ import annotations

import json
import secrets
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from kivy.clock import Clock

from configs.app_config import config


MAX_PROMPT_LENGTH = 4000
MAX_REQUEST_BYTES = 16 * 1024
WEB_ROOT = Path(__file__).resolve().parent / "web"


class LanRequestError(Exception):
    """An expected HTTP error raised while handling a player request."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


class GameBridge:
    """Run all GameBoard reads and writes on Kivy's main thread."""

    def __init__(self, board_provider, *, schedule_once=None, timeout: float = 5.0):
        self._board_provider = board_provider
        self._schedule_once = schedule_once or Clock.schedule_once
        self._timeout = timeout

    def _call(self, operation):
        completed = threading.Event()
        result = {}

        def invoke(_dt):
            try:
                result["value"] = operation(self._board_provider())
            except Exception as exc:
                result["error"] = exc
            finally:
                completed.set()

        self._schedule_once(invoke, 0)
        if not completed.wait(self._timeout):
            raise LanRequestError(503, "El motor del juego no respondió a tiempo.")
        if "error" in result:
            error = result["error"]
            if isinstance(error, LanRequestError):
                raise error
            raise LanRequestError(503, "No se pudo consultar el estado del juego.") from error
        return result["value"]

    def snapshot(self, player_id: int) -> dict:
        def read(board):
            bots = sorted(board.bots, key=lambda bot: int(bot.id))
            if len(bots) != 2:
                raise RuntimeError("The game board is not ready.")

            active_round = board.history_manager.current_round is not None
            rules = board.current_round_settings
            turns_per_round = int(
                getattr(rules, "turns_per_round", None)
                or config.get("game", "turns_per_round")
                or 1
            )
            total_rounds = int(
                getattr(rules, "total_rounds", None)
                or config.get("game", "total_rounds")
                or 1
            )
            bot_states = []
            players = []
            for bot in bots:
                bot_id = int(bot.id)
                ready = bool(getattr(bot, "ready_for_next_round", False))
                bot_states.append({
                    "id": bot_id,
                    "x": float(bot.x),
                    "y": float(bot.y),
                    "rot": float(bot.rot),
                    "health": int(bot.health),
                    "shield": bool(bot.shield),
                    "last_cmd": str(getattr(bot, "last_cmd", "") or ""),
                })
                players.append({"id": bot_id, "ready": ready})

            return {
                "game": int(board.games_started),
                "round": int(board.current_round),
                "turn": int(board.current_turn),
                "turns_per_round": turns_per_round,
                "total_rounds": total_rounds,
                "round_active": active_round,
                "phase": "running" if active_round else "waiting_prompts",
                "model": str(getattr(board.ollama_connector, "model", "") or ""),
                "player_id": player_id,
                "players": players,
                "bots": bot_states,
            }

        return self._call(read)

    def submit_prompt(self, player_id: int, prompt: str) -> dict:
        def submit(board):
            bot = board.get_bot_by_id(player_id)
            if bot is None:
                raise LanRequestError(503, "El jugador no está disponible.")
            if board.history_manager.current_round is not None:
                raise LanRequestError(409, "La ronda ya está en ejecución.")
            if bool(getattr(bot, "ready_for_next_round", False)):
                raise LanRequestError(409, "Ya enviaste tu prompt para esta ronda.")
            if not board.submit_prompt_to_bot(player_id, prompt):
                raise LanRequestError(409, "No se pudo aceptar el prompt.")
            return {
                "accepted": True,
                "waiting_for_opponent": board.history_manager.current_round is None,
            }

        return self._call(submit)


class LanServer:
    """Serve the web client and a single two-player game."""

    def __init__(
        self,
        *,
        board_provider,
        host: str = "0.0.0.0",
        port: int = 8765,
        advertise_host: str | None = None,
        web_root: Path = WEB_ROOT,
        schedule_once=None,
    ):
        self.host = host
        self.requested_port = port
        self.advertise_host = advertise_host or discover_lan_ip()
        self.web_root = Path(web_root)
        self._tokens = {
            1: secrets.token_urlsafe(24),
            2: secrets.token_urlsafe(24),
        }
        self._token_players = {token: player_id for player_id, token in self._tokens.items()}
        self._bridge = GameBridge(board_provider, schedule_once=schedule_once)
        self._httpd = None
        self._thread = None

    @property
    def port(self) -> int:
        if self._httpd is not None:
            return int(self._httpd.server_address[1])
        return self.requested_port

    @property
    def invitation_urls(self) -> dict[int, str]:
        base = f"http://{self.advertise_host}:{self.port}"
        return {
            player_id: f"{base}/play/{token}"
            for player_id, token in self._tokens.items()
        }

    def player_for_token(self, token: str) -> int | None:
        return self._token_players.get(token)

    def start(self):
        if self._httpd is not None:
            return self
        handler = self._make_handler()
        self._httpd = _LanHTTPServer((self.host, self.requested_port), handler)
        self._thread = threading.Thread(
            target=self._httpd.serve_forever,
            name="batllm-lan-http",
            daemon=True,
        )
        self._thread.start()
        return self

    def stop(self):
        if self._httpd is None:
            return
        self._httpd.shutdown()
        self._httpd.server_close()
        if self._thread is not None:
            self._thread.join(timeout=2)
        self._httpd = None
        self._thread = None

    def _make_handler(self):
        owner = self

        class Handler(BaseHTTPRequestHandler):
            server_version = "BatLLM-LAN"

            def log_message(self, _format, *_args):
                return

            def _send(self, status: int, body: bytes, content_type: str):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                self.wfile.write(body)

            def _json(self, status: int, payload: dict):
                body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
                self._send(status, body, "application/json; charset=utf-8")

            def _token_route(self):
                parts = urlsplit(self.path).path.strip("/").split("/")
                if len(parts) != 4 or parts[:2] != ["api", "v1"]:
                    return None, None
                token = parts[3]
                player_id = owner.player_for_token(token)
                if player_id is None:
                    return None, None
                return parts[2], player_id

            def do_GET(self):
                path = urlsplit(self.path).path
                parts = path.strip("/").split("/")
                if len(parts) == 2 and parts[0] == "play":
                    if owner.player_for_token(parts[1]) is None:
                        self._json(403, {"error": "Enlace de invitación inválido."})
                        return
                    try:
                        body = (owner.web_root / "index.html").read_bytes()
                    except OSError:
                        self._json(500, {"error": "No se encontró la interfaz web."})
                        return
                    self._send(200, body, "text/html; charset=utf-8")
                    return

                route, player_id = self._token_route()
                if route == "state":
                    try:
                        self._json(200, owner._bridge.snapshot(player_id))
                    except LanRequestError as exc:
                        self._json(exc.status, {"error": str(exc)})
                    return
                self._json(404, {"error": "Ruta no encontrada."})

            def do_POST(self):
                route, player_id = self._token_route()
                if route != "prompts":
                    self._json(404, {"error": "Ruta no encontrada."})
                    return

                try:
                    length = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    self._json(400, {"error": "Content-Length inválido."})
                    return
                if length <= 0:
                    self._json(400, {"error": "Falta el cuerpo de la solicitud."})
                    return
                if length > MAX_REQUEST_BYTES:
                    self._json(413, {"error": "Solicitud demasiado grande."})
                    return

                try:
                    payload = json.loads(self.rfile.read(length).decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    self._json(400, {"error": "JSON inválido."})
                    return
                if not isinstance(payload, dict):
                    self._json(400, {"error": "El cuerpo debe ser un objeto JSON."})
                    return

                prompt = payload.get("prompt")
                if not isinstance(prompt, str) or not prompt.strip():
                    self._json(400, {"error": "El prompt no puede estar vacío."})
                    return
                prompt = prompt.strip()
                if len(prompt) > MAX_PROMPT_LENGTH:
                    self._json(413, {"error": f"El prompt supera {MAX_PROMPT_LENGTH} caracteres."})
                    return

                try:
                    result = owner._bridge.submit_prompt(player_id, prompt)
                except LanRequestError as exc:
                    self._json(exc.status, {"error": str(exc)})
                    return
                self._json(200, result)

        return Handler


class _LanHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def discover_lan_ip() -> str:
    """Return the IPv4 address selected for outbound LAN traffic."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 80))
        address = probe.getsockname()[0]
        if address and not address.startswith("127."):
            return address
    except OSError:
        pass
    finally:
        probe.close()

    try:
        addresses = socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
    except OSError:
        addresses = []
    for entry in addresses:
        address = entry[4][0]
        if not address.startswith("127."):
            return address
    return "127.0.0.1"
