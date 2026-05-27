const std = @import("std");
const abi = @import("ffi_types.zig");
const prepared_surface_ffi = @import("frame/prepared_surface_ffi.zig");
const surface_text_ffi = @import("frame/surface_text_ffi.zig");

const c = @cImport({
    @cInclude("howl_render.h");
});

comptime {
    std.debug.assert(@sizeOf(abi.FfiFrameLayoutResult) == @sizeOf(c.HowlRenderFrameLayoutResult));
    std.debug.assert(@sizeOf(abi.FfiGeometryResponse) == @sizeOf(c.HowlRenderGeometryResponse));
    std.debug.assert(@sizeOf(abi.FfiPendingState) == @sizeOf(c.HowlRenderPendingState));
    std.debug.assert(@sizeOf(abi.FfiPrepareRequest) == @sizeOf(c.HowlRenderPrepareRequest));
    std.debug.assert(@sizeOf(abi.FfiPreparedFrame) == @sizeOf(c.HowlRenderPreparedFrame));
    std.debug.assert(@sizeOf(abi.FfiPresentedRetire) == @sizeOf(c.HowlRenderPresentedRetire));
    std.debug.assert(@sizeOf(abi.FfiPreparedSurfaceInfo) == @sizeOf(c.HowlRenderPreparedSurfaceInfo));
    std.debug.assert(@sizeOf(abi.FfiPreparedSurfaceBuffer) == @sizeOf(c.HowlRenderPreparedSurfaceBuffer));
    std.debug.assert(@sizeOf(abi.FfiPreparedSurfaceDiagnostics) == @sizeOf(c.HowlRenderPreparedSurfaceDiagnostics));

    std.debug.assert(@intFromEnum(abi.HowlRenderCallStatus.ok) == c.HOWL_RENDER_CALL_OK);
    std.debug.assert(@intFromEnum(abi.HowlRenderCallStatus.missing_handle) == c.HOWL_RENDER_CALL_MISSING_HANDLE);
    std.debug.assert(@intFromEnum(abi.HowlRenderCallStatus.invalid_argument) == c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
    std.debug.assert(@intFromEnum(abi.HowlRenderCallStatus.failed) == c.HOWL_RENDER_CALL_FAILED);

    std.debug.assert(@intFromEnum(abi.HowlRenderPrepareStatus.idle) == c.HOWL_RENDER_PREPARE_IDLE);
    std.debug.assert(@intFromEnum(abi.HowlRenderPrepareStatus.ready) == c.HOWL_RENDER_PREPARE_READY);
    std.debug.assert(@intFromEnum(abi.HowlRenderPrepareStatus.failed) == c.HOWL_RENDER_PREPARE_FAILED);

    std.debug.assert(@intFromEnum(abi.HowlRenderSubmitDecisionStatus.idle) == c.HOWL_RENDER_SUBMIT_DECISION_IDLE);
    std.debug.assert(@intFromEnum(abi.HowlRenderSubmitDecisionStatus.submit) == c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT);
    std.debug.assert(@intFromEnum(abi.HowlRenderSubmitDecisionStatus.stale) == c.HOWL_RENDER_SUBMIT_DECISION_STALE);
    std.debug.assert(@intFromEnum(abi.HowlRenderSubmitDecisionStatus.needs_prepare) == c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE);
    std.debug.assert(@intFromEnum(abi.HowlRenderSubmitDecisionStatus.failed) == c.HOWL_RENDER_SUBMIT_DECISION_FAILED);

    std.debug.assert(c.HOWL_RENDER_MAX_FALLBACK_FONTS == 24);
}

test "render abi missing handles report shipped contract" {
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, surface_text_ffi.setFontSize(null, 12));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, surface_text_ffi.isValidFont(null));

    var pending = std.mem.zeroes(abi.FfiPendingState);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, surface_text_ffi.pendingState(null, &pending));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, pending.status);

    var retire = std.mem.zeroes(abi.FfiPresentedRetire);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, surface_text_ffi.retirePresented(null, &retire));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, retire.status);

    prepared_surface_ffi.release(null);

    var info = std.mem.zeroes(abi.FfiPreparedSurfaceInfo);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, prepared_surface_ffi.describe(null, &info));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, info.status);

    var buffer = std.mem.zeroes(abi.FfiPreparedSurfaceBuffer);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, prepared_surface_ffi.buffer(null, &buffer));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, buffer.status);
    try std.testing.expectEqual(@as(usize, 0), buffer.rgba_pixels.len);
    try std.testing.expect(buffer.rgba_pixels.ptr == null);
    try std.testing.expectEqual(@as(u64, 0), buffer.uploads_committed);

    var diagnostics = std.mem.zeroes(abi.FfiPreparedSurfaceDiagnostics);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, prepared_surface_ffi.diagnostics(null, &diagnostics));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, diagnostics.status);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.missing_glyphs);
}

