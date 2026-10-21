# Aseprite Chat

A native Aseprite chat window for Codex. Talk about the current sprite, inspect its unsaved layers and rendered frame, and approve Lua edits that appear directly in the running editor.

The editor extension is Lua. It connects over WebSocket to a small local Node communication bridge, which starts Codex app-server using its stdio transport. No MCP server, browser, or Python is required. The bridge exists because this Aseprite version always sends an Origin header and Codex rejects that header on its own WebSocket listener.

## Requirements

- Windows, Aseprite 1.3.18.6, and Codex CLI 0.163.0 are the initial verification environment. Other versions/platforms are not claimed as tested.
- Codex must already be signed in (`codex login`). The plugin uses that login through app-server and does not store an API key.
- Node.js 24 or later is required for the local communication bridge.
- The installed Codex version must support the experimental dynamic-tool API. The plugin opts into the experimental protocol during initialization.

## Install and start

1. Build the package with `powershell -ExecutionPolicy Bypass -File scripts/package.ps1`.
2. Double-click `dist/aseprite-chat.aseprite-extension`, or install it through Aseprite's **Edit > Preferences > Extensions > Add Extension**. Enable the extension and restart Aseprite if requested.
3. From this project directory (or the installed extension directory), install the bridge dependency once, then start it and leave the terminal running:

   ```powershell
   npm ci --ignore-scripts
   npm start
   ```

4. Open **View > Aseprite Chat**. Leave Server at `ws://127.0.0.1:4500`; leave Model blank to use the server's configured model, or enter an exact model ID your account can access. Click **Connect**.
5. Open a sprite and send a message. Unsaved sprites work; saving the document first is unnecessary.

The bridge launches `codex app-server --stdio` for each client connection, using the existing Codex configuration and login. If the Codex executable is not on Node's PATH, set `CODEX_CLI` to its absolute executable path before `npm start`. Stop any separate test server already occupying port 4500. Set `ASEPRITE_CHAT_PORT` before startup to choose another local port, and enter the matching URL in Aseprite.

Aseprite may ask permission to connect to localhost and create/read a temporary PNG preview. Grant those permissions only for this installed extension. The preview is an independent render; the original sprite is not saved or flattened.

## Working together

Ask, for example: “Inspect the current sprite and make the highlights on the Wings layer darker while preserving the outline.” Codex receives document metadata and can request an image of a frame. Each edit opens an **Approve Codex Lua** window with the complete code and its summary. **Approve once** runs that request; **Reject** returns the decision to Codex without applying it.

- Normal undoable sprite edits are grouped as one **Codex: ...** entry in Undo History. Use Aseprite's Undo to revert that operation.
- Manual changes, Undo/Redo, layer changes, or switching documents/frames/layers invalidate an older proposed edit. Codex must inspect again before editing the updated context.
- **Stop** cancels model generation and invalidates queued/pending edits. Lua already executing on Aseprite's UI thread cannot be interrupted by this button; approve only short, terminating scripts.
- **Disconnect** preserves the current in-memory conversation for reconnection. Recovery interrupts any unfinished old turn before accepting another prompt and never replays an edit.
- **New Chat** starts another conversation. Closing and reopening the chat window starts a fresh client session.
- Changing the endpoint or model starts a new conversation. An unavailable explicit model produces an error rather than selecting another model.
- Scroll the transcript or code with the mouse wheel; the main transcript also has Up, Down, and Latest controls. Replies are plain text.

## Editing contract

The executor exposes the captured `sprite`, native Aseprite `app`, constructors/constants, and basic Lua libraries. It excludes direct `io`, `os`, `debug`, module loading, and dynamic loading from generated code. Native editor objects still provide powerful operations: this is approved local automation, not a security sandbox for hostile Lua.

Generated scripts must edit only the captured sprite using undoable APIs, without opening, closing, or saving documents. Pixel edits clone a cel image, modify the clone, then assign it back to `cel.image`; directly calling `drawPixel` on an attached image does not create Undo information. The plugin supplies the transaction. A Lua error rolls back undoable operations in that transaction. Undo does not restore arbitrary external side effects.

The supported transport is an IPv4 loopback URL, such as `ws://127.0.0.1:4500`. The bridge accepts the matching native `ws://127.0.0.1:port` Origin (or no Origin), rejects browser origins and Fetch Metadata headers, checks Host, and accepts one client at a time. Each connection owns a separate Codex process; disconnect terminates that process, and reconnection resumes persisted thread state in a fresh process. Remote hosts, TLS setup, and bearer-header authentication are outside this first release. Codex shell/file approval requests are declined; the canvas workflow uses the extension's two tools.

## Development and verification

Run the focused suites with an installed Aseprite executable:

```powershell
./scripts/test.ps1 -Aseprite 'D:\SteamLibrary\steamapps\common\Aseprite\aseprite.exe'
npm test
./scripts/package.ps1
```

The test runner checks printed pass markers as well as exit codes because Aseprite can print a Lua error while returning zero.

For native GUI integration, start `node tests/fixture.mjs`, then launch a **separate disposable** Aseprite process with `--script tests/gui.lua`. This driver creates its own unsaved sprite, exercises approvals/rejection/stale edits/stop/reconnect, and writes `work/gui-fixture.txt` before closing its own editor. Do not run the driver inside an editor containing your work.

The authenticated integration variant is `--script-param mode=live --script tests/gui.lua`, with `npm start` listening on port 4500. It sends actual model requests and writes `work/gui-live.txt`. `tests/live-protocol.lua` separately exercises two real model turns without document tools. These are explicit smoke tests, not part of the default suite.

See [validation evidence](docs/validation.md) for the actual tested results and limitations. Runtime code is split into `main.lua` (controller/lifecycle), `chat.lua` (native UI), `codex.lua` (protocol), and `executor.lua` (document tools).
