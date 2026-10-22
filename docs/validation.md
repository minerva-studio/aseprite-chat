# Validation evidence

Recorded on 2026-10-21. Controlled protocol fixtures and actual authenticated model requests are listed separately.

## Environment and authentication

- Windows, Aseprite 1.3.18.6-x64, Codex CLI 0.163.0, Node 24.18.0, ws 8.22.0.
- Actual `account/read` through the bridge reported `account.type = chatgpt` and `requiresOpenaiAuth = true`. The integration used the existing ChatGPT login. No API key was supplied or stored by this extension.
- Direct WebSocket interoperability failed: Aseprite sends an Origin header, which Codex's own listener rejects with 403. The approved runtime bridge uses Codex stdio and retains restrictions on browser clients.

## Focused suites

`scripts/test.ps1` runs inside Aseprite's actual Lua/JSON runtime and requires successful pass markers as well as exit codes:

- Protocol: 29/29; controlled socket/timer factories cover initialization, same-thread turns, streaming replacement, ordering races, cancellation, duplicate calls, malformed messages, approvals, timeouts, socket lifetime/generation, resume, health-ping failure, paginated model discovery, retired catalog callbacks, and per-turn model/effort overrides.
- Executor: 40/40; actual unsaved Sprites cover metadata, rendered PNG previews including indexed colors and size limits, native JSON userdata arguments, one Undo, transaction rollback, stale metadata/pixels/selection/active context, closed documents, and listener cleanup.
- Chat: 8/8; UTF-8 wrapping, empty lines, narrow widths, completed-item replacement, model/reasoning dropdowns, capability changes, locked generation controls, explicit stale-effort clearing, separate settings lifecycle/state, transcript wheel/thumb/track/key input and streaming reading-position retention, and independent approval scrolling that reveals the final code lines.
- Controller: 15/15; approval exactly once, rejection, stale approval, stop/disconnect, close/reopen, approval-time exceptions, connect failures, menu group existence in the installed Aseprite gui.xml, selection validation and persistence, catalog reload, automatic open, single pending startup, startup cancellation/retry and same-thread reconnect at a new automatic port.
- Launcher: 18/18; bounded polling, completion/cancel/late results, errors, I/O permissions, non-reentrant native permission handling, readable constant command length, permission-wait deadline handling, and real hidden PowerShell startup from a path containing Unicode, spaces, apostrophes, percent, ampersand and dollar syntax under process-local Restricted policy.

`npm test`: 16/16; real WebSocket clients and disposable stdio children cover native Origin/Unicode/IDs, browser/Fetch/Host rejection, one-client ownership, reconnect isolation, malformed/binary input, asynchronous and synchronous spawn failures, formatted JSON preserving large numeric ID spelling, failed-handshake recovery, health identity/busy status, idle shutdown, repeated close, atomic discovery replacement/ownership and startup-error publication.

`powershell.exe -NoProfile -File tests/launch.ps1`: 10/10 in Windows PowerShell 5.1, covering live idle reuse, stale/busy/foreign service rejection, native Node/Codex discovery including desktop/npm paths, missing-runtime remedies, child environment restoration, real hidden startup and fixture process ownership.

Missing-module RED runs were recorded before implementation. Review regressions reproduced old-turn adoption, approval-time exceptions, ignored connect failures, native JSON arguments, the invalid menu group, health-ping failure, and synchronous spawn exceptions before their fixes.

## Native GUI and actual model integration

All GUI drivers ran in separate disposable editors and created their own unsaved 8x8 sprites. They did not load or modify existing user documents.

- `tests/gui-chat.lua`: actual native transcript canvas, approval dialog, close/reopen passed.
- `tests/gui.lua` with `tests/fixture.mjs`: native WebSocket/UI integration passed acceptance, rejection, a direct pixel change while approval was pending, stop while awaiting approval, stop while streaming, abrupt TCP loss, automatic reconnect, and a new approved edit after recovery. Approved edits were each reverted with one Undo; the sprite remained unsaved. The response `Hello 你好 — streaming.` belongs to this deterministic fixture and is not model inference.
- `tests/live-protocol.lua`: two actual model turns retained the word cobalt on the same thread through the bridge.
- `tests/gui.lua` with `mode=live`: three actual model turns on one thread, including explicit disconnect/resume, retained cobalt and invoked both live document tools. The model identified the red top-left preview pixel. Each approved clone/assignment changed pixel (1,1) to green and each edit was restored with one Undo. The document remained unsaved. Logs are written to ignored `work/gui-live.txt` and `work/gui-fixture.txt`.

