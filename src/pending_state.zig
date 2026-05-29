const c = @import("ffi.zig").c;
const handle_owner = @import("handle.zig");
const source_prepare = @import("source/prepare_request.zig");

pub fn pendingState(
    value: c.HowlRenderTextSessionHandle,
    out: ?*c.HowlRenderPendingState,
) callconv(.c) c_int {
    const pending_out = out;
    const owner = handle_owner.textSessionOwner(value) orelse {
        if (pending_out) |pending| pending.* = pendingStateFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
        return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    };
    const pending = pending_out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    pending.* = pendingStateOut(owner.pendingState());
    return c.HOWL_RENDER_CALL_OK;
}

pub fn pendingStateOut(value: source_prepare.PendingState) c.HowlRenderPendingState {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .source_pending = @intFromBool(value.source_pending),
        .prepare_pending = @intFromBool(value.prepare_pending),
        .submit_pending = @intFromBool(value.submit_pending),
    };
}

pub fn pendingStateFailure(status: c_int) c.HowlRenderPendingState {
    return .{
        .status = status,
        .source_pending = 0,
        .prepare_pending = 0,
        .submit_pending = 0,
    };
}
