const std = @import("std");
const Render = @import("howl_render.zig");
const SurfaceText = Render.SurfaceText;
const surface = @import("frame/surface.zig");
const prepared_surface = @import("frame/prepared_surface_ffi.zig");
const surface_text_ffi = @import("frame/surface_text_ffi.zig");
const text_support = @import("text/font/ft_hb/support.zig");

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
    pixels_len: usize,
};

pub const FfiColorDrawSpan = extern struct {
    ptr: [*c]const FfiColorDraw,
    len: usize,
};

pub const FfiCellSpan = extern struct {
    ptr: [*c]const FfiCell,
    len: usize,
};

pub const FfiSpriteDrawSpan = extern struct {
    ptr: [*c]const FfiSpriteDraw,
    len: usize,
};

pub const FfiDecorationDrawSpan = extern struct {
    ptr: [*c]const FfiDecorationDraw,
    len: usize,
};

pub const FfiRasterUploadSpan = extern struct {
    ptr: [*c]const FfiRasterUpload,
    len: usize,
};

pub const FfiByteSpan = extern struct {
    ptr: [*c]const u8,
    len: usize,
};

pub const FfiU16Span = extern struct {
    ptr: [*c]const u16,
    len: usize,
};

pub const FfiFrameGridResult = extern struct {
    status: c_int,
    grid: FfiGridSize,
};

pub const FfiFrameLayoutResult = extern struct {
    status: c_int,
    cell_px: FfiCellSize,
    grid: FfiGridSize,
};

pub const FfiCellFlags = extern struct {
    continuation: u8,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
};

pub const FfiColor = extern struct {
    kind: u8,
    value: u32,
};

pub const FfiCellAttrs = extern struct {
    bold: u8,
    dim: u8,
    italic: u8,
    underline: u8,
    underline_color_set: u8,
    blink: u8,
    inverse: u8,
    invisible: u8,
    strikethrough: u8,
};

pub const FfiCell = extern struct {
    codepoint: u32,
    flags: FfiCellFlags,
    fg_color: FfiColor,
    bg_color: FfiColor,
    underline_color: FfiColor,
    underline_style: u8,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
    attrs: FfiCellAttrs,
    link_id: u32,
};

pub const FfiCursor = extern struct {
    row: u16,
    col: u16,
    visible: u8,
    shape: u8,
};

pub const FfiGeometry = extern struct {
    render_px: FfiPixelSize,
    grid_px: FfiPixelSize,
    cell_px: FfiCellSize,
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

pub const FfiSurfaceQuery = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    render_px: FfiPixelSize,
    grid_px: FfiPixelSize,
    cell_px: FfiCellSize,
    font_size_px: u16,
    reserved0: u16 = 0,
    epoch: u64,
};

pub const FfiPendingState = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    source_pending: u8,
    prepare_pending: u8,
    submit_pending: u8,
    target_valid: u8,
    reserved0: u8 = 0,
};

pub const FfiPrepareRequest = extern struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    damage_base_seq: u64,
    known_target_epoch: u64,
    target_valid: u8,
    damage_kind: u8,
    reserved0: u16 = 0,
};

