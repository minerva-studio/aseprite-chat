# Aseprite Chat

A native Aseprite chat window and a client-neutral local MCP connection. Inspect unsaved sprites, approve Lua edits in the running editor, and export native PNG/GIF/sprite sheets.

The editor extension is Lua. Opening the chat automatically finds or starts a small local Node communication bridge, which starts Codex app-server using its stdio transport. No terminal command, port entry, MCP server, browser, or Python is required for normal use. The bridge exists because this Aseprite version always sends an Origin header and Codex rejects that header on its own WebSocket listener.

## Requirements

- Windows, Aseprite 1.3.18.6, and Codex CLI 0.163.0 are the initial full-chat verification environment. Linux supports **external MCP Connect only** with Aseprite 1.3.18.6 and Node.js 24 or later; see the Linux instructions below. Linux internal Chat and automatic Codex registration are not supported by this change.
- Codex must already be signed in (`codex login`) for the default account. The plugin uses that login through app-server. A **Custom Codex home** account (below) can instead use an API key or a compatible Responses endpoint, in which case a Codex login is not required.
- Node.js 24 or later is required for the local communication bridge. The plugin locates it and the Codex executable automatically; pinned JavaScript runtime dependencies are included in the extension.
- The installed Codex version must support the experimental dynamic-tool API. The plugin opts into the experimental protocol during initialization.

## Install and start

1. Use the supplied `aseprite-chat.aseprite-extension` package. Source builds are described under Development and verification.
2. Double-click `dist/aseprite-chat.aseprite-extension`, or install it through Aseprite's **Edit > Preferences > Extensions > Add Extension**. Enable the extension and restart Aseprite if requested.
3. Open **View > Aseprite Chat**. The plugin detects an existing compatible local service or starts one in the background, then loads your account's model list. Aseprite can ask permission to launch the plugin's connection helper and read its temporary startup result; those are normal native script permissions.
4. Choose a model and reasoning level on the control bar below the input. Supported models show a **Fast** toggle on the action bar below the input; it starts off. Models without Fast have no speed control. An initial model selection uses the catalog's recommended model and reasoning default. If startup fails, the message explains the next action; **Retry** searches again without entering a server address.
5. Open a sprite and send a message. Unsaved sprites work; saving the document first is unnecessary.

The bridge launches `codex app-server --stdio` for each chat client connection, using the existing Codex configuration and login. It sets the child process's originator to `aseprite_chat` so launch-host overrides cannot mix this extension's history with other clients. Codex's built-in tool surfaces (sub-agents, web search, image generation, apps, plugins and similar features) are disabled for every child. Shell commands and `view_image` are disabled too unless the action bar's **Access dropdown** grants file access (see below). Automatic startup looks for native executables on PATH and in the standard Node/Codex desktop installation directories. It validates a per-user service-discovery hint and the conventional port 4500, reuses only an idle compatible bridge (readiness version 4), and otherwise starts its own bridge on an OS-assigned free port. It does not scan or take over arbitrary Codex processes. An automatically started bridge exits after two idle minutes; connected conversations keep it alive.

**Settings... > Manual server (advanced)** is an explicit opt-in for a separately managed compatible bridge. Developer-only manual startup remains available with `npm start`, `CODEX_CLI` and `ASEPRITE_CHAT_PORT`; these are not required in the normal plugin flow.

Chat's cold bootstrap starts native Node through a short detached cmd entry, without invoking PowerShell. Installed paths and job parameters remain JSON data in an owned temporary JavaScript entry, which survives until background completion/cancellation. Discovery, Codex lookup and bridge readiness run in Node; the Lua timer consumes only the final result. The same launcher remembers its last verified endpoint/PID and first rechecks it through a one-second native WebSocket health probe on reopening. This probe starts no Codex process, reserves no chat session and does not extend the bridge's idle lifetime. An idle protocol-4 match skips the startup command; a dead, busy, mismatched or timed-out service requires cold startup again. First-use native network permission can apply to this probe. On Windows, the explicit MCP registration/connect bootstrap keeps its existing PowerShell path. Linux MCP Connect uses a private temporary Node job instead. Cold `os.execute` still has measurable synchronous overhead; the user chose to accept that first/cold-start pause rather than install a Windows login background component. No login startup item is installed.