test "render abi invalid arguments report shipped contract" {
    const handle = surface_text_ffi.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer surface_text_ffi.deinit(handle);
    try std.testing.expect(handle != null);

    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, surface_text_ffi.setFontSize(handle, 0));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, surface_text_ffi.setFontPath(handle, null, 1));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, surface_text_ffi.reservePublishSlot(handle, 0, 1, null));
}

test "render abi lifecycle exports geometry and layout contract" {
    const handle = surface_text_ffi.init(.{ .surface_px = .{ .width = 32, .height = 32 }, .font_size_px = 8 });
    defer surface_text_ffi.deinit(handle);
    try std.testing.expect(handle != null);

    const layout = surface_text_ffi.deriveFrameLayout(handle, .{ .width = 32, .height = 32 }, .{ .width = 32, .height = 32 });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, layout.status);
    try std.testing.expect(layout.cell_px.width > 0);
    try std.testing.expect(layout.cell_px.height > 0);

    const geometry = surface_text_ffi.syncGeometry(handle, .{ .render_px = .{ .width = 32, .height = 32 }, .grid_px = .{ .width = 32, .height = 32 } });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, geometry.status);
    try std.testing.expect(geometry.geometry_epoch != 0);
}

test "render abi prepare and submit seams report initial idle contract" {
    const handle = surface_text_ffi.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer surface_text_ffi.deinit(handle);
    try std.testing.expect(handle != null);

    var request = std.mem.zeroes(abi.FfiPrepareRequest);
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_IDLE, @intFromEnum(surface_text_ffi.takePrepareRequest(handle, &request)));

    var prepared = std.mem.zeroes(abi.FfiPreparedFrame);
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_DECISION_IDLE, @intFromEnum(surface_text_ffi.takeSubmitDecision(handle, &prepared)));
}

test "render abi valid prepared frames are accepted by publish prepared" {
    const handle = surface_text_ffi.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer surface_text_ffi.deinit(handle);
    try std.testing.expect(handle != null);

    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, surface_text_ffi.publishPrepared(handle, validFullPreparedFrame()));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, surface_text_ffi.publishPrepared(handle, validPartialPreparedFrame()));
}

