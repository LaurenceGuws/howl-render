const std = @import("std");

const c_size_t = switch (@sizeOf(*u8)) {
    8 => u64,
    4 => u32,
    else => @compileError("unsupported pointer width"),
};

pub const HowlRenderSurfaceText = opaque {};
pub const HowlRenderPreparedSurfaceObject = opaque {};

pub const SurfaceTextHandle = ?*HowlRenderSurfaceText;
pub const PreparedSurfaceHandle = ?*HowlRenderPreparedSurfaceObject;

pub const HowlRenderCallStatus = enum(c_int) {
    ok = 0,
    missing_handle = -1,
    invalid_argument = -2,
    failed = -3,
};

pub const HowlRenderPrepareStatus = enum(c_int) {
    idle = 0,
    ready = 1,
    failed = -3,
};

pub const HowlRenderSubmitStatus = enum(c_int) {
    idle = 0,
    rendered = 1,
    stale = 2,
    needs_prepare = 3,
    failed = -3,
};

pub const HowlRenderSubmitDecisionStatus = enum(c_int) {
    idle = 0,
    submit = 1,
    stale = 2,
    needs_prepare = 3,
    failed = -3,
};

pub const FfiPixelSize = extern struct {
    width: u16,
    height: u16,
};

pub const FfiCellSize = extern struct {
    width: u16,
    height: u16,
};

pub const FfiRgba8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const FfiGridSize = extern struct {
    cols: u16,
    rows: u16,
};

pub const FfiColorDraw = extern struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: FfiRgba8,
};

pub const FfiSpriteDraw = extern struct {
    slot: u32,
    key: u64,
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: FfiRgba8,
};

pub const FfiDecorationDraw = extern struct {
    kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: FfiRgba8,
};

pub const FfiRasterBounds = extern struct {
    x_px: u16,
    y_px: u16,
    width_px: u16,
    height_px: u16,
};

pub const FfiRasterUpload = extern struct {
    slot: u32,
    key: u64,
    width_px: u16,
    height_px: u16,
    color_mode: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    visual_bounds: FfiRasterBounds,
    pixels_ptr: [*c]const u8,
    pixels_len: c_size_t,
};

pub const FfiColorDrawSpan = extern struct {
    ptr: [*c]const FfiColorDraw,
    len: c_size_t,
};

pub const FfiVtCellFlags = extern struct {
    continuation: u8,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
};

pub const FfiVtColor = extern struct {
    kind: u8,
    value: u32,
};

pub const FfiVtRgb8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const FfiVtRenderColorState = extern struct {
    foreground: FfiVtRgb8,
    background: FfiVtRgb8,
    cursor: FfiVtRgb8,
    palette: [256]FfiVtRgb8,
};

pub const FfiVtCellAttrs = extern struct {
    bold: u8,
    dim: u8,
    italic: u8,
    underline: u8,
    underline_color_set: u8,
    blink: u8,
    inverse: u8,
    invisible: u8,
    strikethrough: u8,
    selected: u8,
};

pub const FfiVtCell = extern struct {
    codepoint: u32,
    combining_len: u8 = 0,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
    combining: [3]u32 = [_]u32{0} ** 3,
    flags: FfiVtCellFlags,
    fg_color: FfiVtColor,
    bg_color: FfiVtColor,
    underline_color: FfiVtColor,
    underline_style: u8,
    reserved3: u8 = 0,
    reserved4: u8 = 0,
    reserved5: u8 = 0,
    attrs: FfiVtCellAttrs,
    link_id: u32,
};

pub const FfiVtCellSpan = extern struct {
    ptr: [*c]const FfiVtCell,
    len: c_size_t,
};

pub const FfiSpriteDrawSpan = extern struct {
    ptr: [*c]const FfiSpriteDraw,
    len: c_size_t,
};

pub const FfiDecorationDrawSpan = extern struct {
    ptr: [*c]const FfiDecorationDraw,
    len: c_size_t,
};

pub const FfiRasterUploadSpan = extern struct {
    ptr: [*c]const FfiRasterUpload,
    len: c_size_t,
};

pub const FfiByteSpan = extern struct {
    ptr: [*c]const u8,
    len: c_size_t,
};

pub const FfiU16Span = extern struct {
    ptr: [*c]const u16,
    len: c_size_t,
};

