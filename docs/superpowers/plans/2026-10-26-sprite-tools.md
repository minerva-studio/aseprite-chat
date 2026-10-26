# Focused Sprite Tools Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans or bounded implementation delegation, with tests before production edits.

**Goal:** Deliver focused sprite tools consistently through Chat and MCP without redundant automatic metadata.

**Architecture:** Keep `tools.json` authoritative for the catalog and `executor.lua` authoritative for document observation and operations. Chat and MCP dispatch those operations; the previous read tool is removed without compatibility per the user's explicit direction.

**Tech Stack:** Aseprite Lua, Node 24, MCP SDK, native batch tests.

**Spec:** `docs/superpowers/specs/2026-10-26-sprite-tools-design.md` (approved conversation design).

## Global Constraints

- Preserve revision checks, transactions, native approvals and unrelated untracked zip.
- English code comments/docs/UI; Chinese user communication. No real model invocation or GUI editor launch.
- Do not change MCP auto-connect, account configuration or startup policy.
- No new dependencies. Do not push or modify real Codex homes.

## Review Focus

- Empty editor must not disconnect MCP or block ordinary chat.
- Sparse payloads must not weaken revision freshness or edit approval.
- Pagination must not hide descendants or report palette indices incorrectly.
- Old calls must not bypass the current tool catalog; users create a new conversation for new definitions.
- Read-only inspection of a reference sprite must not silently move the editing target.

### Task 1: Native tools and catalog

Files: `executor.lua`, `tools.json`, `tests/executor.lua`.

- [x] Write failing native tests for list/view/inspect, sparse switch, empty editor, pagination and frame palettes; run batch to observe RED.
- [x] Implement `Executor:list(args)`, `view(args)`, `inspect(args)` and compact switch; remove `read`, preserve integrity observations, execute and export semantics.
- [x] Advertise exactly seven tools using the approved schema; run native executor tests to GREEN.

### Task 2: Chat and MCP integration

Files: `main.lua`, `mcp.lua`, `scripts/mcp-server.mjs`, `timeline.lua`, related tests.

- [x] Add failing controller/MCP tests for new routing, compact contexts, empty sends and advertised SDK tools.
- [x] Update dispatch and prompts. Derive compact context from bind's existing snapshot; with no document dispose and send hasSprite=false.
- [x] Update timeline summaries and MCP annotations/instructions; remove all legacy dispatch and migrate fixtures to current tools.
- [x] Run controller, protocol, timeline, MCP Lua and SDK/native tests.

### Task 3: Delivery checks

Files: `README.md`, `docs/validation.md`, package manifests and runtime tests.

- [x] Document actual schemas, examples, pagination and transport independence; bump patch/minor release to 0.6.0.
- [x] Run focused native suites and Node suites with concrete regression scope, then package/runtime validation.
- [x] Obtain fresh-context independent review, resolve material findings, and report remaining native GUI/model boundaries.

## Execution evidence

- Native executor RED 60/69 -> GREEN 69/69; query-frame regression RED 69/70 -> GREEN 70/70. The user's later breaking-update instruction removed all old read support and migrated native expectations to view/inspect.
- Controller/context, protocol and timeline failures were observed before their changes; final native suite passes 325 checks (71+13+70+62+56+28+10+7+8).
- Final `npm test`: 121/121, including real stdio SDK/native batch and isolated app-server initialization without model inference.
- Package creation and extracted-runtime checks pass at version 0.6.0. No installation or GUI restart performed.
- Initial R1 review cancelled because the user changed the contract to exclude compatibility. Fresh R2 found no core-path P1/P2 and one GUI-driver P2: the read-count hook still wrapped the deleted executor.read. The fixture now wraps executor.view. This test-driver-only correction is checked by native script parsing and the actual view route in the SDK/native suite; production GUI execution remains explicitly unverified.
- Independent R2 passed executor 70/70, controller 56, protocol 71/71, timeline 10, MCP 8 and Node MCP/native 17/17.
- Remote baseline matched HEAD after fetch. User explicitly authorized commit/push and conflict resolution; preserve untracked aseprite-chat.zip and never force-push.
