# Private ComfyUI Panel distribution v1.1.4

This immutable bootstrap successor distributes the finally certified Panel source at `658f70f3e8b6a3e08dec35d95aeabeffeb55ffc3` as a complete Git bundle with SHA-256 `ead133736c624b2712c1d81783e66db66822921a30dff79b88144e19b00a9466`.

## Certified changes

The Panel keeps the v1.1.3 structured-media approval boundary and fixes media staging so approved image/video loader values are assigned before the single graph add, compatible video-loader fallback stays bound to the captured workflow context, unrelated schema drift still fails closed, and lifecycle/security failures never trigger fallback into a successor workflow.

The required durable Bridge at `4996cea420d9e271224b799eafbfe6b2146a483c` adds validated **read-only** workflow-guidance context. Guidance is advisory context only: it grants no graph mutation, queue, save, media staging, provider, or runtime authority.

Bootstrap continues to checksum the bundle, check out the exact detached commit, verify clean provenance and required source markers, reject Panel repository/commit/checksum overrides, and disable Panel backend autospawn.

## Durable Bridge dependency and product boundary

The Bridge remains an independently deployed, loopback-bound Hermes-host service. It is not vendored, installed, started, restarted, monitored, upgraded, or otherwise managed by the Vast bootstrap. No Bridge source, capability, provider credential, or runtime secret is included in this distribution.

## Scope

This release publishes only the immutable bootstrap distribution successor. Bridge deployment/restart, Vast template creation or mutation, live instance deployment, GPU launch, and fresh browser acceptance are intentionally **not run** and must not be inferred from this publication.

## Rollback

The immediate predecessor v1.1.3 Panel bundle (`f675f2a`, SHA-256 `5ed371c83ba7ed7104f7cfda4533538b2014bbd5489e558aa353af3d80e36632`) is preserved outside the repository at `release-rollbacks/comfy-bootstrap/private-panel-v1.1.3/comfyui-mcp-panel.bundle`. Historical v1.1.1, v1.1.2, and v1.1.3 release evidence remains unchanged in the repository, and the previously preserved predecessor bundles remain available outside it.
