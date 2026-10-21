# Aseprite Chat: Native Codex Client Design

Status: ready for user review; product implementation has not started.

## Goal and accepted scope

Let the user hold a continuous conversation with Codex inside Aseprite and let Codex inspect and edit the currently open sprite, including unsaved edits. Human drawing and agent edits share the running editor's document. The first release uses an independent Lua extension connected directly to a local Codex app-server over WebSocket. Existing MCP projects are references only.

The extension provides native plain-text chat, streamed responses, task status, cancellation, document inspection, image previews, and approved Lua execution. It does not save the user's sprite automatically. Collaboration means alternating edits with stale-context detection; simultaneous pixel edits are not merged.

## Verified environment and evidence

Verified on 2026-10-21:

- Repository: an initial commit on `main`, containing README.md and assets/icon.svg; no existing application code or local changes.
- Running Aseprite: `D:\SteamLibrary\steamapps\common\Aseprite\aseprite.exe`, version `1.3.18.6-x64`.
- Codex CLI: `0.163.0`, already signed in using ChatGPT.
- Its `app-server --help` advertises `--listen ws://IP:PORT` and optional WebSocket authentication flags.
- Its experimental JSON schemas were exported to the operating system temporary directory and inspected. Dynamic tools require `type: "function"`; replies use `contentItems` with `inputText` or `inputImage`, plus `success`.

The CLI/schema inspection establishes the available protocol, not successful runtime interoperability. WebSocket delivery, dialog repainting, live editing, and authenticated model inference remain acceptance tests.

Primary references:

- https://learn.chatgpt.com/docs/app-server
- https://www.aseprite.org/api/websocket
- https://www.aseprite.org/api/dialog
- https://www.aseprite.org/api/plugin
- https://www.aseprite.org/api/json
- https://www.aseprite.org/api/sprite
- https://www.aseprite.org/api/image
- https://www.aseprite.org/api/app
- https://www.aseprite.org/api/app_fs

## Architecture decision

Use Lua native UI and a direct WebSocket connection to a manually launched local Codex app-server. This matches the agreed architecture and keeps the first executable path small. A separate Python/Node relay would add another process and protocol owner; a Webview would add another UI runtime. Neither is part of this release.

The initial endpoint is `ws://127.0.0.1:4500`. The plugin accepts only IPv4 loopback endpoints. The user starts the server in a terminal with `codex app-server --listen ws://127.0.0.1:4500`. The plugin neither launches shell commands nor changes the user's Codex configuration or login. An endpoint protected by bearer authentication is outside this release's transport contract because the documented Aseprite WebSocket constructor has no request-header parameter. The extension exposes no incoming Lua execution server.

Use the server's configured default model, with an optional model ID in plugin settings. Explicit model selection must be passed unchanged; an unavailable model produces an error. Do not silently select a different model.

## Modules and state ownership

- `package.json`: extension metadata and script contribution for `main.lua`.
- `main.lua`: registers the menu command, constructs one client and one chat dialog, routes UI actions and tool requests, and disposes resources on exit. It owns the currently bound turn target and tool-request lifecycle.
- `codex.lua`: WebSocket, JSON encoding/decoding, connection generation, request IDs and callbacks, initialization, thread ID, active turn ID, streaming items, stop requests, and transport errors. It owns protocol state; the UI receives derived views of it.
- `chat.lua`: modeless native Dialog, plain-text transcript canvas, scrolling, input, status, settings, new-chat action, stop, and approve/reject controls. It owns presentation state only.
- `executor.lua`: target binding, document revision tracking, structured inspection, rendered previews, and transaction-wrapped Lua execution. It owns the authoritative local revision counter for its bound sprite.
- `scripts/package.ps1`: deterministic extension packaging into `dist/aseprite-chat.aseprite-extension`.
- `tests/`: focused Lua tests runnable in Aseprite batch mode and a dependency-free Node WebSocket protocol fixture for integration checks.
- `README.md`: installation, local server startup, normal use, permissions, and the verified support matrix.

