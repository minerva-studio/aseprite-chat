# Focused sprite tools

Approved in the conversation: keep `sprite` as the complete Aseprite document. Separate discovery, rendered images and structural queries; default responses carry only the data needed for that operation. No MCP auto-connect changes.

## Contract

- New sessions advertise seven tools: `list_sprites`, `view_sprite`, `inspect_sprite`, `read_pixels`, `switch_sprite`, `execute_lua`, `export_sprite` through the shared `tools.json`.
- `list_sprites({offset?,limit?})` works without a document. Return `{sprites:{items,total,offset,nextOffset?},activeSpriteId?,targetSpriteId?}`. Items contain spriteId, filename, width, height, colorMode and frameCount.
- `view_sprite` takes the existing read selection parameters and returns PNG images with spriteId, target, optional revision, selectedFrames, region, scale, layout and preview dimensions. No full structural arrays.
- `inspect_sprite({spriteId?,sections?,frame?,layers?,offset?,limit?})` defaults to a compact overview: spriteId, target, optional revision, filename, dimensions, colorMode, current frame/layer, modified/file status and collection counts. Sections: layers, frames, tags, slices, cels, palette, selection. Each collection is `{items,total,offset,nextOffset?}`. Offset defaults to 0; limit defaults to 64, maximum 256. Layers are flat records with parentId instead of nested unbounded trees. `layers` filters layers and cels; group IDs include descendants. The frame argument filters cels and chooses the effective frame palette. Results distinguish frame (captured), queryFrame (requested), and paletteFrame (effective palette source). Palette entries have zero-based index and rgba. Selection is one bounds object.
- `read_pixels` retains exact values and the 4096 pixel bound. `switch_sprite` returns only target identity, frame, active layer and revision. Existing execute approval, transaction and revision protections remain.
- View/export retain existing selection semantics: frames > tag > frame, 1-based frames, zero-based coordinates, native layer IDs, group inclusion, clipping, explicit ordering/duplicates.
- User explicitly chose a breaking update without compatibility: remove `read_sprite` entirely, including execution methods and protocol exceptions. Existing app-server threads need a new conversation to acquire the new tools; no tool translation is provided.
- Document-required operations return a failed tool result containing JSON `{error:{code:"NO_OPEN_SPRITE",message:...}}` when no document is available. A missing explicit ID is a separate error. Transport stays connected.
- Each ordinary Chat send/steer carries only `{hasSprite,spriteId?,frame?,layerId?,revision?}` derived from the bind snapshot. With no document it disposes the old target and sends `{hasSprite:false}`. No hidden palette, images or structural arrays.
- Internal integrity observation remains authoritative and complete; reducing response data does not weaken revision checking or claim a scan-time improvement.
- MCP is client-neutral; Codex home registration is optional convenience. Runtime tools do not depend on Codex app-server. Export files are temporary and can be copied by any authorized client file capability.

## Alternatives

Keeping `read_sprite` with include flags is smaller but makes images and structure overlap. The approved split makes the default payload predictable. Avoid a tool for every metadata section; one selective inspect tool keeps the catalog small.

## Validation

Native batch fixtures cover sparse results, empty editor, collections/pagination, frame palettes, hierarchy filters, revisions, preview fidelity and switching. Controller fixtures cover compact send/steer, empty chat, and routing. MCP SDK/native fixtures cover the seven advertised tools, images/errors, approval and disconnected clients. No real model call or GUI editor is required.
