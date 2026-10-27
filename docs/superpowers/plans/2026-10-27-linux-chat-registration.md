# Linux Chat and MCP registration implementation plan

> **For agentic workers:** Use focused TDD; independent Node/Lua ownership is permitted, followed by a fresh-context review.

**Goal:** Complete Linux internal Chat and selected Codex-home MCP registration while preserving Windows behavior.

**Architecture:** Reuse the existing Node startChat/registerMcp operations and secure POSIX private job directory. Share the native Codex resolver between Chat and registration. Keep current child-only account/environment settings, verified readiness/warm reuse, CLI-managed config backups/collision detection and native edit approvals.

**Tech stack:** Aseprite Lua, Node >=24, native Codex CLI, Windows PowerShell/cmd and Linux POSIX shell only for detached process launch.

## Contract and decisions

- Linux launcher supports both Chat (no script) and MCP registration/connect (existing mcp-launch.ps1 operation selector). The selector remains internal; Linux never executes PowerShell.
- Job paths/home/result are JSON data. Only shell-quoted absolute Node and private entry paths enter the POSIX command. Preserve exclusive umask-077 directory creation, permission reentry guards, result validation and cancellation identity retirement.
- The shared resolver supports native Linux x64/arm64 Codex binaries on PATH and the installed npm wrapper's platform package/vendor layout. It must not execute a JavaScript/shell wrapper. Reject missing/non-native/non-executable candidates with safe diagnostics. Preserve Windows discovery behavior.
- Chat discovery uses the same user data directory fallback as the existing server/account code, even without LOCALAPPDATA. Do not migrate account files in this task.
- Chat passes Lua's authoritative accountFile into the child environment. Nondefault account paths bypass cold service reuse (account identity is absent from health metadata); a verified Launcher PID still supports warm reopening.
- Chat defaults cwd to USERPROFILE on Windows, HOME on Linux, with an absolute native user path fallback. Explicit Workspace remains authoritative.
- Windows sandbox overrides apply only on Windows; preserve Linux's native Codex sandbox and the current selected Access profile.
- Enable Linux Register & connect. registerMcp continues to invoke the native CLI only within the explicitly selected CODEX_HOME, back up an existing config, refuse foreign collisions, and verify registration. Connect never changes configuration.
- No new dependencies, login autostart, compatibility layers, real-home writes, GUI launch or real model calls. Preserve the untracked ZIP. Current push authorization persists; push only after verification/review.

## Steps

### 1. Node operations

Files: scripts/register-mcp.mjs, scripts/start-chat.mjs, scripts/server.mjs and their focused Node tests.

- [x] Add failing resolver tests for Linux native PATH, npm/symlink layouts, unsupported wrappers and permissions.
- [x] Implement native Linux lookup without shell execution; preserve existing Windows tests.
- [x] Add failing discovery fallback and platform sandbox tests; implement shared path semantics and Windows-only override.
- [x] Run focused Node checks and report RED/GREEN evidence.

### 2. Native editor integration

Files: launcher.lua, mcp.lua, main.lua, tests/linux.lua, tests/controller.lua, tests/mcp.lua, tests/launcher.lua.

- [x] Add failing POSIX Chat/register job and cwd tests; retain Connect coverage.
- [x] Allow the two existing Node operations through the private POSIX job flow, passing connectOnly from the requested action.
- [x] Enable registration UI/path validation on Linux and correct native cwd resolution. Remove test shims that hide missing production HOME support.
- [x] Run Windows batch suites and Linux-native checks where an existing runtime is available.

### 3. Delivery

Files: README.md, docs/validation.md, package manifests, package/runtime checks.

- [x] Update support scope and prerequisites, bump 0.6.1, document exact evidence and environment limits.
- [x] Run Node/native/package verification, with no model inference or real user configuration mutation.
- [x] Fresh-context review and fix material findings; integrate the verified result into main.

## Evidence

- Windows Node: 143/147 passed, 4 platform skips, no failures; Linux Node with opt-in real CLI: 132/147 passed, 15 platform skips, no failures.
- Windows native Lua: 327; Linux native Lua: 335. Linux0.163 CLI registration and initialize passed without a model turn, all homes temporary.
- Node TDD RED20; POSIX7/9 ->9/9; safe owned symlink target preservation8/9 ->9/9; explicit account routing regression RED ->GREEN.
- Independent review found the missing-HOME account path split. Fixed by explicit accountFile forwarding and nondefault cold reuse isolation, with regression evidence. No further reviewer was spawned for this fix.
- The same 0.6.1 package passed Windows and Linux extracted-runtime checks outside the checkout. The native Linux CLI check also confirms the explicit account file activates its selected custom home.
- Integration uses the existing main branch and ordinary push, per the user's standing instruction; preserve the untracked ZIP. No user installation or GUI restart is performed.
