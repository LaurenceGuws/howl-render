const std = @import("std");
const abi = @import("ffi_types.zig");
const pipeline = @import("frame/pipeline.zig");
const surface_text = @import("frame/surface_text.zig");
const prepared_surface = @import("frame/prepared_surface_ffi.zig");
const surface_text_ffi = @import("frame/surface_text_ffi.zig");
const text_support = @import("text/font/ft_hb/support.zig");

const SurfaceTextHandle = abi.SurfaceTextHandle;
const PreparedSurfaceHandle = abi.PreparedSurfaceHandle;

const HowlRenderCallStatus = abi.HowlRenderCallStatus;
const HowlRenderPrepareStatus = abi.HowlRenderPrepareStatus;
const HowlRenderSubmitStatus = abi.HowlRenderSubmitStatus;
const HowlRenderSubmitDecisionStatus = abi.HowlRenderSubmitDecisionStatus;

const FfiPixelSize = abi.FfiPixelSize;
const FfiVtCell = abi.FfiVtCell;
const FfiVtCursor = abi.FfiVtCursor;
const FfiGeometry = abi.FfiGeometry;
const FfiPendingState = abi.FfiPendingState;
const FfiPublishSlot = abi.FfiPublishSlot;
const FfiPrepareRequest = abi.FfiPrepareRequest;
const FfiPreparedFrame = abi.FfiPreparedFrame;
const FfiSurfaceExecutionInput = abi.FfiSurfaceExecutionInput;
const FfiSurfaceFeedback = abi.FfiSurfaceFeedback;
const FfiPreparedSurfaceInfo = abi.FfiPreparedSurfaceInfo;
const FfiVtRenderColorState = abi.FfiVtRenderColorState;

const surfaceTextDeriveFrameLayout = surface_text_ffi.deriveFrameLayout;
const surfaceTextInit = surface_text_ffi.init;
const surfaceTextDeinit = surface_text_ffi.deinit;
const surfaceTextIsValidFont = surface_text_ffi.isValidFont;
const surfaceTextSetFontSizePx = surface_text_ffi.setFontSize;
const surfaceTextSetFontPath = surface_text_ffi.setFontPath;
const surfaceTextSetFallbackFontPaths = surface_text_ffi.setFallbackFontPaths;
const surfaceTextSetCursorBlinkVisible = surface_text_ffi.setCursorBlinkVisible;
const surfaceTextSyncGeometry = surface_text_ffi.syncGeometry;
const surfaceTextReservePublishSlot = surface_text_ffi.reservePublishSlot;
const surfaceTextCommitPublishDecodedGraphicsSlot = surface_text_ffi.commitPublishDecodedGraphicsSlot;
const surfaceTextRejectPublishSlot = surface_text_ffi.rejectPublishSlot;
const surfaceTextCancelPublishSlot = surface_text_ffi.cancelPublishSlot;
const surfaceTextTakePrepareRequest = surface_text_ffi.takePrepareRequest;
const surfaceTextPublishPrepared = surface_text_ffi.publishPrepared;
const surfaceTextPublishPreparedHandle = surface_text_ffi.publishPreparedHandle;
const surfaceTextTakeSubmitDecision = surface_text_ffi.takeSubmitDecision;
const surfaceTextTakeSubmitHandle = surface_text_ffi.takeSubmitHandle;
const surfaceTextAcceptSubmitted = surface_text_ffi.acceptSubmitted;
const surfaceTextPendingState = surface_text_ffi.pendingState;
const surfaceTextPrepareHandle = surface_text_ffi.prepareHandle;
const preparedSurfaceRelease = prepared_surface.release;
const preparedSurfaceDescribe = prepared_surface.describe;
const preparedSurfaceBuffer = prepared_surface.buffer;
const preparedSurfaceDiagnostics = prepared_surface.diagnostics;
const surfaceTextSubmit = surface_text_ffi.submit;
const surfaceTextSubmitHandle = surface_text_ffi.submitHandle;

const TestPrepareInput = struct {
    request: FfiPrepareRequest,
};

fn testHandle() SurfaceTextHandle {
    return surfaceTextInit(.{
        .surface_px = .{ .width = 16, .height = 16 },
        .font_size_px = 8,
    });
}

