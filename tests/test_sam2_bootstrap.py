from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


class Sam2BootstrapTests(unittest.TestCase):
    def test_runtime_profiles_are_exact_and_unknown_profiles_fail_closed(self) -> None:
        profile = REPO / "lib/runtime-profile.sh"
        for name, torch, vision, audio, cuda, index in (
            ("cu130", "2.9.1+cu130", "0.24.1+cu130", "2.9.1+cu130", "13.0", "cu130"),
            ("cu128", "2.9.1+cu128", "0.24.1+cu128", "2.9.1+cu128", "12.8", "cu128"),
        ):
            command = (
                f"COMFY_RUNTIME_PROFILE={name}; source {profile!s}; "
                "printf '%s|%s|%s|%s|%s|%s' \"$COMFY_RUNTIME_PROFILE\" \"$APPROVED_TORCH_VERSION\" "
                "\"$APPROVED_TORCHVISION_VERSION\" \"$APPROVED_TORCHAUDIO_VERSION\" "
                "\"$APPROVED_TORCH_CUDA_VERSION\" \"$APPROVED_TORCH_INDEX_URL\""
            )
            result = subprocess.run(["bash", "-c", command], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, f"{name}|{torch}|{vision}|{audio}|{cuda}|https://download.pytorch.org/whl/{index}")
        rejected = subprocess.run(
            ["bash", "-c", f"COMFY_RUNTIME_PROFILE=mutable; source {profile!s}"],
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(rejected.returncode, 64)

    def test_vast_runtime_installer_uses_selected_profile_index(self) -> None:
        onstart = (REPO / "onstart.sh").read_text(encoding="utf-8")
        self.assertIn('source "${SCRIPT_DIR}/lib/runtime-profile.sh"', onstart)
        self.assertIn('--index-url "${APPROVED_TORCH_INDEX_URL}"', onstart)
        self.assertIn("Installing the approved ${COMFY_RUNTIME_PROFILE}", onstart)

    def test_required_video_combine_source_is_in_baseline_manifest(self) -> None:
        manifest = (REPO / "custom_nodes_manifest.txt").read_text(encoding="utf-8")
        self.assertIn("Kosinkadink/ComfyUI-VideoHelperSuite", manifest)

    def test_verify_approved_runtime_does_not_reassign_readonly_constants(self) -> None:
        onstart = (REPO / "onstart.sh").read_text(encoding="utf-8")
        function_body = "verify_approved_torch_runtime() {" + onstart.split(
            "verify_approved_torch_runtime() {", 1
        )[1].split("\nwrite_torch_runtime_constraints() {", 1)[0]
        with tempfile.TemporaryDirectory() as temp_dir:
            fake_python = Path(temp_dir) / "python3"
            fake_python.write_text(
                "#!/usr/bin/env bash\n"
                "set -Eeuo pipefail\n"
                "[[ \"$1\" == - ]]\n"
                "[[ \"$2\" == 2.9.1+cu130 ]]\n"
                "[[ \"$3\" == 0.24.1+cu130 ]]\n"
                "[[ \"$4\" == 2.9.1+cu130 ]]\n"
                "[[ \"$5\" == 13.0 ]]\n"
                "[[ \"$6\" == 1.0.6 ]]\n"
                "cat >/dev/null\n",
                encoding="utf-8",
            )
            fake_python.chmod(0o755)
            harness = (
                "set -Eeuo pipefail\n"
                f"RUNTIME_PYTHON={fake_python!s}\n"
                "readonly RUNTIME_PYTHON\n"
                "readonly APPROVED_TORCH_VERSION=2.9.1+cu130\n"
                "readonly APPROVED_TORCHVISION_VERSION=0.24.1+cu130\n"
                "readonly APPROVED_TORCHAUDIO_VERSION=2.9.1+cu130\n"
                "readonly APPROVED_TORCH_CUDA_VERSION=13.0\n"
                "readonly APPROVED_SAGEATTENTION_VERSION=1.0.6\n"
                + function_body
                + "\nverify_approved_torch_runtime\n"
            )
            result = subprocess.run(
                ["bash", "-c", harness],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stdout)

    def test_fresh_vast_image_establishes_exact_runtime_before_preflight(self) -> None:
        onstart = (REPO / "onstart.sh").read_text(encoding="utf-8")
        self.assertIn("ensure_approved_torch_runtime", onstart)
        self.assertIn('"${APPROVED_TORCH_INDEX_URL}"', onstart)
        self.assertIn('"torch==${APPROVED_TORCH_VERSION}"', onstart)
        self.assertIn('"torchvision==${APPROVED_TORCHVISION_VERSION}"', onstart)
        self.assertIn('"torchaudio==${APPROVED_TORCHAUDIO_VERSION}"', onstart)
        self.assertIn('"sageattention==${APPROVED_SAGEATTENTION_VERSION}"', onstart)
        ensure_call = onstart.index("  ensure_approved_torch_runtime\n", onstart.index("main() {"))
        self.assertLess(ensure_call, onstart.index("  if [[ \"${TAILSCALE_PROOF_ONLY:-0}\" == \"1\" ]]", onstart.index("main() {")))
        self.assertLess(ensure_call, onstart.index("  configure_rclone\n", onstart.index("main() {")))
        ensure_body = onstart.split("ensure_approved_torch_runtime() {", 1)[1].split("\nwrite_torch_runtime_constraints() {", 1)[0]
        self.assertGreaterEqual(ensure_body.count("verify_approved_torch_runtime"), 2)
        self.assertIn("--no-deps", ensure_body)

    def test_sam2_reuses_existing_torch_without_build_isolation(self) -> None:
        onstart = (REPO / "onstart.sh").read_text(encoding="utf-8")
        self.assertIn("requirements_use_existing_torch_build_env", onstart)
        self.assertIn("facebookresearch/sam2(\\.git)?", onstart)
        self.assertIn("--no-build-isolation --no-deps", onstart)
        self.assertIn("write_torch_runtime_constraints", onstart)
        self.assertIn('handle.write(f"torch=={torch.__version__}', onstart)
        self.assertIn('handle.write(f"torchvision==', onstart)
        self.assertIn('handle.write(f"torchaudio==', onstart)
        self.assertIn("torch.cuda.is_available()", onstart)
        self.assertIn('importlib.import_module("sageattention")', onstart)
        self.assertIn("verify_torch_runtime_unchanged", onstart)
        self.assertIn("invalidated the stamp for retry", onstart)
        self.assertGreaterEqual(onstart.count('rm -f "${stamp_file}"'), 2)
        self.assertIn("Required workflow-node validation remains authoritative", onstart)
        self.assertIn("required repo baseline only", onstart)
        self.assertNotIn("B2 catch-all manifests differ; using the union", onstart)
        self.assertIn(
            'pip_install_with_fallback install --no-cache-dir -c "${torch_constraints}" -r "${requirements_file}"',
            onstart,
        )
        self.assertIn(
            'elif pip_install_with_fallback install --no-cache-dir -c "${torch_constraints}" -r "${requirements_file}" &&\n'
            '         verify_torch_runtime_unchanged "${torch_runtime_before}"; then',
            onstart,
        )
        self.assertEqual(onstart.count('local torch_constraints=""'), 4)
        self.assertIn('PYTHON="${RUNTIME_PYTHON}" PIP_CONSTRAINT="${torch_constraints}" "${RUNTIME_PYTHON}" "${install_script}"', onstart)
        self.assertIn('PYTHON="${RUNTIME_PYTHON}" PIP_CONSTRAINT="${torch_constraints}" bash "${install_script}"', onstart)
        self.assertIn("optional custom-node install scripts had failures", onstart)
        self.assertIn("Approved runtime identity drifted during custom-node install scripts; refusing readiness.", onstart)
        self.assertIn("verify_approved_torch_runtime", onstart)
        self.assertIn('source "${SCRIPT_DIR}/lib/runtime-profile.sh"', onstart)
        self.assertLess(
            onstart.index("Approved Torch/torchvision/CUDA/SageAttention runtime preflight failed before custom-node requirements."),
            onstart.index("Custom node requirements unchanged; skipping reinstall."),
        )
        self.assertLess(
            onstart.index("Approved Torch/torchvision/CUDA/SageAttention runtime preflight failed before custom-node install scripts."),
            onstart.index("Custom node install scripts unchanged; skipping re-run."),
        )
        self.assertIn('RUNTIME_PYTHON=/opt/conda/bin/python3', onstart)
        self.assertIn('"${RUNTIME_PYTHON}" -m pip', onstart)
        self.assertIn('nohup "${RUNTIME_PYTHON}" main.py', onstart)
        self.assertIn('runtime_environment_fingerprint_material', onstart)
        self.assertIn('compute_comfy_requirements_runtime_fingerprint', onstart)
        self.assertIn('"${RUNTIME_PYTHON}" -m pip freeze --all', onstart)
        self.assertIn('process_executable', onstart)
        install_hook_body = onstart.split('run_custom_node_install_scripts() {', 1)[1].split('install_comfy_requirements() {', 1)[0]
        self.assertNotIn('write_stamp "${requirements_stamp_file}"', install_hook_body)
        self.assertNotIn('current_fingerprint="$(compute_node_install_scripts_fingerprint', install_hook_body.split('if (( failed_count == 0 )); then', 1)[1])
        self.assertIn("Final approved Torch/torchvision/CUDA/SageAttention gate failed", onstart)


if __name__ == "__main__":
    unittest.main()
