# Native sprite export implementation plan

Approved behavior: export live, unsaved Aseprite selections as PNG frames, GIF animation, or a PNG spritesheet with optional JSON metadata. Source documents remain unchanged. Destination copies use Codex filesystem tools and existing Access/approval rules.

1. Add native file tests before implementation. Extract one shared frame/layer/region selection and rendering path from `read_sprite`; preserve its preview scaling behavior.
2. Implement `export.lua` as the owner of unique temporary export directories and tracked files. Encode PNGs from detached RGB Images; construct and close a scratch Sprite for native GIF encoding, restoring the previous active document/frame/layer in success and failure paths. Use an explicit integer scale, transparent inter-cell padding and array-shaped JSON metadata.
3. Add `export_sprite` after the existing four tools. Validate format combinations and allocation limits before rendering: 16,777,216 total rendered pixels, 16,777,216 sheet pixels, dimensions at most 16384. Reject unsupported options and destination paths. Preserve explicit frame order/duplicates; tags retain the existing numeric-range behavior.
4. Dispatch export as a non-edit tool under active-turn validation. Keep artifacts across completed/stopped turns and reconnects; clear tracked artifacts when changing conversations/accounts/server identity or closing the window. Never delete arbitrary directories recursively.
5. Run actual Aseprite batch tests that reopen encoded images/animations, test frame timing, alpha, layout and failure cleanup. Run controller lifecycle tests, existing render regressions, bridge/package checks, then an independent review. Package version 0.4.14, install with backup/hash verification, and commit locally without pushing.

No actual model calls or new GUI editors are required. Native GUI first-frame behavior and third-party provider tool selection remain outside the automated checks. New dynamic tools require a new chat because existing thread tool lists are persisted by Codex.
