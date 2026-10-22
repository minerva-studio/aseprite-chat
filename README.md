# Aseprite Chat

A native Aseprite chat window for Codex. Talk about the current sprite, inspect its unsaved layers and rendered frame, and approve Lua edits that appear directly in the running editor.

The editor extension is Lua. Opening the chat automatically finds or starts a small local Node communication bridge, which starts Codex app-server using its stdio transport. No terminal command, port entry, MCP server, browser, or Python is required for normal use. The bridge exists because this Aseprite version always sends an Origin header and Codex rejects that header on its own WebSocket listener.

## Requirements

- Windows, Aseprite 1.3.18.6, and Codex CLI 0.163.0 are the initial verification environment. Other versions/platforms are not claimed as tested.
- Codex must already be signed in (`codex login`) for the default account. The plugin uses that login through app-server. A **Custom Codex home** account (below) can instead use an API key or a compatible Responses endpoint, in which case a Codex login is not required.
- Node.js 24 or later is required for the local communication bridge. The plugin locates it and the Codex executable automatically; the bridge's pinned JavaScript dependency is included in the extension.
- The installed Codex version must support the experimental dynamic-tool API. The plugin opts into the experimental protocol during initialization.

## Install and start

1. Use the supplied `aseprite-chat.aseprite-extension` package. Source builds are described under Development and verification.
2. Double-click `dist/aseprite-chat.aseprite-extension`, or install it through Aseprite's **Edit > Preferences > Extensions > Add Extension**. Enable the extension and restart Aseprite if requested.
3. Open **View > Aseprite Chat**. The plugin detects an existing compatible local service or starts one in the background, then loads your account's model list. Aseprite can ask permission to launch the plugin's connection helper and read its temporary startup result; those are normal native script permissions.
4. Choose a model and reasoning level on the control bar below the input. Supported models show a **Fast** toggle on the action bar below the input; it starts off. Models without Fast have no speed control. An initial model selection uses the catalog's recommended model and reasoning default. If startup fails, the message explains the next action; **Retry** searches again without entering a server address.
5. Open a sprite and send a message. Unsaved sprites work; saving the document first is unnecessary.

The bridge launches `codex app-server --stdio` for each client connection, using the existing Codex configuration and login. It sets the child process's originator to `aseprite_chat` so launch-host overrides cannot mix this extension's history with other clients. Codex's built-in tool surfaces (sub-agents, web search, image generation, apps, plugins and similar features) are disabled for every child. Shell commands and `view_image` are disabled too unless the action bar's **Access dropdown** grants file access (see below). Automatic startup looks for native executables on PATH and in the standard Node/Codex desktop installation directories. It validates a per-user service-discovery hint and the conventional port 4500, reuses only an idle compatible bridge (readiness version 3), and otherwise starts its own bridge on an OS-assigned free port. It does not scan or take over arbitrary Codex processes. An automatically started bridge exits after two idle minutes; connected conversations keep it alive.

**Settings... > Manual server (advanced)** is an explicit opt-in for a separately managed compatible bridge. Developer-only manual startup remains available with `npm start`, `CODEX_CLI` and `ASEPRITE_CHAT_PORT`; these are not required in the normal plugin flow.

Aseprite may ask permission to connect to localhost and create/read a temporary PNG preview. Grant those permissions only for this installed extension. The preview is an independent render; the original sprite is not saved or flattened.

## Account

**Settings... > Account** chooses which Codex home and credentials the bridge uses. Applying an account saves it to `%LOCALAPPDATA%\AsepriteChat\providers.json`, starts a new conversation, and reconnects; it is only possible while the chat is idle.

