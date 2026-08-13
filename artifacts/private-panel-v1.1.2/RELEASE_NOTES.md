# Private ComfyUI Panel distribution v1.1.2

This immutable bootstrap successor distributes the certified Panel source at `5b8b29a767980ef1776c56dc1c0a551e3401b37e` as a complete Git bundle with SHA-256 `f7398428051d861f52b4e6892e6027749ea82f4a139b475c5f8f603a5f03997d`.

The durable Hermes–Comfy bridge remains deployed separately from certified commit `89d8436793da86fcdb4eb80555f1580616701620`; this release does not modify it. No bridge source, bridge capability, provider credential, or runtime secret is included in the bootstrap.

Bootstrap continues to reject Panel repository, commit, and checksum overrides that differ from the immutable release pins.

## Scope

This release publishes only the bootstrap distribution successor. Vast template creation or update, live instance `47629306`, GPU launch, and fresh browser acceptance are intentionally **not run** and must not be inferred from this publication.

## Rollback

The predecessor v1.1.1 Panel bundle (`c33cce2`, SHA-256 `cca874a7bb9b08450cdcfedbc5a63480ab9da0c6a01e3bf322b9e8350cd06115`) is preserved outside the repository as a non-published rollback artifact.
