from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import threading
import unittest
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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

    def test_panel_release_pins_reject_mismatched_environment_overrides(self) -> None:
        repository = "${SCRIPT_DIR}/vendor/comfyui-mcp-panel.bundle"
        commit = "484cc6776b8c29dac539c5b429ba94cab600a617"
        checksum = "0c682745782625c3338b87b207ca7b950f43399276a2dbaec1d71422ab9b4b5a"
        validator = "validate_mcp_panel_release_overrides() {" + self.onstart.split(
            "validate_mcp_panel_release_overrides() {", 1
        )[1].split("\n\nensure_mcp_panel_pinned() {", 1)[0]

        for name, bad_value in (
            ("MCP_PANEL_REPOSITORY", "/tmp/unreviewed-panel.bundle"),
            ("MCP_PANEL_COMMIT", "0000000000000000000000000000000000000000"),
            ("MCP_PANEL_BUNDLE_SHA256", "0" * 64),
        ):
            rejected = subprocess.run(
                [
                    "bash",
                    "-c",
                    "set -Eeuo pipefail\n"
                    "log() { :; }\n"
                    f"SCRIPT_DIR=/immutable/template\n"
                    f"readonly MCP_PANEL_RELEASE_REPOSITORY='{repository}'\n"
                    f"readonly MCP_PANEL_RELEASE_COMMIT='{commit}'\n"
                    f"readonly MCP_PANEL_RELEASE_BUNDLE_SHA256='{checksum}'\n"
                    + validator
                    + f"\n{name}='{bad_value}'\n"
                    + "validate_mcp_panel_release_overrides\n",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=10,
            )
            self.assertNotEqual(rejected.returncode, 0, rejected.stdout)

        accepted = subprocess.run(
            [
                "bash",
                "-c",
                "set -Eeuo pipefail\n"
                "log() { :; }\n"
                f"SCRIPT_DIR=/immutable/template\n"
                f"readonly MCP_PANEL_RELEASE_REPOSITORY='{repository}'\n"
                f"readonly MCP_PANEL_RELEASE_COMMIT='{commit}'\n"
                f"readonly MCP_PANEL_RELEASE_BUNDLE_SHA256='{checksum}'\n"
                + validator
                + f"\nMCP_PANEL_REPOSITORY='{repository}'\n"
                + f"MCP_PANEL_COMMIT='{commit}'\n"
                + f"MCP_PANEL_BUNDLE_SHA256='{checksum}'\n"
                + "validate_mcp_panel_release_overrides\n",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stdout)
        self.assertIn('readonly MCP_PANEL_RELEASE_REPOSITORY="${SCRIPT_DIR}/vendor/comfyui-mcp-panel.bundle"', self.onstart)
        self.assertIn(f'readonly MCP_PANEL_RELEASE_COMMIT="{commit}"', self.onstart)
        self.assertIn(f'readonly MCP_PANEL_RELEASE_BUNDLE_SHA256="{checksum}"', self.onstart)
        self.assertNotIn('local panel_repo="${MCP_PANEL_REPOSITORY:-', self.onstart)
        self.assertNotIn('local panel_commit="${MCP_PANEL_COMMIT:-', self.onstart)
        self.assertNotIn('local panel_bundle_sha256="${MCP_PANEL_BUNDLE_SHA256:-', self.onstart)

    def test_panel_is_pinned_preserved_and_not_snapshotted(self) -> None:
        commit = "484cc6776b8c29dac539c5b429ba94cab600a617"
        bundle = REPO / "vendor/comfyui-mcp-panel.bundle"
        self.assertEqual(
            hashlib.sha256(bundle.read_bytes()).hexdigest(),
            "0c682745782625c3338b87b207ca7b950f43399276a2dbaec1d71422ab9b4b5a",
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
        self.assertIn("Pinned MCP Panel checkout did not resolve to the reviewed commit.", self.onstart)
        self.assertIn("model_download_routes", self.onstart)
        self.assertIn("_advertised_bridge_dial", self.onstart)
        self.assertIn("bridge-capability.js", self.onstart)
        self.assertIn("advertisedBridgeDialOptions", self.onstart)
        self.assertIn("models_download", self.onstart)
        self.assertIn("graph_stage_input_video", self.onstart)
        self.assertIn("graph_expert_snapshot", self.onstart)
        self.assertIn("input_asset_ticket_request", self.onstart)
        self.assertIn("ensure_mcp_panel_pinned", self.onstart)
        self.assertIn("COMFYUI_MCP_NO_AUTOSPAWN=1", self.onstart)
        self.assertIn('comfyui-mcp-panel/**', self.save)
        activate = (REPO / "snapshot_activate.py").read_text(encoding="utf-8")
        self.assertIn('PRESERVED_BAKED_NODES = ("comfyui-mcp-panel",)', activate)

    def test_existing_panel_checkout_requires_clean_bundle_provenance(self) -> None:
        checker = "panel_checkout_matches_release() {" + self.onstart.split(
            "panel_checkout_matches_release() {", 1
        )[1].split("\n\nensure_mcp_panel_pinned() {", 1)[0]
        self.assertIn('git bundle verify "${panel_repo}"', checker)
        self.assertIn('git bundle list-heads "${panel_repo}"', checker)
        self.assertIn('git -C "${panel_dir}" symbolic-ref -q HEAD', checker)
        self.assertIn('git -C "${panel_dir}" status --porcelain --untracked-files=all', checker)
        self.assertIn('panel_checkout_matches_release "${panel_dir}" "${panel_repo}"', self.onstart)
        self.assertIn("Pinned MCP Panel checkout failed post-install provenance verification.", self.onstart)

    def test_external_advertisement_mode_never_imports_a_capability_but_allows_private_supervision(self) -> None:
        self.assertIn("HERMES_PANEL_EXTERNAL_ADVERTISEMENT", self.onstart)
        self.assertIn("external_bridge_advertisement_enabled()", self.onstart)
        self.assertIn("no capability is present in this instance", self.onstart)
        self.assertIn("External Hermes advertisement supervisor owns route refresh", self.onstart)
        self.assertLess(
            self.onstart.index("external_bridge_advertisement_enabled()"),
            self.onstart.index("advertise_hermes_bridge()"),
        )

    def test_external_bridge_is_mandatory_wss_capability_and_read_back(self) -> None:
        advertise = "advertise_hermes_bridge() {" + self.onstart.split(
            "advertise_hermes_bridge() {", 1
        )[1].split("\n\nstart_bridge_advertisement_watch() {", 1)[0]
        self.assertIn("HERMES_PANEL_BRIDGE_URL is required for MCP Panel/Hermes control readiness.", self.onstart)
        self.assertIn('url.scheme != "wss"', advertise)
        self.assertIn("not url.fragment", advertise)
        self.assertIn("url.query", advertise)
        self.assertIn("urlunsplit", advertise)
        self.assertIn('readback.get("url") != expected_url', advertise)
        self.assertIn('readback.get("protocol") != expected_protocol', advertise)
        self.assertIn("/comfyui_mcp_panel/advertise_bridge", advertise)
        self.assertIn("/comfyui_mcp_panel/bridge_url", advertise)
        self.assertGreaterEqual(self.onstart.count("advertise_hermes_bridge"), 3)

    def test_bridge_fragment_readback_uses_sanitized_endpoint_and_protocol(self) -> None:
        advertised: list[dict[str, str]] = []
        case = self

        class PanelHandler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                pass

            def do_POST(self) -> None:
                case.assertEqual(self.path, "/comfyui_mcp_panel/advertise_bridge")
                advertised.append(json.loads(self.rfile.read(int(self.headers["content-length"]))))
                self.send_response(200)
                self.end_headers()

            def do_GET(self) -> None:
                case.assertEqual(self.path, "/comfyui_mcp_panel/bridge_url")
                body = json.dumps(
                    {"url": "wss://bridge.example.test/control", "protocol": "opaque-capability"}
                ).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = ThreadingHTTPServer(("127.0.0.1", 0), PanelHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            advertise = "advertise_hermes_bridge() {" + self.onstart.split(
                "advertise_hermes_bridge() {", 1
            )[1].split("\n\nstart_bridge_advertisement_watch() {", 1)[0]
            result = subprocess.run(
                ["bash", "-c", "set -Eeuo pipefail\nlog() { :; }\n" + advertise + "\nadvertise_hermes_bridge\n"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    "PATH": "/usr/bin:/bin",
                    "RUNTIME_PYTHON": sys.executable,
                    "DEFAULT_COMFY_PORT": str(server.server_port),
                    "COMFYUI_ACTIVE_PORT": str(server.server_port),
                    "HERMES_PANEL_BRIDGE_URL": "wss://bridge.example.test/control#opaque-capability",
                },
                timeout=20,
            )
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            advertised,
            [{"url": "wss://bridge.example.test/control#opaque-capability"}],
        )

    def test_bridge_fragment_readback_rejects_protocol_mismatch(self) -> None:
        class PanelHandler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                pass

            def do_POST(self) -> None:
                self.send_response(200)
                self.end_headers()

            def do_GET(self) -> None:
                body = b'{"url":"wss://bridge.example.test/control","protocol":"wrong-capability"}'
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = ThreadingHTTPServer(("127.0.0.1", 0), PanelHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            advertise = "advertise_hermes_bridge() {" + self.onstart.split(
                "advertise_hermes_bridge() {", 1
            )[1].split("\n\nstart_bridge_advertisement_watch() {", 1)[0]
            result = subprocess.run(
                ["bash", "-c", "set -Eeuo pipefail\nlog() { printf '%s\\n' \"$*\"; }\n" + advertise + "\nadvertise_hermes_bridge\n"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    "PATH": "/usr/bin:/bin",
                    "RUNTIME_PYTHON": sys.executable,
                    "DEFAULT_COMFY_PORT": str(server.server_port),
                    "COMFYUI_ACTIVE_PORT": str(server.server_port),
                    "HERMES_PANEL_BRIDGE_URL": "wss://bridge.example.test/control#opaque-capability",
                },
                timeout=20,
            )
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MCP Panel did not retain the advertised Hermes bridge route.", result.stdout)
        self.assertNotIn("opaque-capability", result.stdout + result.stderr)

    def test_vast_bootstrap_does_not_manage_or_vendor_a_bridge(self) -> None:
        forbidden = (
            "vendor/hermes-comfy-bridge.bundle",
            "ensure_hermes_comfy_bridge",
            "verify_hermes_bridge_source",
            "HERMES_BRIDGE_",
            "HERMES_COMFY_BRIDGE_TOKEN",
            "HERMES_COMFY_PANEL_WS_TOKEN",
            "uvicorn hermes_comfy_bridge",
            "--port 9177",
            "http://127.0.0.1:9177",
            "git clone --no-checkout \"${bridge_bundle}\"",
        )
        self.assertFalse((REPO / "vendor/hermes-comfy-bridge.bundle").exists())
        for value in forbidden:
            self.assertNotIn(value, self.onstart)
        self.assertNotIn("HERMES_COMFY_", self.onstart)
        self.assertNotIn("HERMES_COMFY_", (REPO / "README.md").read_text(encoding="utf-8"))

    def test_bridge_capability_is_not_logged_or_persisted_by_advertisement(self) -> None:
        advertise = "advertise_hermes_bridge() {" + self.onstart.split(
            "advertise_hermes_bridge() {", 1
        )[1].split("\n\nstart_bridge_advertisement_watch() {", 1)[0]
        self.assertNotIn('log "${bridge_url}', advertise)
        self.assertNotIn("printf", advertise)
        self.assertNotIn("write_stamp", advertise)
        self.assertNotIn(">>", advertise)
        self.assertNotIn('> "${', advertise)

    def test_bridge_listener_watcher_re_advertises_after_pid_change_without_persisting_capability(self) -> None:
        watcher = "start_bridge_advertisement_watch() {" + self.onstart.split(
            "start_bridge_advertisement_watch() {", 1
        )[1].split("\n\nvalidate_workflow_nodes_available() {", 1)[0]
        self.assertIn('current_pid="$(find_comfy_listener_pid_for_port', watcher)
        self.assertIn('"${current_pid}" != "${observed_pid}"', watcher)
        self.assertIn('curl -fsS --max-time 5 "http://127.0.0.1:${port}/system_stats"', watcher)
        self.assertIn("advertise_hermes_bridge", watcher)
        self.assertNotIn("HERMES_PANEL_BRIDGE_URL=", watcher)
        self.assertNotIn("write_stamp", watcher)
        self.assertNotIn("saveBridgeUrl", watcher)
        self.assertLess(
            self.onstart.index("start_bridge_advertisement_watch", self.onstart.index("main()")),
            self.onstart.index("validate_workflow_nodes_available", self.onstart.index("main()")),
        )

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
