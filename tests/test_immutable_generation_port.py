from __future__ import annotations

import subprocess
import tempfile
import unittest
import hashlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


class ImmutableGenerationPortTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.onstart = (REPO / "onstart.sh").read_text(encoding="utf-8")
        cls.save = (REPO / "save_snapshot.sh").read_text(encoding="utf-8")

    def test_vast_is_reader_only_with_provider_local_codex(self) -> None:
        self.assertIn('readonly PROVIDER_NAME="${PROVIDER_NAME:-vast}"', self.onstart)
        self.assertIn('ACTIVE_STATE_ROOT="${COMFY_STATE_ROOT}/unavailable"', self.onstart)
        self.assertIn('CODEX_STATE_ROOT="${CODEX_STATE_ROOT:-myb2:comfy-provider-local/${PROVIDER_NAME}/codex-home}"', self.onstart)
        self.assertIn('if [[ "${SNAPSHOT_WRITER:-0}" != "1" ]]', self.onstart)
        self.assertNotIn('readonly SNAPSHOT_WRITER="1"', self.onstart)

    def test_pid1_hydration_has_explicit_precedence_and_lifecycle_coverage(self) -> None:
        hydration = "hydrate_runtime_env_allowlist() {" + self.onstart.split(
            "hydrate_runtime_env_allowlist() {", 1
        )[1].split("\nfinalize_runtime_state_roots() {", 1)[0]
        finalize = "finalize_runtime_state_roots() {" + self.onstart.split(
            "finalize_runtime_state_roots() {", 1
        )[1].split("\nmain() {", 1)[0]
        for required in (
            "B2_ACCOUNT_ID",
            "B2_APP_KEY",
            "TAILSCALE_AUTH_KEY",
            "HERMES_PANEL_BRIDGE_URL",
            "TAILSCALE_PROOF_ONLY",
            "SNAPSHOT_WRITER",
            "SNAPSHOT_WRITER_ID",
        ):
            self.assertIn(required, hydration)
        self.assertNotIn("printenv", hydration)
        self.assertNotIn("env |", hydration)

        with tempfile.TemporaryDirectory() as temp_dir:
            environ = Path(temp_dir) / "pid1.environ"
            environ.write_bytes(
                b"COMFY_STATE_ROOT=pid1:shared\0"
                b"CODEX_STATE_ROOT=pid1:codex\0"
                b"SNAPSHOT_WRITER=1\0"
                b"SNAPSHOT_WRITER_ID=pid1-writer\0"
                b"TAILSCALE_PROOF_ONLY=1\0"
                b"B2_ACCOUNT_ID=test-account\0"
            )
            test_hydration = hydration.replace(
                'local environ_path="/proc/1/environ"',
                f'local environ_path="{environ!s}"',
            )
            common = (
                "set -Eeuo pipefail\n"
                "COMFY_STATE_ROOT=default:shared\n"
                "CODEX_STATE_ROOT=default:codex\n"
                "ACTIVE_STATE_ROOT= REMOTE_CUSTOM_NODES= REMOTE_WORKFLOWS= REMOTE_SETTINGS= REMOTE_CODEX_HOME=\n"
                + test_hydration
                + "\n"
                + finalize
                + "\n"
            )
            inherited = subprocess.run(
                [
                    "bash",
                    "-c",
                    common
                    + "COMFY_STATE_ROOT_WAS_SET=0; CODEX_STATE_ROOT_WAS_SET=0\n"
                    + "hydrate_runtime_env_allowlist\n"
                    + "finalize_runtime_state_roots\n"
                    + "printf '%s|%s|%s|%s|%s|%s\\n' \"$COMFY_STATE_ROOT\" \"$CODEX_STATE_ROOT\" \"$SNAPSHOT_WRITER\" \"$SNAPSHOT_WRITER_ID\" \"$TAILSCALE_PROOF_ONLY\" \"$B2_ACCOUNT_ID\"\n",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=10,
            )
            self.assertEqual(inherited.returncode, 0, inherited.stdout)
            self.assertEqual(
                inherited.stdout.strip(),
                "pid1:shared|pid1:codex|1|pid1-writer|1|test-account",
            )

            explicit = subprocess.run(
                [
                    "bash",
                    "-c",
                    common
                    + "COMFY_STATE_ROOT_WAS_SET=1; CODEX_STATE_ROOT_WAS_SET=1\n"
                    + "SNAPSHOT_WRITER=0\n"
                    + "hydrate_runtime_env_allowlist\n"
                    + "finalize_runtime_state_roots\n"
                    + "printf '%s|%s|%s\\n' \"$COMFY_STATE_ROOT\" \"$CODEX_STATE_ROOT\" \"$SNAPSHOT_WRITER\"\n",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=10,
            )
            self.assertEqual(explicit.returncode, 0, explicit.stdout)
            self.assertEqual(explicit.stdout.strip(), "default:shared|default:codex|0")

    def test_generation_restore_is_verified_and_transactional(self) -> None:
        self.assertIn("select_snapshot_generation()", self.onstart)
        self.assertIn('ALLOW_LEGACY_SNAPSHOT:-0', self.onstart)
        self.assertIn("restore_transactional_generation()", self.onstart)
        self.assertIn('snapshot_contract.py" verify-stage', self.onstart)
        self.assertIn('snapshot_activate.py"', self.onstart)
        self.assertIn("Generation content failed integrity validation; immutable baseline was not modified.", self.onstart)
        self.assertIn("Generation activation failed and was rolled back.", self.onstart)
        self.assertIn("Using the custom-node manifest retained from the verified generation.", self.onstart)

    def test_panel_is_pinned_preserved_and_not_snapshotted(self) -> None:
        commit = "f322153ebc1189e289304e3f0f773d67b03d07b6"
        bundle = REPO / "vendor/comfyui-mcp-panel.bundle"
        self.assertEqual(
            hashlib.sha256(bundle.read_bytes()).hexdigest(),
            "7b35776d3e1edbde4744fd6fab048f3ed9349e9a9e85fa75bef138968c2bfd62",
        )
        verified = subprocess.run(
            ["git", "bundle", "verify", str(bundle)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
        )
        self.assertEqual(verified.returncode, 0, verified.stdout)
        heads = subprocess.check_output(
            ["git", "bundle", "list-heads", str(bundle)], text=True, timeout=20
        )
        self.assertIn(commit, heads)
        self.assertIn(commit, self.onstart)
        self.assertIn("vendor/comfyui-mcp-panel.bundle", self.onstart)
        self.assertIn("Vendored MCP Panel bundle checksum mismatch.", self.onstart)
        self.assertIn("model_download_routes", self.onstart)
        self.assertIn("models_download", self.onstart)
        self.assertIn("ensure_mcp_panel_pinned", self.onstart)
        self.assertIn("COMFYUI_MCP_NO_AUTOSPAWN=1", self.onstart)
        self.assertIn('comfyui-mcp-panel/**', self.save)
        activate = (REPO / "snapshot_activate.py").read_text(encoding="utf-8")
        self.assertIn('PRESERVED_BAKED_NODES = ("comfyui-mcp-panel",)', activate)

    def test_bridge_is_mandatory_wss_and_read_back(self) -> None:
        self.assertIn("HERMES_PANEL_BRIDGE_URL is required for MCP Panel/Hermes control readiness.", self.onstart)
        self.assertIn('[[ "${bridge_url}" == wss://* ]]', self.onstart)
        self.assertIn("/comfyui_mcp_panel/advertise_bridge", self.onstart)
        self.assertIn("/comfyui_mcp_panel/bridge_url", self.onstart)
        self.assertGreaterEqual(self.onstart.count("advertise_hermes_bridge"), 3)

    def test_required_node_policy_and_live_registry_fail_closed(self) -> None:
        self.assertIn('local policy="${WORKFLOW_VALIDATION_POLICY:-required}"', self.onstart)
        self.assertIn('workflow_validation.py"', self.onstart)
        self.assertIn('--required "${REQUIRED_RUNTIME_NODES:-}"', self.onstart)
        self.assertNotIn("VALIDATION_ERROR unable to fetch object_info: {exc}\")\n    sys.exit(0)", self.onstart)

    def test_active_port_export_and_post_hook_exact_runtime_gate(self) -> None:
        self.assertIn("export COMFYUI_ACTIVE_PORT", self.onstart)
        hooks = self.onstart.index("run_custom_node_install_scripts\n", self.onstart.index("main()"))
        exact = self.onstart.index("verify_approved_torch_runtime || {", hooks)
        restart = self.onstart.index("restart_comfy_if_idle", exact)
        validate = self.onstart.index("validate_workflow_nodes_available", restart)
        self.assertLess(hooks, exact)
        self.assertLess(exact, restart)
        self.assertLess(restart, validate)

    def test_writer_is_immutable_and_completion_marker_is_last(self) -> None:
        self.assertIn('[[ "${SNAPSHOT_WRITER:-0}" == "1" ]]', self.save)
        self.assertIn("require_env SNAPSHOT_WRITER_ID", self.save)
        self.assertIn("ensure_remote_generation_absent", self.save)
        self.assertIn('rclone_run check "${STAGE_ROOT}" "${REMOTE_ROOT}"', self.save)
        self.assertIn('rclone_run copyto "${completion}" "${COMPLETION_REMOTE}"', self.save)
        self.assertLess(self.save.index('rclone_run check "${STAGE_ROOT}" "${REMOTE_ROOT}"'), self.save.index('rclone_run copyto "${completion}" "${COMPLETION_REMOTE}"'))
        self.assertNotIn("REMOTE_ROOT=\"${COMFY_STATE_ROOT}\"", self.save)


if __name__ == "__main__":
    unittest.main()
