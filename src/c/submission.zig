const std = @import("std");
const c = @import("howl_render_c");
const handle_owner = @import("text_session_handle.zig");
const prepared_handle = @import("../surface/handle.zig");
const render_session = @import("../render_session.zig");
const tokens = @import("../tokens.zig");

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

pub fn acceptSubmitted(value: c.HowlRenderTextSessionHandle, prepared_in: c.HowlRenderPreparedSurfaceToken) callconv(.c) c_int {
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepared = preparedSurfaceTokenIn(prepared_in) orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.acceptSubmitted(.{ .token = prepared.token });
    return c.HOWL_RENDER_CALL_OK;
}

pub fn submit(text_session_handle: c.HowlRenderTextSessionHandle, rdr_sfc_handle: c.HowlRenderRdrSfcHandle, prepared_token_in: c.HowlRenderPreparedSurfaceToken, execution_in: ?*const c.HowlRenderSubmitExecution, result_out: ?*c.HowlRenderSubmitResult) callconv(.c) c_int {
    if (result_out) |out| out.* = failedSubmitResult(c.HOWL_RENDER_CALL_FAILED);
    const owner = handle_owner.textSessionOwner(text_session_handle) orelse {
        if (result_out) |out| out.* = failedSubmitResult(c.HOWL_RENDER_CALL_MISSING_HANDLE);
        return c.HOWL_RENDER_SUBMIT_FAILED;
    };
    const prepared = prepared_handle.PreparedHandle.fromHandle(rdr_sfc_handle) orelse {
        if (result_out) |out| out.* = failedSubmitResult(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
        return c.HOWL_RENDER_SUBMIT_FAILED;
    };
    const execution = execution_in orelse {
        if (result_out) |out| out.* = failedSubmitResult(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
        return c.HOWL_RENDER_SUBMIT_FAILED;
    };
    const prepared_token = preparedSurfaceTokenIn(prepared_token_in) orelse {
        if (result_out) |out| out.* = failedSubmitResult(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
        return c.HOWL_RENDER_SUBMIT_FAILED;
    };
    return switch (owner.submitPrepared(prepared, prepared_token, submitExecutionIn(execution.*))) {
        .rendered => |submitted| blk: {
            if (result_out) |out| out.* = submitResultOut(submitted);
            break :blk c.HOWL_RENDER_SUBMIT_RENDERED;
        },
        .needs_prepare => c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE,
        .failed => c.HOWL_RENDER_SUBMIT_FAILED,
    };
}

pub fn preparedSurfaceTokenOut(value: tokens.PreparedSurfaceToken) c.HowlRenderPreparedSurfaceToken {
    std.debug.assert(value.token.snapshot_seq != 0);
    std.debug.assert(value.token.dirty_epoch != 0);
    std.debug.assert(value.token.geometry_epoch != 0);
    std.debug.assert(value.token.damage_kind != .none);
    if (value.token.damage_kind == .partial) {
        std.debug.assert(value.token.damage_base_seq != 0);
        std.debug.assert(value.required_base_seq == value.token.damage_base_seq);
    } else {
        std.debug.assert(value.token.damage_base_seq == 0);
        std.debug.assert(value.required_base_seq == 0);
    }
    return .{
        .snapshot_seq = value.token.snapshot_seq,
        .dirty_epoch = value.token.dirty_epoch,
        .geometry_epoch = value.token.geometry_epoch,
        .damage_base_seq = value.token.damage_base_seq,
        .required_base_seq = value.required_base_seq,
        .damage_kind = @intFromEnum(value.token.damage_kind),
    };
}

pub fn preparedSurfaceTokenIn(value: c.HowlRenderPreparedSurfaceToken) ?tokens.PreparedSurfaceToken {
    const damage_kind = damageKindIn(value.damage_kind) orelse return null;
    if (value.snapshot_seq == 0) return null;
    if (value.dirty_epoch == 0) return null;
    if (value.geometry_epoch == 0) return null;
    if (damage_kind == .none) return null;
    switch (damage_kind) {
        .none => unreachable,
        .full => {
            if (value.damage_base_seq != 0) return null;
            if (value.required_base_seq != 0) return null;
        },
        .partial => {
            if (value.damage_base_seq == 0) return null;
            if (value.required_base_seq == 0) return null;
            if (value.required_base_seq != value.damage_base_seq) return null;
        },
    }
    return .{
        .token = .{
            .snapshot_seq = value.snapshot_seq,
            .dirty_epoch = value.dirty_epoch,
            .geometry_epoch = value.geometry_epoch,
            .damage_base_seq = value.damage_base_seq,
            .damage_kind = damage_kind,
        },
        .required_base_seq = value.required_base_seq,
    };
}

fn damageKindIn(value: u8) ?tokens.DamageKind {
    return switch (value) {
        @intFromEnum(tokens.DamageKind.none) => .none,
        @intFromEnum(tokens.DamageKind.partial) => .partial,
        @intFromEnum(tokens.DamageKind.full) => .full,
        else => null,
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
