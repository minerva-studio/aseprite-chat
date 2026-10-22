# Native Aseprite Codex Chat Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for bounded modules and focused review. The user approved the design and authorized implementation on 2026-10-21.

**Goal:** Continuous native Aseprite chat with Codex, inspection of unsaved sprites, and approved undoable edits.

**Architecture:** Lua Dialog and WebSocket connect to a loopback Node bridge, which starts Codex app-server over stdio. The approved transport revision in the spec supersedes the original direct WebSocket plan. Protocol state belongs to the client; document revisions belong to the executor; the controller owns pending approvals. UI is a projection of those owners.

**Tech Stack:** Aseprite 1.3.18.6 Lua API, Codex CLI 0.163.0 app-server, Node 24 with pinned ws 8.22.0 for the runtime bridge and fixtures, PowerShell packaging.

**Spec:** `docs/superpowers/specs/2026-10-21-aseprite-chat-design.md`

## Global Constraints

- Connect to the approved local bridge at `ws://127.0.0.1:4500`; no MCP server.
- Plain-text, modeless native chat and approval dialogs.
- Every mutation requires approval and a current revision; no automatic document save.
- One active turn; stop invalidates pending execution before interrupting the server.
- Local preferences store endpoint, canonical model and reasoning effort, not conversation history.
- Preserve other work; do not push or merge.

## Review Focus

- Late socket events and turn/start replies must not revive stopped or completed turns.
- Approval can become stale while the user edits or switches away and back.
- Actual Aseprite image operations must generate a single Undo and roll back failures.
- Reconnect must retain tools without replaying an edit.
- UTF-8 wrapping and native callback failures must not leave unusable dialogs.

## Task 1: Protocol client

**Files:** `codex.lua`, `tests/protocol.lua`.

**Interfaces:** `local Codex = dofile(path)`; `Codex.new(options)` returns client. Options: `tools`, `instructions`, callbacks `on_state(state)`, `on_message(id,text,isDelta)`, `on_tool(params,reply)`, `on_cancel(reason)`, `on_error(text)`. Optional `socket_factory(spec)` and `timer_factory(spec)` replace native WebSocket/Timer only in protocol tests. Methods: `connect(endpoint)`, `disconnect()`, `send(prompt,contextText,settings)` returning boolean/error, `list_models(callback)` returning a paginated model catalog, `stop()`, `new_chat()` returning boolean/error, `can_execute(params)` returning boolean. Public fields: `state`, `thread_id`, `turn_id`. Tool reply callback accepts `{success=boolean,contentItems=array}` and is single-use/generation-bound. All snake_case is deliberate Lua naming.

- [x] Write tests for initialize, two turns on the same thread, pre-response stop, completed-item deduplication boundary, tool dispatch/late rejection, unexpected close and resume, intentional close and stale OPEN, errors/unknown requests, and timeouts.
- [x] Run tests in Aseprite batch mode and observe missing-client failure.
- [x] Implement the client using the local exported 0.163.0 schemas. Register tool specs verbatim. Use `sandbox="read-only"`, `approvalPolicy="on-request"`; decline built-in approval requests with their actual typed response. No invented resume fields.
- [x] Run `aseprite --batch --script tests/protocol.lua`; expect every assertion to pass.
- [x] Review protocol module before integration; retain test evidence.

## Task 2: Document executor

**Files:** `executor.lua`, `tests/executor.lua`.

**Interfaces:** `local Executor = dofile(path)`; `Executor.tools` is the two dynamic-tool specs. `Executor.new()` returns executor. `bind(sprite,frame,layer)` captures native objects; frame may be native Frame or number. `metadata()` returns table; `read(args)` returns dynamic-tool result with metadata text and PNG data URL; `check(expectedRevision)` returns boolean/error; `execute(args)` returns dynamic-tool result; `dispose()` removes listeners. Controller is responsible for approval and protocol validity before calling execute. Results use `success` and `contentItems` with `inputText`/`inputImage`.

- [x] Write real Sprite tests for preview/metadata of an unsaved sprite, successful pixel editing and one Undo, transaction rollback, stale context, direct image mutation, selection/metadata changes, target close, and cleanup.
- [x] Run tests before module exists and observe failure.
- [x] Implement event tracking and the observation signature from the spec. Expose only the documented execution environment. Tool instructions require cloning and assigning cel images for undoable pixel edits; raw image:drawPixel on an attached image is not undoable.
- [x] Run `aseprite --batch --script tests/executor.lua`; expect every assertion to pass.
- [x] Review executor module before integration; retain evidence.

## Task 3: Native UI and controller

**Files:** `main.lua`, `chat.lua`, `package.json`, `tests/chat.lua`, `tests/controller.lua`.

**Interfaces:** `Chat.new(callbacks,preferences)` returns a native view. Callbacks: `on_connect(endpoint)`, `on_settings(model,effort)`, `on_disconnect()`, `on_send(text)`, `on_stop()`, `on_new_chat()`, `on_close()`. Methods: `show()`, `show_settings()`, `set_state(state)`, `set_models(models,model,effort)`, `add_message(id,role,text,append)`, `request_approval(args,callback)`, `dismiss_approval()`, `close()`. UI owns its own derived transcript and separate native settings dialog. Controller validates every approval again through both client and executor.

`main.lua` defines extension `init(plugin)`/`exit(plugin)` and returns a module exposing `create({path,preferences})` for the extension and integration driver. Controller public user actions: `open`, `connect`, `send`, `stop`, `disconnect`, `new_chat`, `close`. `client`, `executor`, and `view` are owned native components, not independently writable state copies.

- [x] Write tests for wrapping/stream replacement and controller stale approval, rejection, stop and close. Observe initial missing-module failures.
- [x] Implement a scrollable GraphicsContext transcript and approval canvas, native controls, modeless lifecycle, and controller routing.
- [x] Register the extension manifest and command in the installed native `view_controls` menu group; exercise its modules in a real GUI and verify the menu group against the installed gui.xml.
- [x] Run focused tests plus real GUI fixture; expect chat, stream, approval and Undo to work.

## Task 4: End-to-end verification and packaging

**Files:** `tests/fixture.mjs`, `tests/gui.lua`, `scripts/test.ps1`, `scripts/package.ps1`, `README.md`, `docs/validation.md`.

- [x] Load the production extension modules in an isolated disposable editor against a local WebSocket fixture; exercise approval, stale rejection, stop and abrupt reconnect without touching user documents. Record the exact coverage and manual verification boundaries in docs/validation.md.
- [x] Run a real app-server smoke test in that editor: handshake, two prompt turns retaining context, live inspection and approved edit, one Undo, and reconnect tool invocation. Record exact observed results; fixture evidence is separate.
- [x] Run all focused suites, resolve review findings, then perform independent whole-change review on Sol 6.1.
- [x] Package only runtime files into `dist/aseprite-chat.aseprite-extension`, list archive entries, and document installation/start instructions and actual limitations.
- [x] Keep implementation and evidence in the current checkout; no push or merge.
