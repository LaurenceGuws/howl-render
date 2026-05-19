const std = @import("std");
const Render = @import("howl_render.zig");
const abi = @import("ffi_types.zig");
const surface = @import("frame/surface.zig");
const prepared_surface = @import("frame/prepared_surface_ffi.zig");
const surface_text_ffi = @import("frame/surface_text_ffi.zig");
const text_support = @import("text/font/ft_hb/support.zig");

pub const HowlRenderSurfaceText = abi.HowlRenderSurfaceText;
pub const HowlRenderPreparedSurfaceObject = abi.HowlRenderPreparedSurfaceObject;

pub const SurfaceTextHandle = abi.SurfaceTextHandle;
pub const PreparedSurfaceHandle = abi.PreparedSurfaceHandle;

pub const HowlRenderCallStatus = abi.HowlRenderCallStatus;
pub const HowlRenderPrepareStatus = abi.HowlRenderPrepareStatus;
pub const HowlRenderSubmitStatus = abi.HowlRenderSubmitStatus;
pub const HowlRenderSubmitDecisionStatus = abi.HowlRenderSubmitDecisionStatus;

pub const FfiPixelSize = abi.FfiPixelSize;
pub const FfiCellSize = abi.FfiCellSize;
pub const FfiRgba8 = abi.FfiRgba8;
pub const FfiGridSize = abi.FfiGridSize;
pub const FfiColorDraw = abi.FfiColorDraw;
pub const FfiSpriteDraw = abi.FfiSpriteDraw;
pub const FfiDecorationDraw = abi.FfiDecorationDraw;
pub const FfiRasterBounds = abi.FfiRasterBounds;
pub const FfiRasterUpload = abi.FfiRasterUpload;
pub const FfiColorDrawSpan = abi.FfiColorDrawSpan;
pub const FfiCellSpan = abi.FfiCellSpan;
pub const FfiSpriteDrawSpan = abi.FfiSpriteDrawSpan;
pub const FfiDecorationDrawSpan = abi.FfiDecorationDrawSpan;
pub const FfiRasterUploadSpan = abi.FfiRasterUploadSpan;
pub const FfiByteSpan = abi.FfiByteSpan;
pub const FfiU16Span = abi.FfiU16Span;
pub const FfiFrameGridResult = abi.FfiFrameGridResult;
pub const FfiFrameLayoutResult = abi.FfiFrameLayoutResult;
pub const FfiCellFlags = abi.FfiCellFlags;
pub const FfiColor = abi.FfiColor;
pub const FfiCellAttrs = abi.FfiCellAttrs;
pub const FfiCell = abi.FfiCell;
pub const FfiCursor = abi.FfiCursor;
pub const FfiGeometry = abi.FfiGeometry;
pub const FfiGeometryResponse = abi.FfiGeometryResponse;
pub const FfiSurfaceQuery = abi.FfiSurfaceQuery;
pub const FfiPendingState = abi.FfiPendingState;
pub const FfiPrepareRequest = abi.FfiPrepareRequest;
pub const FfiPreparedFrame = abi.FfiPreparedFrame;
pub const FfiVtSnapshot = abi.FfiVtSnapshot;
pub const FfiVtPublishResult = abi.FfiVtPublishResult;
pub const FfiSurfaceMetrics = abi.FfiSurfaceMetrics;
pub const FfiQueueMetrics = abi.FfiQueueMetrics;
pub const FfiSurfaceHandle = abi.FfiSurfaceHandle;
pub const FfiPreparedSurfaceInfo = abi.FfiPreparedSurfaceInfo;
pub const FfiPreparedSurfaceBuffer = abi.FfiPreparedSurfaceBuffer;
pub const FfiPreparedSurfaceDiagnostics = abi.FfiPreparedSurfaceDiagnostics;
pub const FfiSurfaceExecutionInput = abi.FfiSurfaceExecutionInput;
pub const FfiVtSurface = abi.FfiVtSurface;
pub const FfiSurfaceFeedback = abi.FfiSurfaceFeedback;
pub const FfiSurfaceTextConfig = abi.FfiSurfaceTextConfig;

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
    return surface_text_ffi.deriveFrameLayout(handle, render_px, grid_px);
}

pub fn surfaceTextInit(config: FfiSurfaceTextConfig) callconv(.c) SurfaceTextHandle {
    return surface_text_ffi.init(config);
}

pub fn surfaceTextDeinit(handle: SurfaceTextHandle) callconv(.c) void {
    surface_text_ffi.deinit(handle);
}

pub fn surfaceTextSetFontSizePx(handle: SurfaceTextHandle, font_size_px: u16) callconv(.c) c_int {
    return surface_text_ffi.setFontSize(handle, font_size_px);
}

