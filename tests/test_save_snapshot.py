from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

GENERATION = "20260807T020304Z-fedcba654321"
REPO = Path(__file__).resolve().parents[1]

RCLONE_FAKE = r'''#!/usr/bin/env python3
import filecmp, os, shutil, sys
from pathlib import Path
cmd=sys.argv[1]
a=Path(sys.argv[2]) if len(sys.argv)>2 else None
b=Path(sys.argv[3]) if len(sys.argv)>3 else None
if os.environ.get("FAKE_RCLONE_LOG"):
    with open(os.environ["FAKE_RCLONE_LOG"], "a", encoding="utf-8") as handle:
        handle.write(" ".join(sys.argv[1:4]) + "\n")
if cmd == "lsf":
    if os.environ.get("FAKE_RCLONE_FAIL_LSF") == "1": sys.exit(9)
    if a.exists():
        for child in sorted(a.iterdir()): print(child.name + ('/' if child.is_dir() else ''))
elif cmd == "sync":
    if os.environ.get("FAKE_RCLONE_FAIL_SYNC") == "1": sys.exit(9)
    if b.exists():
        shutil.rmtree(b) if b.is_dir() else b.unlink()
    b.parent.mkdir(parents=True,exist_ok=True)
    if a.exists(): shutil.copytree(a,b)
    if os.environ.get("FAKE_RCLONE_CORRUPT_AFTER_SYNC") == "1":
        target = next((p for p in b.rglob('*') if p.is_file()), None)
        if target: target.write_bytes(b"corrupt\n")
elif cmd == "copyto":
    if os.environ.get("FAKE_RCLONE_FAIL_COPYTO") == "1": sys.exit(9)
    b.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(a,b)
elif cmd == "check":
    if os.environ.get("FAKE_RCLONE_FAIL_CHECK") == "1": sys.exit(9)
    def tree(root):
        return {str(p.relative_to(root)):p.read_bytes() for p in root.rglob('*') if p.is_file()}
    sys.exit(0 if a.exists() and b.exists() and tree(a)==tree(b) else 8)
else:
    print("unsupported fake rclone command",cmd,file=sys.stderr); sys.exit(7)
'''

CURL_FAKE = r'''#!/usr/bin/env python3
import os,sys
if os.environ.get("FAKE_CURL_UNHEALTHY") == "1": sys.exit(22)
url=sys.argv[-1]
if url.endswith('/queue') and os.environ.get("FAKE_CURL_BUSY") == "1":
    print('{"queue_running":[[1,{}]],"queue_pending":[]}')
else:
    print('{"queue_running":[],"queue_pending":[]}' if url.endswith('/queue') else '{"system":{}}')
'''


class SaveSnapshotIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.comfy = self.root / "ComfyUI"
        (self.comfy / "user/default/workflows").mkdir(parents=True)
        (self.comfy / "custom_nodes/example").mkdir(parents=True)
        (self.comfy / "main.py").write_text("# comfy\n")
        (self.comfy / "user/default/workflows/a.json").write_text("{}\n")
        (self.comfy / "custom_nodes/example/node.py").write_text("VALUE=1\n")
        self.bootstrap = self.root / "bootstrap"
        self.bootstrap.mkdir()
        for name in ("save_snapshot.sh", "snapshot_contract.py", "generate_manifest.sh", "custom_nodes_manifest.txt"):
            shutil.copy2(REPO / name, self.bootstrap / name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "rclone").write_text(RCLONE_FAKE)
        (self.bin / "curl").write_text(CURL_FAKE)
        (self.bin / "rclone").chmod(0o755)
        (self.bin / "curl").chmod(0o755)
        self.remote = self.root / "remote"
        self.env = os.environ.copy()
        self.env.update({
            "PATH": str(self.bin) + os.pathsep + self.env["PATH"],
            "WORKSPACE_ROOT": str(self.root / "workspace"),
            "COMFY_ROOT": str(self.comfy),
            "BOOTSTRAP_ROOT_OVERRIDE": str(self.bootstrap),
            "COMFY_STATE_ROOT": str(self.remote),
            "B2_ACCOUNT_ID": "test-account",
            "B2_APP_KEY": "test-key",
            "PROVIDER_NAME": "test-provider",
            "SNAPSHOT_WRITER": "1",
            "SNAPSHOT_WRITER_ID": "test-primary",
            "SNAPSHOT_GENERATION_ID": GENERATION,
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        Path(self.env["WORKSPACE_ROOT"]).mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_save(self, **changes: str) -> subprocess.CompletedProcess[str]:
        env = self.env | changes
        return subprocess.run(
            ["bash", str(self.bootstrap / "save_snapshot.sh")],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
        )

    def test_success_publishes_verified_frozen_layout_then_marker(self) -> None:
        result = self.run_save()
        self.assertEqual(result.returncode, 0, result.stdout)
        generation_root = self.remote / "generations" / GENERATION
        marker = json.loads((self.remote / "snapshot.complete.json").read_text())
        self.assertEqual(marker["generation"], GENERATION)
        self.assertTrue((generation_root / "workflows/a.json").is_file())
        self.assertTrue((generation_root / "custom_nodes/example/node.py").is_file())
        subprocess.run(
            ["python3", str(self.bootstrap / "snapshot_contract.py"), "verify-stage", str(generation_root), str(generation_root / "snapshot.manifest.json")],
            check=True,
        )

    def test_writer_identity_and_generation_are_fail_closed(self) -> None:
        missing = self.run_save(SNAPSHOT_WRITER_ID="")
        self.assertNotEqual(missing.returncode, 0)
        invalid = self.run_save(SNAPSHOT_GENERATION_ID="../../escape")
        self.assertNotEqual(invalid.returncode, 0)
        self.assertFalse((self.remote / "snapshot.complete.json").exists())

    def test_existing_generation_is_never_overwritten(self) -> None:
        first = self.run_save()
        self.assertEqual(first.returncode, 0, first.stdout)
        generation_root = self.remote / "generations" / GENERATION
        original = (generation_root / "workflows/a.json").read_text()
        original_marker = (self.remote / "snapshot.complete.json").read_text()
        (self.comfy / "user/default/workflows/a.json").write_text('{"changed":true}\n')
        second = self.run_save()
        self.assertNotEqual(second.returncode, 0, second.stdout)
        self.assertEqual((generation_root / "workflows/a.json").read_text(), original)
        self.assertEqual((self.remote / "snapshot.complete.json").read_text(), original_marker)

    def test_health_gate_is_fail_closed(self) -> None:
        result = self.run_save(FAKE_CURL_UNHEALTHY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.remote / "snapshot.complete.json").exists())

    def test_busy_queue_is_fail_closed(self) -> None:
        result = self.run_save(FAKE_CURL_BUSY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.remote / "snapshot.complete.json").exists())

    def test_remote_corruption_never_updates_completion_marker(self) -> None:
        result = self.run_save(FAKE_RCLONE_CORRUPT_AFTER_SYNC="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.remote / "snapshot.complete.json").exists())

    def test_interrupted_verification_never_updates_completion_marker(self) -> None:
        result = self.run_save(FAKE_RCLONE_FAIL_CHECK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.remote / "snapshot.complete.json").exists())

    def test_completion_marker_upload_is_the_last_remote_write(self) -> None:
        event_log = self.root / "rclone-events.log"
        result = self.run_save(FAKE_RCLONE_LOG=str(event_log))
        self.assertEqual(result.returncode, 0, result.stdout)
        writes = []
        for line in event_log.read_text().splitlines():
            fields = line.split()
            if fields[0] in {"sync", "copyto"} and fields[2].startswith(str(self.remote)):
                writes.append(line)
        self.assertTrue(writes[-1].startswith("copyto "))
        self.assertTrue(writes[-1].endswith("snapshot.complete.json"), writes)


if __name__ == "__main__":
    unittest.main()
