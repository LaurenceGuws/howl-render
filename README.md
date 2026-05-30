# howl-render

Backend-agnostic render library for Howl.

`howl-render` consumes render-owned source snapshots derived from VT truth, derives geometry, shapes text, prepares complete surface images, and records submit/retire consequences. Hosts own concrete backend resources and presentation.

## Public ABI

- Header: `include/howl_render.h`
- Exported symbols: `howl_render_*`
- Public root: `src/libhowl_render.zig`

Internal Zig files are not an embedding surface.

## Build

```sh
zig build check
zig build test
```

## Boundary

- Render owns render contracts, geometry policy, retained render state, prepared surfaces, and text shaping.
- VT owns terminal state truth.
- Hosts own upload, backend resource realization, event loops, and present.

See `design.md` for the current owner map and invariants.
