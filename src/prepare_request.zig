const std = @import("std");
const c = @import("ffi.zig").c;
const frame = @import("frame.zig");
const handle_owner = @import("handle.zig");

pub fn takePrepareRequest(
    value: c.HowlRenderSurfaceTextHandle,
    out: ?*c.HowlRenderPrepareRequest,
) callconv(.c) c_int {
    const prepare_out = out orelse return c.HOWL_RENDER_PREPARE_FAILED;
    prepare_out.* = std.mem.zeroes(c.HowlRenderPrepareRequest);
    const owner = handle_owner.surfaceTextOwner(value) orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const request = owner.prepare() orelse return c.HOWL_RENDER_PREPARE_IDLE;
    prepare_out.* = frame.prepareRequestOut(request);
    return c.HOWL_RENDER_PREPARE_READY;
}
