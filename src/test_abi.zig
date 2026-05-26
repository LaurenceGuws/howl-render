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