- **Codex default (~/.codex)** runs Codex exactly as before, with your normal Codex home (usually a ChatGPT sign-in from `codex login`).
- **Custom Codex home** runs Codex with `CODEX_HOME` set to the chosen folder (default `%LOCALAPPDATA%\AsepriteChat\codex-home`). Codex keeps its own configuration and writes its session history inside that home, so **Chats...**, **Rename...** and conversation resume work per home — switching accounts switches history too.
  - **Base URL** and **API key** are optional. With either set, the child uses a custom `model_provider` speaking the Responses API: requests go to `<Base URL>/responses` with `Authorization: Bearer <key>` (a key with an empty URL targets the official `https://api.openai.com/v1`). With both empty, the custom home's own configuration and login are used instead.
  - The API key is stored **plaintext in `providers.json` only** — never in Aseprite preferences, Codex's `config.toml`, command lines, or logs. Settings shows only a trailing hint; the key entry stays blank to keep the saved key, and **Remove saved key** clears it.
  - **Models** optionally lists model IDs (comma-separated). When non-empty it replaces the server catalog in the picker — Codex's `model/list` always returns its bundled OpenAI entries regardless of provider, which is rarely useful for a custom endpoint. Each listed model is offered with low/medium/high reasoning and normal speed, with no Fast control.

## Canvas tools

The model works through the extension's own tools:

- `read_sprite` returns document metadata (open sprites, layers, frames, palette, tags, slices, cels) and PNG previews. It can select frames by list or tag with no frame limit (several sheets plus a layout when needed), isolate layers without changing the document, crop a region, and overlay a grid. Small pixel art is upscaled with nearest-neighbor.
- `read_pixels` returns exact pixel values for up to 4096 pixels without an approval.
- Other open sprites can be read by `spriteId` as references. Edits apply only to the current target; `switch_sprite` activates another open sprite and makes it the target.
- `execute_lua` proposes edits through the approval flow described below.

Conversations created before a tool was added keep their original tool list, because Codex fixes dynamic tools when a thread starts.

## Access

The native **Access dropdown** below the input maps to Codex's sandbox for the current account. Selecting a profile applies it directly and reconnects while the current conversation continues, preserving the workspace and boundary reviewer. Choose **Access settings...** to edit those extra settings in a separate draft window. Selecting Workspace write without a configured workspace also opens that draft. **Apply access** commits it; closing without applying preserves the saved settings.

| Level | Codex sandbox | Shell and `view_image` |
|---|---|---|
| **Canvas only** (default) | read-only | disabled |
| **Read files** | read-only | enabled; writes are denied |
| **Workspace write** | workspace-write, with the chosen workspace folder as the working directory | enabled; writes only inside the workspace (and temp) |
| **Full access (danger)** | danger-full-access | enabled; no sandbox |

On native Windows without MXC (for example Windows 10 with the `unelevated` sandbox), Codex cannot restrict reads: every level except Canvas only can read any file on the PC, and `view_image` can open any image path. Custom homes without a `[windows] sandbox` setting use `unelevated`.

**Boundary approvals** chooses who decides when Codex asks to cross the sandbox (for example a command requesting escalation): **Ask me** shows an approval window in Aseprite, and **Auto-review** uses Codex's reviewer agent instead. Auto-review runs on the account's model provider; with a provider that cannot produce the reviewer's JSON verdict, requests are denied. **Auto-approve edits** only covers canvas Lua edits, never Codex commands.

## Working together

Ask, for example: “Inspect the current sprite and make the highlights on the Wings layer darker while preserving the outline.” Codex receives document metadata and can request an image of a frame. By default, each edit opens an **Approve Codex Lua** window with the complete code and its summary. **Approve once** runs that request; **Reject** returns the decision to Codex without applying it.

