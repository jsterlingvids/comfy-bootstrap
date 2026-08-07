from __future__ import annotations

import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


class Sam2BootstrapTests(unittest.TestCase):
    def test_sam2_reuses_existing_torch_without_build_isolation(self) -> None:
        onstart = (REPO / "onstart.sh").read_text(encoding="utf-8")
        self.assertIn("requirements_use_existing_torch_build_env", onstart)
        self.assertIn("facebookresearch/sam2(\\.git)?", onstart)
        self.assertIn("--no-build-isolation --no-deps", onstart)
        self.assertIn("write_torch_runtime_constraints", onstart)
        self.assertIn('handle.write(f"torch=={torch.__version__}', onstart)
        self.assertIn('handle.write(f"torchvision==', onstart)
        self.assertIn("torch.cuda.is_available()", onstart)
        self.assertIn('importlib.import_module("sageattention")', onstart)
        self.assertIn("verify_torch_runtime_unchanged", onstart)
        self.assertIn("preserving previous stamp and refusing readiness", onstart)


if __name__ == "__main__":
    unittest.main()
