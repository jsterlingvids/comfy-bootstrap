from __future__ import annotations

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("render_vast_onstart", REPO / "release" / "render_vast_onstart.py")
assert SPEC and SPEC.loader
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class VastReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.template = (REPO / "release" / "vast-onstart.sh.tmpl").read_text(encoding="utf-8")
        self.values = dict(
            repository="https://github.com/jsterlingvids/comfy-bootstrap.git",
            bootstrap_commit="a" * 40,
            panel_commit="b" * 40,
            panel_bundle_sha256="c" * 64,
        )

    def test_rendered_loader_is_immutable_and_contains_release_pins(self) -> None:
        rendered = module.render(self.template, **self.values)
        self.assertIn('git -C "${BOOTSTRAP_DIR}" fetch --depth=1 origin "${BOOTSTRAP_COMMIT}"', rendered)
        self.assertIn('git -C "${BOOTSTRAP_DIR}" checkout --detach "${BOOTSTRAP_COMMIT}"', rendered)
        self.assertNotIn("pull --ff-only", rendered)
        self.assertNotIn("@BOOTSTRAP_", rendered)
        self.assertIn(self.values["bootstrap_commit"], rendered)
        self.assertIn(self.values["panel_commit"], rendered)
        self.assertIn(self.values["panel_bundle_sha256"], rendered)
        check = subprocess.run(["bash", "-n"], input=rendered, text=True, capture_output=True, timeout=10)
        self.assertEqual(check.returncode, 0, check.stderr)

    def test_rejects_mutable_or_malformed_release_fields(self) -> None:
        with self.assertRaises(ValueError):
            module.render(self.template, **(self.values | {"bootstrap_commit": "main"}))
        with self.assertRaises(ValueError):
            module.render(self.template, **(self.values | {"repository": "git@github.com:bad/repo.git"}))
        with self.assertRaises(ValueError):
            module.render(self.template.replace("@PANEL_COMMIT@", "missing"), **self.values)

    def test_cli_writes_executable_loader(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "onstart.sh"
            completed = subprocess.run(
                [
                    "python3", str(REPO / "release" / "render_vast_onstart.py"),
                    "--output", str(output),
                    "--repository", self.values["repository"],
                    "--bootstrap-commit", self.values["bootstrap_commit"],
                    "--panel-commit", self.values["panel_commit"],
                    "--panel-bundle-sha256", self.values["panel_bundle_sha256"],
                ],
                text=True, capture_output=True, timeout=10,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(output.stat().st_mode & 0o100)
            self.assertEqual(output.read_text(encoding="utf-8"), module.render(self.template, **self.values))


if __name__ == "__main__":
    unittest.main()