pub fn surfaceTextSetFontPath(handle: SurfaceTextHandle, ptr: ?[*]const u8, len: usize) callconv(.c) c_int {
    return surface_text_ffi.setFontPath(handle, ptr, len);
}

pub fn surfaceTextSetFallbackFontPaths(handle: SurfaceTextHandle, ptrs: ?[*]const ?[*]const u8, count: usize) callconv(.c) c_int {
    return surface_text_ffi.setFallbackFontPaths(handle, ptrs, count);
}

pub fn surfaceTextSyncGeometry(handle: SurfaceTextHandle, geometry: FfiGeometry) callconv(.c) FfiGeometryResponse {
    return surface_text_ffi.syncGeometry(handle, geometry);
}

pub fn surfaceTextSurfaceQuery(handle: SurfaceTextHandle) callconv(.c) FfiSurfaceQuery {
    return surface_text_ffi.surfaceQuery(handle);
}

pub fn surfaceTextPublishVtSnapshot(handle: SurfaceTextHandle, snapshot: FfiVtSnapshot) callconv(.c) FfiVtPublishResult {
    return surface_text_ffi.publishVtSnapshot(handle, snapshot);
}

pub fn surfaceTextTakePrepareRequest(handle: SurfaceTextHandle, prepare_request_out: ?*FfiPrepareRequest) callconv(.c) HowlRenderPrepareStatus {
    return surface_text_ffi.takePrepareRequest(handle, prepare_request_out);
}

pub fn surfaceTextPublishPrepared(handle: SurfaceTextHandle, prepared_frame: FfiPreparedFrame) callconv(.c) c_int {
    return surface_text_ffi.publishPrepared(handle, prepared_frame);
}

pub fn surfaceTextTakeSubmitDecision(handle: SurfaceTextHandle, prepared_frame_out: ?*FfiPreparedFrame) callconv(.c) HowlRenderSubmitDecisionStatus {
    return surface_text_ffi.takeSubmitDecision(handle, prepared_frame_out);
}

pub fn surfaceTextAcceptSubmitted(handle: SurfaceTextHandle, prepared_frame: FfiPreparedFrame, surface_handle: FfiSurfaceHandle, content_valid: u8) callconv(.c) c_int {
    return surface_text_ffi.acceptSubmitted(handle, prepared_frame, surface_handle, content_valid);
}

pub fn surfaceTextMarkPresented(handle: SurfaceTextHandle) callconv(.c) void {
    surface_text_ffi.markPresented(handle);
}

pub fn surfaceTextPendingState(handle: SurfaceTextHandle, pending_out: ?*FfiPendingState) callconv(.c) c_int {
    return surface_text_ffi.pendingState(handle, pending_out);
}

pub fn surfaceTextTakeQueueMetrics(handle: SurfaceTextHandle, metrics_out: ?*FfiQueueMetrics) callconv(.c) c_int {
    return surface_text_ffi.takeQueueMetrics(handle, metrics_out);
}

pub fn surfaceTextPrepareHandle(surface_text_handle: SurfaceTextHandle, vt_surface_in: ?*const FfiVtSurface, prepare_request: FfiPrepareRequest, query: FfiSurfaceQuery, prepared_handle_out: ?*PreparedSurfaceHandle) callconv(.c) HowlRenderPrepareStatus {
    return surface_text_ffi.prepareHandle(surface_text_handle, vt_surface_in, prepare_request, query, prepared_handle_out);
}

pub fn preparedSurfaceRelease(prepared_surface_handle: PreparedSurfaceHandle) callconv(.c) void {
    const owner = prepared_surface.fromHandle(prepared_surface_handle) orelse return;
    owner.destroy();
}