Aseprite may ask permission to connect to localhost and create/read a temporary PNG preview. Grant those permissions only for this installed extension. The preview is an independent render; the original sprite is not saved or flattened.

## Account

**Settings... > Account** chooses which Codex home and credentials the bridge uses. Applying an account saves it to `%LOCALAPPDATA%\AsepriteChat\providers.json`, starts a new conversation, and reconnects; it is only possible while the chat is idle.

- **Codex default (~/.codex)** runs Codex exactly as before, with your normal Codex home (usually a ChatGPT sign-in from `codex login`).
- **Custom Codex home** runs Codex with `CODEX_HOME` set to the chosen folder (default `%LOCALAPPDATA%\AsepriteChat\codex-home`). Codex keeps its own configuration and writes its session history inside that home, so **Chats...**, **Rename...** and conversation resume work per home — switching accounts switches history too.
  - **Base URL** and **API key** are optional. With either set, the child uses a custom `model_provider` speaking the Responses API: requests go to `<Base URL>/responses` with `Authorization: Bearer <key>` (a key with an empty URL targets the official `https://api.openai.com/v1`). With both empty, the custom home's own configuration and login are used instead.
  - The API key is stored **plaintext in `providers.json` only** — never in Aseprite preferences, Codex's `config.toml`, command lines, or logs. Settings shows only a trailing hint; the key entry stays blank to keep the saved key, and **Remove saved key** clears it.
  - **Models** optionally lists model IDs (comma-separated). When non-empty it replaces the server catalog in the picker — Codex's `model/list` always returns its bundled OpenAI entries regardless of provider, which is rarely useful for a custom endpoint. Each listed model is offered with low/medium/high reasoning and normal speed, with no Fast control.

## External clients through MCP

Open **View > Aseprite MCP** to connect an external MCP client to this running editor. This runtime is independent of the internal chat: it does not start Codex app-server or require a model login. The built-in registration shortcut targets Codex homes; another local client supporting stdio MCP can configure the same server manually.

Use native Node as the MCP command, with arguments `["<installed extension>/scripts/mcp-server.mjs", "--home", "<same home selected in Aseprite MCP>"]`. The home identifies the local hub; the runtime does not require it to contain Codex configuration. Image input and file-copy capabilities depend on the external client/model. **Connect** only needs Node; **Register & connect** additionally needs the Codex CLI to edit its configuration.

1. Set **Target Codex home** to the home used by the external Codex client. On first use it defaults to the account selected in Aseprite Chat Settings; subsequent opens remember the MCP panel's chosen home.
2. Click **Register & connect**. The plugin creates the selected home directory if it is new, backs up an existing `config.toml` to `<home>/.aseprite-chat/config-backup-<uuid>.toml`, then invokes the native Codex CLI with process-local `CODEX_HOME` to add the `aseprite_chat` stdio MCP entry. The entry runs the installed `scripts/mcp-server.mjs` with native Node and `--home <home>`. Other model/provider/login settings and unrelated MCP entries are retained. Repeating an exact registration is a no-op; a foreign or altered same-name entry is rejected for manual inspection.
3. Restart the external Codex client or start a fresh session so it loads the entry. Ask it to inspect or edit the current Aseprite document. All seven tools below are available through MCP, including PNG preview image content.
4. Keep the MCP panel connected while using these tools. **Connect** reconnects without changing Codex configuration. **Disconnect**, closing the panel or exiting the extension cancels pending native approvals and retires its document observations and temporary exports. A connection loss requires an explicit Connect. There is no automatic replay.

The panel's home is independent of the internal chat account. It does not copy API keys or change the external host's model, provider, filesystem sandbox or approval settings. MCP edits always require **Approve once** in Aseprite, including when the internal chat has Auto-approve edits enabled. The full proposed Lua is shown and the captured revision/context is checked before execution. The original Undo contract applies. Cancelled or stale callbacks cannot execute. Enter in the MCP panel or its approval cannot submit a background internal chat draft. The internal chat disables only its own `aseprite_chat` MCP entry through a child runtime override, since it already provides these operations as dynamic tools; the saved configuration is unchanged by that override.

