# Aseprite Chat: Native Codex Client Design

Status: approved for implementation on 2026-10-21. The user accepted the local communication bridge revision below after real direct-connection testing failed.

## Approved transport revision after runtime testing

Real Aseprite WebSocket traffic contains `Origin: ws://127.0.0.1:<port>`, while Codex 0.163.0 rejects any Origin header before initialization. The documented and inspected Aseprite Lua constructor provides no header override. On 2026-10-21 the user accepted adding a local communication bridge to preserve native chat and live unsaved document editing. This revision supersedes references below to direct app-server WebSocket connectivity and a relay-free runtime.

The revised runtime is Aseprite Lua WebSocket -> loopback Node bridge -> Codex app-server stdio. `scripts/server.mjs` starts a separate Codex process per connected client, forwarding JSON frames as JSON lines and protocol output back as text frames. One active client is allowed. Disconnect terminates only that connection's Codex process; reconnect resumes the persisted thread with its tools in a new process. Node 24 and pinned `ws` 8.22.0 are runtime requirements; ws is bundled in the extension. No MCP server or additional model API integration is introduced.

The user's subsequent automatic-connection request supersedes manual terminal startup. Opening the chat resolves an idle compatible service from a per-user discovery hint or port 4500, or starts a hidden bridge on an OS-assigned loopback port. The Windows bootstrap finds installed native Node/Codex executables; it does not take over arbitrary Codex processes. Lua writes a unique temporary cmd containing encoded fixed PowerShell commands so Aseprite's native permission dialog displays a short readable command path. PowerShell reads the installed bootstrap as inline commands with an explicit extension root; it does not modify execution policy. The bridge exits after 120 idle seconds, with no idle limit while connected. Settings exposes manual server configuration only as an advanced opt-in. Bootstrap cancellation invalidates callbacks; it does not kill a service that another client might own.

History requires stable persisted ownership. The bridge sets only its own Codex child's `CODEX_INTERNAL_ORIGINATOR_OVERRIDE` to `aseprite_chat`, overriding any host-specific value without changing global environment/configuration. Discovery and readiness use protocol version 2; automatic startup must not reuse version 1. History list requests use the supported `useStateDbOnly=true` index path, preserving updated_at sorting and avoiding the rollout scan-and-repair latency observed in actual testing.

The listener binds only 127.0.0.1, validates its exact Host, accepts only no Origin or the exact native ws:// loopback Origin matching its port, and rejects browser http(s)/null/foreign origins and Fetch Metadata headers. It does not disable Codex's browser-origin policy or transparently forward arbitrary browser clients. Each text frame must contain one JSON value; binary/multiple-JSON input and oversized traffic are rejected. Child process errors close the client visibly. Tests must establish those behaviors and actual authenticated inference through the bridge.

## Goal and accepted scope

Let the user hold a continuous conversation with Codex inside Aseprite and let Codex inspect and edit the currently open sprite, including unsaved edits. Human drawing and agent edits share the running editor's document. The first release uses an independent Lua extension connected to local Codex app-server stdio through the approved WebSocket bridge. Existing MCP projects are references only.

The extension provides native plain-text chat, streamed responses, task status, cancellation, document inspection, image previews, and approved Lua execution. It does not save the user's sprite automatically. Collaboration means alternating edits with stale-context detection; simultaneous pixel edits are not merged.

## Verified environment and evidence

Verified on 2026-10-21:

- Repository: an initial commit on `main`, containing README.md and assets/icon.svg; no existing application code or local changes.
- Running Aseprite: `D:\SteamLibrary\steamapps\common\Aseprite\aseprite.exe`, version `1.3.18.6-x64`.
- Codex CLI: `0.163.0`, already signed in using ChatGPT.
- Its `app-server --help` advertises `--listen ws://IP:PORT` and optional WebSocket authentication flags.
- Its experimental JSON schemas were exported to the operating system temporary directory and inspected. Dynamic tools require `type: "function"`; replies use `contentItems` with `inputText` or `inputImage`, plus `success`.

The CLI/schema inspection establishes the available protocol. Subsequent runtime results, including authenticated inference and live editing, are recorded in `docs/validation.md`.

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

Use Lua native UI and a WebSocket connection to the local Node bridge. The bridge only adapts transport framing and owns its Codex child process; protocol state stays in the Lua client. A Webview is outside this release.

The default is automatic local discovery/startup; port 4500 is only a conventional discovery candidate. The plugin accepts only IPv4 loopback endpoints. The bridge spawns `codex app-server --stdio` without a shell, using the user's existing configuration and login. Bearer-header authentication is outside this release's transport contract because the documented Aseprite WebSocket constructor has no request-header parameter. The extension exposes no incoming Lua execution server.

