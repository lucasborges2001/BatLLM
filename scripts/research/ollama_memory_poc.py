#!/usr/bin/env python3
"""Run a controlled Ollama context-forwarding proof of concept.

This is an API-level research utility. It does not use BatLLM's
OllamaConnector/modelito integration and is deliberately separate from
Windows Doctor.
"""
from __future__ import annotations

import argparse
import json
import platform
import secrets
import sys
import time
import uuid
from datetime import datetime, timezone
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from typing import Any, Callable

DEFAULT_MODEL = "smollm2:360m"
DEFAULT_TRIALS = 3
DEFAULT_TEMPERATURE = 0.0
DEFAULT_SEED = 42
DEFAULT_NUM_PREDICT = 64

CONDITIONS = ("without_history", "with_history")


def _field(value: Any, name: str, default: Any = None) -> Any:
    """Read a field from either a mapping or an object."""
    if isinstance(value, dict):
        return value.get(name, default)
    return getattr(value, name, default)


def _json_safe(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return str(value)


def _response_content(response: Any) -> str:
    message = _field(response, "message")
    content = _field(message, "content", "")
    return "" if content is None else str(content)


def _response_metadata(response: Any) -> dict[str, Any]:
    fields = (
        "model",
        "created_at",
        "done",
        "done_reason",
        "total_duration",
        "load_duration",
        "prompt_eval_count",
        "prompt_eval_duration",
        "eval_count",
        "eval_duration",
    )
    return {
        name: _json_safe(_field(response, name))
        for name in fields
        if _field(response, name) is not None
    }


def build_prompts(identifier: str) -> tuple[str, str]:
    first_prompt = (
        "Memorizá este identificador para la próxima pregunta. "
        f"No lo inventes ni lo modifiques: {identifier}. "
        f"Respondé exactamente: RECIBIDO {identifier}."
    )
    second_prompt = (
        "¿Qué identificador te indiqué en el mensaje anterior? "
        "Respondé únicamente con el identificador exacto. "
        "Si no está en el contexto recibido, respondé NO DISPONIBLE."
    )
    return first_prompt, second_prompt


def build_second_messages(
    condition: str,
    first_prompt: str,
    first_response: str,
    second_prompt: str,
) -> list[dict[str, str]]:
    if condition == "without_history":
        return [{"role": "user", "content": second_prompt}]
    if condition == "with_history":
        return [
            {"role": "user", "content": first_prompt},
            {"role": "assistant", "content": first_response},
            {"role": "user", "content": second_prompt},
        ]
    raise ValueError(f"Unknown condition: {condition}")


def classify_response(condition: str, identifier: str, response: str) -> dict[str, Any]:
    identifier_found = identifier.casefold() in response.casefold()
    return {
        "identifier_found": identifier_found,
        "exact_identifier_only": response.strip() == identifier,
        "outcome": (
            "recalled" if identifier_found else "not_recalled"
        ) if condition == "with_history" else (
            "unexpected_recall" if identifier_found else "not_recalled"
        ),
    }


def ask(
    client: Any,
    model: str,
    messages: list[dict[str, str]],
    options: dict[str, Any],
) -> dict[str, Any]:
    started = time.perf_counter()
    response = client.chat(
        model=model,
        messages=messages,
        options=options,
        stream=False,
    )
    elapsed = time.perf_counter() - started
    return {
        "request_messages": [dict(message) for message in messages],
        "response": _response_content(response),
        "elapsed_seconds": round(elapsed, 3),
        "response_metadata": _response_metadata(response),
    }


def run_condition(
    client: Any,
    condition: str,
    model: str,
    options: dict[str, Any],
    identifier_factory: Callable[[], str] | None = None,
) -> dict[str, Any]:
    if condition not in CONDITIONS:
        raise ValueError(f"Unknown condition: {condition}")

    make_identifier = identifier_factory or (
        lambda: "BATLLM-" + secrets.token_hex(6).upper()
    )
    identifier = make_identifier()
    first_prompt, second_prompt = build_prompts(identifier)

    result: dict[str, Any] = {
        "condition": condition,
        "identifier": identifier,
        "status": "ERROR",
    }

    try:
        first = ask(
            client,
            model,
            [{"role": "user", "content": first_prompt}],
            options,
        )
        result["request_1"] = first
    except Exception as exc:  # Ollama/network errors belong in the report.
        result["error"] = f"request_1: {type(exc).__name__}: {exc}"
        return result

    try:
        second_messages = build_second_messages(
            condition,
            first_prompt,
            first["response"],
            second_prompt,
        )
        second = ask(client, model, second_messages, options)
        result["request_2"] = second
        result["analysis"] = classify_response(
            condition,
            identifier,
            second["response"],
        )
        result["status"] = "PASS"
    except Exception as exc:  # Keep a partial first-request result.
        result["error"] = f"request_2: {type(exc).__name__}: {exc}"

    return result


def run_experiment(
    client: Any,
    model: str = DEFAULT_MODEL,
    trials: int = DEFAULT_TRIALS,
    temperature: float = DEFAULT_TEMPERATURE,
    seed: int = DEFAULT_SEED,
    num_predict: int = DEFAULT_NUM_PREDICT,
    identifier_factory: Callable[[], str] | None = None,
) -> dict[str, Any]:
    if trials < 1:
        raise ValueError("trials must be at least 1")

    options = {
        "temperature": temperature,
        "seed": seed,
        "num_predict": num_predict,
    }
    make_identifier = identifier_factory or (
        lambda: "BATLLM-" + secrets.token_hex(6).upper()
    )

    started_at = datetime.now(timezone.utc).isoformat()
    trial_results = []

    for trial_number in range(1, trials + 1):
        order = (
            list(CONDITIONS)
            if trial_number % 2 == 1
            else list(reversed(CONDITIONS))
        )
        conditions: dict[str, Any] = {}
        for condition in order:
            conditions[condition] = run_condition(
                client=client,
                condition=condition,
                model=model,
                options=options,
                identifier_factory=make_identifier,
            )
        trial_results.append({
            "trial": trial_number,
            "execution_order": order,
            "conditions": conditions,
        })

    valid_pairs = [
        trial for trial in trial_results
        if all(
            trial["conditions"].get(condition, {}).get("status") == "PASS"
            for condition in CONDITIONS
        )
    ]
    without_history_recalled = sum(
        bool(trial["conditions"]["without_history"]["analysis"]["identifier_found"])
        for trial in valid_pairs
    )
    with_history_recalled = sum(
        bool(trial["conditions"]["with_history"]["analysis"]["identifier_found"])
        for trial in valid_pairs
    )
    paired_supported = sum(
        (
            not trial["conditions"]["without_history"]["analysis"]["identifier_found"]
            and trial["conditions"]["with_history"]["analysis"]["identifier_found"]
        )
        for trial in valid_pairs
    )
    strict_format_passes = sum(
        bool(trial["conditions"]["with_history"]["analysis"]["exact_identifier_only"])
        for trial in valid_pairs
    )
    error_count = sum(
        1
        for trial in trial_results
        for condition in CONDITIONS
        if trial["conditions"].get(condition, {}).get("status") != "PASS"
    )

    if not valid_pairs:
        conclusion = "INCOMPLETE"
    elif paired_supported == len(valid_pairs):
        conclusion = "SUPPORTED_ALL_VALID_PAIRS"
    elif paired_supported > 0:
        conclusion = "PARTIALLY_SUPPORTED"
    else:
        conclusion = "NOT_SUPPORTED"

    try:
        ollama_client_version = version("ollama")
    except PackageNotFoundError:
        ollama_client_version = "unknown"

    return {
        "schema_version": 1,
        "tool": "batllm-ollama-memory-poc",
        "run_id": str(uuid.uuid4()),
        "started_at_utc": started_at,
        "completed_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "Ollama API context forwarding; not BatLLM OllamaConnector integration",
        "environment": {
            "python": platform.python_version(),
            "platform": platform.platform(),
            "ollama_python_client": ollama_client_version,
        },
        "configuration": {
            "model": model,
            "trials": trials,
            "options": options,
            "order": "alternating A/B and B/A by trial",
        },
        "conditions": {
            "without_history": "Second request contains only the second user prompt.",
            "with_history": "Second request contains first user prompt, first assistant response, and second user prompt.",
        },
        "trials": trial_results,
        "summary": {
            "valid_pairs": len(valid_pairs),
            "requested_pairs": trials,
            "without_history_identifier_found": without_history_recalled,
            "with_history_identifier_found": with_history_recalled,
            "paired_hypothesis_supported": paired_supported,
            "with_history_exact_format_passes": strict_format_passes,
            "request_or_condition_errors": error_count,
            "conclusion": conclusion,
        },
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run an API-level Ollama context experiment. "
            "This does not modify BatLLM or run inside Windows Doctor."
        )
    )
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--trials", type=int, default=DEFAULT_TRIALS)
    parser.add_argument("--temperature", type=float, default=DEFAULT_TEMPERATURE)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--num-predict", type=int, default=DEFAULT_NUM_PREDICT)
    parser.add_argument(
        "--output",
        type=Path,
        help="Optional JSON report path. Without it, JSON is printed to stdout.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Allow replacing an existing --output file.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.trials < 1:
        parser.error("--trials must be at least 1")
    if args.num_predict < 1:
        parser.error("--num-predict must be at least 1")
    if not args.model.strip():
        parser.error("--model cannot be empty")
    if args.force and args.output is None:
        parser.error("--force requires --output")

    output_path = args.output.expanduser() if args.output is not None else None
    if output_path is not None and output_path.exists() and not args.force:
        print(
            f"ERROR: output already exists: {output_path}. "
            "Use --force only if replacement is intended.",
            file=sys.stderr,
        )
        return 2

    try:
        import ollama
    except ImportError as exc:
        print(
            "ERROR: the Python package 'ollama' is not installed in this interpreter. "
            "No dependency was installed automatically.",
            file=sys.stderr,
        )
        return 2

    try:
        client = ollama.Client()
        report = run_experiment(
            client=client,
            model=args.model,
            trials=args.trials,
            temperature=args.temperature,
            seed=args.seed,
            num_predict=args.num_predict,
        )
    except Exception as exc:
        print(f"ERROR: unable to initialise Ollama POC: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2

    rendered = json.dumps(report, indent=2, ensure_ascii=False)
    if output_path is None:
        print(rendered)
    else:
        try:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_text(rendered + "\n", encoding="utf-8")
        except OSError as exc:
            print(f"ERROR: cannot write report: {exc}", file=sys.stderr)
            return 2
        print(f"Report written: {output_path}")
        print(json.dumps(report["summary"], indent=2))

    return 1 if report["summary"]["request_or_condition_errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
