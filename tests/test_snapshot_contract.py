from __future__ import annotations

import errno
import hashlib
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

from snapshot_activate import ActivationError, activate, activate_legacy_custom_nodes
from snapshot_contract import (
    ContractError,
    create_manifest,
    parse_completion,
    validate_generation_id,
    validate_manifest,
    verify_stage,
)

GENERATION = "20260807T010203Z-012345abcdef"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_stage(root: Path) -> Path:
    stage = root / "stage"
    (stage / "workflows").mkdir(parents=True)
    (stage / "settings").mkdir()
    (stage / "custom_nodes/example").mkdir(parents=True)
    (stage / "workflows/new.json").write_text('{"new":true}\n')
    (stage / "settings/comfy.settings.json").write_text('{"theme":"dark"}\n')
    (stage / "custom_nodes/example/node.py").write_text("VALUE = 1\n")
    (stage / "custom_nodes_manifest.txt").write_text("https://example.invalid/example.git\n")
    create_manifest(stage, GENERATION, "runpod", "deadbeef", stage / "snapshot.manifest.json")
    return stage


class SnapshotContractTests(unittest.TestCase):
    def test_valid_completion_and_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stage = make_stage(root)
            manifest = stage / "snapshot.manifest.json"
            marker = root / "snapshot.complete.json"
            marker.write_text(json.dumps({
                "schema": "comfy-state-completion-v1",
                "generation": GENERATION,
                "manifest_sha256": digest(manifest),
                "published_at": "2026-08-07T01:02:03+00:00",
            }))
            generation, expected = parse_completion(marker)
            self.assertEqual((generation, expected), (GENERATION, digest(manifest)))
            validate_manifest(manifest, generation, expected)
            verify_stage(stage, manifest)

    def test_completion_rejects_path_traversal_generation(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp) / "marker.json"
            marker.write_text(json.dumps({
                "schema": "comfy-state-completion-v1",
                "generation": "../../current",
                "manifest_sha256": "a" * 64,
                "published_at": "2026-08-07T01:02:03+00:00",
            }))
            with self.assertRaises(ContractError):
                parse_completion(marker)

    def test_generation_override_validation(self) -> None:
        self.assertEqual(validate_generation_id(GENERATION), GENERATION)
        for invalid in ("latest", "../x", "20260807T010203Z-XYZ", ""):
            with self.subTest(invalid=invalid), self.assertRaises(ContractError):
                validate_generation_id(invalid)

    def test_manifest_rejects_wrong_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            stage = make_stage(Path(temp))
            with self.assertRaises(ContractError):
                validate_manifest(stage / "snapshot.manifest.json", GENERATION, "0" * 64)

    def test_manifest_rejects_wrong_generation(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            stage = make_stage(Path(temp))
            manifest = stage / "snapshot.manifest.json"
            with self.assertRaises(ContractError):
                validate_manifest(manifest, "20260807T010204Z-012345abcdef", digest(manifest))

    def test_manifest_rejects_invalid_provider_and_unsupported_surface(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            stage = make_stage(Path(temp))
            manifest = stage / "snapshot.manifest.json"
            value = json.loads(manifest.read_text())
            value["provider"] = ""
            manifest.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
            with self.assertRaises(ContractError):
                validate_manifest(manifest, GENERATION, digest(manifest))

            value["provider"] = "runpod:writer-a"
            value["surfaces"]["unsupported"] = {"files": 0, "bytes": 0, "tree_sha256": "0" * 64}
            manifest.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
            with self.assertRaises(ContractError):
                validate_manifest(manifest, GENERATION, digest(manifest))

    def test_manifest_measures_uploaded_flat_settings_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            stage = make_stage(Path(temp))
            value = json.loads((stage / "snapshot.manifest.json").read_text())
            expected_size = (stage / "settings/comfy.settings.json").stat().st_size
            self.assertEqual(value["surfaces"]["settings"]["files"], 1)
            self.assertEqual(value["surfaces"]["settings"]["bytes"], expected_size)
            self.assertEqual(value["surfaces"]["custom_nodes_manifest"]["files"], 1)

    def test_tampered_or_partial_generation_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            stage = make_stage(Path(temp))
            (stage / "workflows/new.json").write_text("tampered\n")
            with self.assertRaises(ContractError):
                verify_stage(stage, stage / "snapshot.manifest.json")

    def test_unexpected_stage_object_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            stage = make_stage(Path(temp))
            (stage / "secret.txt").write_text("nope")
            with self.assertRaises(ContractError):
                verify_stage(stage, stage / "snapshot.manifest.json")

    def test_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stage = make_stage(root)
            (stage / "custom_nodes/link").symlink_to(root / "outside")
            with self.assertRaises(ContractError):
                verify_stage(stage, stage / "snapshot.manifest.json")


class SnapshotActivationTests(unittest.TestCase):
    def make_comfy(self, root: Path) -> Path:
        comfy = root / "ComfyUI"
        (comfy / "user/default/workflows").mkdir(parents=True)
        (comfy / "custom_nodes/comfyui-mcp-panel/.git").mkdir(parents=True)
        (comfy / "main.py").write_text("# comfy\n")
        (comfy / "user/default/workflows/old.json").write_text("old\n")
        (comfy / "custom_nodes/comfyui-mcp-panel/.git/HEAD").write_text("pinned\n")
        (comfy / "custom_nodes/comfyui-mcp-panel/panel.py").write_text("panel\n")
        return comfy

    def test_activation_replaces_state_and_preserves_baked_panel(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stage = make_stage(root)
            comfy = self.make_comfy(root)
            activate(stage, stage / "snapshot.manifest.json", comfy)
            self.assertTrue((comfy / "user/default/workflows/new.json").is_file())
            self.assertFalse((comfy / "user/default/workflows/old.json").exists())
            self.assertTrue((comfy / "custom_nodes/example/node.py").is_file())
            self.assertEqual((comfy / "custom_nodes/comfyui-mcp-panel/.git/HEAD").read_text(), "pinned\n")
            self.assertEqual((comfy / "user/default/comfy.settings.json").read_text(), '{"theme":"dark"}\n')

    def test_injected_failure_rolls_back_every_applied_surface(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stage = make_stage(root)
            comfy = self.make_comfy(root)
            with mock.patch.dict(os.environ, {"SNAPSHOT_ACTIVATE_FAIL_AFTER": "2"}):
                with self.assertRaises(ActivationError):
                    activate(stage, stage / "snapshot.manifest.json", comfy)
            self.assertEqual((comfy / "user/default/workflows/old.json").read_text(), "old\n")
            self.assertFalse((comfy / "user/default/workflows/new.json").exists())
            self.assertFalse((comfy / "custom_nodes/example").exists())
            self.assertTrue((comfy / "custom_nodes/comfyui-mcp-panel/.git/HEAD").is_file())

    def test_failure_between_backup_and_replacement_restores_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stage = make_stage(root)
            comfy = self.make_comfy(root)
            real_replace = os.replace

            def fail_candidate(source: str | os.PathLike[str], destination: str | os.PathLike[str]) -> None:
                src = Path(source)
                if src.name == "workflows" and src.parent.name == "candidates":
                    raise OSError("injected replace failure")
                real_replace(source, destination)

            with mock.patch("snapshot_activate.os.replace", side_effect=fail_candidate):
                with self.assertRaises(OSError):
                    activate(stage, stage / "snapshot.manifest.json", comfy)
            self.assertEqual((comfy / "user/default/workflows/old.json").read_text(), "old\n")
            self.assertFalse((comfy / "user/default/workflows/new.json").exists())

    def test_generation_rollback_failure_retains_backup_on_disk(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stage = make_stage(root)
            comfy = self.make_comfy(root)
            real_replace = os.replace

            def fail_candidate_and_restore(source: str | os.PathLike[str], destination: str | os.PathLike[str]) -> None:
                src = Path(source)
                if src.name == "workflows" and src.parent.name in {"candidates", "backups"}:
                    raise OSError("injected candidate/rollback failure")
                real_replace(source, destination)

            with mock.patch("snapshot_activate.os.replace", side_effect=fail_candidate_and_restore):
                with self.assertRaisesRegex(ActivationError, "backups retained"):
                    activate(stage, stage / "snapshot.manifest.json", comfy)
            retained = list(comfy.glob(".snapshot-activate-*/backups/workflows"))
            self.assertEqual(len(retained), 1)
            self.assertEqual((retained[0] / "old.json").read_text(), "old\n")

    def test_legacy_custom_nodes_activate_atomically_and_preserve_panel(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            comfy = self.make_comfy(root)
            candidate = root / "legacy-candidate"
            (candidate / "WanWrapper").mkdir(parents=True)
            (candidate / "WanWrapper/node.py").write_text("wan\n")
            (candidate / "broken.invalid-20260716").mkdir()
            (candidate / "broken.invalid-20260716/node.py").write_text("broken\n")
            activate_legacy_custom_nodes(candidate, comfy)
            self.assertTrue((comfy / "custom_nodes/WanWrapper/node.py").is_file())
            self.assertFalse((comfy / "custom_nodes/broken.invalid-20260716").exists())
            self.assertTrue((comfy / "custom_nodes/comfyui-mcp-panel/.git/HEAD").is_file())

    def test_legacy_custom_nodes_overlay_exdev_materializes_and_activates(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            comfy = self.make_comfy(root)
            candidate = root / "legacy-candidate"
            (candidate / "WanWrapper").mkdir(parents=True)
            (candidate / "WanWrapper/node.py").write_text("wan\n")
            live = comfy / "custom_nodes"
            real_replace = os.replace
            injected = False

            def replace_with_overlay_exdev(source: Any, destination: Any) -> None:
                nonlocal injected
                if Path(source) == live and not injected:
                    injected = True
                    raise OSError(errno.EXDEV, "Invalid cross-device link")
                real_replace(source, destination)

            with mock.patch("snapshot_activate.os.replace", side_effect=replace_with_overlay_exdev):
                activate_legacy_custom_nodes(candidate, comfy)
            self.assertTrue(injected)
            self.assertEqual((comfy / "custom_nodes/WanWrapper/node.py").read_text(), "wan\n")
            self.assertTrue((comfy / "custom_nodes/comfyui-mcp-panel/.git/HEAD").is_file())

    def test_legacy_overlay_exdev_partial_backup_copy_preserves_live(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            comfy = self.make_comfy(root)
            live = comfy / "custom_nodes"
            (live / "sentinel").mkdir()
            (live / "sentinel/node.py").write_text("sentinel\n")
            candidate = root / "legacy-candidate"
            (candidate / "WanWrapper").mkdir(parents=True)
            (candidate / "WanWrapper/node.py").write_text("wan\n")
            real_replace = os.replace
            real_copytree = shutil.copytree
            injected_exdev = False

            def replace_with_overlay_exdev(source: Any, destination: Any) -> None:
                nonlocal injected_exdev
                if Path(source) == live and not injected_exdev:
                    injected_exdev = True
                    raise OSError(errno.EXDEV, "Invalid cross-device link")
                real_replace(source, destination)

            def fail_partial_live_copy(source: Any, destination: Any, *args: Any, **kwargs: Any) -> Any:
                if Path(source) == live:
                    destination_path = Path(destination)
                    destination_path.mkdir(parents=True)
                    real_copytree(live / "comfyui-mcp-panel", destination_path / "comfyui-mcp-panel")
                    raise OSError(errno.ENOSPC, "injected partial backup copy failure")
                return real_copytree(source, destination, *args, **kwargs)

            with mock.patch("snapshot_activate.os.replace", side_effect=replace_with_overlay_exdev), mock.patch(
                "snapshot_activate.shutil.copytree", side_effect=fail_partial_live_copy
            ):
                with self.assertRaises(OSError):
                    activate_legacy_custom_nodes(candidate, comfy)
            self.assertTrue(injected_exdev)
            self.assertTrue((live / "comfyui-mcp-panel/.git/HEAD").is_file())
            self.assertEqual((live / "sentinel/node.py").read_text(), "sentinel\n")
            self.assertFalse((live / "WanWrapper").exists())

    def test_generation_overlay_exdev_materializes_and_activates(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stage = make_stage(root)
            comfy = self.make_comfy(root)
            live = comfy / "user/default/workflows"
            real_replace = os.replace
            injected = False

            def replace_with_overlay_exdev(source: Any, destination: Any) -> None:
                nonlocal injected
                if Path(source) == live and not injected:
                    injected = True
                    raise OSError(errno.EXDEV, "Invalid cross-device link")
                real_replace(source, destination)

            with mock.patch("snapshot_activate.os.replace", side_effect=replace_with_overlay_exdev):
                activate(stage, stage / "snapshot.manifest.json", comfy)
            self.assertTrue(injected)
            self.assertEqual((comfy / "user/default/workflows/new.json").read_text(), '{"new":true}\n')
            self.assertFalse((comfy / "user/default/workflows/old.json").exists())

    def test_generation_overlay_exdev_partial_backup_copy_preserves_live(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stage = make_stage(root)
            comfy = self.make_comfy(root)
            live = comfy / "user/default/workflows"
            (live / "second.json").write_text("second\n")
            real_replace = os.replace
            real_copytree = shutil.copytree
            injected_exdev = False

            def replace_with_overlay_exdev(source: Any, destination: Any) -> None:
                nonlocal injected_exdev
                if Path(source) == live and not injected_exdev:
                    injected_exdev = True
                    raise OSError(errno.EXDEV, "Invalid cross-device link")
                real_replace(source, destination)

            def fail_partial_live_copy(source: Any, destination: Any, *args: Any, **kwargs: Any) -> Any:
                if Path(source) == live:
                    destination_path = Path(destination)
                    destination_path.mkdir(parents=True)
                    shutil.copy2(live / "old.json", destination_path / "old.json")
                    raise OSError(errno.ENOSPC, "injected partial backup copy failure")
                return real_copytree(source, destination, *args, **kwargs)

            with mock.patch("snapshot_activate.os.replace", side_effect=replace_with_overlay_exdev), mock.patch(
                "snapshot_activate.shutil.copytree", side_effect=fail_partial_live_copy
            ):
                with self.assertRaises(OSError):
                    activate(stage, stage / "snapshot.manifest.json", comfy)
            self.assertTrue(injected_exdev)
            self.assertEqual((live / "old.json").read_text(), "old\n")
            self.assertEqual((live / "second.json").read_text(), "second\n")
            self.assertFalse((live / "new.json").exists())

    def test_legacy_custom_nodes_reject_symlink_without_mutating_live(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            comfy = self.make_comfy(root)
            candidate = root / "legacy-candidate"
            candidate.mkdir()
            (candidate / "node.py").write_text("node\n")
            (candidate / "link").symlink_to(candidate / "node.py")
            with self.assertRaises(ActivationError):
                activate_legacy_custom_nodes(candidate, comfy)
            self.assertTrue((comfy / "custom_nodes/comfyui-mcp-panel/.git/HEAD").is_file())

    def test_legacy_candidate_install_failure_restores_baked_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            comfy = self.make_comfy(root)
            candidate = root / "legacy-candidate"
            (candidate / "WanWrapper").mkdir(parents=True)
            (candidate / "WanWrapper/node.py").write_text("wan\n")
            real_replace = os.replace

            def fail_candidate(source: str | os.PathLike[str], destination: str | os.PathLike[str]) -> None:
                if Path(source) == candidate:
                    raise OSError("injected legacy install failure")
                real_replace(source, destination)

            with mock.patch("snapshot_activate.os.replace", side_effect=fail_candidate):
                with self.assertRaises(OSError):
                    activate_legacy_custom_nodes(candidate, comfy)
            self.assertTrue((comfy / "custom_nodes/comfyui-mcp-panel/.git/HEAD").is_file())
            self.assertFalse((comfy / "custom_nodes/WanWrapper").exists())

    def test_legacy_rollback_failure_retains_backup_on_disk(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            comfy = self.make_comfy(root)
            candidate = root / "legacy-candidate"
            (candidate / "WanWrapper").mkdir(parents=True)
            (candidate / "WanWrapper/node.py").write_text("wan\n")
            real_replace = os.replace

            def fail_candidate_and_restore(source: str | os.PathLike[str], destination: str | os.PathLike[str]) -> None:
                src = Path(source)
                if src == candidate or (
                    src.name == "custom_nodes" and src.parent.name.startswith(".legacy-nodes-activate-")
                ):
                    raise OSError("injected candidate/rollback failure")
                real_replace(source, destination)

            with mock.patch("snapshot_activate.os.replace", side_effect=fail_candidate_and_restore):
                with self.assertRaisesRegex(ActivationError, "backup retained"):
                    activate_legacy_custom_nodes(candidate, comfy)
            retained = list(comfy.glob(".legacy-nodes-activate-*/custom_nodes"))
            self.assertEqual(len(retained), 1)
            self.assertTrue((retained[0] / "comfyui-mcp-panel/.git/HEAD").is_file())

    def test_invalid_stage_never_mutates_live_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stage = make_stage(root)
            comfy = self.make_comfy(root)
            (stage / "custom_nodes/example/node.py").write_text("corrupt\n")
            with self.assertRaises(ContractError):
                activate(stage, stage / "snapshot.manifest.json", comfy)
            self.assertEqual((comfy / "user/default/workflows/old.json").read_text(), "old\n")


if __name__ == "__main__":
    unittest.main()