pub const FfiByteWriteSpan = extern struct {
    ptr: [*c]u8,
    len: c_size_t,
};

pub const FfiU16WriteSpan = extern struct {
    ptr: [*c]u16,
    len: c_size_t,
};

pub const FfiFrameLayoutResult = extern struct {
    status: c_int,
    cell_px: FfiCellSize,
    grid: FfiGridSize,
};

pub const FfiVtCellWriteSpan = extern struct {
    ptr: [*c]FfiVtCell,
    len: c_size_t,
};

pub const FfiVtCursor = extern struct {
    row: u16,
    col: u16,
    visible: u8,
    shape: u8,
    blink: u8,
};

pub const FfiVtSelectionPos = extern struct {
    row: i32,
    col: u16,
    reserved0: u16 = 0,
};

pub const FfiVtSelection = extern struct {
    active: u8,
    selecting: u8,
    reserved0: u16 = 0,
    start: FfiVtSelectionPos,
    end: FfiVtSelectionPos,
};

pub const FfiVtGraphicsMeta = extern struct {
    image_count: u32,
    placement_count: u32,
    virtual_placement_count: u32,
    placeholder_run_count: u32 = 0,
    is_alternate_screen: u8,
    reserved0: u8 = 0,
    publication_seq: u64,
    dirty_generation: u64,
};

pub const FfiVtGraphicsRowAnchor = extern struct {
    kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    value: u32,
};

pub const FfiVtGraphicsImage = extern struct {
    image_id: u32,
    image_number: u32,
    format: u16,
    reserved0: u16 = 0,
    width: u32,
    height: u32,
    payload_len: u64,
};

pub const FfiVtGraphicsPlacement = extern struct {
    image_id: u32,
    placement_id: u32,
    z_index: i32,
    anchor: FfiVtGraphicsRowAnchor,
    anchor_col: u16,
    reserved0: u16 = 0,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    cell_x_offset: u32,
    cell_y_offset: u32,
    columns: u32,
    rows: u32,
    dest_left_cell_px: u32,
    dest_top_cell_px: u32,
    dest_right_cell_px: u32,
    dest_bottom_cell_px: u32,
    dest_grid_columns: u32,
    dest_grid_rows: u32,
    effective_columns: u32,
    effective_rows: u32,
};

pub const FfiVtGraphicsVirtualPlacement = extern struct {
    image_id: u32,
    placement_id: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    columns: u32,
    rows: u32,
};

pub const FfiVtGraphicsPlaceholderRun = extern struct {
    image_id: u32,
    placement_id: u32,
    virtual_placement_index: u32,
    run_order: u32,
    cell_row: u16,
    cell_col: u16,
    reserved0: u32 = 0,
    image_row: u32,
    image_col: u32,
    columns: u32,
};

pub const FfiGeometry = extern struct {
    render_px: FfiPixelSize,
    grid_px: FfiPixelSize,
};

pub const FfiGeometryResponse = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    changed: u8,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
    reserved3: u32 = 0,
    render_px: FfiPixelSize,
    grid_px: FfiPixelSize,
    cell_px: FfiCellSize,
    geometry_epoch: u64,
};

pub const FfiPendingState = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    source_pending: u8,
    prepare_pending: u8,
    submit_pending: u8,
    present_pending: u8,
    reserved0: u32 = 0,
};

pub const FfiPrepareRequest = extern struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    damage_base_seq: u64,
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const FfiPreparedFrame = extern struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    damage_base_seq: u64,
    required_base_seq: u64,
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const FfiVtPublishResult = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    published: u8,
    queued: u8,
    damage_kind: u8,
    reserved0: u8 = 0,
    snapshot_seq: u64,
    geometry_epoch: u64,
};

pub const FfiPublishSlot = extern struct {
    cells: FfiVtCellWriteSpan,
    dirty_rows: FfiByteWriteSpan,
    dirty_cols_start: FfiU16WriteSpan,
    dirty_cols_end: FfiU16WriteSpan,
};