On connection, query all pages of `model/list` with `includeHidden=false`. Use the canonical model field and its returned reasoning capabilities to populate native Model and Reasoning dropdowns. An unset selection uses the catalog's recommended model and reasoning default. Persist explicit model/effort selections; when they become unavailable, block Send until the user selects a supported pair. Do not silently replace an explicit choice. For a model that no longer supports reasoning, require model reconfirmation to clear an old effort. Selection is locked during generation. Each turn snapshots the choice and sends model/effort overrides on `turn/start`, preserving the same conversation when settings change. Changing the endpoint starts a new conversation.

## Modules and state ownership

- `package.json`: extension metadata and script contribution for `main.lua`.
- `main.lua`: registers the menu command, constructs one client and one chat dialog, routes UI actions and tool requests, and disposes resources on exit. It owns the currently bound turn target and tool-request lifecycle.
- `codex.lua`: WebSocket, JSON encoding/decoding, connection generation, request IDs and callbacks, initialization, thread ID, active turn ID, streaming items, stop requests, and transport errors. It owns protocol state; the UI receives derived views of it.
- `chat.lua`: modeless native Dialog, plain-text transcript canvas, scrolling, input, status, settings, new-chat action, stop, and approve/reject controls. It owns presentation state only.
- `executor.lua`: target binding, document revision tracking, structured inspection, rendered previews, and transaction-wrapped Lua execution. It owns the authoritative local revision counter for its bound sprite.
- `timeline.lua`: stateless projection of persisted items and live tool results into transcript entries. It omits raw reasoning and image payloads, bounds code/results, and never invokes tools.
- `launcher.lua`: one cancellable bootstrap attempt, short temporary startup command and non-reentrant result polling; connection state stays in the protocol client.
- `scripts/launch.ps1`: bounded native executable discovery, live idle-service validation and hidden process startup; accepts an explicit extension root for inline invocation.
- `scripts/package.ps1`: deterministic extension packaging with the complete pinned ws runtime into `dist/aseprite-chat.aseprite-extension`.
- `tests/`: focused Lua tests runnable in Aseprite batch mode and a dependency-free Node WebSocket protocol fixture for integration checks.
- `README.md`: installation, local server startup, normal use, permissions, and the verified support matrix.

Use local modules loaded relative to the extension directory. Do not mutate global package paths. Do not keep a second persisted copy of Codex conversation history. Plugin preferences contain endpoint, canonical model and reasoning effort; thread and target bindings remain in memory for the current extension session.

## Conversation and UI flow

Opening the menu command creates or reveals one modeless chat window. Controls include catalog model and reasoning dropdowns, status, New Chat, message input, Send, Stop, Latest and Settings, and a scrollable transcript. Settings opens one separate modeless native dialog containing endpoint and Connect/Disconnect. Closing settings preserves the chat; closing the chat also closes settings and approvals. The address is editable only while disconnected/error, and preferences change only when the controller starts a connection. Status distinguishes disconnected, connecting, initializing, ready, working, awaiting approval, stopping, and error. Send is enabled only when ready with a bound open sprite. No sprite is required merely to connect.

User messages and agent output appear as plain text. Transcript entries are keyed by protocol item ID; deltas append to that item, while completed-item text replaces its accumulated text to prevent duplicates. Rendering wraps text using GraphicsContext measurements and preserves UTF-8 character boundaries. Both transcript and approval canvases support wheel scrolling, a draggable thumb, track paging, and focused Page Up/Down, Home/End and arrow keys. Their scroll states are independent; reading older text pauses automatic following until the user reaches the bottom or selects Latest. The shared canvas handler uses Aseprite's native mouse capture and scaled coordinates. Whole-dialog autoscrollbars only address widget overflow and are not a substitute for transcript scrolling. Repainting does not recreate the dialog or steal drawing focus.

At Send, bind the currently active sprite, frame, and layer to that turn. Include fresh structured context with the prompt. Subsequent messages use the same server thread. A later turn can bind a different current sprite, and its prompt explicitly identifies the new target. There is one active turn and one pending Lua approval at a time; sending another prompt is disabled until that turn ends.

New Chat is enabled only while idle. It clears the current local transcript and thread binding, then creates a new server thread on the next message. Closing the window cancels the active turn, rejects pending execution, closes the socket, and removes document listeners. Reopening starts a fresh client session.

