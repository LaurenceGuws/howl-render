# howl-render Design

Updated: 2026-05-30.

Shared rules: [`../AGENTS.md`](../AGENTS.md), [`../project-memory.md`](../project-memory.md), [`../libs.yaml`](../libs.yaml)

## Purpose

`howl-render` owns backend-agnostic render contracts and text rendering work for Howl.

It consumes render-owned source snapshots derived from VT truth, derives geometry, prepares complete surface images, and records submit/retire consequences. It does not own PTY behavior, VT terminal semantics, host textures, event loops, upload, swap, or presentation cadence.

## Public Surface

- The shipped embedding contract is `include/howl_render.h` plus exported `howl_render_*` symbols.
- `src/libhowl_render.zig` is the C ABI export root.
- Hosts and embedders must not use internal Zig files as integration surfaces.
- Public ABI names are product names; wrong names should be broken and fixed rather than shimmed.

## Owners

- `src/ffi.zig` translates the C ABI only.
- `src/text_session.zig` and `src/session/text.zig` compose one render text session behind the C handle.
- `src/session/submitted.zig` owns submitted/retired token state.
- `src/source/` owns render source snapshots, source cells, dirty metadata, publication slots, and prepare requests.
- `src/prepared/` owns prepared surface output and submit result contracts.
- `src/surface/` owns surface buffers, geometry/input contracts, tokens, publication-source storage, and prepared-surface handle state.
- `src/render/` owns render geometry policy and geometry contracts.
- `src/text/` owns shaping, classification, scene building, raster cache use, and font-provider integration.

## Boundary

- Render public ABI must not include `howl_vt.h` or expose `HowlVt*` types.
- VT owns terminal state truth. Host/VT adapter code converts VT truth into render-owned source ABI structs.
- Render owns prepared render output, retained render-source state, and submit/retire consequences.
- Host owns backend resource realization, upload, concrete textures, and presentation.
- `submit` means the host consumed a prepared output and render may update retained render-owned state; it never means backend present.

## Main Flow

1. Host initializes a render text session with explicit font paths and render configuration.
2. Host asks render to derive geometry from render/grid pixel constraints.
3. Host reserves or publishes a render-owned source slot.
4. Host fills source data from VT truth through the ABI adapter and commits it.
5. Render issues a prepare request and builds a prepared surface image.
6. Host uploads the prepared buffer into host-owned backend resources.
7. Host submits execution facts through render's submit contract.
8. Host later retires presented work so render can return the VT snapshot identity to acknowledge.

## Invariants

- No backend object names such as GL texture IDs belong in render public contracts except as opaque host-surface identity where explicitly named.
- FFI files cast and validate contracts only; source/session/prepared/render/text owners own behavior.
- Source owners do not own prepared output.
- Prepared owners do not own VT truth or host presentation.
- Geometry truth is derived by render from explicit constraints; hosts do not feed competing cell geometry.
- No compatibility typedefs or aliases for rejected ABI vocabulary.

## Non-Goals

- Terminal parser behavior.
- PTY lifecycle or child I/O.
- SDL, OpenGL, Vulkan, Metal, swapchains, or window loops.
- Host presentation cadence.
- Host font discovery policy.