pub const FfiPublishSlotCommit = extern struct {
    history_count: u64,
    scroll_row: u64,
    snapshot_seq: u64,
    is_alternate_screen: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    cursor: FfiVtCursor,
    colors: FfiVtRenderColorState,
    selection: FfiVtSelection,
    graphics: FfiVtGraphicsMeta,
    graphics_images: FfiVtGraphicsImageSpan,
    graphics_placements: FfiVtGraphicsPlacementSpan,
    graphics_virtual_placements: FfiVtGraphicsVirtualPlacementSpan,
    graphics_placeholder_runs: FfiVtGraphicsPlaceholderRunSpan = .{ .ptr = null, .len = 0 },
    graphics_payload_bytes: FfiByteSpan,
};

pub const FfiSurfaceMetrics = extern struct {
    sync_us: u64,
    copy_us: u64,
    render_us: u64,
    glyphs: u64,
    fills: u64,
    clear_fills: u64,
    background_fills: u64,
    decoration_fills: u64,
    cursor_fills: u64,
    uploads: u64,
    face_checks: u64,
    face_cache_hits: u64,
    shape_requests: u64,
    shape_cache_hits: u64,
    fallback_hits: u64,
    fallback_misses: u64,
    missing_glyphs: u64,
};

pub const FfiPresentedRetire = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    snapshot_seq: u64,
};

pub const FfiSurfaceHandle = extern struct {
    host_surface_id: u64,
    width: u16,
    height: u16,
};

pub const FfiPreparedSurfaceInfo = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    render_px: FfiPixelSize,
    cell_px: FfiCellSize,
    grid: FfiGridSize,
    prepare_metrics: FfiSurfaceMetrics,
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const FfiPreparedSurfaceBuffer = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    rgba_pixels: FfiByteSpan,
    uploads_committed: u64,
};

pub const FfiPreparedSurfaceDiagnostics = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    missing_glyphs: u64,
    resolve_metrics: FfiSurfaceMetrics,
};

pub const FfiSurfaceExecutionInput = extern struct {
    surface: FfiSurfaceHandle,
    uploads_committed: u64,
    render_us: u64,
};

pub const FfiVtSurface = extern struct {
    cells: FfiVtCellSpan,
    cols: u16,
    rows: u16,
    history_count: u64,
    scroll_row: u64,
    snapshot_seq: u64,
    is_alternate_screen: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    dirty_rows: FfiByteSpan,
    dirty_cols_start: FfiU16Span,
    dirty_cols_end: FfiU16Span,
    cursor: FfiVtCursor,
    colors: FfiVtRenderColorState,
    selection: FfiVtSelection,
    graphics: FfiVtGraphicsMeta,
    graphics_images: FfiVtGraphicsImageSpan,
    graphics_placements: FfiVtGraphicsPlacementSpan,
    graphics_virtual_placements: FfiVtGraphicsVirtualPlacementSpan,
    graphics_placeholder_runs: FfiVtGraphicsPlaceholderRunSpan = .{ .ptr = null, .len = 0 },
    graphics_payload_bytes: FfiByteSpan,
};

pub const FfiVtGraphicsImageSpan = extern struct {
    ptr: [*c]const FfiVtGraphicsImage,
    len: c_size_t,
};

pub const FfiVtGraphicsPlacementSpan = extern struct {
    ptr: [*c]const FfiVtGraphicsPlacement,
    len: c_size_t,
};

pub const FfiVtGraphicsVirtualPlacementSpan = extern struct {
    ptr: [*c]const FfiVtGraphicsVirtualPlacement,
    len: c_size_t,
};

pub const FfiVtGraphicsPlaceholderRunSpan = extern struct {
    ptr: [*c]const FfiVtGraphicsPlaceholderRun,
    len: c_size_t,
};

pub const FfiSurfaceFeedback = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    surface: FfiSurfaceHandle,
    metrics: FfiSurfaceMetrics,
};

pub const FfiSurfaceTextConfig = extern struct {
    surface_px: FfiPixelSize,
    font_size_px: u16,
    reserved0: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(FfiPixelSize) == 4);
    std.debug.assert(@sizeOf(FfiCellSize) == 4);
    std.debug.assert(@sizeOf(FfiGridSize) == 4);
    std.debug.assert(@sizeOf(FfiByteSpan) == 16);
    std.debug.assert(@sizeOf(FfiVtColor) == 8);
    std.debug.assert(@sizeOf(FfiVtRgb8) == 3);
    std.debug.assert(@sizeOf(FfiVtRenderColorState) == 777);
    std.debug.assert(@sizeOf(FfiVtCursor) == 8);
}