Independent review found and resolved three protocol/controller issues and one bridge startup issue. The final scoped review closed the spawn finding, found no new concrete P1/P2 or unresolved objections, and independently reran protocol 26/26 and bridge 8/8. GUI evidence was inspected without another reviewer-driven GUI run.

## Model selector update

The updated picker uses actual `model/list` capabilities, not a hard-coded model roster or effort enum. Protocol/controller tests verify that model and effort reach `turn/start` without replacing the conversation. The original endpoint/model text-entry behavior has been replaced; changing only the endpoint still starts a new thread.

`tests/gui-models.lua` passed against the real account catalog (7 models): native selectors chose gpt-6.1-sol with low reasoning, then gpt-6-luna with low reasoning; both turns returned orchid in the same thread. This focused smoke test deliberately requested no tools and did not save the disposable sprite. It verifies the model selection path; the preceding live-edit evidence belongs to the earlier full integration run.

`tests/gui-chat.lua` passed actual native dropdown options and selection updates, plus a single model with no reasoning support and a stale persisted effort. Selecting the model from the confirmation placeholder cleared that effort explicitly; canvas/approval/close/reopen assertions also passed. The final result is visible in work/ui-selector-final-464412.png. The drivers leave labeled results in the disposable editor; GUI `print` does not produce redirected stdout in this Aseprite build. Initial attempts to write test logs were paused by file-access prompts and were stopped; those attempts are not counted as successful runs. Result screenshots remain under ignored work/.

The first selector review found the empty-reasoning recovery issue. Its mock regression was observed RED and then GREEN after the confirmation option was added. Scoped review closed the P2 with no new concrete P1/P2 or unresolved objections and independently reran UI 5/5 plus Controller 11/11.

## Native settings and scrolling update

The UI remains inside Aseprite. Connection address and Connect/Disconnect now live in Settings, while Model/Reasoning remain in the main chat. Closing settings leaves the conversation running; closing the main chat cleans up settings and approval windows. The controller remains the sole owner of committed endpoint preferences.

Up/Down buttons were removed. Both canvases use a wider scrollbar with thumb dragging and track paging, mouse wheel input, and focused Page Up/Down, Home/End and arrow keys. Reading older transcript text pauses following; reaching the bottom or selecting Latest resumes it. Aseprite's v1.3.18 canvas implementation establishes native mouse capture and consistent scaled drawing/input coordinates. The documented whole-dialog autoscrollbars option scrolls widget overflow, not canvas text.

RED runs first reproduced connection controls in the main window and then missing canvas mouse handlers. All 88 Lua checks passed (29 protocol, 40 executor, 8 UI, 11 controller). The actual native GUI driver passed settings open/close/reopen and parent cleanup, long-text scrollbar geometry, existing model controls, approval and chat reopening. The layout is captured in ignored work/settings-final-493080.png. Wheel/drag/key behavior is driven through controlled canvas callbacks in batch; this update does not claim an OS-level automated mouse gesture or another model inference run.

Independent review found one P2: painting an approval with fitting content enabled bottom-follow, so restoring its smaller size skipped the beginning. A new fit-then-shrink assertion reproduced the failure; removing the painter's implicit follow assignment passed the regression. Painting now preserves the existing reading policy. The reviewer independently ran UI 8/8 and Controller 11/11 before that correction; the parent reran all 88 Lua checks afterwards. Native GUI passed an actual approval bounds expansion/restoration (work/settings-resize-final-329876.png), while the controlled regression establishes the preserved text position.

## Automatic connection update

The 0.2.0 package includes the complete pinned ws 8.22.0 runtime/license and Windows launcher. Normal use requires installed Node/Codex and the existing login, without npm installation, manual server commands or endpoint entry. Retry repeats discovery/startup; changing an automatically assigned port retains the same thread. The bridge is reused only when live health confirms compatible identity/protocol/PID/port and idle status.

