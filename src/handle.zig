const c = @import("howl_render_c");
const prepared_handle = @import("surface/handle.zig");
const render_session = @import("render_session.zig");

pub fn textSessionOwner(handle: c.HowlRenderTextSessionHandle) ?*render_session.TextSessionOwner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

pub fn opaqueRdrSfcHandle(value: c.HowlRenderRdrSfcHandle) prepared_handle.PreparedSurfaceHandle {
    return if (value) |handle| @ptrCast(handle) else null;
}

pub fn abiRdrSfcHandle(value: prepared_handle.PreparedSurfaceHandle) c.HowlRenderRdrSfcHandle {
    return if (value) |handle| @ptrCast(handle) else null;
}