The user's approved history/activity revision adds a modeless conversation list with search, refresh and pagination from Codex's persisted threads. Only originator `aseprite_chat` conversations appear. Explicit opening verifies an inactive thread, resumes it with current developer instructions and reads full turn pages in chronological order before replacing the local binding/transcript. Failure preserves the old conversation. Historical tools are display-only; the next turn binds the current editor target. Active conversations in other editors are not interrupted. Protocol ownership remains in `codex.lua`, with no second history store.

The transcript shows keyed live tool activity and bounded persisted code/textual results, plus provider-supplied reasoning summaries. Tools/summaries default to compact collapsed rows; clicking their header or Enter on a selected activity toggles details without discarding text or replaying tools. Expansion is presentation state on the keyed message, preserved by updates. The main toolbar groups conversation navigation; previous/next controls jump to user prompts and model/reasoning selectors sit near the composer. The conversation list uses compact two-line canvas rows, title/time/preview, selection highlighting, keyboard navigation and double-click/Enter to open. Its scroll state is manual, separate from transcript follow; refresh resets to the top and pagination preserves position. Summary deltas are ordered by section; the completed summary replaces streaming text, including an empty final summary. Raw reasoning content is omitted. Live user messages use the local send echo once; persisted user items are projected when opening history.

## Wire protocol and failure behavior

One JSON message is sent per WebSocket text frame, without a `jsonrpc` field. Client request IDs are monotonically increasing. Server request IDs are echoed exactly, preserving their string or numeric type. Unknown notifications are ignored; unsupported server requests receive a JSON-RPC method-not-found error rather than remaining unanswered.

1. On OPEN, send `initialize` with client name, title, version, and `capabilities.experimentalApi = true`.
2. After initialization succeeds, send `initialized` and expose ready status.
3. Before the first turn, call `thread/start` with the dynamic tools, optional model, plain-text/Aseprite developer instructions, and read-only Codex filesystem sandbox settings. Request explicit approval for built-in shell or file actions; those are not needed for the canvas workflow and are rejected by this client with a visible explanation.
4. Send `turn/start` with the thread ID and user prompt plus current target context. Record the turn ID from either response or matching notification.
5. Handle `item/agentMessage/delta`, `item/started`, `item/completed`, `turn/started`, `turn/completed`, and errors by matching thread and turn IDs. Avoid speculative success messages before tool results arrive.
6. Stop first invalidates local execution permission and rejects queued Lua calls, then sends `turn/interrupt`. If the turn ID has not arrived, remember the stop intent and interrupt as soon as it is known.

Separate a socket-object lifetime from a connection generation. A Connect action creates one WebSocket object and a new lifetime token. Its callback captures that token and ignores every event once the token is invalid. Each OPEN on that object, including automatic reconnect, begins a new connection generation, invalidates old request callbacks, and performs initialization again. Each unexpected CLOSE immediately invalidates outstanding requests and pending approvals. Do not create a competing reconnect timer: Aseprite's WebSocket owns retry scheduling.

After initialization, send a WebSocket ping every two seconds. Aseprite 1.3.18.6 may discover an abrupt peer FIN only on a subsequent write. A failed ping invalidates the current generation and pending execution while retaining the socket for native reconnection. Stop the heartbeat on loss, retirement, and before a new OPEN; it does not impose a model-thinking timeout.

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

The user's explicit additional option **Auto-approve edits (this chat)** defaults off and lives only in the controller, with the view projecting it. It can be enabled only while idle, is never persisted, resets on New Chat, successful explicit history selection, closing the chat or changing the server, and survives reconnection of the same open chat. Both approval modes use the same single-use execution path, immediate target/revision/turn checks and Undo transaction. Aseprite native file/process/network trust remains a separate user decision stored by script filename.

Compile text-only Lua with `load(code, name, "t", environment)`. Provide the captured `sprite`, native `app`, Aseprite constructors/constants, and ordinary math/string/table/UTF-8 functions. Do not expose `io`, `os`, `debug`, `package`, `require`, `dofile`, `loadfile`, or recursive `load` to model code. The native Aseprite objects remain powerful; this is an approved editor automation contract, not a security sandbox for hostile Lua.

Run the compiled function inside `app.transaction("Codex: " .. summary, callback)`. Do not swallow Lua errors inside the transaction callback: they must escape it to roll back undoable changes, then be reported outside it. Refresh the editor after success. Return the result and new revision. Mutation scripts use supported undoable Aseprite APIs, edit only the captured sprite, and do not open/close/save documents or invoke external side effects. Prompt instructions document these obligations; the approval UI makes the proposed script inspectable. Undo covers normal undoable sprite edits, not every possible effect of native Lua APIs.