Use local modules loaded relative to the extension directory. Do not mutate global package paths. Do not keep a second persisted copy of Codex conversation history. Plugin preferences contain endpoint and optional model; thread and target bindings remain in memory for the current extension session.

## Conversation and UI flow

Opening the menu command creates or reveals one modeless chat window. Controls include endpoint, optional model, Connect/Disconnect, New Chat, message input, Send, Stop, and a scrollable transcript. Status distinguishes disconnected, connecting, initializing, ready, working, awaiting approval, stopping, and error. Send is enabled only when ready with a bound open sprite. No sprite is required merely to connect.

User messages and agent output appear as plain text. Transcript entries are keyed by protocol item ID; deltas append to that item, while completed-item text replaces its accumulated text to prevent duplicates. Rendering wraps text using GraphicsContext measurements and preserves UTF-8 character boundaries. Repainting does not recreate the dialog or steal drawing focus.

At Send, bind the currently active sprite, frame, and layer to that turn. Include fresh structured context with the prompt. Subsequent messages use the same server thread. A later turn can bind a different current sprite, and its prompt explicitly identifies the new target. There is one active turn and one pending Lua approval at a time; sending another prompt is disabled until that turn ends.

New Chat is enabled only while idle. It clears the current local transcript and thread binding, then creates a new server thread on the next message. Closing the window cancels the active turn, rejects pending execution, closes the socket, and removes document listeners. Reopening starts a fresh client session.

## Wire protocol and failure behavior

One JSON message is sent per WebSocket text frame, without a `jsonrpc` field. Client request IDs are monotonically increasing. Server request IDs are echoed exactly, preserving their string or numeric type. Unknown notifications are ignored; unsupported server requests receive a JSON-RPC method-not-found error rather than remaining unanswered.

1. On OPEN, send `initialize` with client name, title, version, and `capabilities.experimentalApi = true`.
2. After initialization succeeds, send `initialized` and expose ready status.
3. Before the first turn, call `thread/start` with the dynamic tools, optional model, plain-text/Aseprite developer instructions, and read-only Codex filesystem sandbox settings. Request explicit approval for built-in shell or file actions; those are not needed for the canvas workflow and are rejected by this client with a visible explanation.
4. Send `turn/start` with the thread ID and user prompt plus current target context. Record the turn ID from either response or matching notification.
5. Handle `item/agentMessage/delta`, `item/started`, `item/completed`, `turn/started`, `turn/completed`, and errors by matching thread and turn IDs. Avoid speculative success messages before tool results arrive.
6. Stop first invalidates local execution permission and rejects queued Lua calls, then sends `turn/interrupt`. If the turn ID has not arrived, remember the stop intent and interrupt as soon as it is known.

Separate a socket-object lifetime from a connection generation. A Connect action creates one WebSocket object and a new lifetime token. Its callback captures that token and ignores every event once the token is invalid. Each OPEN on that object, including automatic reconnect, begins a new connection generation, invalidates old request callbacks, and performs initialization again. Each unexpected CLOSE immediately invalidates outstanding requests and pending approvals. Do not create a competing reconnect timer: Aseprite's WebSocket owns retry scheduling.

Disconnect and window close first invalidate the socket lifetime token, clear the client socket reference, and settle local pending requests, then call `WebSocket:close()`. A late OPEN from that retired object must be closed without sending initialization. A subsequent explicit Connect creates a new socket object. A timeout or malformed protocol message retires the socket through the same path. These rules prevent callbacks from a retired object from reviving an intentionally closed session.

On connection loss, abort pending approvals and mark an in-flight turn interrupted locally; never replay an edit. After reconnect initialization, send `thread/resume` with `threadId` and `excludeTurns: true`. Keep the original tool definitions unchanged: the server persists and restores them from the thread metadata. In the inspected Codex 0.163.0 schema, `ThreadResumeParams` has no `dynamicTools` field; do not send an invented resume parameter. Verify a real tool invocation after resume in the integration test.