Each home owns a loopback hub and a private discovery descriptor under `.aseprite-chat`. The hub authenticates native connections, accepts one Aseprite editor, and supports multiple Codex clients with isolated captured targets/revisions. Only one operation can be active globally; additional calls fail busy rather than queueing edits. An interrupted request stays busy until native cancellation acknowledgement; a 90-second hub deadline disconnects an unresponsive editor and revokes its pending approvals. Codex's own tool timeout can be shorter. No-peer hubs exit after two minutes. Do not share a home between different active Aseprite editors; use another home for a second editor.

MCP export paths survive individual calls but expire when that external client disconnects or the native control connection ends. Copy them using the external host's authorized file tools before ending the session. The internal chat's Access dropdown does not configure an external Codex host. Native execution/encoding is synchronous and cannot be interrupted after it starts. This is trusted local automation with native approval, not a sandbox for hostile Lua.

Registration uses [Codex's documented MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli). A local Codex home registration does not configure ChatGPT web, which does not read local Codex configuration files. The new MCP transport is first verified with SDK clients, isolated native Codex CLI registration and batch Aseprite documents; production GUI/WebSocket approval timing and real model selection remain separate manual checks.

### Linux: connect an external MCP client

Install the same extension package, or install lockfile dependencies in the source checkout with `npm ci --ignore-scripts`. Make sure **the Aseprite process** inherits a PATH containing Node.js 24+; desktop launchers do not necessarily inherit a terminal's PATH. Restart Aseprite from that terminal if needed.

1. Open **View > Aseprite MCP**, enter an absolute Linux home such as `/home/me/aseprite-mcp-home`, and click **Connect**. Use a dedicated home for isolated testing rather than your normal Codex account. Windows drive paths, relative paths and literal `~` are not accepted on Linux.
2. Configure your external MCP client's **stdio** command as an absolute Node executable, with these arguments (replace all example paths):

   ```json
   {
     "command": "/absolute/path/to/node",
     "args": ["/absolute/path/to/aseprite-chat/scripts/mcp-server.mjs", "--home", "/home/me/aseprite-mcp-home"]
   }
   ```

   This is the server entry to put inside your client's MCP configuration format. It is not an HTTP URL. A local Codex CLI client may use the equivalent `[mcp_servers.aseprite_chat]` `command` and `args` fields in its own configuration.
3. Keep the panel and external client on the same machine/network namespace and use exactly the same home. Ask the client to inspect the active sprite, then approve any proposed edit in Aseprite. Reads, previews, revision checks, native approval, Undo and export cleanup use the existing implementation.

**Connect does not discover/run Codex, register MCP, read its `config.toml`, or log in.** The external client owns its own model/login. **Register & connect** is unavailable on Linux; configure the client explicitly. Internal **Aseprite Chat** startup is still Windows-only.

Linux startup creates an exclusive `0700` temporary directory before writing its job and result, quotes shell paths, and preserves Aseprite's native file/process/network permission prompts. The hub remains authenticated and bound to `127.0.0.1`; its private capability descriptor under `<home>/.aseprite-chat` must not be shared. Disconnect does not kill another editor or a shared hub; a no-peer hub exits after two idle minutes.

For compatibility with the existing Node bridge, account defaults without `LOCALAPPDATA` use `$HOME/AppData/Local/AsepriteChat`; the panel can instead use any explicit absolute home. The `ASEPRITE_CHAT_ACCOUNT_FILE` override is preserved. No account file is required for Connect.

## Canvas tools

The model works through the extension's own tools:

- `list_sprites` discovers open documents without requiring an editing target. It returns a paged `sprites` collection of IDs, filenames, dimensions, color modes and frame counts, plus active/target identities. No open document returns an empty collection successfully.
- `view_sprite` returns rendered PNG previews and only the identity, revision (editing target only), selected frames, crop, scale and sheet layout needed to interpret them. It can select frames by list or tag, isolate layers without changing the document, crop a region, and overlay a grid. Small pixel art is upscaled with nearest-neighbor. It does not return the document's palette or structural arrays.
- `inspect_sprite` returns a compact document overview and counts. Add `sections` to request any of `layers`, `frames`, `tags`, `slices`, `cels`, `palette`, `selection`; omitted sections stay omitted. No preview images are generated.
- `read_pixels` returns exact pixel values for up to 4096 pixels without an approval.
- Other open sprites can be read by `spriteId` as references. Edits apply only to the current target; `switch_sprite` activates another open sprite and returns its identity, current frame/layer and new revision without full metadata.
- `execute_lua` proposes edits through the approval flow described below.
- `export_sprite` encodes live selections as PNG frames, animated GIF, or a PNG spritesheet with optional JSON. It returns temporary file paths; destination copies use the client's authorized file capability (internal Chat follows Access and approvals). Export does not save or modify the source document.

Here `sprite` consistently means a complete Aseprite document, including all layers and frames. Frames are 1-based, pixel coordinates and palette indices are 0-based, and layers use native IDs. Both view and inspect return the editing target's current revision; pass it to `execute_lua` for approval and stale-state validation. Reference reads never grant editing permission.

`list_sprites` and inspect collections accept `offset` (default 0) and `limit` (default 64, maximum 256). Each collection returns `{items,total,offset,nextOffset?}`; an absent nextOffset means complete. Inspect layers are flat records with parentId, so pagination cannot hide a nested subtree. `layers` filters requested layers/cels and includes group descendants. The `frame` argument chooses cel records and the effective frame palette; palette entries contain explicit `{index,rgba}`. The result distinguishes `frame` (captured frame), `queryFrame` (requested frame) and `paletteFrame` (effective palette's source frame). Selection is a single bounds object instead of a collection.

Examples:

```js
list_sprites({})
view_sprite({frame: 3})
inspect_sprite({sections: ["layers", "tags"]})
inspect_sprite({sections: ["palette"], frame: 3, offset: 0, limit: 32})
```

Ordinary Chat sends/steers attach only `{hasSprite,spriteId?,frame?,layerId?,revision?}`; they never automatically send a palette, image or full structure. Chat works with no canvas. Document operations return a failed tool result with `{error:{code:"NO_OPEN_SPRITE",message:...}}` when no document is open; the MCP connection stays online. Internal revision observations remain complete, so this is a payload reduction, not a promise of faster document scanning.

This release deliberately breaks the previous tool contract. `read_sprite` is removed. Codex fixes dynamic tools when a thread starts, so start a new conversation to use these tools; previous tool definitions are not translated or supported. Reconnect external MCP clients to refresh their catalogs. Existing transcripts remain readable.

**Upgrading a running MCP installation:** the hub caches its tool catalog when it starts. Reconnecting only the external client can leave an old five-tool hub alive, even when the files were updated in place. Reload the complete native Lua controller and restart the stdio client using a fresh dedicated home, or first disconnect every old editor/client and verify that the old owned hub has exited. A hub with no peers exits after two idle minutes. Preserve unsaved work before any editor restart; a transport-only switch does not require closing Aseprite. Never mix old Lua, an old hub or an old client with the new tool definitions.

### Export parameters

`export_sprite` uses the same `spriteId`, `frame`, `frames`, `tag`, `layers` and `region` selectors as `view_sprite`. Explicit `frames` take precedence over `tag`, then `frame`; the default is the captured frame (frame 1 for another sprite). Explicit lists retain order and duplicates. Tags select their inclusive numeric frame range; playback direction and repeat counts are not expanded. Regions are clipped to the canvas. Without `layers`, visible layers are composited; selected layers render in isolation.

| Parameter | Default | Behavior |
| --- | --- | --- |
| `format` | `"png"` | PNG or animated `"gif"` |
| `output` | `"frames"` | One PNG per selected frame; `"sheet"` packs them into one PNG |
| `scale` | `1` | Positive integer nearest-neighbor multiplier; no preview resizing or grid |
| `columns` | `ceil(sqrt(frame count))` | Sheet columns, capped at the number of selected frames |
| `padding` | `0` | Transparent space between sheet cells; no outer border |
| `metadata` | `false` | Sheet-only JSON with ordered frame rectangles and durations in milliseconds |

`columns`, `padding` and `metadata` apply only to `output:"sheet"`; GIF cannot be a sheet. Examples:

```json
{"frame":1}
{"frames":[1,3,2],"scale":2}
{"tag":"idle","format":"gif"}
{"tag":"walk","output":"sheet","columns":4,"padding":1,"metadata":true}
```

Results include `spriteId`, `selectedFrames`, `scale`, output `width`/`height`, `files[].path` and ordered `frames` entries with source `frame` and source `duration` in milliseconds. PNG/GIF frame entries include their file `path`; sheet entries include `x`, `y`, `width`, `height`. PNG preserves alpha. Native GIF encoding quantizes colors to a palette, supports binary transparency, and has 10 ms timing precision, so encoded GIF durations can differ from the reported source durations. JSON uses an array of `frames`, with `sourceFrame`, `frame:{x,y,w,h}`, `duration`, `sourceSize`, `spriteSourceSize`, `rotated:false` and `trimmed:false`, plus `meta.image`, `meta.size`, `meta.format` and `meta.scale`.

Exports use fresh `aseprite-chat-export-<uuid>` temporary directories. PNGs use ordinal names (`frame-0001.png`), so duplicate source frames cannot overwrite each other. GIF uses `animation.gif`; sheets use `sheet.png` and optional `sheet.json`. Copy these files before switching chats/accounts/server identity or closing the chat window. Turn completion, Stop and reconnect retain artifacts. Historical paths can expire; export again when needed. Cleanup removes only tracked files and empty owned directories. Failed deletions are reported and retried up to three times, with later attempts on a native timer; persistent failures stay tracked for the next cleanup boundary. Retries preserve exports created after that boundary. Abrupt process termination or persistent file locks can leave temporary artifacts; the plugin does not scan or delete untracked directories on startup.

No destination-path argument is accepted. **Canvas only** can encode temporary artifacts but cannot copy them into a project; destination writes require the relevant Codex filesystem access/approval. Do not use `execute_lua` to bypass this. Allocation checks reject exports above 16,777,216 source-frame rendering pixels, scaled-frame pixels or sheet pixels, or above 16384 pixels per output dimension, rather than silently shrinking them. Encoding runs on Aseprite's UI thread; Stop cannot interrupt an export already encoding.

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

## Plugin instructions

The extension sends its own developer instructions from [main.lua](main.lua): the shared `instructions` text near the top plus the current Access description and working directory built by `Controller:_thread_settings`. They are regenerated for new threads, reconnection and history restoration. These are extension-authored instructions, separate from chat messages; both parts are visible in that source file. They require concise plain text in the user's language, inspecting live documents before edits, undoable canvas operations, respecting rejection and asking about consequential unresolved choices. They do not require confidence percentages.

File/project work follows the selected Access level and Codex's own approvals. **Full access** explicitly allows requested project-file reads/edits and commands; there is no extra plugin-wide references/exports restriction. **Ask before edits** controls the canvas `execute_lua` tool independently. Document saves, external file access and process calls remain prohibited inside `execute_lua`, whose transaction is limited to undoable canvas edits. That local tool contract does not disable shell/file tools allowed by Access. Direct external writes to files currently open in Aseprite remain prohibited to avoid desynchronizing the editor.

## Working together

Ask, for example: “Inspect the current sprite and make the highlights on the Wings layer darker while preserving the outline.” Codex receives document metadata and can request an image of a frame. By default, each edit opens an **Approve Codex Lua** window with the complete code and its summary. **Approve once** runs that request; **Reject** returns the decision to Codex without applying it.

- Normal undoable sprite edits are grouped as one **Codex: ...** entry in Undo History. Use Aseprite's Undo to revert that operation.
- Manual changes, Undo/Redo, layer changes, or switching documents/frames/layers invalidate an older proposed edit. Codex must inspect again before editing the updated context.
- **Stop** cancels model generation and invalidates queued/pending edits. Lua already executing on Aseprite's UI thread cannot be interrupted by this button; approve only short, terminating scripts.
- While a turn is running, **Send** becomes **Steer** once its active turn ID is known. Add an instruction in the same input to redirect that turn without creating another one. Steering cancels an older pending edit approval and refreshes the captured canvas revision; old proposals must inspect again. The button briefly shows **Steering...** while waiting for acknowledgement, and Stop remains available. A rejected instruction is shown with the error and is never automatically sent as a new turn. You can still steer after closing the canvas, with canvas tools unavailable.
- **Disconnect** preserves the current in-memory conversation for reconnection. Recovery interrupts any unfinished old turn before accepting another prompt and never replays an edit.
- **New Chat** starts another conversation. Closing and reopening the chat window starts a fresh client session.
- **Rename...** names the current idle conversation after its first message has created a Codex thread. Save waits for server confirmation; the name survives restarting Aseprite and appears when history is refreshed or reopened.
- Codex can ask a question through **Aseprite Chat · Question**. The question stays above the options canvas. Its default height fits the options, including Other; only oversized content or a manually reduced window requires scrolling. Click a row or focus the list and use Up/Down or number keys; Enter continues or submits. The native **Note** entry below keeps Aseprite text/IME handling. Notes supplement the selected answer and survive switching choices and paging. Select **Other** when offered to submit the note as a custom answer; free-text questions require only the text. No answer is preselected. **Back** retains drafts, and **Skip** or closing returns no answers. After submission, one Question record contains all question–answer pairs, with each answer and its optional Note directly below its question. Concurrent requests wait their turn. Stop, disconnect, turn completion and server cancellation retire pending questions and canvas handlers. Edit auto-approval never answers questions. Ordinary-mode questions are enabled per thread without changing your Codex configuration files. Password/API-key prompts are skipped because native Lua entries do not provide secure credential input.
- **Chats...** opens a searchable, scrollable list of persisted conversations created by Aseprite Chat through your existing Codex login. Each compact row shows a title, time and preview. Click to select, use Up/Down or Page Up/Down to navigate, and double-click or press Enter to open an idle conversation. Search, refresh or load more pages; pagination preserves your reading position. A conversation active in another editor cannot be opened. Restoring history displays prior tools and messages without executing edits again; the next prompt targets the current Aseprite document.
- **Tool** and **Thoughts** entries start collapsed as compact status rows. Click their headers or press Enter on the selected activity to expand/collapse them; streaming updates retain your choice. Expanded tools show their name, proposed Lua and bounded textual results. PNG previews are sent to Codex without dumping their base64 data into the chat. **Thoughts** entries show provider-supplied reasoning text when available (for example, a compatible open-model provider), otherwise the supplied summary. Both live `item/reasoning/textDelta` and restored reasoning `content` are supported. Opaque encrypted content is not rendered; a model/provider can omit readable thoughts.
- **Context** information appears to the right of the four native dropdowns. The default caption shows the latest server-reported percentage; open it for used/window token counts. Missing usage or capacity is explicitly unknown. During a reported compaction it shows **Compacting...**; after completion, **Compacted** appears in its details. Usage comes from the latest request, not cumulative billing, and updates when Codex reports it. The context window is Codex-reported; custom providers need correct model configuration. This indicator does not predict the auto-compaction threshold or trigger compaction.
- **Ask before edits / Auto-approve edits** is a native dropdown beside model, reasoning and Access that controls the plugin's per-edit dialog for this chat. Auto-approval requires explicit opt-in, resets on New Chat, opening a different conversation, closing the chat, or changing server, and is never saved to preferences. Reconnecting the same open chat retains it. Turn/revision checks and one-operation Undo still apply.
- Change the model, reasoning level or **Fast** toggle while idle; the choice is remembered and takes effect on the next message in the same conversation. Fast appears only when the selected model's catalog advertises it and increases usage; see [Codex speed](https://learn.chatgpt.com/docs/agent-configuration/speed). Turning it off explicitly requests normal speed, including on restored threads. A model without Fast clears an old speed selection so the hidden control cannot block sending. Controls are locked during generation. The taller native input retains Aseprite's single-line text and IME handling, with native model, reasoning, Access and edit-approval dropdowns on one row below it. All four use their native content widths. **Send / Steer** and conditional **Stop** share one compact bottom-right action row, with optional Fast/Retry on the left. The action canvas does not change native layout while painting. Send remains clickable with background plugin windows open. Access profile selections apply directly while preserving the workspace and boundary reviewer. Choose **Access settings...** for those additional settings; an unconfigured Workspace write selection opens its draft without applying it. Arrow keys and Space navigate the focused action row. **Stop** appears only while generating, steering, awaiting approval or stopping. Changing the server endpoint starts a new conversation.
- The extension registers **Aseprite Chat: Send / Steer** as a shortcut-bindable command and contributes an **Enter** binding in Aseprite's Normal, Selection and FramesSelection key contexts. Enter submits the draft while chat is open; after closing chat it retains the editor's native Play Animation action. Transformation retains its more specific native Enter binding. User keyboard customizations can override extension bindings. Shortcut submission pauses while plugin settings, Access, history, rename or approval windows are open, preventing their unhandled Enter from sending a chat draft; mouse Send remains available when returning to the main chat. This guard tracks owned windows because Lua exposes no focused-native-entry getter. The Send button itself no longer captures unhandled Enter as a default button. Command registration refreshes native menu/key bindings once after plugin initialization without editing the user's shortcut file.
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
node --test tests/start-chat.test.mjs
npm test
./scripts/package.ps1
./tests/package.ps1
```

The test runners check printed pass markers as well as exit codes because Aseprite can print a Lua error while returning zero. A cross-platform runner creates an isolated Aseprite profile automatically:

```sh
npm run test:native -- /absolute/path/to/aseprite
# SDK/native integration also needs an executable and a writable disposable profile:
ASEPRITE_EXE=/absolute/path/to/aseprite ASEPRITE_USER_FOLDER=/absolute/disposable/profile npm test
```

On Linux, Windows launcher/controller branches run with explicit test platform/environment fixtures; the actual Windows Chat process test is skipped. `tests/linux.lua` exercises the real POSIX process boundary without starting a hub or model. These batch checks do not establish visible GUI/WebSocket permission timing.

For native GUI integration, start `node tests/fixture.mjs`, then launch a **separate disposable** Aseprite process with `--script tests/gui.lua`. This driver creates its own unsaved sprite, exercises approvals/rejection/stale edits/stop/reconnect, and writes `work/gui-fixture.txt` before closing its own editor. Do not run the driver inside an editor containing your work.

The authenticated integration variant is `--script-param mode=live --script tests/gui.lua`, with `npm start` listening on port 4500. It sends actual model requests and writes `work/gui-live.txt`. `tests/live-protocol.lua` separately exercises two real model turns without document tools. These are explicit smoke tests, not part of the default suite.

`tests/gui-models.lua` exercises the actual model catalog, native selectors, low-effort Sol/Luna turns, and same-thread context. `tests/gui-chat.lua` checks native selector updates and clearing stale reasoning for a single model with no reasoning support. These drivers leave labeled results in their disposable editor so they can be inspected without granting file access; close that test editor afterwards.

`tests/gui-auto.lua` accepts `--script-param extension_root=<unpacked package path>` and checks automatic native connection/catalog loading in a disposable editor. It leaves a labeled result window. First-use Aseprite file/process/network permission dialogs require the user's decision; tests do not change global trust.

`tests/gui-settings.lua` checks compact settings geometry across automatic/manual modes, state refreshes and reopening. Run it in a separate editor with an isolated `ASEPRITE_USER_FOLDER`; it does not connect to a service or open a source sprite.

`tests/gui-actionbar.lua` validates native Fast/approval toggles, conditional Stop and the separate Access draft window without network, account files or source sprites. Run it with an isolated profile, optionally `--script-param variant=fast` to leave a working Fast layout visible; the default leaves an unsupported-model idle layout visible.

`tests/gui-steering-live.lua` accepts `--script-param endpoint=ws://127.0.0.1:<test bridge port>` and must run in a disposable editor/profile. It creates its own unsaved sprite, waits for a real edit approval, steers to a no-edit answer, checks the old approval cannot execute, and closes its own editor after writing `work/steering-live-result.json`.

See [validation evidence](docs/validation.md) for actual results and limitations. `main.lua` owns internal chat lifecycle; `chat.lua` owns its UI; `codex.lua` handles app-server; `executor.lua` implements the shared `tools.json` definitions; `export.lua` owns encoders/artifacts. `mcp.lua` owns external native control, `scripts/mcp-bridge.mjs` its loopback hub, `scripts/mcp-server.mjs` the SDK stdio surface, and `scripts/register-mcp.mjs` plus `scripts/mcp-launch.ps1` selected-home registration. `account.lua` stores account settings; `launcher.lua` supplies asynchronous native bootstrapping. `tests/live-account.mjs` remains an opt-in app-server check using a disposable home/local mock (or an actual default-account turn with `--default-live`).
