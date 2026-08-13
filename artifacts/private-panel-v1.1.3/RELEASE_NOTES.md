# Private ComfyUI Panel distribution v1.1.3

This immutable bootstrap successor distributes the finally certified Panel source at `f675f2a5a4093a579f27742d9a927599ed95075d` as a complete Git bundle with SHA-256 `5ed371c83ba7ed7104f7cfda4533538b2014bbd5489e558aa353af3d80e36632`.

The release adds the certified structured-media approval flow and its exact completed-turn proof. Bootstrap continues to checksum the bundle, check out the exact detached commit, verify clean provenance and required security markers, reject Panel repository/commit/checksum overrides, and disable Panel backend autospawn.

## Durable Bridge dependency and product boundary

This distribution requires the independently deployed durable Hermes–Comfy Bridge at certified commit `55691b424835541adb9e18dd54c5b06bae74fa50`. The Bridge remains a loopback-bound Hermes-host service and is not vendored, installed, started, restarted, monitored, or otherwise managed by the Vast bootstrap. No Bridge source, capability, provider credential, or runtime secret is included.

## Scope

This release publishes only the immutable bootstrap distribution successor. Bridge deployment/restart, provider template creation or mutation, live instance deployment, GPU launch, and fresh browser acceptance are intentionally **not run** and must not be inferred from this publication.

## Rollback

The immediate predecessor v1.1.2 Panel bundle (`5b8b29a`, SHA-256 `f7398428051d861f52b4e6892e6027749ea82f4a139b475c5f8f603a5f03997d`) is preserved outside the repository at `release-rollbacks/comfy-bootstrap/private-panel-v1.1.2/comfyui-mcp-panel.bundle`. Historical v1.1, v1.1.1, and v1.1.2 release evidence remains unchanged in the repository.