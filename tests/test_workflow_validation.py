from __future__ import annotations

import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from workflow_validation import (
    classify_missing,
    collect_workflow_node_types,
    main,
    parse_required,
    workflow_node_types,
)


class WorkflowValidationTests(unittest.TestCase):
    def test_frontend_parser_ignores_nested_socket_and_widget_types(self) -> None:
        payload = {
            "nodes": [
                {
                    "id": 1,
                    "type": "WanVideoSampler",
                    "inputs": [{"name": "model", "type": "WANVIDEOMODEL"}],
                    "outputs": [{"name": "image", "type": "IMAGE"}],
                    "widgets_values": [{"type": "qwen_image"}],
                }
            ],
            "extra": {"type": "not-a-node"},
        }
        self.assertEqual(workflow_node_types(payload), {"WanVideoSampler"})

    def test_api_parser_finds_class_type_at_any_prompt_depth(self) -> None:
        payload = {
            "prompt": {
                "1": {"class_type": "KSampler", "inputs": {"model": ["2", 0]}},
                "2": {"class_type": "CheckpointLoaderSimple", "inputs": {}},
            }
        }
        self.assertEqual(workflow_node_types(payload), {"KSampler", "CheckpointLoaderSimple"})

    def test_subgraph_nodes_are_included(self) -> None:
        payload = {
            "definitions": {
                "subgraphs": [{"nodes": [{"id": 2, "type": "VHS_VideoCombine"}]}]
            }
        }
        self.assertEqual(workflow_node_types(payload), {"VHS_VideoCombine"})

    def test_missing_classification_and_required_parser(self) -> None:
        runtime, frontend = classify_missing(
            {"WanVideoSampler", "Reroute", "01b6a731-fb78-4070-9a38-c87146da9604"},
            set(),
        )
        self.assertEqual(runtime, ["WanVideoSampler"])
        self.assertEqual(len(frontend), 2)
        self.assertEqual(parse_required("WanVideoSampler, VHS_VideoCombine\nKSampler"), {
            "WanVideoSampler", "VHS_VideoCombine", "KSampler"
        })
    def test_collection_is_recursive_and_reports_malformed_json(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "nested").mkdir()
            (root / "nested/workflow.json").write_text(
                json.dumps({"nodes": [{"id": 1, "type": "WanVideoSampler"}]}),
                encoding="utf-8",
            )
            (root / "broken.json").write_text("{not json", encoding="utf-8")
            used, count, errors = collect_workflow_node_types(root)
            self.assertEqual(used, {"WanVideoSampler"})
            self.assertEqual(count, 1)
            self.assertEqual(len(errors), 1)
            self.assertIn("broken.json", errors[0])

    def test_required_policy_fails_on_parse_error_and_writes_report(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "broken.json").write_text("{not json", encoding="utf-8")
            report = root / "report.json"
            response = io.BytesIO(json.dumps({"WanVideoSampler": {}}).encode())
            argv = [
                "workflow_validation.py",
                str(root),
                "8188",
                "--policy",
                "required",
                "--required",
                "WanVideoSampler",
                "--report",
                str(report),
            ]
            with mock.patch("sys.argv", argv), mock.patch(
                "workflow_validation.urllib.request.urlopen", return_value=response
            ):
                self.assertEqual(main(), 1)
            payload = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(len(payload["parse_errors"]), 1)
            self.assertEqual(payload["required_missing"], [])


if __name__ == "__main__":
    unittest.main()