Before enabling Send, inspect `thread.status`. If active, call `thread/turns/list` with `limit: 1`, `sortDirection: "desc"`, and `itemsView: "summary"` to obtain the active turn ID, then send `turn/interrupt` and wait for that turn to become terminal. No tool may execute during recovery. If an active turn cannot be identified or interrupted, keep Send disabled and show the failure. If resume fails, show the error and let the user explicitly start a new chat; do not silently discard history.

Malformed JSON, protocol errors, failed thread/turn requests, and socket errors become visible transcript/status messages. A failed send does not claim that the model received the prompt. A server overload error is shown without automatically replaying a turn or tool response. A 30-second timeout on initialization and client request responses closes the connection and invalidates pending callbacks; model generation itself has no artificial short timeout.

## Document tools and edit contract

Register two dynamic tools:

### `read_sprite`

Input: optional `frame` (1-based integer); omitted means the turn's captured frame.

Return structured text containing sprite ID, revision, dimensions, color mode, modified/file association flags, frame count and durations, nested layers with IDs/names/types/visibility/locking, active layer, and selection bounds. Return a rendered image of the requested frame as an `inputImage` PNG data URL alongside the text. The image is rendered from the live sprite using an independent RGB image and `Image:drawSprite`; it does not save, flatten, or otherwise modify the user's document.

Encode the preview by writing a plugin-owned temporary PNG beneath `app.fs.tempPath`, reading its bytes, encoding them with a small local base64 implementation, and deleting that file after encoding. Cap preview dimensions at 1024 pixels on the longest edge while preserving aspect ratio; report the original and preview dimensions. Refuse malformed or out-of-range frame inputs.

### `execute_lua`

Input: `code` (string), `summary` (short user-facing explanation), and `expectedRevision` (integer returned by inspection).

Check that the request belongs to the live active thread/turn, the captured sprite is still open and active, the frame/layer context is unchanged, and its revision equals `expectedRevision`. A failed check returns a tool failure instructing Codex to inspect again. It never switches the user's active document to run stale code.

Show the summary and complete proposed Lua in a scrollable modeless native approval dialog with Approve and Reject. Keep receiving protocol events while the user considers it. Approval applies only to that request, target, and revision. Recheck all conditions immediately before execution because the user may have drawn while the approval was pending. Cancellation, disconnect, closed target, or a resolved request invalidates the approval.

Compile text-only Lua with `load(code, name, "t", environment)`. Provide the captured `sprite`, native `app`, Aseprite constructors/constants, and ordinary math/string/table/UTF-8 functions. Do not expose `io`, `os`, `debug`, `package`, `require`, `dofile`, `loadfile`, or recursive `load` to model code. The native Aseprite objects remain powerful; this is an approved editor automation contract, not a security sandbox for hostile Lua.

Run the compiled function inside `app.transaction("Codex: " .. summary, callback)`. Do not swallow Lua errors inside the transaction callback: they must escape it to roll back undoable changes, then be reported outside it. Refresh the editor after success. Return the result and new revision. Mutation scripts use supported undoable Aseprite APIs, edit only the captured sprite, and do not open/close/save documents or invoke external side effects. Prompt instructions document these obligations; the approval UI makes the proposed script inspectable. Undo covers normal undoable sprite edits, not every possible effect of native Lua APIs.

Lua execution is synchronous on Aseprite's UI thread. Stop cancels model generation and pending execution; it cannot interrupt a script already running or a native editor operation in progress. The first release requires short, terminating scripts and states this limit beside execution approval. Do not claim arbitrary Lua can always be stopped or rolled back.

