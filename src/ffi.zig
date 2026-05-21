const std = @import("std");
const Render = @import("howl_render.zig");
const abi = @import("ffi_types.zig");
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

pub const surfaceTextDeriveFrameLayout = surface_text_ffi.deriveFrameLayout;
pub const surfaceTextInit = surface_text_ffi.init;
pub const surfaceTextDeinit = surface_text_ffi.deinit;
pub const surfaceTextSetFontSizePx = surface_text_ffi.setFontSize;
pub const surfaceTextSetFontPath = surface_text_ffi.setFontPath;
pub const surfaceTextSetFallbackFontPaths = surface_text_ffi.setFallbackFontPaths;
pub const surfaceTextSyncGeometry = surface_text_ffi.syncGeometry;
pub const surfaceTextSurfaceQuery = surface_text_ffi.surfaceQuery;
pub const surfaceTextPublishVtSnapshot = surface_text_ffi.publishVtSnapshot;
pub const surfaceTextTakePrepareRequest = surface_text_ffi.takePrepareRequest;
pub const surfaceTextPublishPrepared = surface_text_ffi.publishPrepared;
pub const surfaceTextTakeSubmitDecision = surface_text_ffi.takeSubmitDecision;
pub const surfaceTextAcceptSubmitted = surface_text_ffi.acceptSubmitted;
pub const surfaceTextMarkPresented = surface_text_ffi.markPresented;
pub const surfaceTextPendingState = surface_text_ffi.pendingState;
pub const surfaceTextTakeQueueMetrics = surface_text_ffi.takeQueueMetrics;
pub const surfaceTextPrepareHandle = surface_text_ffi.prepareHandle;
pub const preparedSurfaceRelease = prepared_surface.release;
pub const preparedSurfaceDescribe = prepared_surface.describe;
pub const preparedSurfaceBuffer = prepared_surface.buffer;
pub const preparedSurfaceDiagnostics = prepared_surface.diagnostics;
pub const surfaceTextSubmit = surface_text_ffi.submit;

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
    var prepared_handle: PreparedSurfaceHandle = @ptrFromInt(1);
    try std.testing.expectEqual(
        HowlRenderPrepareStatus.failed,
        surfaceTextPrepareHandle(handle, &vt_surface, input.request, input.query, &prepared_handle),
    );
    try std.testing.expect(prepared_handle == null);
}

test "ffi surface session rejects missing handle" {
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.missing_handle), surfaceTextSetFontSizePx(null, 12));
}

test "ffi pending state writes missing-handle status" {
    var pending = FfiPendingState{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .source_pending = 1,
        .prepare_pending = 1,
        .submit_pending = 1,
        .target_valid = 1,
    };
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.missing_handle),
        surfaceTextPendingState(null, &pending),
    );
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.missing_handle), pending.status);
    try std.testing.expectEqual(@as(u8, 0), pending.source_pending);
}

test "ffi take prepare request clears output on failure" {
    var request = FfiPrepareRequest{
        .snapshot_seq = 9,
        .dirty_epoch = 9,
        .geometry_epoch = 9,
        .damage_base_seq = 9,
        .known_target_epoch = 9,
        .target_valid = 1,
        .damage_kind = @intFromEnum(Render.FramePipeline.DamageKind.full),
    };
    try std.testing.expectEqual(HowlRenderPrepareStatus.failed, surfaceTextTakePrepareRequest(null, &request));
    try std.testing.expectEqual(@as(u64, 0), request.snapshot_seq);
}

test "ffi take submit decision clears output on failure" {
    var prepared = FfiPreparedFrame{
        .snapshot_seq = 9,
        .dirty_epoch = 9,
        .geometry_epoch = 9,
        .damage_base_seq = 9,
        .required_base_seq = 9,
        .required_target_epoch = 9,
        .damage_kind = @intFromEnum(Render.FramePipeline.DamageKind.full),
    };
    try std.testing.expectEqual(HowlRenderSubmitDecisionStatus.failed, surfaceTextTakeSubmitDecision(null, &prepared));
    try std.testing.expectEqual(@as(u64, 0), prepared.snapshot_seq);
}

test "ffi surface session initializes" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);
}

test "ffi surface session rejects zero font size at init" {
    const handle = surfaceTextInit(.{
        .surface_px = .{ .width = 16, .height = 16 },
        .font_size_px = 0,
    });
    try std.testing.expect(handle == null);
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

    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.invalid_argument),
        surfaceTextSetFallbackFontPaths(handle, null, 1),
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

test "ffi prepare handle rejects missing output pointer" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);

    const input = try nextPrepareInput(handle);
    const cells = [_]FfiCell{testCell()};
    const vt_surface = testVtSurface(&cells, testCursor(0));
    try std.testing.expectEqual(
        HowlRenderPrepareStatus.failed,
        surfaceTextPrepareHandle(handle, &vt_surface, input.request, input.query, null),
    );
}

test "ffi prepare handle clears output when vt surface pointer is missing" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);

    const input = try nextPrepareInput(handle);
    var prepared_handle: PreparedSurfaceHandle = @ptrFromInt(1);
    try std.testing.expectEqual(
        HowlRenderPrepareStatus.failed,
        surfaceTextPrepareHandle(handle, null, input.request, input.query, &prepared_handle),
    );
    try std.testing.expect(prepared_handle == null);
}

test "ffi submit clears feedback on failure" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);

    var feedback = FfiSurfaceFeedback{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .damage_kind = @intFromEnum(Render.FramePipeline.DamageKind.full),
        .surface = .{ .host_surface_id = 99, .width = 9, .height = 9, .epoch = 9 },
        .metrics = std.mem.zeroes(FfiSurfaceMetrics),
    };
    const execution = FfiSurfaceExecutionInput{
        .surface = .{ .host_surface_id = 1, .width = 1, .height = 1, .epoch = 1 },
        .uploads_committed = 0,
        .render_us = 0,
        .content_valid = 1,
    };
    try std.testing.expectEqual(
        HowlRenderSubmitStatus.failed,
        surfaceTextSubmit(handle, null, std.mem.zeroes(FfiPreparedFrame), &execution, &feedback),
    );
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.failed), feedback.status);
    try std.testing.expectEqual(@as(u64, 0), feedback.surface.host_surface_id);
}

test "ffi prepared surface describe writes missing-handle status" {
    var info = FfiPreparedSurfaceInfo{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .geometry_epoch = 1,
        .required_base_seq = 1,
        .required_surface_epoch = 1,
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .prepare_metrics = std.mem.zeroes(FfiSurfaceMetrics),
        .damage_kind = @intFromEnum(Render.FramePipeline.DamageKind.full),
    };
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.missing_handle),
        preparedSurfaceDescribe(null, &info),
    );
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.missing_handle), info.status);
    try std.testing.expectEqual(@as(u64, 0), info.snapshot_seq);
}

test "ffi queue metrics clears output on failure" {
    var metrics = FfiQueueMetrics{
        .snapshot_publishes = 9,
        .snapshot_clean_drops = 9,
        .prepare_requests = 9,
        .prepare_coalesces = 9,
        .prepare_forced_full = 9,
        .prepare_takes = 9,
        .prepared_publishes = 9,
        .prepared_coalesces = 9,
        .submit_takes = 9,
        .submit_valid = 9,
        .submit_rejected = 9,
        .full_prepare_requests = 9,
        .submitted_accepts = 9,
        .presents = 9,
        .target_invalidations = 9,
    };
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.missing_handle),
        surfaceTextTakeQueueMetrics(null, &metrics),
    );
    try std.testing.expectEqual(@as(u64, 0), metrics.snapshot_publishes);
}
