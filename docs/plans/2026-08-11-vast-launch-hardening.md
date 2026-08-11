# Vast Launch Hardening Implementation Plan

> **For Hermes:** Execute this plan in small, tested commits; do not promote a provider template until fresh-instance browser acceptance completes.

**Goal:** Make a Vast launch reliably restore verified Comfy state, run a pinned private direct-Hermes Panel, and provide an explicit safe snapshot-publish path without recurring manual repair.

**Architecture:** Vast remains a disposable, private Comfy runtime. The durable Hermes host owns the bridge; Vast only receives a runtime-only WSS fragment capability and advertises it into the pinned Panel. Backblaze B2 stores immutable, verified state generations for workflows/settings/approved custom nodes; models stay provider-local and are validated against a non-secret requirements manifest rather than copied wholesale.

**Non-goals:** No PC-local bridge agent, no browser shell/filesystem access, no static bridge capability/token, no shared provider credentials, no automatic model mirroring to B2.

---

## Release gates

A candidate may be promoted only after all are true:

1. immutable template loader checks out the declared bootstrap revision, never mutable `main`;
2. bootstrap verifies Panel bundle checksum, exact commit, clean worktree, and one canonical Panel package;
3. Comfy loopback health, Tailscale ingress, WSS advertise/readback, and re-advertisement after a Comfy PID change pass;
4. B2 reader restores a completed immutable generation transactionally and reports surface counts;
5. custom-node lock and workflow/model requirements acceptance pass;
6. fresh browser profile passes Sidebar → Connect → hard reload → Connect → Reconnect with no loopback dial or Panel console error;
7. snapshot publication is explicit, idle-gated, single-writer fenced, immutable, and read-back verified;
8. provider template is created/read back by ID and a fresh private instance passes every gate.

## Task 1: Immutable provider release descriptor and loader

**Files:**
- Create: `release/vast-release.json`
- Create: `release/render-vast-onstart.py`
- Create: `release/vast-onstart.sh.tmpl`
- Create: `tests/test_vast_release.py`
- Modify: `README.md`

**Implementation:** Define a release descriptor with template-facing image tag, bootstrap commit, bootstrap tree digest, Panel commit, Panel bundle SHA-256, and required runtime profile. Render a minimal onstart loader that clones/fetches the named bootstrap commit, checks out detached, verifies descriptor fields and tree content, and `exec`s `onstart.sh`. The rendered loader must not pull a mutable branch.

**Tests:** A fixture advances a remote default branch after descriptor creation and proves the loader still checks out exactly the declared commit. Reject an absent/malformed descriptor, branch ref, or mismatched tree digest.

## Task 2: Immutable Panel reconciliation

**Files:**
- Modify: `onstart.sh:validate_mcp_panel_release_overrides`, `ensure_mcp_panel_pinned`
- Modify: `tests/test_immutable_generation_port.py`

**Implementation:** Verify the vendored bundle checksum on every launch. Existing Panel checkouts are acceptable only when detached at the exact bundle head, clean (`git status --porcelain` empty), and source markers match. Archive and replace any dirty, wrong-origin, wrong-commit, duplicate, or marker-mismatched checkout outside `custom_nodes`.

**Tests:** Mutate Panel JS while retaining the same `HEAD`; assert the bootstrap archives/replaces it from the checked bundle. Add a duplicate package fixture and assert exactly one canonical extension remains loadable.

## Task 3: Bridge advertisement lifecycle supervisor

**Files:**
- Modify: `onstart.sh`
- Modify: `tests/test_immutable_generation_port.py`

**Implementation:** Add an in-memory background watcher launched only after initial Comfy health plus successful WSS advertise/readback. When the verified loopback Comfy listener PID changes, wait for health and repeat advertise/readback before marking the route ready. Never write or log the capability; watcher inherits it only in process memory. Retain controlled idle-restart behavior.

