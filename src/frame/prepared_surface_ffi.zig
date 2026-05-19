const abi = @import("../ffi_types.zig");
const prepared_surface_owner = @import("prepared_surface_owner.zig");

pub fn release(prepared_surface_handle: abi.PreparedSurfaceHandle) callconv(.c) void {
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return;
    owner.destroy();
}

pub fn describe(prepared_surface_handle: abi.PreparedSurfaceHandle, info_out: ?*abi.FfiPreparedSurfaceInfo) callconv(.c) c_int {
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const out = info_out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    out.* = owner.info();
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn buffer(prepared_surface_handle: abi.PreparedSurfaceHandle, buffer_out: ?*abi.FfiPreparedSurfaceBuffer) callconv(.c) c_int {
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const out = buffer_out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    out.* = owner.buffer();
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn diagnostics(prepared_surface_handle: abi.PreparedSurfaceHandle, diagnostics_out: ?*abi.FfiPreparedSurfaceDiagnostics) callconv(.c) c_int {
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const out = diagnostics_out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    out.* = owner.diagnostics();
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}