pub fn preparedSurfaceDescribe(prepared_surface_handle: PreparedSurfaceHandle, info_out: ?*FfiPreparedSurfaceInfo) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = info_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.infoOut(owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceBuffer(prepared_surface_handle: PreparedSurfaceHandle, plan_out: ?*FfiPreparedSurfaceBuffer) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = plan_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.bufferOut(owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceDiagnostics(prepared_surface_handle: PreparedSurfaceHandle, diagnostics_out: ?*FfiPreparedSurfaceDiagnostics) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = diagnostics_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.diagnosticsOut(owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn surfaceTextSubmit(surface_text_handle: SurfaceTextHandle, prepared_surface_handle: PreparedSurfaceHandle, prepared_frame_in: FfiPreparedFrame, execution_in: ?*const FfiSurfaceExecutionInput, feedback_out: ?*FfiSurfaceFeedback) callconv(.c) HowlRenderSubmitStatus {
    return surface_text_ffi.submit(surface_text_handle, prepared_surface_handle, prepared_frame_in, execution_in, feedback_out);
}

const TestPrepareInput = struct {
    query: FfiSurfaceQuery,
    request: FfiPrepareRequest,
};

fn testHandle() SurfaceTextHandle {
    return surfaceTextInit(.{
        .surface_px = .{ .width = 16, .height = 16 },
        .font_size_px = 8,
    });
}

fn testCell() FfiCell {
    return .{
        .codepoint = 'a',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{},
        .link_id = 0,
    };
}

fn testCursor(shape: u8) FfiCursor {
    return .{ .row = 0, .col = 0, .visible = 1, .shape = shape };
}

fn testVtSurface(cells: []const FfiCell, cursor: FfiCursor) FfiVtSurface {
    return .{
        .cells = .{ .ptr = if (cells.len == 0) null else cells.ptr, .len = cells.len },
        .cols = 1,
        .rows = 1,
        .scroll_row = 0,
        .is_alternate_screen = 0,
        .full_damage = 1,
        .dirty_rows = .{ .ptr = null, .len = 0 },
        .dirty_cols_start = .{ .ptr = null, .len = 0 },
        .dirty_cols_end = .{ .ptr = null, .len = 0 },
        .cursor = cursor,
    };
}

fn nextPrepareInput(handle: SurfaceTextHandle) !TestPrepareInput {
    const render_px = FfiPixelSize{ .width = 16, .height = 16 };
    const grid_px = FfiPixelSize{ .width = 16, .height = 16 };
    const layout = surfaceTextDeriveFrameLayout(handle, render_px, grid_px);
    try std.testing.expectEqual(@as(c_int, 0), layout.status);

    const sync = surfaceTextSyncGeometry(handle, .{
        .render_px = render_px,
        .grid_px = grid_px,
        .cell_px = layout.cell_px,
    });
    try std.testing.expectEqual(@as(c_int, 0), sync.status);

    const publish = surfaceTextPublishVtSnapshot(handle, .{
        .cols = 1,
        .rows = 1,
        .is_alternate_screen = 0,
        .damage_kind = @intFromEnum(Render.FramePipeline.DamageKind.full),
        .scrollback_offset = 0,
        .snapshot_seq = 1,
    });
    try std.testing.expectEqual(@as(c_int, 0), publish.status);

    var request: FfiPrepareRequest = undefined;
    try std.testing.expectEqual(HowlRenderPrepareStatus.ready, surfaceTextTakePrepareRequest(handle, &request));

    const query = surfaceTextSurfaceQuery(handle);
    try std.testing.expectEqual(@as(c_int, 0), query.status);

    return .{ .query = query, .request = request };
}

fn expectPrepareHandleFails(vt_surface: FfiVtSurface) !void {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);

    const input = try nextPrepareInput(handle);
    var prepared_handle: PreparedSurfaceHandle = null;
    try std.testing.expectEqual(
        HowlRenderPrepareStatus.failed,
        surfaceTextPrepareHandle(handle, &vt_surface, input.request, input.query, &prepared_handle),
    );
    try std.testing.expect(prepared_handle == null);
}

test "ffi surface session rejects missing handle" {
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.missing_handle), surfaceTextSetFontSizePx(null, 12));
}

test "ffi surface session initializes" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);
}

test "ffi fallback font paths accept abi limit and reject overflow" {
    const handle = testHandle();
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
    const handle = testHandle();
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
    const handle = testHandle();
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

test "ffi prepare handle rejects invalid cell color kind" {
    var cell = testCell();
    cell.fg_color.kind = 9;
    const cells = [_]FfiCell{cell};
    try expectPrepareHandleFails(testVtSurface(&cells, testCursor(0)));
}

test "ffi prepare handle rejects rgb value outside u24" {
    var cell = testCell();
    cell.fg_color.kind = 2;
    cell.fg_color.value = std.math.maxInt(u24) + 1;
    const cells = [_]FfiCell{cell};
    try expectPrepareHandleFails(testVtSurface(&cells, testCursor(0)));
}

test "ffi prepare handle rejects invalid cursor shape" {
    const cells = [_]FfiCell{testCell()};
    try expectPrepareHandleFails(testVtSurface(&cells, testCursor(9)));
}

test "ffi prepare handle rejects invalid underline style" {
    var cell = testCell();
    cell.underline_style = 9;
    const cells = [_]FfiCell{cell};
    try expectPrepareHandleFails(testVtSurface(&cells, testCursor(0)));
}

test "ffi prepare handle rejects extra cells beyond declared grid" {
    const cells = [_]FfiCell{ testCell(), testCell() };
    try expectPrepareHandleFails(testVtSurface(&cells, testCursor(0)));
}
