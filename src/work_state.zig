const std = @import("std");
const c = @import("howl_render_c");
const handle_owner = @import("handle.zig");
const render_session = @import("render_session.zig");

pub fn workState(value: c.HowlRenderTextSessionHandle, out: ?*c.HowlRenderSessionWorkState) callconv(.c) c_int {
    const session_work_state_out = out;
    const owner = handle_owner.textSessionOwner(value) orelse {
        if (session_work_state_out) |state| state.* = sessionWorkStateFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
        return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    };
    const state = session_work_state_out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    state.* = sessionWorkStateOut(owner.workState());
    return c.HOWL_RENDER_CALL_OK;
}

pub fn sessionWorkStateOut(value: render_session.SessionWorkState) c.HowlRenderSessionWorkState {
    std.debug.assert(@intFromBool(value.source_pending) <= 1);
    std.debug.assert(@intFromBool(value.prepare_pending) <= 1);
    std.debug.assert(@intFromBool(value.submit_pending) <= 1);
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .source_pending = @intFromBool(value.source_pending),
        .prepare_pending = @intFromBool(value.prepare_pending),
        .submit_pending = @intFromBool(value.submit_pending),
    };
}

pub fn sessionWorkStateFailure(status: c_int) c.HowlRenderSessionWorkState {
    return .{
        .status = status,
        .source_pending = 0,
        .prepare_pending = 0,
        .submit_pending = 0,
    };
}
