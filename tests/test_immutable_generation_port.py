from __future__ import annotations

import subprocess
import tempfile
import unittest
import hashlib
import os
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
        commit = "d559ba3611108c46e2fd115bdb3af2455455c5c7"
        bundle = REPO / "vendor/comfyui-mcp-panel.bundle"
        self.assertEqual(
            hashlib.sha256(bundle.read_bytes()).hexdigest(),
            "cc52c27d966bf1bf35e2f3e81ac34f32db84eead01dc82c2261119bf657fe30e",
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
        self.assertIn("graph_stage_input_video", self.onstart)
        self.assertIn("graph_expert_snapshot", self.onstart)
        self.assertIn("input_asset_ticket_request", self.onstart)
        self.assertIn("ensure_mcp_panel_pinned", self.onstart)
        self.assertIn("COMFYUI_MCP_NO_AUTOSPAWN=1", self.onstart)
        self.assertIn('comfyui-mcp-panel/**', self.save)
        activate = (REPO / "snapshot_activate.py").read_text(encoding="utf-8")
        self.assertIn('PRESERVED_BAKED_NODES = ("comfyui-mcp-panel",)', activate)

    def test_bridge_is_mandatory_wss_and_read_back(self) -> None:
        bridge_commit = "44a553db20fb4d5e007ea5b29bc95691de1cfa1e"
        bridge_sha256 = "3d59f0efce97fe29201bc5258d3a917b395352eb354f0ba581d383c5c53a35fc"
        bridge_bundle = REPO / "vendor/hermes-comfy-bridge.bundle"
        self.assertEqual(
            hashlib.sha256(bridge_bundle.read_bytes()).hexdigest(),
            bridge_sha256,
        )
        verified = subprocess.run(
            ["git", "bundle", "verify", str(bridge_bundle)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
        )
        self.assertEqual(verified.returncode, 0, verified.stdout)
        heads = subprocess.check_output(
            ["git", "bundle", "list-heads", str(bridge_bundle)], text=True, timeout=20
        )
        self.assertIn(bridge_commit, heads)
        self.assertIn("HERMES_PANEL_BRIDGE_URL is required for MCP Panel/Hermes control readiness.", self.onstart)
        self.assertIn('[[ "${bridge_url}" == wss://* ]]', self.onstart)
        self.assertIn("/comfyui_mcp_panel/advertise_bridge", self.onstart)
        self.assertIn("/comfyui_mcp_panel/bridge_url", self.onstart)
        self.assertGreaterEqual(self.onstart.count("advertise_hermes_bridge"), 3)

    def test_bridge_bundle_is_consumed_by_a_pinned_private_lifecycle(self) -> None:
        bridge_commit = "44a553db20fb4d5e007ea5b29bc95691de1cfa1e"
        bridge_sha256 = "3d59f0efce97fe29201bc5258d3a917b395352eb354f0ba581d383c5c53a35fc"
        lifecycle = "ensure_hermes_comfy_bridge() {" + self.onstart.split(
            "ensure_hermes_comfy_bridge() {", 1
        )[1].split("\n\nensure_comfyui_manager_v4() {", 1)[0]
        source_verify = "verify_hermes_bridge_source() {" + self.onstart.split(
            "verify_hermes_bridge_source() {", 1
        )[1].split("\n\nvalidate_hermes_bridge_runtime_config() {", 1)[0]
        main = "main() {" + self.onstart.split("main() {", 1)[1]

        # A release with a verified bundle but no startup consumer is invalid.
        self.assertTrue((REPO / "vendor/hermes-comfy-bridge.bundle").is_file())
        self.assertIn("ensure_hermes_comfy_bridge", main)
        self.assertLess(main.index("ensure_hermes_comfy_bridge"), main.index("advertise_hermes_bridge"))
        self.assertIn(bridge_commit, lifecycle)
        self.assertIn(bridge_sha256, lifecycle)
        self.assertIn('bridge_bundle="${SCRIPT_DIR}/vendor/hermes-comfy-bridge.bundle"', lifecycle)
        self.assertIn('sha256sum "${bridge_bundle}"', lifecycle)
        self.assertIn('git bundle verify "${bridge_bundle}"', lifecycle)
        self.assertIn('git clone --no-checkout "${bridge_bundle}" "${HERMES_BRIDGE_DIR}"', lifecycle)
        self.assertIn('checkout --detach "${bridge_commit}"', lifecycle)
        self.assertIn("hmac.compare_digest", source_verify)
        self.assertIn("query token refused", source_verify)
        self.assertIn("ALLOWED_COMMANDS", source_verify)
        self.assertIn("--no-deps --no-build-isolation", lifecycle)

    def test_bridge_lifecycle_is_loopback_only_and_fails_closed_without_runtime_secrets(self) -> None:
        lifecycle = "ensure_hermes_comfy_bridge() {" + self.onstart.split(
            "ensure_hermes_comfy_bridge() {", 1
        )[1].split("\n\nensure_comfyui_manager_v4() {", 1)[0]
        config = "validate_hermes_bridge_runtime_config() {" + self.onstart.split(
            "validate_hermes_bridge_runtime_config() {", 1
        )[1].split("\n\nverify_hermes_bridge_health() {", 1)[0]
        health = "verify_hermes_bridge_health() {" + self.onstart.split(
            "verify_hermes_bridge_health() {", 1
        )[1].split("\n\nensure_hermes_comfy_bridge() {", 1)[0]
        self.assertIn("HERMES_COMFY_BRIDGE_TOKEN is required", config)
        self.assertIn("HERMES_COMFY_PANEL_WS_TOKEN is required", config)
        self.assertIn('url.query or url.fragment != expected', config)
        self.assertNotIn("openssl rand", lifecycle)
        self.assertNotIn("?token=", lifecycle)
        self.assertIn("--host 127.0.0.1 --port 9177", lifecycle)
        self.assertIn("--no-access-log", lifecycle)
        self.assertIn("http://127.0.0.1:9177/healthz", health)
        self.assertIn("list_loopback_listening_pids_for_port 9177", lifecycle)
        self.assertIn("Port 9177 is occupied by an unverified listener; refusing advertisement without disrupting it.", lifecycle)
        self.assertIn("Managed Hermes bridge on port 9177 failed health verification.", lifecycle)
        self.assertIn("HERMES_BRIDGE_IDENTITY_FILE", lifecycle)
        self.assertIn("pid_matches_hermes_bridge", lifecycle)
        self.assertNotIn("kill -", lifecycle)
        self.assertNotIn("COMFY_STATE_ROOT", lifecycle)
        self.assertNotIn("rclone", lifecycle)

    def test_bridge_identity_rejects_substitution_and_reuses_only_managed_listener(self) -> None:
        """Exercise the identity decision helpers without opening a real listener."""
        with tempfile.TemporaryDirectory() as temp_dir:
            script = r'''
set -Eeuo pipefail
source "$REPO/onstart.sh"
mkdir -p "$HERMES_BRIDGE_STATE_DIR"
chmod 700 "$HERMES_BRIDGE_STATE_DIR"
fake_listener() { echo "${FAKE_LISTENER:-}"; }
list_listening_pids_for_port() { fake_listener; }
list_loopback_listening_pids_for_port() { fake_listener; }

# A real loopback endpoint can forge the expected health document, but it has
# no protected bootstrap identity and therefore cannot be reused.
python3 -c '
from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b"{\"ok\": true, \"service\": \"hermes-comfy-bridge\"}")
    def log_message(self, *args): pass
HTTPServer(("127.0.0.1", 9177), Handler).serve_forever()
' &
fake_pid=$!
for _ in $(seq 1 20); do
  curl -fsS --max-time 1 http://127.0.0.1:9177/healthz >/dev/null && break
  sleep 0.05
done
if ! curl -fsS --max-time 1 http://127.0.0.1:9177/healthz >/dev/null; then
  kill "$fake_pid" 2>/dev/null || true
  wait "$fake_pid" 2>/dev/null || true
  exit 77
fi
FAKE_LISTENER=$fake_pid
verify_hermes_bridge_health
! managed_hermes_bridge_listener_pid
kill "$fake_pid"
wait "$fake_pid" 2>/dev/null || true

# A stale owned identity is removed only while the port is free.
echo 999999 > "$HERMES_BRIDGE_IDENTITY_FILE"
chmod 600 "$HERMES_BRIDGE_IDENTITY_FILE"
FAKE_LISTENER=
remove_hermes_bridge_identity_if_port_free
[[ ! -e "$HERMES_BRIDGE_IDENTITY_FILE" ]]

# A live record whose process has the wrong cwd/cmdline does not prove bridge
# provenance (use a real non-uvicorn process rather than a mocked matcher).
unset -f pid_matches_hermes_bridge
sleep 30 &
wrong_pid=$!
echo "$wrong_pid" > "$HERMES_BRIDGE_IDENTITY_FILE"
chmod 600 "$HERMES_BRIDGE_IDENTITY_FILE"
! pid_matches_hermes_bridge "$wrong_pid"
FAKE_LISTENER=$wrong_pid
! managed_hermes_bridge_listener_pid
kill "$wrong_pid"
wait "$wrong_pid" 2>/dev/null || true
FAKE_LISTENER=

# A protected identity plus its exact managed listener PID is reusable on a
# rerun; no health-only substitution is sufficient.
pid_matches_hermes_bridge() { [[ "$1" == 4242 ]]; }
echo 4242 > "$HERMES_BRIDGE_IDENTITY_FILE"
chmod 600 "$HERMES_BRIDGE_IDENTITY_FILE"
FAKE_LISTENER=4242
managed_hermes_bridge_listener_pid | grep -Fx 4242
'''
            result = subprocess.run(
                ["bash", "-c", script],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=15,
                env={
                    **os.environ,
                    "REPO": str(REPO),
                    "WORKSPACE_ROOT": temp_dir,
                },
            )
            if result.returncode == 77:
                self.skipTest("loopback port 9177 is already in use by an external process")
            self.assertEqual(result.returncode, 0, result.stdout)

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