- Normal undoable sprite edits are grouped as one **Codex: ...** entry in Undo History. Use Aseprite's Undo to revert that operation.
- Manual changes, Undo/Redo, layer changes, or switching documents/frames/layers invalidate an older proposed edit. Codex must inspect again before editing the updated context.
- **Stop** cancels model generation and invalidates queued/pending edits. Lua already executing on Aseprite's UI thread cannot be interrupted by this button; approve only short, terminating scripts.
- While a turn is running, **Send** becomes **Steer** once its active turn ID is known. Add an instruction in the same input to redirect that turn without creating another one. Steering cancels an older pending edit approval and refreshes the captured canvas revision; old proposals must inspect again. The button briefly shows **Steering...** while waiting for acknowledgement, and Stop remains available. A rejected instruction is shown with the error and is never automatically sent as a new turn. You can still steer after closing the canvas, with canvas tools unavailable.
- **Disconnect** preserves the current in-memory conversation for reconnection. Recovery interrupts any unfinished old turn before accepting another prompt and never replays an edit.
- **New Chat** starts another conversation. Closing and reopening the chat window starts a fresh client session.
- **Rename...** names the current idle conversation after its first message has created a Codex thread. Save waits for server confirmation; the name survives restarting Aseprite and appears when history is refreshed or reopened.
- **Chats...** opens a searchable, scrollable list of persisted conversations created by Aseprite Chat through your existing Codex login. Each compact row shows a title, time and preview. Click to select, use Up/Down or Page Up/Down to navigate, and double-click or press Enter to open an idle conversation. Search, refresh or load more pages; pagination preserves your reading position. A conversation active in another editor cannot be opened. Restoring history displays prior tools and messages without executing edits again; the next prompt targets the current Aseprite document.
- **Tool** and **Thoughts** entries start collapsed as compact status rows. Click their headers or press Enter on the selected activity to expand/collapse them; streaming updates retain your choice. Expanded tools show their name, proposed Lua and bounded textual results. PNG previews are sent to Codex without dumping their base64 data into the chat. **Thoughts** entries show provider-supplied reasoning text when available (for example, a compatible open-model provider), otherwise the supplied summary. Both live `item/reasoning/textDelta` and restored reasoning `content` are supported. Opaque encrypted content is not rendered; a model/provider can omit readable thoughts.
- **Ask before edits / Auto-approve edits** is a toggle beside Send that controls the plugin's per-edit dialog for this chat. Auto-approval requires explicit opt-in, resets on New Chat, opening a different conversation, closing the chat, or changing server, and is never saved to preferences. Reconnecting the same open chat retains it. Turn/revision checks and one-operation Undo still apply.
- Change the model, reasoning level or **Fast** toggle while idle; the choice is remembered and takes effect on the next message in the same conversation. Fast appears only when the selected model's catalog advertises it and increases usage; see [Codex speed](https://learn.chatgpt.com/docs/agent-configuration/speed). Turning it off explicitly requests normal speed, including on restored threads. A model without Fast clears an old speed selection so the hidden control cannot block sending. Controls are locked during generation. The taller native input retains Aseprite's single-line text and IME handling, with native model, reasoning and Access dropdowns below it; approval and optional Fast/Stop actions use the compact row beneath them. **Send** occupies its own native row at the bottom right, preserving Enter-to-send/steer from the native input. All three selectors keep their native content widths without stretching to fill the row. The selectors use native dropdown menus and keyboard handling. Access profile selections apply directly while preserving the workspace and boundary reviewer. Choose **Access settings...** for those additional settings; an unconfigured Workspace write selection opens its draft without applying it. Arrow keys and Space navigate the focused action row; Enter remains the native Send action. **Stop** appears only while generating, steering, awaiting approval or stopping. Changing the server endpoint starts a new conversation.
- Reconnection refreshes the catalog. If a remembered model or reasoning level is no longer available, select a valid option before sending; another model is not silently substituted. A model without reasoning support displays **Not supported**. If an old reasoning choice needs clearing, **Confirm model selection** lets you explicitly select that model again.
- Scroll the transcript or Lua code with the mouse wheel, drag its right-hand scrollbar, or click the scrollbar track to page. Click the text area to use Page Up/Down, Home/End, and arrow keys. Scrolling up pauses automatic following; reaching the bottom or clicking **Jump to latest**, shown inside the transcript while reading older messages, resumes it. User bubbles and their **You** labels align right; message bodies remain left-aligned for reading. Line heights measure the actual displayed text using the current graphics context, including installed fallback-font metrics. Replies are plain text.
- Automatic connection is the default. **Settings...** contains connection status and an optional advanced manual server; model and reasoning stay beside the message composer. Conversation navigation is in the top toolbar. Closing settings keeps the chat running; closing the chat cancels pending startup and closes its settings and approval windows too.

Aseprite's own permission dialog offers **Give full trust to this script** to remember file, process and network access. Trust is stored per Lua filename, so separate extension modules can ask separately, and moving the installation can require new grants. This is independent of **Auto-approve edits**, which controls the current chat's canvas-edit confirmation. The extension does not grant native trust or change Aseprite's global permissions itself.

## Editing contract

