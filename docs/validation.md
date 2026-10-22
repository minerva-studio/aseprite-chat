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
- Chat: 5/5; UTF-8 wrapping, empty lines, narrow widths, completed-item replacement, model/reasoning dropdowns, capability changes, locked generation controls, and explicit stale-effort clearing for a model with no reasoning support.
- Controller: 11/11; approval exactly once, rejection, stale approval, stop/disconnect, close/reopen, approval-time exceptions, connect failures, menu group existence in the installed Aseprite gui.xml, selection validation and persistence, and catalog reload without silently replacing unavailable models.

`npm test`: 8/8; real WebSocket clients and disposable stdio children cover native Origin/Unicode/IDs, browser/Fetch/Host rejection, one-client ownership, reconnect isolation, malformed/binary input, asynchronous and synchronous spawn failures, and formatted JSON preserving large numeric ID spelling.

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

## Practical boundaries

- The packaged extension manifest and menu group are checked; installation into the user's existing Aseprite profile is a separate user step. Native UI integration loads the same production modules through its test driver.
- Heartbeats prompted detection of the observed abrupt disconnect. The successful fixture covers that sequence, not every network/OS failure timing.
- The revision signature scans image bytes because direct `drawPixel` does not reliably advance Image.version in this version. Large animations incur linear observation cost; the digest is not cryptographic. Automated changes exercise invalidation; every possible interactive drawing command is not separately automated.
- Approval allows trusted local Lua. Stop cannot preempt Lua already running on the UI thread; transactions undo supported sprite edits, not arbitrary native/external side effects. Scripts must be short, terminating, confined to the captured sprite, and must not save/open/close documents.
- Tested only on the versions above. The first release supports loopback IPv4, one client, plain-text native chat, and no bearer-header or remote transport.