Real packaged runs unpacked the extension into separate system-temp directories containing Chinese, spaces, apostrophes, percent and ampersand characters. Actual Aseprite Lua invoked the hidden Windows PowerShell bootstrap, started Node on an OS-assigned port, then invoked bootstrap again and received that same idle endpoint. Actual account/read reported chatgpt and model/list returned seven models. The final run completed a real Sol request with reply startup-ok on thread 01a16115-67d7-7523-90b7-65f32dae4335. No API key was passed; these responses were not fixtures. The runtime loaded its bundled dependency from the extracted package.

Independent review first found a Restricted-policy direct-file invocation failure and a malformed WebSocket handshake leaving the bridge busy. Both were reproduced and fixed: installed PowerShell code now executes as inline commands with an explicit extension root and caught load errors, without changing execution policy; session ownership begins only after synchronous handshake validation. A second review found nested command encoding could exceed the Windows cmd line limit on long installation paths; the outer source now lives in its own unique temporary file and the actual cmd line is fixed at 210 characters. The scoped final review closed that finding, found no new P1/P2 or unresolved objections, and inspected source lifetime/cancellation cleanup. Focused regressions pass.

The first disposable GUI attempt exposed an unreadably long native command-permission dialog and a reentrant test error handler. That run failed and is not counted as a successful GUI connection. The command now runs from short unique temporary cmd/source paths with fixed cmd line length; the launcher and GUI driver guard permission/result processing against timer reentry. The second disposable editor displayed a readable native file-write prompt (ignored work/auto-gui-short-411880.png) and was closed without granting permissions or changing trust. First-use file/process/network approval and reaching ready after those approvals remain a manual GUI acceptance step. Both test editors were stopped by their recorded owned PIDs; existing user editors were not operated.

## Installation repair in 0.2.1

The user's actual profile still contained 0.1.2 without launcher.lua, while ws 8.22.0 appeared as a separate extension. The 0.2.0 ZIP sorted node_modules/ws/package.json before the root manifest. Aseprite v1.3.18 Extensions::getCompressedExtensionInfo selects the first archive entry whose basename is package.json, then uses its parent as the extraction prefix. Thus the earlier extracted-package smoke established runtime behavior but did not establish native installability.

Packaging now puts the root package.json first and sorts the remaining entries. tests/package.ps1 first reproduced the wrong ws identity, then passed with aseprite-chat 0.2.1 while retaining the complete nested runtime/license. The interpretation is checked against the official v1.3.18 source at https://github.com/aseprite/aseprite/blob/v1.3.18/src/app/extensions.cpp#L1145.

The actual profile installation was backed up and replaced with 0.2.1, preserving __pref.lua byte-for-byte and updating the installed-file inventory. The accidentally installed ws directory was moved into that same backup only after matching its identity and every runtime file against the bundled dependency. No editor process or document was closed. Actual Aseprite Lua loaded launcher.lua from the profile's installed extension directory, started/reused the bridge, and a real account/catalog/turn probe reported chatgpt, seven models and startup-ok on thread 01a1611d-cbbe-7ff1-9f89-abaa4b65b8a8. Existing editors still need a user-controlled restart to replace already loaded old Lua; first-use GUI permission decisions remain native prompts.

## Practical boundaries

- The packaged extension manifest and menu group are checked; installation into the user's existing Aseprite profile is a separate user step. Native UI integration loads the same production modules through its test driver.
- Heartbeats prompted detection of the observed abrupt disconnect. The successful fixture covers that sequence, not every network/OS failure timing.
- The revision signature scans image bytes because direct `drawPixel` does not reliably advance Image.version in this version. Large animations incur linear observation cost; the digest is not cryptographic. Automated changes exercise invalidation; every possible interactive drawing command is not separately automated.
- Approval allows trusted local Lua. Stop cannot preempt Lua already running on the UI thread; transactions undo supported sprite edits, not arbitrary native/external side effects. Scripts must be short, terminating, confined to the captured sprite, and must not save/open/close documents.
- Tested only on the versions above. The first release supports loopback IPv4, one client, plain-text native chat, and no bearer-header or remote transport.