The executor exposes the captured `sprite`, native Aseprite `app`, constructors/constants, and basic Lua libraries. It excludes direct `io`, `os`, `debug`, module loading, and dynamic loading from generated code. Native editor objects still provide powerful operations: this is approved local automation, not a security sandbox for hostile Lua.

Generated scripts must edit only the captured sprite using undoable APIs, without opening, closing, or saving documents. Pixel edits clone a cel image, modify the clone, then assign it back to `cel.image`; directly calling `drawPixel` on an attached image does not create Undo information. The plugin supplies the transaction. A Lua error rolls back undoable operations in that transaction. Undo does not restore arbitrary external side effects.

The supported transport is an IPv4 loopback URL. The bridge accepts the matching native `ws://127.0.0.1:port` Origin (or no Origin), rejects browser origins and Fetch Metadata headers, checks Host, and accepts one client at a time. Each connection owns a separate Codex process; disconnect terminates that process, and reconnection resumes persisted thread state in a fresh process. A changed automatically assigned port preserves the conversation. Remote hosts, TLS setup, and bearer-header authentication are outside this release. With **Canvas only**, Codex shell/file approval requests are declined; other access levels route them as described under Access.

## Development and verification

Run the focused suites with an installed Aseprite executable:

```powershell
./scripts/test.ps1 -Aseprite 'D:\SteamLibrary\steamapps\common\Aseprite\aseprite.exe'
powershell.exe -NoProfile -File tests/launch.ps1
npm test
./scripts/package.ps1
./tests/package.ps1
```

The test runner checks printed pass markers as well as exit codes because Aseprite can print a Lua error while returning zero.

For native GUI integration, start `node tests/fixture.mjs`, then launch a **separate disposable** Aseprite process with `--script tests/gui.lua`. This driver creates its own unsaved sprite, exercises approvals/rejection/stale edits/stop/reconnect, and writes `work/gui-fixture.txt` before closing its own editor. Do not run the driver inside an editor containing your work.

The authenticated integration variant is `--script-param mode=live --script tests/gui.lua`, with `npm start` listening on port 4500. It sends actual model requests and writes `work/gui-live.txt`. `tests/live-protocol.lua` separately exercises two real model turns without document tools. These are explicit smoke tests, not part of the default suite.

`tests/gui-models.lua` exercises the actual model catalog, native selectors, low-effort Sol/Luna turns, and same-thread context. `tests/gui-chat.lua` checks native selector updates and clearing stale reasoning for a single model with no reasoning support. These drivers leave labeled results in their disposable editor so they can be inspected without granting file access; close that test editor afterwards.

`tests/gui-auto.lua` accepts `--script-param extension_root=<unpacked package path>` and checks automatic native connection/catalog loading in a disposable editor. It leaves a labeled result window. First-use Aseprite file/process/network permission dialogs require the user's decision; tests do not change global trust.

`tests/gui-settings.lua` checks compact settings geometry across automatic/manual modes, state refreshes and reopening. Run it in a separate editor with an isolated `ASEPRITE_USER_FOLDER`; it does not connect to a service or open a source sprite.

`tests/gui-actionbar.lua` validates native Fast/approval toggles, conditional Stop and the separate Access draft window without network, account files or source sprites. Run it with an isolated profile, optionally `--script-param variant=fast` to leave a working Fast layout visible; the default leaves an unsupported-model idle layout visible.

`tests/gui-steering-live.lua` accepts `--script-param endpoint=ws://127.0.0.1:<test bridge port>` and must run in a disposable editor/profile. It creates its own unsaved sprite, waits for a real edit approval, steers to a no-edit answer, checks the old approval cannot execute, and closes its own editor after writing `work/steering-live-result.json`.

See [validation evidence](docs/validation.md) for the actual tested results and limitations. Runtime code is split into `main.lua` (controller/lifecycle), `chat.lua` (native UI), `codex.lua` (protocol), `executor.lua` (document tools), `account.lua` (account file), and `launcher.lua` plus `scripts/launch.ps1` (automatic startup). `tests/live-account.mjs` is an opt-in live check: it drives a real Codex through a temp custom account against a local mock Responses endpoint (or, with `--default-live`, one read-mostly turn against your default home).
