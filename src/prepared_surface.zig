const std = @import("std");
const c = @import("ffi.zig").c;
const frame = @import("frame.zig");
const handle_owner = @import("handle.zig");
const prepared_owner = @import("surface/prepared_owner.zig");
const surface_feedback = @import("surface_feedback.zig");

pub fn prepareHandle(
    surface_text_handle: c.HowlRenderSurfaceTextHandle,
    prepare_request: c.HowlRenderPrepareRequest,
    prepared_handle_out: ?*c.HowlRenderPreparedSurfaceHandle,
) callconv(.c) c_int {
    const prepared_out = prepared_handle_out;
    if (prepared_out) |value| value.* = null;
    const owner = handle_owner.surfaceTextOwner(surface_text_handle) orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const value = prepared_out orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const token = frame.prepareTokenIn(prepare_request) orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const prepared = owner.prepareHandle(token) catch return c.HOWL_RENDER_PREPARE_FAILED;
    value.* = @ptrCast(prepared);
    return c.HOWL_RENDER_PREPARE_READY;
}

pub fn release(prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle) callconv(.c) void {
    const owner = prepared_owner.Owner.fromHandle(prepared_surface_handle) orelse return;
    owner.release();
}

pub fn describe(
    prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle,
    info_out: ?*c.HowlRenderPreparedSurfaceInfo,
) callconv(.c) c_int {
    const out = info_out;
    const owner = prepared_owner.Owner.fromHandle(prepared_surface_handle) orelse {
        if (out) |value| value.* = infoFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
        return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    };
    const value = out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!owner.isLive()) {
        value.* = infoFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
        return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    }
    value.* = preparedInfoOut(owner.info());
    return c.HOWL_RENDER_CALL_OK;
}

pub fn buffer(
    prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle,
    buffer_out: ?*c.HowlRenderPreparedSurfaceBuffer,
) callconv(.c) c_int {
    const out = buffer_out;
    const owner = prepared_owner.Owner.fromHandle(prepared_surface_handle) orelse {
        if (out) |value| value.* = bufferFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
        return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    };
    const value = out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!owner.isLive()) {
        value.* = bufferFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
        return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    }
    value.* = preparedBufferOut(owner.buffer());
    return c.HOWL_RENDER_CALL_OK;
}

pub fn diagnostics(
    prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle,
    diagnostics_out: ?*c.HowlRenderPreparedSurfaceDiagnostics,
) callconv(.c) c_int {
    const out = diagnostics_out;
    const owner = prepared_owner.Owner.fromHandle(prepared_surface_handle) orelse {
        if (out) |value| value.* = diagnosticsFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
        return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    };
    const value = out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!owner.isLive()) {
        value.* = diagnosticsFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
        return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    }
    value.* = preparedDiagnosticsOut(owner.diagnostics());
    return c.HOWL_RENDER_CALL_OK;
}

pub fn preparedInfoOut(value: prepared_owner.PreparedInfo) c.HowlRenderPreparedSurfaceInfo {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .snapshot_seq = value.snapshot_seq,
        .dirty_epoch = value.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .required_base_seq = value.required_base_seq,
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .grid = .{ .cols = value.grid.cols, .rows = value.grid.rows },
        .prepare_metrics = surface_feedback.surfaceMetricsOut(value.prepare_metrics),
        .damage_kind = value.damage_kind,
    };
}

pub fn infoFailure(status: c_int) c.HowlRenderPreparedSurfaceInfo {
    return .{
        .status = status,
        .snapshot_seq = 0,
        .dirty_epoch = 0,
        .geometry_epoch = 0,
        .required_base_seq = 0,
        .render_px = .{ .width = 0, .height = 0 },
        .cell_px = .{ .width = 0, .height = 0 },
        .grid = .{ .cols = 0, .rows = 0 },
        .prepare_metrics = std.mem.zeroes(c.HowlRenderSurfaceMetrics),
        .damage_kind = 0,
    };
}

pub fn preparedBufferOut(value: prepared_owner.PreparedBuffer) c.HowlRenderPreparedSurfaceBuffer {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .rgba_pixels = byteSpan(value.rgba_pixels),
        .uploads_committed = value.uploads_required,
    };
}

pub fn bufferFailure(status: c_int) c.HowlRenderPreparedSurfaceBuffer {
    return .{
        .status = status,
        .rgba_pixels = .{ .ptr = null, .len = 0 },
        .uploads_committed = 0,
    };
}

pub fn preparedDiagnosticsOut(
    value: prepared_owner.PreparedDiagnostics,
) c.HowlRenderPreparedSurfaceDiagnostics {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .missing_glyphs = value.missing_glyphs,
        .resolve_metrics = surface_feedback.surfaceMetricsOut(value.resolve_metrics),
    };
}

pub fn diagnosticsFailure(status: c_int) c.HowlRenderPreparedSurfaceDiagnostics {
    return .{
        .status = status,
        .missing_glyphs = 0,
        .resolve_metrics = std.mem.zeroes(c.HowlRenderSurfaceMetrics),
    };
}

fn byteSpan(items: []u8) c.HowlRenderByteSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}
