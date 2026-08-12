# Upgrade and rollback — Private Panel stable v1.0.0

## Upgrade

1. Launch private Vast template `534171` (`comfy-private-panel-stable`).
2. Require real non-interactive SSH before trusting provider key association.
3. Require bootstrap `82088809685b6f150808aced3adfe7f943874d77` and Panel `a3e75aa6bb836d4034a20fb94eb4792ee91b1606` in detached clean checkouts.
4. Require vendored bundle SHA-256 `fa71e450599ee63b7c0de3e87c9c9fa965da00f0c6de16b3c3d8d43c46a31b9d`.
5. Verify ComfyUI loopback health and empty queue.
6. Establish Tailnet-only routing; require public ComfyUI probes to fail.
7. Advertise a fresh split WSS endpoint/subprotocol capability from durable Hermes.
8. Verify Agent first frame, Connect, Reconnect, and one active route with zero pending commands.
9. Send the private Panel URL only after all gates pass.

## Rollback

- Stable rollback template: `532775`.
- Stop or destroy only the failed disposable candidate.
- Do not retag, mutate, or delete the accepted stable or rollback templates during diagnosis.
- Remove temporary Hermes proxy overrides and capability advertisements when closing an acceptance run.
- Preserve release evidence and diagnose exact failed gate before creating a successor generation.