test "render abi invalid prepared frames are rejected at prepared seams" {
    const handle = surface_text_ffi.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer surface_text_ffi.deinit(handle);
    try std.testing.expect(handle != null);

    const prepared_handle = try createPreparedHandle(handle);
    defer prepared_surface_ffi.release(prepared_handle);

    var zero_snapshot = validFullPreparedFrame();
    zero_snapshot.snapshot_seq = 0;
    try expectInvalidPreparedFrameRejected(handle, prepared_handle, zero_snapshot);

    var zero_dirty = validFullPreparedFrame();
    zero_dirty.dirty_epoch = 0;
    try expectInvalidPreparedFrameRejected(handle, prepared_handle, zero_dirty);

    var zero_geometry = validFullPreparedFrame();
    zero_geometry.geometry_epoch = 0;
    try expectInvalidPreparedFrameRejected(handle, prepared_handle, zero_geometry);

    var none_kind = validFullPreparedFrame();
    none_kind.damage_kind = damageNone();
    try expectInvalidPreparedFrameRejected(handle, prepared_handle, none_kind);

    var unknown_kind = validFullPreparedFrame();
    unknown_kind.damage_kind = 2;
    try expectInvalidPreparedFrameRejected(handle, prepared_handle, unknown_kind);

    var full_nonzero_damage_base = validFullPreparedFrame();
    full_nonzero_damage_base.damage_base_seq = 1;
    try expectInvalidPreparedFrameRejected(handle, prepared_handle, full_nonzero_damage_base);

    var full_nonzero_required_base = validFullPreparedFrame();
    full_nonzero_required_base.required_base_seq = 1;
    try expectInvalidPreparedFrameRejected(handle, prepared_handle, full_nonzero_required_base);

    var partial_zero_damage_base = validPartialPreparedFrame();
    partial_zero_damage_base.damage_base_seq = 0;
    try expectInvalidPreparedFrameRejected(handle, prepared_handle, partial_zero_damage_base);

    var partial_zero_required_base = validPartialPreparedFrame();
    partial_zero_required_base.required_base_seq = 0;
    try expectInvalidPreparedFrameRejected(handle, prepared_handle, partial_zero_required_base);

    var partial_mismatched_required_base = validPartialPreparedFrame();
    partial_mismatched_required_base.required_base_seq = partial_mismatched_required_base.damage_base_seq + 1;
    try expectInvalidPreparedFrameRejected(handle, prepared_handle, partial_mismatched_required_base);
}

test "render abi invalid prepare requests fail and leave output handle null" {
    const handle = surface_text_ffi.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer surface_text_ffi.deinit(handle);
    try std.testing.expect(handle != null);

    var zero_snapshot = validFullPrepareRequest();
    zero_snapshot.snapshot_seq = 0;
    try expectPrepareHandleFailedWithNullOutput(handle, zero_snapshot);

    var zero_dirty = validFullPrepareRequest();
    zero_dirty.dirty_epoch = 0;
    try expectPrepareHandleFailedWithNullOutput(handle, zero_dirty);

    var zero_geometry = validFullPrepareRequest();
    zero_geometry.geometry_epoch = 0;
    try expectPrepareHandleFailedWithNullOutput(handle, zero_geometry);

    var none_kind = validFullPrepareRequest();
    none_kind.damage_kind = damageNone();
    try expectPrepareHandleFailedWithNullOutput(handle, none_kind);

    var unknown_kind = validFullPrepareRequest();
    unknown_kind.damage_kind = 2;
    try expectPrepareHandleFailedWithNullOutput(handle, unknown_kind);

    var full_nonzero_damage_base = validFullPrepareRequest();
    full_nonzero_damage_base.damage_base_seq = 1;
    try expectPrepareHandleFailedWithNullOutput(handle, full_nonzero_damage_base);

    var partial_zero_damage_base = validPartialPrepareRequest();
    partial_zero_damage_base.damage_base_seq = 0;
    try expectPrepareHandleFailedWithNullOutput(handle, partial_zero_damage_base);
}

fn validFullPrepareRequest() abi.FfiPrepareRequest {
    return .{
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .geometry_epoch = 1,
        .damage_base_seq = 0,
        .damage_kind = damageFull(),
    };
}

fn validPartialPrepareRequest() abi.FfiPrepareRequest {
    return .{
        .snapshot_seq = 2,
        .dirty_epoch = 2,
        .geometry_epoch = 1,
        .damage_base_seq = 1,
        .damage_kind = damagePartial(),
    };
}

fn validFullPreparedFrame() abi.FfiPreparedFrame {
    return .{
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .geometry_epoch = 1,
        .damage_base_seq = 0,
        .required_base_seq = 0,
        .damage_kind = damageFull(),
    };
}

fn validPartialPreparedFrame() abi.FfiPreparedFrame {
    return .{
        .snapshot_seq = 2,
        .dirty_epoch = 2,
        .geometry_epoch = 1,
        .damage_base_seq = 1,
        .required_base_seq = 1,
        .damage_kind = damagePartial(),
    };
}

