const c = @import("../ffi.zig").c;
const prepared_handle = @import("../prepared/handle.zig");
const text_session = @import("../session/text.zig");

pub fn textSessionOwner(handle: c.HowlRenderTextSessionHandle) ?*text_session.TextSessionOwner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

pub fn opaquePreparedHandle(value: c.HowlRenderPreparedSurfaceHandle) prepared_handle.PreparedSurfaceHandle {
    return if (value) |handle| @ptrCast(handle) else null;
}

pub fn abiPreparedHandle(value: prepared_handle.PreparedSurfaceHandle) c.HowlRenderPreparedSurfaceHandle {
    return if (value) |handle| @ptrCast(handle) else null;
}