pub const FfiPreparedFrame = extern struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    damage_base_seq: u64,
    required_base_seq: u64,
    required_target_epoch: u64,
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const FfiVtSnapshot = extern struct {
    cols: u16,
    rows: u16,
    is_alternate_screen: u8,
    damage_kind: u8,
    scrollback_offset: u64,
    snapshot_seq: u64,
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

pub const FfiQueueMetrics = extern struct {
    snapshot_publishes: u64,
    snapshot_hidden_drops: u64,
    snapshot_clean_drops: u64,
    prepare_requests: u64,
    prepare_coalesces: u64,
    prepare_forced_full: u64,
    prepare_takes: u64,
    prepared_publishes: u64,
    prepared_coalesces: u64,
    submit_takes: u64,
    submit_valid: u64,
    submit_rejected: u64,
    full_prepare_requests: u64,
    submitted_accepts: u64,
    presents: u64,
    target_invalidations: u64,
};

pub const FfiSurfaceHandle = extern struct {
    host_surface_id: u64,
    width: u16,
    height: u16,
    epoch: u64,
};

pub const FfiPreparedSurfaceInfo = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    required_surface_epoch: u64,
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
    content_valid: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const FfiVtSurface = extern struct {
    cells: FfiCellSpan,
    cols: u16,
    rows: u16,
    scroll_row: u64,
    is_alternate_screen: u8,
    full_damage: u8,
    reserved1: u16 = 0,
    dirty_rows: FfiByteSpan,
    dirty_cols_start: FfiU16Span,
    dirty_cols_end: FfiU16Span,
    cursor: FfiCursor,
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
    std.debug.assert(@sizeOf(FfiColor) == 8);
    std.debug.assert(@sizeOf(FfiCursor) == 6);
}

fn pixelIn(value: FfiPixelSize) surface.PixelSize {
    return .{ .width = value.width, .height = value.height };
}

fn cellIn(value: FfiCellSize) surface.CellSize {
    return .{ .width = value.width, .height = value.height };
}

fn gridOut(value: surface.GridSize) FfiGridSize {
    return .{ .cols = value.cols, .rows = value.rows };
}

pub fn deriveGridSize(grid_px: FfiPixelSize, cell_px: FfiCellSize) callconv(.c) FfiGridSize {
    return gridOut(Render.deriveGridSize(pixelIn(grid_px), cellIn(cell_px)));
}

pub fn deriveFrameGridSize(render_px: FfiPixelSize, grid_px: FfiPixelSize, cell_px: FfiCellSize) callconv(.c) FfiFrameGridResult {
    const grid = Render.deriveGridForFrame(pixelIn(render_px), pixelIn(grid_px), cellIn(cell_px)) catch |err| {
        return .{
            .status = switch (err) {
                error.InvalidSurfaceSize => -1,
                error.InvalidGridSize => -2,
            },
            .grid = .{ .cols = 0, .rows = 0 },
        };
    };
    return .{ .status = 0, .grid = gridOut(grid) };
}

pub fn surfaceTextDeriveFrameLayout(handle: SurfaceTextHandle, render_px: FfiPixelSize, grid_px: FfiPixelSize) callconv(.c) FfiFrameLayoutResult {
    return surface_text_ffi.deriveFrameLayout(@This(), handle, render_px, grid_px);
}

pub fn surfaceTextInit(config: FfiSurfaceTextConfig) callconv(.c) SurfaceTextHandle {
    return surface_text_ffi.init(@This(), config);
}

pub fn surfaceTextDeinit(handle: SurfaceTextHandle) callconv(.c) void {
    surface_text_ffi.deinit(@This(), handle);
}

pub fn surfaceTextSetFontSizePx(handle: SurfaceTextHandle, font_size_px: u16) callconv(.c) c_int {
    return surface_text_ffi.setFontSize(@This(), handle, font_size_px);
}

pub fn surfaceTextSetFontPath(handle: SurfaceTextHandle, ptr: ?[*]const u8, len: usize) callconv(.c) c_int {
    return surface_text_ffi.setFontPath(@This(), handle, ptr, len);
}

pub fn surfaceTextSetFallbackFontPaths(handle: SurfaceTextHandle, ptrs: ?[*]const ?[*]const u8, count: usize) callconv(.c) c_int {
    return surface_text_ffi.setFallbackFontPaths(@This(), handle, ptrs, count);
}

pub fn surfaceTextSyncGeometry(handle: SurfaceTextHandle, geometry: FfiGeometry) callconv(.c) FfiGeometryResponse {
    return surface_text_ffi.syncGeometry(@This(), handle, geometry);
}

pub fn surfaceTextSurfaceQuery(handle: SurfaceTextHandle) callconv(.c) FfiSurfaceQuery {
    return surface_text_ffi.surfaceQuery(@This(), handle);
}

pub fn surfaceTextPublishVtSnapshot(handle: SurfaceTextHandle, snapshot: FfiVtSnapshot) callconv(.c) FfiVtPublishResult {
    return surface_text_ffi.publishVtSnapshot(@This(), handle, snapshot);
}

pub fn surfaceTextTakePrepareRequest(handle: SurfaceTextHandle, prepare_request_out: ?*FfiPrepareRequest) callconv(.c) HowlRenderPrepareStatus {
    return surface_text_ffi.takePrepareRequest(@This(), handle, prepare_request_out);
}

pub fn surfaceTextPublishPrepared(handle: SurfaceTextHandle, prepared_frame: FfiPreparedFrame) callconv(.c) c_int {
    return surface_text_ffi.publishPrepared(@This(), handle, prepared_frame);
}

pub fn surfaceTextTakeSubmitDecision(handle: SurfaceTextHandle, prepared_frame_out: ?*FfiPreparedFrame) callconv(.c) HowlRenderSubmitDecisionStatus {
    return surface_text_ffi.takeSubmitDecision(@This(), handle, prepared_frame_out);
}

pub fn surfaceTextAcceptSubmitted(handle: SurfaceTextHandle, prepared_frame: FfiPreparedFrame, surface_handle: FfiSurfaceHandle, content_valid: u8) callconv(.c) c_int {
    return surface_text_ffi.acceptSubmitted(@This(), handle, prepared_frame, surface_handle, content_valid);
}

pub fn surfaceTextMarkPresented(handle: SurfaceTextHandle) callconv(.c) void {
    surface_text_ffi.markPresented(@This(), handle);
}

pub fn surfaceTextPendingState(handle: SurfaceTextHandle, pending_out: ?*FfiPendingState) callconv(.c) c_int {
    return surface_text_ffi.pendingState(@This(), handle, pending_out);
}

pub fn surfaceTextTakeQueueMetrics(handle: SurfaceTextHandle, metrics_out: ?*FfiQueueMetrics) callconv(.c) c_int {
    return surface_text_ffi.takeQueueMetrics(@This(), handle, metrics_out);
}

pub fn surfaceTextPrepareHandle(surface_text_handle: SurfaceTextHandle, vt_surface_in: ?*const FfiVtSurface, prepare_request: FfiPrepareRequest, query: FfiSurfaceQuery, prepared_handle_out: ?*PreparedSurfaceHandle) callconv(.c) HowlRenderPrepareStatus {
    return surface_text_ffi.prepareHandle(@This(), surface_text_handle, vt_surface_in, prepare_request, query, prepared_handle_out);
}

pub fn preparedSurfaceRelease(prepared_surface_handle: PreparedSurfaceHandle) callconv(.c) void {
    const owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return;
    owner.destroy();
}

pub fn preparedSurfaceDescribe(prepared_surface_handle: PreparedSurfaceHandle, info_out: ?*FfiPreparedSurfaceInfo) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = info_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.infoOut(@This(), owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceBuffer(prepared_surface_handle: PreparedSurfaceHandle, plan_out: ?*FfiPreparedSurfaceBuffer) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = plan_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.bufferOut(@This(), owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceDiagnostics(prepared_surface_handle: PreparedSurfaceHandle, diagnostics_out: ?*FfiPreparedSurfaceDiagnostics) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = diagnostics_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.diagnosticsOut(@This(), owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn surfaceTextSubmit(surface_text_handle: SurfaceTextHandle, prepared_surface_handle: PreparedSurfaceHandle, prepared_frame_in: FfiPreparedFrame, execution_in: ?*const FfiSurfaceExecutionInput, feedback_out: ?*FfiSurfaceFeedback) callconv(.c) HowlRenderSubmitStatus {
    return surface_text_ffi.submit(@This(), surface_text_handle, prepared_surface_handle, prepared_frame_in, execution_in, feedback_out);
}

test "ffi surface session rejects missing handle" {
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.missing_handle), surfaceTextSetFontSizePx(null, 12));
}

test "ffi surface session initializes" {
    const handle = surfaceTextInit(.{
        .surface_px = .{ .width = 16, .height = 16 },
        .font_size_px = 8,
    });
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);
}

test "ffi fallback font paths accept abi limit and reject overflow" {
    const handle = surfaceTextInit(.{
        .surface_px = .{ .width = 16, .height = 16 },
        .font_size_px = 8,
    });
    defer surfaceTextDeinit(handle);

    var ok_paths: [text_support.max_fallback_fonts]?[*]const u8 = [_]?[*]const u8{"font".ptr} ** text_support.max_fallback_fonts;
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.ok),
        surfaceTextSetFallbackFontPaths(handle, &ok_paths, ok_paths.len),
    );

    var overflow_paths: [text_support.max_fallback_fonts + 1]?[*]const u8 = [_]?[*]const u8{"font".ptr} ** (text_support.max_fallback_fonts + 1);
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.invalid_argument),
        surfaceTextSetFallbackFontPaths(handle, &overflow_paths, overflow_paths.len),
    );
}