fn createPreparedHandle(handle: abi.SurfaceTextHandle) !abi.PreparedSurfaceHandle {
    const request = try nextPrepareRequest(handle);
    var prepared_handle: abi.PreparedSurfaceHandle = null;
    try std.testing.expectEqual(abi.HowlRenderPrepareStatus.ready, surface_text_ffi.prepareHandle(handle, request, &prepared_handle));
    try std.testing.expect(prepared_handle != null);
    return prepared_handle;
}

fn nextPrepareRequest(handle: abi.SurfaceTextHandle) !abi.FfiPrepareRequest {
    const render_px = abi.FfiPixelSize{ .width = 16, .height = 16 };
    const grid_px = abi.FfiPixelSize{ .width = 16, .height = 16 };
    const layout = surface_text_ffi.deriveFrameLayout(handle, render_px, grid_px);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, layout.status);

    const sync = surface_text_ffi.syncGeometry(handle, .{
        .render_px = render_px,
        .grid_px = grid_px,
    });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, sync.status);

    const cells = [_]abi.FfiVtCell{testCell()};
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{0};
    const dirty_cols_end = [_]u16{0};
    const publish = surface_text_ffi.publishVtSource(handle, .{
        .cells = .{ .ptr = cells[0..].ptr, .len = cells.len },
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = 0,
        .dirty_rows = .{ .ptr = dirty_rows[0..].ptr, .len = dirty_rows.len },
        .dirty_cols_start = .{ .ptr = dirty_cols_start[0..].ptr, .len = dirty_cols_start.len },
        .dirty_cols_end = .{ .ptr = dirty_cols_end[0..].ptr, .len = dirty_cols_end.len },
        .cursor = .{ .row = 0, .col = 0, .visible = 1, .shape = 0, .blink = 0 },
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = std.mem.zeroes(abi.FfiVtGraphicsMeta),
        .graphics_images = .{ .ptr = null, .len = 0 },
        .graphics_placements = .{ .ptr = null, .len = 0 },
        .graphics_virtual_placements = .{ .ptr = null, .len = 0 },
        .graphics_placeholder_runs = .{ .ptr = null, .len = 0 },
        .graphics_payload_bytes = .{ .ptr = null, .len = 0 },
    });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, publish.status);

    var request = std.mem.zeroes(abi.FfiPrepareRequest);
    try std.testing.expectEqual(abi.HowlRenderPrepareStatus.ready, surface_text_ffi.takePrepareRequest(handle, &request));
    return request;
}

fn testCell() abi.FfiVtCell {
    return .{
        .codepoint = 'a',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = std.mem.zeroes(abi.FfiVtCellAttrs),
        .link_id = 0,
    };
}

fn damageNone() u8 {
    return @intCast(c.HOWL_RENDER_DAMAGE_NONE);
}

fn damagePartial() u8 {
    return @intCast(c.HOWL_RENDER_DAMAGE_PARTIAL);
}

fn damageFull() u8 {
    return @intCast(c.HOWL_RENDER_DAMAGE_FULL);
}

fn expectInvalidPreparedFrameRejected(handle: abi.SurfaceTextHandle, prepared_handle: abi.PreparedSurfaceHandle, prepared: abi.FfiPreparedFrame) !void {
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, surface_text_ffi.publishPrepared(handle, prepared));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, surface_text_ffi.acceptSubmitted(handle, prepared));

    const execution = abi.FfiSurfaceExecutionInput{
        .surface = .{ .host_surface_id = 1, .width = 1, .height = 1 },
        .uploads_committed = 0,
        .render_us = 0,
    };
    try std.testing.expectEqual(abi.HowlRenderSubmitStatus.failed, surface_text_ffi.submit(handle, prepared_handle, prepared, &execution, null));
}

fn expectPrepareHandleFailedWithNullOutput(handle: abi.SurfaceTextHandle, request: abi.FfiPrepareRequest) !void {
    var prepared_handle: abi.PreparedSurfaceHandle = null;
    try std.testing.expectEqual(abi.HowlRenderPrepareStatus.failed, surface_text_ffi.prepareHandle(handle, request, &prepared_handle));
    try std.testing.expect(prepared_handle == null);
}