**Tests:** Simulate an external Comfy PID replacement and assert advertise/readback repeats. Assert watcher source cannot write bridge capability to disk/settings/log files.

## Task 4: Locked custom-node provenance

**Files:**
- Create: `custom_nodes.lock.json`
- Modify: `generate_manifest.sh`, `snapshot_contract.py`, `snapshot_activate.py`, `onstart.sh`
- Create: `tests/test_custom_node_lock.py`

**Implementation:** Replace URL-only reconciliation with lock entries: canonical source URL, exact commit, repository tree digest, expected node classes, and approved dependency fingerprint. Verify a restored custom-node tree against the lock before requirements/install hooks. Fresh clones fetch/check out exact commits. Reject undeclared snapshot repositories, mutated origins, commits, or tree content before code executes.

**Tests:** Upstream branch movement changes nothing; altered snapshot source or unknown repo fails before hooks; expected node classes are checked against `/object_info` after startup.

## Task 5: State and model requirements acceptance

**Files:**
- Create: `model_requirements.py`
- Create: `model_requirements.json` schema/documentation
- Modify: `workflow_validation.py`, `save_snapshot.sh`, `onstart.sh`
- Create: `tests/test_model_requirements.py`

**Implementation:** Derive required runtime node classes from restored workflow JSON and fail closed for missing executable classes by default, with a reviewed frontend-only allowlist. Generate a non-secret provider-local model requirements manifest: Comfy category, selected filename, source binding, optional byte size/hash. At launch compare live model catalogs and verify critical artifact integrity before readiness. Do not place model files in B2.

**Tests:** Missing workflow node, missing required VAE/checkpoint/text encoder, wrong category, and corrupted critical safetensors each block readiness. Frontend-only classes remain explicitly allowed.

## Task 6: Fenced snapshot publication and legacy migration

**Files:**
- Modify: `save_snapshot.sh`, `snapshot_contract.py`, `SHARED_COMFY_STATE.md`
- Create: `snapshot_lease.py`
- Create: `tests/test_snapshot_lease.py`
- Create: `scripts/migrate_legacy_state.py`

**Implementation:** Add remote writer lease/fence semantics before publishing a generation and compare-and-swap/conditional completion-pointer update. Include writer identity and fence in the manifest/completion record. The one-time legacy migration copies the old workflow/settings/approved-node state into a new canonical generation, verifies it, and publishes only after explicit operator confirmation. Readers never auto-publish.

**Tests:** Two writers contend; exactly one may publish. Interrupted/corrupt migrations cannot move the authority pointer. A reader restores only the selected verified generation.

## Task 7: Provider readback and browser acceptance runner

**Files:**
- Create: `scripts/vast_release_acceptance.py`
- Create: `tests/test_vast_release_acceptance.py`
- Modify: `README.md`

**Implementation:** Require exact Vast template readback: template ID/name, image, rendered immutable loader, environment *key names only*, bootstrap commit, Panel bundle SHA, and no static bridge capability. On a fresh private instance collect: runtime identity, loopback health, B2 restore counts, required-node/model acceptance, Tailnet private URL, advertised route readback, browser sidebar controls, Connect → hard reload → Connect → Reconnect, one approved reversible native-Undo mutation, and console error scan. Automatically destroy disposable failed/idle acceptance instances after artifact capture.

**Tests:** Offline fixtures validate structured report formatting and hard-fail conditions. Live run is a release gate, not an ordinary unit test.

## Task 8: Publish and promotion

1. Run all static/unit tests and independent code review.
2. Commit the hardened bootstrap, lockfiles, release descriptor, and generated loader.
3. Push the bootstrap repository.
4. Create a new Vast candidate template; retain V10.5 as rollback.
5. Read back the provider template by ID.
6. Perform the one-time B2 legacy migration only after explicit approval.
7. Launch a fresh candidate and run acceptance.
8. Report only the precise achieved stage: local, pushed, provider template read back, or fresh-browser accepted.
