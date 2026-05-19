const std = @import("std");
const abi = @import("../ffi_types.zig");
const prepared_surface_owner = @import("prepared_surface_owner.zig");

pub fn release(prepared_surface_handle: abi.PreparedSurfaceHandle) callconv(.c) void {
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return;
    owner.destroy();
}

pub fn describe(prepared_surface_handle: abi.PreparedSurfaceHandle, info_out: ?*abi.FfiPreparedSurfaceInfo) callconv(.c) c_int {
    const out = info_out;
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse {
        if (out) |value| value.* = infoFailure(@intFromEnum(abi.HowlRenderCallStatus.missing_handle));
        return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    };
    const value = out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    value.* = owner.info();
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn buffer(prepared_surface_handle: abi.PreparedSurfaceHandle, buffer_out: ?*abi.FfiPreparedSurfaceBuffer) callconv(.c) c_int {
    const out = buffer_out;
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse {
        if (out) |value| value.* = bufferFailure(@intFromEnum(abi.HowlRenderCallStatus.missing_handle));
        return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    };
    const value = out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    value.* = owner.buffer();
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn diagnostics(prepared_surface_handle: abi.PreparedSurfaceHandle, diagnostics_out: ?*abi.FfiPreparedSurfaceDiagnostics) callconv(.c) c_int {
    const out = diagnostics_out;
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse {
        if (out) |value| value.* = diagnosticsFailure(@intFromEnum(abi.HowlRenderCallStatus.missing_handle));
        return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    };
    const value = out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    value.* = owner.diagnostics();
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

fn infoFailure(status: c_int) abi.FfiPreparedSurfaceInfo {
    return .{
        .status = status,
        .snapshot_seq = 0,
        .dirty_epoch = 0,
        .geometry_epoch = 0,
        .required_base_seq = 0,
        .required_surface_epoch = 0,
        .render_px = .{ .width = 0, .height = 0 },
        .cell_px = .{ .width = 0, .height = 0 },
        .grid = .{ .cols = 0, .rows = 0 },
        .prepare_metrics = std.mem.zeroes(abi.FfiSurfaceMetrics),
        .damage_kind = 0,
    };
}

fn bufferFailure(status: c_int) abi.FfiPreparedSurfaceBuffer {
    return .{
        .status = status,
        .rgba_pixels = .{ .ptr = null, .len = 0 },
        .uploads_committed = 0,
    };
}

fn diagnosticsFailure(status: c_int) abi.FfiPreparedSurfaceDiagnostics {
    return .{
        .status = status,
        .missing_glyphs = 0,
        .resolve_metrics = std.mem.zeroes(abi.FfiSurfaceMetrics),
    };
}
