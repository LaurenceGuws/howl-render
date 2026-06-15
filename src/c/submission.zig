const std = @import("std");
const c = @import("howl_render_c");
const handle_owner = @import("text_session_handle.zig");
const prepared_handle = @import("../surface/handle.zig");
const render_session = @import("../render_session.zig");

pub fn takeSubmitHandle(value: c.HowlRenderTextSessionHandle, out: ?*c.HowlRenderRdrSfcHandle) callconv(.c) c_int {
    const rdr_sfc_out = out orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    rdr_sfc_out.* = null;
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    return switch (owner.takeSubmitHandle()) {
        .idle => c.HOWL_RENDER_SUBMIT_DECISION_IDLE,
        .stale => c.HOWL_RENDER_SUBMIT_DECISION_STALE,
        .needs_full_prepare => c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE,
        .submit => |prepared| blk: {
            rdr_sfc_out.* = @ptrCast(prepared);
            break :blk c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT;
        },
        .failed => c.HOWL_RENDER_SUBMIT_DECISION_FAILED,
    };
}

pub fn submitHandle(text_session_handle: c.HowlRenderTextSessionHandle, rdr_sfc_handle: c.HowlRenderRdrSfcHandle, execution_in: ?*const c.HowlRenderSubmitExecution, result_out: ?*c.HowlRenderSubmitResult) callconv(.c) c_int {
    if (result_out) |out| out.* = failedSubmitResult(c.HOWL_RENDER_CALL_FAILED);
    const owner = handle_owner.textSessionOwner(text_session_handle) orelse {
        if (result_out) |out| out.* = failedSubmitResult(c.HOWL_RENDER_CALL_MISSING_HANDLE);
        return c.HOWL_RENDER_SUBMIT_FAILED;
    };
    const execution = execution_in orelse {
        if (result_out) |out| out.* = failedSubmitResult(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
        return c.HOWL_RENDER_SUBMIT_FAILED;
    };
    const prepared = prepared_handle.PreparedHandle.fromHandle(rdr_sfc_handle) orelse {
        if (result_out) |out| out.* = failedSubmitResult(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
        return c.HOWL_RENDER_SUBMIT_FAILED;
    };
    return switch (owner.submitPreparedHandle(prepared, submitExecutionIn(execution.*))) {
        .rendered => |result| blk: {
            if (result_out) |out| out.* = submitResultOut(result);
            break :blk c.HOWL_RENDER_SUBMIT_RENDERED;
        },
        .needs_prepare => c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE,
        .failed => c.HOWL_RENDER_SUBMIT_FAILED,
    };
}

fn submitResultOut(value: render_session.SubmitResult) c.HowlRenderSubmitResult {
    std.debug.assert(value.host_surface.width > 0);
    std.debug.assert(value.host_surface.height > 0);
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .damage_kind = @intFromEnum(value.damage_kind),
        .host_surface = .{
            .host_surface_id = value.host_surface.host_surface_id,
            .width = value.host_surface.width,
            .height = value.host_surface.height,
        },
    };
}

fn failedSubmitResult(status: c_int) c.HowlRenderSubmitResult {
    return .{
        .status = status,
        .damage_kind = 0,
        .host_surface = .{ .host_surface_id = 0, .width = 0, .height = 0 },
    };
}

fn submitExecutionIn(value: c.HowlRenderSubmitExecution) render_session.TextSession.SubmitExecution {
    return .{
        .host_surface = .{
            .host_surface_id = value.host_surface.host_surface_id,
            .width = value.host_surface.width,
            .height = value.host_surface.height,
        },
    };
}
