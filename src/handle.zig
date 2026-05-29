const c = @import("ffi.zig").c;
const prepared_owner = @import("surface/prepared_owner.zig");
const surface_text = @import("surface/text.zig");

pub fn surfaceTextOwner(handle: c.HowlRenderSurfaceTextHandle) ?*surface_text.SurfaceTextOwner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

pub fn opaquePreparedHandle(
    value: c.HowlRenderPreparedSurfaceHandle,
) prepared_owner.PreparedSurfaceHandle {
    return if (value) |handle| @ptrCast(handle) else null;
}

pub fn abiPreparedHandle(
    value: prepared_owner.PreparedSurfaceHandle,
) c.HowlRenderPreparedSurfaceHandle {
    return if (value) |handle| @ptrCast(handle) else null;
}