test "ffi vt snapshot rejects invalid damage kind" {
    const handle = surfaceTextInit(.{
        .surface_px = .{ .width = 16, .height = 16 },
        .font_size_px = 8,
    });
    defer surfaceTextDeinit(handle);

    const result = surfaceTextPublishVtSnapshot(handle, .{
        .cols = 1,
        .rows = 1,
        .is_alternate_screen = 0,
        .damage_kind = 2,
        .scrollback_offset = 0,
        .snapshot_seq = 1,
    });
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.invalid_argument), result.status);
}

test "ffi prepared frame rejects invalid damage kind" {
    const handle = surfaceTextInit(.{
        .surface_px = .{ .width = 16, .height = 16 },
        .font_size_px = 8,
    });
    defer surfaceTextDeinit(handle);

    const prepared = FfiPreparedFrame{
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .geometry_epoch = 1,
        .damage_base_seq = 0,
        .required_base_seq = 0,
        .required_target_epoch = 0,
        .damage_kind = 2,
    };
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.invalid_argument),
        surfaceTextPublishPrepared(handle, prepared),
    );
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.invalid_argument),
        surfaceTextAcceptSubmitted(handle, prepared, .{ .host_surface_id = 1, .width = 1, .height = 1, .epoch = 1 }, 1),
    );
}
