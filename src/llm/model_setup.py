"""Select an installed Ollama model and persist it as a BatLLM preference."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import sys
from collections.abc import Iterable

from configs.app_config import config
from llm import service as ollama_service


class ModelSetupError(RuntimeError):
    """Raised when a safe model selection cannot be made."""


@dataclass(frozen=True)
class ModelSelection:
    model: str
    reason: str


def _inventory(models: Iterable[str]) -> list[str]:
    """Return unique, non-empty model names without changing their spelling."""
    result = []
    seen = set()
    for item in models:
        if not isinstance(item, str):
            continue
        name = item.strip()
        key = name.casefold()
        if name and key not in seen:
            result.append(name)
            seen.add(key)
    return result


def _family(name: str) -> str:
    """Return the model family without registry path or tag."""
    return name.rsplit("/", 1)[-1].split(":", 1)[0].casefold()


def _match_installed(
    candidate: str,
    installed: list[str],
    *,
    allow_family: bool,
) -> str | None:
    """Resolve an exact name, an implicit latest tag, or one unique family tag."""
    candidate = str(candidate or "").strip()
    if not candidate:
        return None

    by_name = {name.casefold(): name for name in installed}
    exact = by_name.get(candidate.casefold())
    if exact:
        return exact

    last_component = candidate.rsplit("/", 1)[-1]
    if ":" not in last_component:
        latest = by_name.get((candidate + ":latest").casefold())
        if latest:
            return latest
        if allow_family:
            matches = [name for name in installed if _family(name) == _family(candidate)]
            if len(matches) == 1:
                return matches[0]
    return None


def resolve_model(
    installed_models: Iterable[str],
    configured_model: str = "",
    last_served_model: str = "",
    requested_model: str = "",
) -> ModelSelection | None:
    """Choose deterministically, returning None only when user choice is needed."""
    installed = _inventory(installed_models)
    if not installed:
        raise ModelSetupError("No local Ollama models were found.")

    if requested_model:
        try:
            requested = ollama_service.validate_model_name(requested_model)
        except ValueError as exc:
            raise ModelSetupError(str(exc)) from exc
        match = _match_installed(requested, installed, allow_family=False)
        if not match:
            raise ModelSetupError(
                f"Requested model {requested!r} is not installed. "
                "Use the exact local model name, including its tag."
            )
        return ModelSelection(match, "explicit")

    match = _match_installed(configured_model, installed, allow_family=True)
    if match:
        reason = "configured model" if match.casefold() == configured_model.strip().casefold() else "configured model family"
        return ModelSelection(match, reason)

    match = _match_installed(last_served_model, installed, allow_family=True)
    if match:
        return ModelSelection(match, "last served model")

    if len(installed) == 1:
        return ModelSelection(installed[0], "only installed model")
    return None


def persist_model(model: str, preferences=config) -> bool:
    """Save only llm.model through the guarded atomic user-preference writer."""
    selected = str(model or "").strip()
    if not selected:
        raise ModelSetupError("A model must be selected before saving.")
    current = str(preferences.get("llm", "model") or "").strip()
    if current == selected:
        return False
    preferences.set("llm", "model", selected)
    preferences.save()
    return True


def _prompt_for_model(models: list[str]) -> str:
    print("Select an installed model:")
    for index, name in enumerate(models, start=1):
        print(f"  {index}. {name}")
    while True:
        answer = input("Model number (or q to cancel): ").strip()
        if answer.casefold() in {"q", "quit", "cancel"}:
            raise ModelSetupError("Model selection cancelled; configuration was not changed.")
        try:
            selected = int(answer)
        except ValueError:
            selected = 0
        if 1 <= selected <= len(models):
            return models[selected - 1]
        print(f"Enter a number from 1 to {len(models)}, or q to cancel.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Select an installed Ollama model for BatLLM without downloading or starting it."
    )
    parser.add_argument(
        "--model",
        default="",
        help="select this exact installed model name (including its tag)",
    )
    parser.add_argument(
        "--non-interactive",
        action="store_true",
        help="fail instead of prompting when several models are equally eligible",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        installed = _inventory(ollama_service.list_local_models())
    except Exception as exc:  # The configured local API is an external prerequisite.
        print(f"ERROR: Could not read the configured Ollama model inventory: {exc}", file=sys.stderr)
        return 2

    configured = str(config.get("llm", "model") or "").strip()
    last_served = str(config.get("llm", "last_served_model") or "").strip()
    print("BatLLM Model Setup")
    print("Installed models:")
    if installed:
        for name in installed:
            print(f"  - {name}")
    else:
        print("  (none)")
    print(f"Configured model: {configured or '(not set)'}")

    try:
        selection = resolve_model(installed, configured, last_served, args.model)
        if selection is None:
            if args.non_interactive or not sys.stdin.isatty():
                choices = ", ".join(installed)
                raise ModelSetupError(
                    "Several local models are available and no existing preference matches. "
                    f"Choose one with -Model / --model. Available: {choices}"
                )
            selection = ModelSelection(_prompt_for_model(installed), "manual selection")
        changed = persist_model(selection.model)
    except ModelSetupError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        print(f"ERROR: Could not save the user configuration: {exc}", file=sys.stderr)
        return 3

    print(f"Selected model: {selection.model} ({selection.reason})")
    print(f"Configuration: {'updated' if changed else 'unchanged'}")
    print("No model was downloaded, warmed up, started, stopped or unloaded.")
    print("Next: .\\scripts\\windows\\batllm-doctor.ps1 -Target Gameplay -Model " + selection.model)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
