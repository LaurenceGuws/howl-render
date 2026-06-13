const c = @import("howl_render_c");
const render_session = @import("render_session.zig");

pub fn textSessionOwner(handle: c.HowlRenderTextSessionHandle) ?*render_session.TextSessionOwner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}
