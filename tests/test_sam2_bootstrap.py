from __future__ import annotations

import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


class Sam2BootstrapTests(unittest.TestCase):
    def test_sam2_reuses_existing_torch_without_build_isolation(self) -> None:
        onstart = (REPO / "onstart.sh").read_text(encoding="utf-8")
        self.assertIn("requirements_use_existing_torch_build_env", onstart)
        self.assertIn("facebookresearch/sam2", onstart)
        self.assertIn("--no-build-isolation", onstart)
        self.assertIn("verify_torch_runtime_unchanged", onstart)


if __name__ == "__main__":
    unittest.main()