Maintain one monotonically increasing revision for the bound sprite. Register `sprite.events` listeners for `change`, `filenamechange`, `layerblendmode`, `layername`, `layeropacity`, and `layervisibility`; every notification increments that revision, including Undo/Redo notifications. Also observe `app.events.sitechange` to invalidate a previously read context after a document/frame/layer switch, even if the user switches back. Conservatively increment the same revision on `app.events.aftercommand` while the bound sprite is active, because editor commands can change selection, locks, or other context beyond the sprite event list. This can require an extra inspection after an unrelated command; it must never authorize stale execution.

At every inspection and immediately before approval/execution, compare the live sprite against a derived observation signature: dimensions, color mode, frame identities/durations, layer hierarchy and relevant properties, cel positions/opacities and image IDs/versions, palette colors, and selection bounds. A changed signature advances the same revision and replaces the cached signature. `Image.version` covers direct pixel mutations that may not emit an undoable content event. The signature is an observation cache, never another writable document model or a separate revision source. Changes to selection shape through supported editor commands are covered by `aftercommand`; non-command external scripts that mutate selection without any observable event are outside the first release's concurrent-editor contract.

Do not use `Sprite.isModified` as a revision: it is only a saved-state flag. Attach listeners before the first read, publish the current revision only after collecting the live observation, and remove all listener handles on target replacement or disposal. A failed observation or an invalid/closed sprite prevents execution and requests another inspection. Successful agent mutations advance this same revision source; they do not reset it or maintain a separate agent revision. Always inspect afresh before edits in a new turn.

## Acceptance and validation

The release is complete only when the following evidence is recorded:

1. In Aseprite, connect to a real local Codex app-server and complete initialization.
2. Send two successive prompts on one thread and observe streamed replies and retained conversation context.
3. Create a disposable unsaved sprite, make an identifiable manual change, and verify `read_sprite` reports it and returns a matching preview.
4. Approve an edit that changes a known pixel/layer; observe the live result and undo it with one Undo. Verify no source document was saved.
5. Reject another edit and verify the document is unchanged.
6. After inspection, separately test a manual stroke, Undo, Redo, layer creation/deletion, layer name/visibility/opacity/blend-mode/lock changes, selection changes, frame changes, and active-document changes; each must invalidate pending execution. Switch away and back and verify the old approval is still invalid. Test a direct pixel mutation by another script and verify image-version observation detects it. Close the target and verify no other document is modified.
7. Make a transaction fail after an initial mutation and verify rollback.
8. Stop while streaming and while awaiting approval; verify no later tool call is executed for that turn.
9. Disconnect/reconnect while idle and during an active turn; invoke both document tools after resuming the same thread and verify tools remain available, callbacks and edits are not replayed, and the UI returns to a usable state. Exercise OPEN/CLOSE events on the same socket object, intentional Disconnect followed by a late OPEN, and a replacement socket receiving old-object events; retired objects must not initialize or execute tools.
10. Check UTF-8 wrapping, long replies, scrolling, repeated open/close, listener cleanup, unknown server requests, malformed messages, and duplicate completed-item delivery.

Use Aseprite batch-mode tests for real Sprite/transaction behavior and Lua protocol tests with a fake transport for ordering/races. Use a local fixture to exercise the real Aseprite WebSocket/UI callbacks. A fixture cannot establish successful model inference; report it separately from the real Codex smoke test. Test against disposable documents and an isolated test editor instance so existing user documents remain untouched.

Package the extension and document exact install/start steps. Do not push or merge. Any required installation outside the workspace or manual interaction that automation cannot perform must be reported explicitly, with the remaining acceptance test identified.

## Design review disposition

Read-only Luna review round 1 returned three findings on 2026-10-21. The lifecycle and revision-coverage concerns are accepted and resolved by the explicit socket lifetime/generation rules, event list, live observation signature, and expanded acceptance cases above. The proposed `dynamicTools` resume parameter is rejected: it is absent from the locally generated 0.163.0 `ThreadResumeParams`, and the official app-server documentation describes restoring tools from persisted thread metadata. The design now states that mechanism and requires a post-resume tool test. These are design resolutions; runtime evidence remains outstanding.
