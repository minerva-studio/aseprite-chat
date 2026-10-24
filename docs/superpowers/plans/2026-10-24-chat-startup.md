# Chat Startup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Checkboxes track the approved, narrowed startup fix.

**Goal:** Remove PowerShell startup waits from the native Chat open callback while preserving automatic discovery, permission handling and cancellation.

**Architecture:** Lua locates native Node using file checks, writes an owned temporary JavaScript entry and launches it through a short detached cmd entry. The JavaScript entry carries JSON data, never interpolated shell arguments, and calls an asynchronous Node bootstrap. The existing MCP PowerShell bootstrap remains unchanged; this task does not redesign tools, metadata, MCP connectivity or chat layout.

**Tech Stack:** Windows, Aseprite 1.3.18.6 Lua, Node 24, existing ws bridge.

**Spec:** Approved startup proposal in this thread, narrowed by the user to Chat startup only. The observed os.execute -> PowerShell wait is removed; native GUI responsiveness still needs native validation.

**Accepted timing boundary:** Subsequent native measurements show synchronous os.execute overhead even for empty commands. The user explicitly chose direct Node with a brief first/cold-start pause, instead of a Windows login background component. No login startup item is authorized. Reopening the same plugin instance first probes a memory-cached verified endpoint/PID asynchronously; only expired, busy or invalid services require cold startup.

## Global Constraints

- Preserve current tool APIs and outputs. Preserve real account/home configuration.
- Do not launch a GUI editor or real model in automated tests. Only disposable homes/services and owned processes.
- No new native executable or dependency. Keep hidden process windows and readable Aseprite permissions.
- Startup result is authoritative. Shell return is only launch acceptance, not readiness.
- A retired attempt never connects. It never terminates an existing editor/bridge.

## Review Focus

- Unicode, spaces, percent, ampersand, quotes and shell metacharacters in installed paths must remain data.
- Background code must survive the launcher's immediate return and disappear after completion/cancellation.
- Late callbacks after close/cancel cannot connect or restart polling.
- Missing Node, missing Codex, busy/stale discovery, process failure and malformed readiness must fail safely.
- A Node bootstrap must actually return control before slow startup completes; mock-only tests are insufficient.

### Task 1: Asynchronous native Node bootstrap

**Files:** Create scripts/start-chat.mjs, tests/start-chat.test.mjs. Modify scripts/register-mcp.mjs only to export/document its existing nativeCodex resolver for shared use.

**Interfaces:** startChat({extensionRoot,resultPath}, dependencies={}) publishes {endpoint,pid} or safe Chinese {error} atomically. It reuses only exact protocol-4 idle bridge discovery/conventional port 4500; otherwise it locates native Codex and launches scripts/server.mjs with inherited process-local readiness/discovery/idle settings. It does not invoke PowerShell, shells, models or registration. Tests may inject native executable lookup, discovery location and spawn boundaries; production uses native Node and real resolver.

- [x] Add failing tests for protocol identity/busy reuse, owned startup and failures, and special paths.
- [x] Observe RED, implement bootstrap and shared native resolver, then verify GREEN using actual local sockets/child processes.

### Task 2: Native Chat launch entry

**Files:** Modify launcher.lua and tests/launcher.lua. The explicit mcp-launch.ps1 path keeps its existing mechanism.

**Interfaces:** Launcher.new and ensure(callback) keep their asynchronous readiness/cancel contract. Default Chat writes a temporary .mjs entry containing JSON job data; a temporary short .cmd uses setlocal DisableDelayedExpansion, UTF-8 cmd input and start /b with native Node. Only validated executable and owned ASCII temporary entry names enter cmd. All extension/result paths remain JavaScript JSON data. Completion/cancel removes owned files; launcher return alone must not delete the .mjs entry.

- [x] Observe failing regressions for no PowerShell, retained background source and unchanged MCP path.
- [x] Implement native Node lookup without a child process, safe cmd launch, lifecycle cleanup and background error publication.
- [x] Replace the default native PowerShell fixture with a disposable slow Node bootstrap; prove launch acceptance precedes ready and special paths survive.
- [x] Run launcher and controller suites. Measure launch-return latency separately from real GUI latency.

### Task 2b: Warm reopen without process startup

**Files:** launcher.lua/tests/launcher.lua; scripts/server.mjs/tests/bridge.test.mjs; scripts/start-chat.mjs/tests/start-chat.test.mjs; tests/startup-native.*.

**Interfaces:** Internal readiness protocol 4 adds a native WebSocket /readyz response with the same metadata as HTTP health, without reserving a chat session or spawning Codex. startChat publishes {endpoint,pid}. Launcher retains that verified pair in memory; ensure probes it using native WebSocket and requires protocol4, matching PID/port and busy=false. It closes the probe before callback. Probe failure/mismatch/busy/timeout clears the derived cache and starts one cold attempt. Cancellation retires probe callbacks first. Explicit MCP bootstrapping has no warm cache and keeps its current contract.

- [x] Observe failing tests for warm success without a shell call, identity mismatch/busy fallback, bounded timeout and retired callback suppression.
- [x] Implement /readyz without changing active-client or idle lifetime state, and require protocol4 before new automatic reuse.
- [x] Run the real native fixture twice with one Launcher, verifying one os.execute call total and the same owned bridge PID/endpoint.

### Task 3: Delivery and focused review

**Files:** scripts/package.ps1, tests/package.ps1, package.json/lock, README.md, docs/validation.md.

- [x] Include the Node bootstrap in package 0.5.1 and explain the runtime launch change.
- [x] Run Node startup/bridge/registration tests, native launcher/controller suites, package checks and a real Codex/local mock-provider round trip.
- [x] Obtain an independent clean-context review; fix concrete findings and recheck affected behavior.
- [x] Back up and install verified package files with preference/hash checks. Do not restart the user's editor or change real Codex home.
- [x] Commit locally without attribution trailers; no push or merge.
