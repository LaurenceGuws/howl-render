const std = @import("std");
const c = @import("howl_render_c");
const handle_owner = @import("handle.zig");
const prepared_handle = @import("surface/handle.zig");
const prepared_surface = @import("surface/prepared_surface.zig");
const render_surface_emitter = @import("surface/emitter.zig");
const prepare_request_boundary = @import("prepare_request.zig");

pub fn prepareHandle(
    text_session_handle: c.HowlRenderTextSessionHandle,
    prepare_request: c.HowlRenderPrepareRequest,
    rdr_sfc_handle_out: ?*c.HowlRenderRdrSfcHandle,
) callconv(.c) c_int {
    const rdr_sfc_out = rdr_sfc_handle_out;
    if (rdr_sfc_out) |value| value.* = null;
    const owner = handle_owner.textSessionOwner(text_session_handle) orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const value = rdr_sfc_out orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const token = prepare_request_boundary.prepareTokenIn(prepare_request) orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const prepared = owner.prepareHandle(token) catch return c.HOWL_RENDER_PREPARE_FAILED;
    value.* = @ptrCast(prepared);
    return c.HOWL_RENDER_PREPARE_READY;
}

pub fn release(rdr_sfc_handle: c.HowlRenderRdrSfcHandle) callconv(.c) void {
    const prepared = prepared_handle.PreparedHandle.fromHandle(rdr_sfc_handle) orelse return;
    prepared.release();
}

pub fn describe(rdr_sfc_handle: c.HowlRenderRdrSfcHandle, info_out: ?*c.HowlRenderPreparedSurfaceInfo) callconv(.c) c_int {
    const out = info_out;
    const prepared = prepared_handle.PreparedHandle.fromHandle(rdr_sfc_handle) orelse {
        if (out) |value| value.* = infoFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
        return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    };
    const value = out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!prepared.isLive()) {
        value.* = infoFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
        return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    }
    value.* = preparedInfoOut(prepared.info());
    return c.HOWL_RENDER_CALL_OK;
}

pub fn renderSurface(rdr_sfc_handle: c.HowlRenderRdrSfcHandle, surface_out: ?*?*const c.HowlRenderSurface) callconv(.c) c.HowlRenderPreparedSurfaceRenderSurfaceStatus {
    const out = surface_out;
    if (out) |value| value.* = null;
    const prepared = prepared_handle.PreparedHandle.fromHandle(rdr_sfc_handle) orelse {
        return c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_MISSING_HANDLE;
    };
    const value = out orelse return c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_INVALID_ARGUMENT;
    if (!prepared.isLive()) return c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_INVALID_ARGUMENT;
    value.* = prepared.renderSurface() orelse return renderSurfaceStatusFromFailure(prepared.renderSurfaceEmissionFailure());
    return c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_OK;
}

fn renderSurfaceStatusFromFailure(failure: render_surface_emitter.RenderSurfaceEmissionFailure) c.HowlRenderPreparedSurfaceRenderSurfaceStatus {
    return switch (failure) {
        .none => c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_OK,
        .allocation_failed => c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_ALLOCATION_FAILED,
        .command_bound_overflow => c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_COMMAND_BOUND_OVERFLOW,
        .create_bound_overflow => c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_CREATE_BOUND_OVERFLOW,
        .damage_bound_overflow => c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_DAMAGE_BOUND_OVERFLOW,
        .retire_bound_overflow => c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_RETIRE_BOUND_OVERFLOW,
        .resource_bound_overflow => c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_RESOURCE_BOUND_OVERFLOW,
        .upload_bound_overflow => c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_UPLOAD_BOUND_OVERFLOW,
        .upload_bytes_overflow => c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_UPLOAD_BYTES_OVERFLOW,
        .invalid_prepared_sprite => c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_INVALID_PREPARED_SPRITE,
        .missing_prepared_sprite => c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_MISSING_PREPARED_SPRITE,
    };
}

pub fn preparedInfoOut(value: prepared_surface.PreparedInfo) c.HowlRenderPreparedSurfaceInfo {
    std.debug.assert(value.snapshot_seq != 0);
    std.debug.assert(value.dirty_epoch != 0);
    std.debug.assert(value.geometry_epoch != 0);
    std.debug.assert(value.render_px.width > 0);
    std.debug.assert(value.render_px.height > 0);
    std.debug.assert(value.cell_px.width > 0);
    std.debug.assert(value.cell_px.height > 0);
    std.debug.assert(value.grid.cols > 0);
    std.debug.assert(value.grid.rows > 0);
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .snapshot_seq = value.snapshot_seq,
        .dirty_epoch = value.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .required_base_seq = value.required_base_seq,
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .grid = .{ .cols = value.grid.cols, .rows = value.grid.rows },
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
        .damage_kind = 0,
    };
}