fn testCell() FfiVtCell {
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

fn testCursor(shape: u8) FfiVtCursor {
    return .{ .row = 0, .col = 0, .visible = 1, .shape = shape, .blink = 0 };
}

fn nextPrepareInput(handle: SurfaceTextHandle) !TestPrepareInput {
    const render_px = FfiPixelSize{ .width = 16, .height = 16 };
    const grid_px = FfiPixelSize{ .width = 16, .height = 16 };
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{0};
    const dirty_cols_end = [_]u16{0};
    const layout = surfaceTextDeriveFrameLayout(handle, render_px, grid_px);
    try std.testing.expectEqual(@as(c_int, 0), layout.status);

    const sync = surfaceTextSyncGeometry(handle, .{
        .render_px = render_px,
        .grid_px = grid_px,
    });
    try std.testing.expectEqual(@as(c_int, 0), sync.status);

    var slot: FfiPublishSlot = undefined;
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.ok),
        surfaceTextReservePublishSlot(handle, 1, 1, &slot),
    );
    slot.cells.ptr[0] = testCell();
    slot.dirty_rows.ptr[0] = dirty_rows[0];
    slot.dirty_cols_start.ptr[0] = dirty_cols_start[0];
    slot.dirty_cols_end.ptr[0] = dirty_cols_end[0];

    const publish = surfaceTextCommitPublishDecodedGraphicsSlot(handle, .{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = 0,
        .reserved0 = 0,
        .reserved1 = 0,
        .cursor = testCursor(0),
        .colors = std.mem.zeroes(FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = std.mem.zeroes(abi.FfiVtGraphicsMeta),
        .graphics_images = .{ .ptr = null, .len = 0 },
        .graphics_placements = .{ .ptr = null, .len = 0 },
        .graphics_payload_bytes = .{ .ptr = null, .len = 0 },
    });
    try std.testing.expectEqual(@as(c_int, 0), publish.status);

    var request: FfiPrepareRequest = undefined;
    try std.testing.expectEqual(HowlRenderPrepareStatus.ready, surfaceTextTakePrepareRequest(handle, &request));

    return .{ .request = request };
}

test "ffi surface session rejects missing handle" {
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.missing_handle), surfaceTextSetFontSizePx(null, 12));
}

test "ffi valid font reports missing handle and invalid config" {
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.missing_handle), surfaceTextIsValidFont(null));

    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.failed), surfaceTextIsValidFont(handle));
}

test "ffi pending state writes missing-handle status" {
    var pending = FfiPendingState{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .source_pending = 1,
        .prepare_pending = 1,
        .submit_pending = 1,
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
        .damage_kind = @intFromEnum(pipeline.DamageKind.full),
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
        .damage_kind = @intFromEnum(pipeline.DamageKind.full),
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

test "ffi prepared frame rejects invalid damage kind" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);

    const prepared = FfiPreparedFrame{
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .geometry_epoch = 1,
        .damage_base_seq = 0,
        .required_base_seq = 0,
        .damage_kind = 2,
    };
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.invalid_argument),
        surfaceTextPublishPrepared(handle, prepared),
    );
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.invalid_argument),
        surfaceTextAcceptSubmitted(handle, prepared),
    );
}

test "ffi publish slot exposes render-owned reserved cells directly" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);

    const render_px = FfiPixelSize{ .width = 16, .height = 16 };
    const grid_px = FfiPixelSize{ .width = 16, .height = 16 };
    const layout = surfaceTextDeriveFrameLayout(handle, render_px, grid_px);
    try std.testing.expectEqual(@as(c_int, 0), layout.status);
    const sync = surfaceTextSyncGeometry(handle, .{ .render_px = render_px, .grid_px = grid_px });
    try std.testing.expectEqual(@as(c_int, 0), sync.status);

    var slot: FfiPublishSlot = undefined;
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.ok),
        surfaceTextReservePublishSlot(handle, 1, 1, &slot),
    );
    defer surfaceTextCancelPublishSlot(handle);

    const owner: *surface_text.SurfaceTextOwner = @ptrCast(@alignCast(handle.?));
    try std.testing.expect(owner.flow.publication_state.reserved != null);
    try std.testing.expect(slot.cells.ptr != null);
    try std.testing.expectEqual(@as(c_size_t, 1), slot.cells.len);
    try std.testing.expectEqual(owner.flow.publication_state.reserved.?.cells.ptr, slot.cells.ptr);
    slot.cells.ptr[0] = testCell();
    slot.dirty_rows.ptr[0] = 1;
    slot.dirty_cols_start.ptr[0] = 0;
    slot.dirty_cols_end.ptr[0] = 0;

    const publish = surfaceTextCommitPublishDecodedGraphicsSlot(handle, .{
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = 0,
        .cursor = testCursor(0),
        .colors = std.mem.zeroes(FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = std.mem.zeroes(abi.FfiVtGraphicsMeta),
        .graphics_images = .{ .ptr = null, .len = 0 },
        .graphics_placements = .{ .ptr = null, .len = 0 },
        .graphics_payload_bytes = .{ .ptr = null, .len = 0 },
    });
    try std.testing.expectEqual(@as(c_int, 0), publish.status);
    try std.testing.expectEqual(@as(u8, 1), publish.published);

    var request: FfiPrepareRequest = undefined;
    try std.testing.expectEqual(HowlRenderPrepareStatus.ready, surfaceTextTakePrepareRequest(handle, &request));
}