Lua execution is synchronous on Aseprite's UI thread. Stop cancels model generation and pending execution; it cannot interrupt a script already running or a native editor operation in progress. The first release requires short, terminating scripts and states this limit beside execution approval. Do not claim arbitrary Lua can always be stopped or rolled back.

Maintain one monotonically increasing revision for the bound sprite. Register `sprite.events` listeners for `change`, `filenamechange`, `layerblendmode`, `layername`, `layeropacity`, and `layervisibility`; every notification increments that revision, including Undo/Redo notifications. Also observe `app.events.sitechange` to invalidate a previously read context after a document/frame/layer switch, even if the user switches back. Conservatively increment the same revision on `app.events.aftercommand` while the bound sprite is active, because editor commands can change selection, locks, or other context beyond the sprite event list. This can require an extra inspection after an unrelated command; it must never authorize stale execution.

At every inspection and immediately before approval/execution, compare the live sprite against a derived observation signature: dimensions, color mode, frame identities/durations, layer hierarchy and relevant properties, cel positions/opacities and image IDs/versions, a derived pixel-byte digest, palette colors, and selection bounds. A changed signature advances the same revision and replaces the cached signature. Actual `drawPixel` tests show `Image.version` alone does not cover all direct pixel mutations, so the digest scans live bytes as well. This has linear cost and is not a cryptographic guarantee against adversarial collisions. The signature is an observation cache, never another writable document model or a separate revision source. Changes to selection shape through supported editor commands are covered by `aftercommand`; non-command external scripts that mutate selection without any observable event are outside the first release's concurrent-editor contract.

Do not use `Sprite.isModified` as a revision: it is only a saved-state flag. Attach listeners before the first read, publish the current revision only after collecting the live observation, and remove all listener handles on target replacement or disposal. A failed observation or an invalid/closed sprite prevents execution and requests another inspection. Successful agent mutations advance this same revision source; they do not reset it or maintain a separate agent revision. Always inspect afresh before edits in a new turn.

## Acceptance and validation

The release is complete only when the following evidence is recorded:

1. In Aseprite, connect to a real local Codex app-server and complete initialization.
2. Send two successive prompts on one thread and observe streamed replies and retained conversation context.
3. Create a disposable unsaved sprite, make an identifiable manual change, and verify `read_sprite` reports it and returns a matching preview.
4. Approve an edit that changes a known pixel/layer; observe the live result and undo it with one Undo. Verify no source document was saved.
5. Reject another edit and verify the document is unchanged.
6. After inspection, separately test a manual stroke, Undo, Redo, layer creation/deletion, layer name/visibility/opacity/blend-mode/lock changes, selection changes, frame changes, and active-document changes; each must invalidate pending execution. Switch away and back and verify the old approval is still invalid. Test a direct pixel mutation by another script and verify the live pixel observation detects it. Close the target and verify no other document is modified.
7. Make a transaction fail after an initial mutation and verify rollback.
8. Stop while streaming and while awaiting approval; verify no later tool call is executed for that turn.
9. Disconnect/reconnect while idle and during an active turn; invoke both document tools after resuming the same thread and verify tools remain available, callbacks and edits are not replayed, and the UI returns to a usable state. Exercise OPEN/CLOSE events on the same socket object, intentional Disconnect followed by a late OPEN, and a replacement socket receiving old-object events; retired objects must not initialize or execute tools.
10. Check UTF-8 wrapping, long replies, scrolling, repeated open/close, listener cleanup, unknown server requests, malformed messages, and duplicate completed-item delivery.

Use Aseprite batch-mode tests for real Sprite/transaction behavior and Lua protocol tests with a fake transport for ordering/races. Use a local fixture to exercise the real Aseprite WebSocket/UI callbacks. A fixture cannot establish successful model inference; report it separately from the real Codex smoke test. Test against disposable documents and an isolated test editor instance so existing user documents remain untouched.

Package the extension and document exact install/start steps. Do not push or merge. Any required installation outside the workspace or manual interaction that automation cannot perform must be reported explicitly, with the remaining acceptance test identified.

## Design review disposition

Read-only Luna review round 1 returned three findings on 2026-10-21. The lifecycle and revision-coverage concerns are accepted and resolved by the explicit socket lifetime/generation rules, event list, live observation signature, and expanded acceptance cases above. The proposed `dynamicTools` resume parameter is rejected: it is absent from the locally generated 0.163.0 `ThreadResumeParams`, and the official app-server documentation describes restoring tools from persisted thread metadata. The design now states that mechanism and requires a post-resume tool test. These are design resolutions; subsequent runtime evidence is recorded in docs/validation.md.
