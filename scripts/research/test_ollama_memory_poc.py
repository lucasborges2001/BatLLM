"""Unit tests for the Ollama memory/context POC; no live Ollama calls."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from ollama_memory_poc import (  # noqa: E402
    build_second_messages,
    classify_response,
    run_condition,
    run_experiment,
)


class FakeClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def chat(self, **kwargs):
        self.calls.append(kwargs)
        content = self.responses.pop(0)
        return SimpleNamespace(
            message=SimpleNamespace(content=content),
            model="fake-model",
            total_duration=123456,
            prompt_eval_count=10,
            eval_count=4,
        )


class ContextAwareFakeClient:
    def __init__(self):
        self.calls = []

    def chat(self, **kwargs):
        self.calls.append(kwargs)
        messages = kwargs["messages"]
        if len(messages) == 1 and messages[0]["content"].startswith("Memorizá"):
            content = messages[0]["content"]
            identifier = content.split("No lo inventes ni lo modifiques: ", 1)[1].split(".", 1)[0]
            response = f"RECIBIDO {identifier}"
        elif len(messages) == 1:
            response = "NO DISPONIBLE"
        else:
            content = messages[0]["content"]
            identifier = content.split("No lo inventes ni lo modifiques: ", 1)[1].split(".", 1)[0]
            response = identifier
        return SimpleNamespace(
            message=SimpleNamespace(content=response),
            model="fake-model",
        )


class OllamaMemoryPocTests(unittest.TestCase):
    def test_without_history_sends_only_second_prompt(self):
        client = FakeClient([
            "RECIBIDO BATLLM-TEST-01",
            "NO DISPONIBLE",
        ])
        result = run_condition(
            client=client,
            condition="without_history",
            model="fake-model",
            options={"temperature": 0, "seed": 42},
            identifier_factory=lambda: "BATLLM-TEST-01",
        )

        self.assertEqual(result["status"], "PASS")
        self.assertEqual(len(client.calls), 2)
        self.assertEqual(
            client.calls[1]["messages"],
            [{"role": "user", "content": result["request_2"]["request_messages"][0]["content"]}],
        )
        self.assertFalse(result["analysis"]["identifier_found"])
        self.assertEqual(result["analysis"]["outcome"], "not_recalled")

    def test_with_history_sends_user_assistant_user_messages(self):
        client = FakeClient([
            "RECIBIDO BATLLM-TEST-02",
            "Recibido BATLLM-TEST-02.",
        ])
        result = run_condition(
            client=client,
            condition="with_history",
            model="fake-model",
            options={"temperature": 0, "seed": 42},
            identifier_factory=lambda: "BATLLM-TEST-02",
        )

        self.assertEqual(result["status"], "PASS")
        second_messages = client.calls[1]["messages"]
        self.assertEqual([item["role"] for item in second_messages], ["user", "assistant", "user"])
        self.assertEqual(second_messages[1]["content"], "RECIBIDO BATLLM-TEST-02")
        self.assertTrue(result["analysis"]["identifier_found"])
        self.assertFalse(result["analysis"]["exact_identifier_only"])

    def test_classifier_separates_recall_from_exact_format(self):
        result = classify_response(
            "with_history",
            "BATLLM-TEST-03",
            "Recibido BATLLM-TEST-03.",
        )
        self.assertTrue(result["identifier_found"])
        self.assertFalse(result["exact_identifier_only"])
        self.assertEqual(result["outcome"], "recalled")

    def test_experiment_alternates_order_and_classifies_pairs(self):
        client = ContextAwareFakeClient()
        identifiers = iter([
            "BATLLM-TEST-A1",
            "BATLLM-TEST-B1",
            "BATLLM-TEST-B2",
            "BATLLM-TEST-A2",
        ])
        report = run_experiment(
            client=client,
            model="fake-model",
            trials=2,
            identifier_factory=lambda: next(identifiers),
        )

        self.assertEqual(
            report["trials"][0]["execution_order"],
            ["without_history", "with_history"],
        )
        self.assertEqual(
            report["trials"][1]["execution_order"],
            ["with_history", "without_history"],
        )
        self.assertEqual(report["summary"]["valid_pairs"], 2)
        self.assertEqual(report["summary"]["paired_hypothesis_supported"], 2)
        self.assertEqual(report["summary"]["conclusion"], "SUPPORTED_ALL_VALID_PAIRS")
        self.assertEqual(len(client.calls), 8)

    def test_invalid_condition_is_rejected(self):
        with self.assertRaises(ValueError):
            build_second_messages("unknown", "first", "answer", "second")


if __name__ == "__main__":
    unittest.main()
