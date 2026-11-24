"""Start BatLLM with a two-player LAN web client."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"

if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from util.compat import require_supported_python  # noqa: E402

require_supported_python("BatLLM")

from kivy.clock import Clock  # noqa: E402
from kivy.config import Config  # noqa: E402
from kivy.core.window import Window  # noqa: E402
from main import BatLLM  # noqa: E402
from network.lan_server import LanServer  # noqa: E402


class LanBatLLM(BatLLM):
    """Run the existing desktop game and expose it to two LAN players."""

    def __init__(self, *, port: int = 8765, **kwargs):
        super().__init__(**kwargs)
        self._lan_port = port
        self._lan_server = None

    def on_start(self):
        super().on_start()
        try:
            home = self.root.get_screen("home")
            self._lan_server = LanServer(
                board_provider=home.get_game_board,
                port=self._lan_port,
            ).start()
        except OSError as exc:
            print(f"BatLLM LAN: no se pudo iniciar el servidor: {exc}")
            Clock.schedule_once(lambda _dt: self.stop(), 0)
            return

        urls = self._lan_server.invitation_urls
        print("\nBatLLM Online LAN")
        print(f"Servidor: http://{self._lan_server.advertise_host}:{self._lan_server.port}")
        print(f"Jugador 1: {urls[1]}")
        print(f"Jugador 2: {urls[2]}")
        print("Compartí cada enlace con un jugador de la misma red local.\n")

    def on_stop(self):
        if self._lan_server is not None:
            self._lan_server.stop()
            self._lan_server = None
        super().on_stop()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Start a two-player BatLLM LAN game")
    parser.add_argument("--port", type=int, default=8765, help="HTTP port (default: 8765)")
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")

    Config.set("kivy", "log_level", "error")
    Config.write()
    if hasattr(Window, "maximize"):
        Window.maximize()
    LanBatLLM(port=args.port).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