test "ffi reject publish slot returns render-owned failure result" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);

    const render_px = FfiPixelSize{ .width = 16, .height = 16 };
    const grid_px = FfiPixelSize{ .width = 16, .height = 16 };
    const layout = surfaceTextDeriveFrameLayout(handle, render_px, grid_px);
    try std.testing.expectEqual(@as(c_int, 0), layout.status);
    const sync = surfaceTextSyncGeometry(handle, .{ .render_px = render_px, .grid_px = grid_px });
    try std.testing.expectEqual(@as(c_int, 0), sync.status);

    var slot: FfiPublishSlot = undefined;
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.ok),
        surfaceTextReservePublishSlot(handle, 1, 1, &slot),
    );

    const publish = surfaceTextRejectPublishSlot(handle, 7);
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.failed), publish.status);
    try std.testing.expectEqual(@as(u8, 0), publish.published);
    try std.testing.expectEqual(@as(u8, 0), publish.queued);
    try std.testing.expectEqual(@as(u8, 0), publish.damage_kind);
    try std.testing.expectEqual(@as(u64, 7), publish.snapshot_seq);
    try std.testing.expectEqual(sync.geometry_epoch, publish.geometry_epoch);
}

test "ffi prepare handle rejects missing output pointer" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);

    const input = try nextPrepareInput(handle);
    try std.testing.expectEqual(
        HowlRenderPrepareStatus.failed,
        surfaceTextPrepareHandle(handle, input.request, null),
    );
}

test "ffi prepare handle rejects mismatched prepare token" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);

    const input = try nextPrepareInput(handle);
    var wrong = input.request;
    wrong.snapshot_seq +%= 1;
    var prepared_handle: PreparedSurfaceHandle = @ptrFromInt(1);
    try std.testing.expectEqual(
        HowlRenderPrepareStatus.failed,
        surfaceTextPrepareHandle(handle, wrong, &prepared_handle),
    );
    try std.testing.expect(prepared_handle == null);
}

test "ffi prepare handle clears output when source was never published" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);

    const render_px = FfiPixelSize{ .width = 16, .height = 16 };
    const grid_px = FfiPixelSize{ .width = 16, .height = 16 };
    const layout = surfaceTextDeriveFrameLayout(handle, render_px, grid_px);
    try std.testing.expectEqual(@as(c_int, 0), layout.status);
    const sync = surfaceTextSyncGeometry(handle, .{ .render_px = render_px, .grid_px = grid_px });
    try std.testing.expectEqual(@as(c_int, 0), sync.status);

    var request = FfiPrepareRequest{
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .geometry_epoch = sync.geometry_epoch,
        .damage_base_seq = 0,
        .damage_kind = @intFromEnum(pipeline.DamageKind.full),
    };
    var prepared_handle: PreparedSurfaceHandle = @ptrFromInt(1);
    try std.testing.expectEqual(
        HowlRenderPrepareStatus.failed,
        surfaceTextPrepareHandle(handle, request, &prepared_handle),
    );
    try std.testing.expect(prepared_handle == null);
}

test "ffi submit clears feedback on failure" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);

    var feedback = FfiSurfaceFeedback{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .damage_kind = @intFromEnum(pipeline.DamageKind.full),
        .surface = .{ .host_surface_id = 99, .width = 9, .height = 9 },
        .metrics = std.mem.zeroes(FfiSurfaceMetrics),
    };
    const execution = FfiSurfaceExecutionInput{
        .surface = .{ .host_surface_id = 1, .width = 1, .height = 1 },
        .uploads_committed = 0,
        .render_us = 0,
    };
    try std.testing.expectEqual(
        HowlRenderSubmitStatus.failed,
        surfaceTextSubmit(handle, null, std.mem.zeroes(FfiPreparedFrame), &execution, &feedback),
    );
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.failed), feedback.status);
    try std.testing.expectEqual(@as(u64, 0), feedback.surface.host_surface_id);
}

test "ffi prepared-handle submit decision returns opaque handle" {
    const handle = testHandle();
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);

    const input = try nextPrepareInput(handle);
    var prepared_handle: PreparedSurfaceHandle = null;
    try std.testing.expectEqual(
        HowlRenderPrepareStatus.ready,
        surfaceTextPrepareHandle(handle, input.request, &prepared_handle),
    );
    defer preparedSurfaceRelease(prepared_handle);
    try std.testing.expect(prepared_handle != null);

    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.ok),
        surfaceTextPublishPreparedHandle(handle, prepared_handle),
    );

    var submit_handle: PreparedSurfaceHandle = null;
    try std.testing.expectEqual(
        HowlRenderSubmitDecisionStatus.submit,
        surfaceTextTakeSubmitHandle(handle, &submit_handle),
    );
    try std.testing.expect(submit_handle == prepared_handle);
}

test "ffi prepared surface describe writes missing-handle status" {
    var info = FfiPreparedSurfaceInfo{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .geometry_epoch = 1,
        .required_base_seq = 1,
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .prepare_metrics = std.mem.zeroes(FfiSurfaceMetrics),
        .damage_kind = @intFromEnum(pipeline.DamageKind.full),
    };
    try std.testing.expectEqual(
        @intFromEnum(HowlRenderCallStatus.missing_handle),
        preparedSurfaceDescribe(null, &info),
    );
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.missing_handle), info.status);
    try std.testing.expectEqual(@as(u64, 0), info.snapshot_seq);
}
