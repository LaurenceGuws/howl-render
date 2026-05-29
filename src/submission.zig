const std = @import("std");
const c = @import("ffi.zig").c;
const frame = @import("frame.zig");
const handle_owner = @import("handle.zig");
const prepared_owner = @import("surface/prepared_owner.zig");
const surface_feedback = @import("surface_feedback.zig");

pub fn publishPrepared(
    value: c.HowlRenderSurfaceTextHandle,
    prepared_in: c.HowlRenderPreparedFrame,
) callconv(.c) c_int {
    const owner = handle_owner.surfaceTextOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepared = frame.preparedFrameIn(prepared_in) orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.publishPrepared(prepared);
    return c.HOWL_RENDER_CALL_OK;
}

pub fn publishPreparedHandle(
    value: c.HowlRenderSurfaceTextHandle,
    prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle,
) callconv(.c) c_int {
    const owner = handle_owner.surfaceTextOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepared = prepared_owner.Owner.fromHandle(prepared_surface_handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (!prepared.belongsToSession(owner)) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!prepared.markPublished()) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.prepared_submit_handle = null;
    owner.prepared_publish_handle = handle_owner.opaquePreparedHandle(prepared_surface_handle);
    owner.publishPrepared(prepared.pipelineFrame());
    return c.HOWL_RENDER_CALL_OK;
}

pub fn takeSubmitDecision(
    value: c.HowlRenderSurfaceTextHandle,
    out: ?*c.HowlRenderPreparedFrame,
) callconv(.c) c_int {
    const prepared_out = out orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    prepared_out.* = std.mem.zeroes(c.HowlRenderPreparedFrame);
    const owner = handle_owner.surfaceTextOwner(value) orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    return switch (owner.submit()) {
        .idle => c.HOWL_RENDER_SUBMIT_DECISION_IDLE,
        .stale => c.HOWL_RENDER_SUBMIT_DECISION_STALE,
        .submit => |prepared| blk: {
            prepared_out.* = frame.preparedFrameOut(prepared);
            break :blk c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT;
        },
        .needs_full_prepare => c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE,
    };
}

pub fn takeSubmitHandle(
    value: c.HowlRenderSurfaceTextHandle,
    out: ?*c.HowlRenderPreparedSurfaceHandle,
) callconv(.c) c_int {
    const prepared_out = out orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    prepared_out.* = null;
    const owner = handle_owner.surfaceTextOwner(value) orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    return switch (owner.submit()) {
        .idle => c.HOWL_RENDER_SUBMIT_DECISION_IDLE,
        .stale => blk: {
            owner.prepared_publish_handle = null;
            owner.prepared_submit_handle = null;
            break :blk c.HOWL_RENDER_SUBMIT_DECISION_STALE;
        },
        .needs_full_prepare => blk: {
            owner.prepared_publish_handle = null;
            owner.prepared_submit_handle = null;
            break :blk c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE;
        },
        .submit => |prepared| blk: {
            const prepared_handle = owner.prepared_publish_handle orelse break :blk c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
            const prepared_surface = prepared_owner.Owner.fromHandle(prepared_handle) orelse break :blk c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
            if (!prepared_surface.isLive()) {
                owner.prepared_publish_handle = null;
                owner.prepared_submit_handle = null;
                break :blk c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
            }
            if (!frame.samePreparedFrame(prepared_surface.pipelineFrame(), prepared)) break :blk c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
            if (!prepared_surface.markSubmitReady()) break :blk c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
            owner.prepared_publish_handle = null;
            owner.prepared_submit_handle = prepared_handle;
            prepared_out.* = handle_owner.abiPreparedHandle(prepared_handle);
            break :blk c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT;
        },
    };
}

pub fn acceptSubmitted(
    value: c.HowlRenderSurfaceTextHandle,
    prepared_in: c.HowlRenderPreparedFrame,
) callconv(.c) c_int {
    const owner = handle_owner.surfaceTextOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepared = frame.preparedFrameIn(prepared_in) orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.acceptSubmitted(.{ .token = prepared.token });
    return c.HOWL_RENDER_CALL_OK;
}

pub fn submit(
    surface_text_handle: c.HowlRenderSurfaceTextHandle,
    prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle,
    prepared_frame_in: c.HowlRenderPreparedFrame,
    execution_in: ?*const c.HowlRenderSurfaceExecutionInput,
    feedback_out: ?*c.HowlRenderSurfaceFeedback,
) callconv(.c) c_int {
    if (feedback_out) |out| out.* = surface_feedback.failedSurfaceFeedback();
    const owner = handle_owner.surfaceTextOwner(surface_text_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const prepared = prepared_owner.Owner.fromHandle(prepared_surface_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const execution = execution_in orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const prepared_frame = frame.preparedFrameIn(prepared_frame_in) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    return switch (prepared.submit(owner, prepared_frame, surface_feedback.executionInputIn(execution.*))) {
        .rendered => |submitted| blk: {
            if (feedback_out) |out| out.* = surface_feedback.surfaceFeedbackOut(submitted);
            break :blk c.HOWL_RENDER_SUBMIT_RENDERED;
        },
        .needs_prepare => c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE,
        .failed => c.HOWL_RENDER_SUBMIT_FAILED,
    };
}

pub fn submitHandle(
    surface_text_handle: c.HowlRenderSurfaceTextHandle,
    prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle,
    execution_in: ?*const c.HowlRenderSurfaceExecutionInput,
    feedback_out: ?*c.HowlRenderSurfaceFeedback,
) callconv(.c) c_int {
    if (feedback_out) |out| out.* = surface_feedback.failedSurfaceFeedback();
    const owner = handle_owner.surfaceTextOwner(surface_text_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const execution = execution_in orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    if (owner.prepared_submit_handle != handle_owner.opaquePreparedHandle(prepared_surface_handle)) return c.HOWL_RENDER_SUBMIT_FAILED;
    const prepared = prepared_owner.Owner.fromHandle(prepared_surface_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    if (!prepared.isLive()) {
        owner.prepared_submit_handle = null;
        return c.HOWL_RENDER_SUBMIT_FAILED;
    }
    const submitted = prepared.pipelineFrame().token;
    return switch (prepared.submitOwned(owner, surface_feedback.executionInputIn(execution.*))) {
        .rendered => |feedback| blk: {
            owner.prepared_submit_handle = null;
            owner.acceptSubmitted(.{ .token = submitted });
            if (feedback_out) |out| out.* = surface_feedback.surfaceFeedbackOut(feedback);
            break :blk c.HOWL_RENDER_SUBMIT_RENDERED;
        },
        .needs_prepare => c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE,
        .failed => c.HOWL_RENDER_SUBMIT_FAILED,
    };
}
