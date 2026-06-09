const std = @import("std");
const c = @import("../ffi.zig").c;
const handle_owner = @import("handle.zig");
const prepared_handle = @import("../prepared/handle.zig");
const submit_result = @import("submit_result.zig");
const tokens = @import("../render/tokens.zig");

pub fn publishPrepared(value: c.HowlRenderTextSessionHandle, prepared_in: c.HowlRenderPreparedSurfaceToken) callconv(.c) c_int {
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepared = preparedSurfaceTokenIn(prepared_in) orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.publishPrepared(prepared);
    return c.HOWL_RENDER_CALL_OK;
}

pub fn publishPreparedHandle(value: c.HowlRenderTextSessionHandle, prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle) callconv(.c) c_int {
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepared = prepared_handle.PreparedHandle.fromHandle(prepared_surface_handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (!owner.publishPreparedHandle(prepared)) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    return c.HOWL_RENDER_CALL_OK;
}

pub fn takeSubmitDecision(value: c.HowlRenderTextSessionHandle, out: ?*c.HowlRenderPreparedSurfaceToken) callconv(.c) c_int {
    const prepared_out = out orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    prepared_out.* = std.mem.zeroes(c.HowlRenderPreparedSurfaceToken);
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    return switch (owner.submit()) {
        .idle => c.HOWL_RENDER_SUBMIT_DECISION_IDLE,
        .stale => c.HOWL_RENDER_SUBMIT_DECISION_STALE,
        .submit => |prepared| blk: {
            prepared_out.* = preparedSurfaceTokenOut(prepared);
            break :blk c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT;
        },
        .needs_full_prepare => c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE,
    };
}

pub fn takeSubmitHandle(value: c.HowlRenderTextSessionHandle, out: ?*c.HowlRenderPreparedSurfaceHandle) callconv(.c) c_int {
    const prepared_out = out orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    prepared_out.* = null;
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    return switch (owner.takeSubmitHandle()) {
        .idle => c.HOWL_RENDER_SUBMIT_DECISION_IDLE,
        .stale => c.HOWL_RENDER_SUBMIT_DECISION_STALE,
        .needs_full_prepare => c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE,
        .submit => |prepared| blk: {
            prepared_out.* = handle_owner.abiPreparedHandle(@ptrCast(prepared));
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

pub fn submit(
    text_session_handle: c.HowlRenderTextSessionHandle,
    prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle,
    prepared_token_in: c.HowlRenderPreparedSurfaceToken,
    execution_in: ?*const c.HowlRenderSubmitExecution,
    result_out: ?*c.HowlRenderSubmitResult,
) callconv(.c) c_int {
    if (result_out) |out| out.* = submit_result.failedSubmitResult();
    const owner = handle_owner.textSessionOwner(text_session_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const prepared = prepared_handle.PreparedHandle.fromHandle(prepared_surface_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const execution = execution_in orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const prepared_token = preparedSurfaceTokenIn(prepared_token_in) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    return switch (owner.submitPrepared(prepared, prepared_token, submit_result.submitExecutionIn(execution.*))) {
        .rendered => |submitted| blk: {
            if (result_out) |out| out.* = submit_result.submitResultOut(submitted);
            break :blk c.HOWL_RENDER_SUBMIT_RENDERED;
        },
        .needs_prepare => c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE,
        .failed => c.HOWL_RENDER_SUBMIT_FAILED,
    };
}

pub fn preparedSurfaceTokenOut(value: tokens.PreparedSurfaceToken) c.HowlRenderPreparedSurfaceToken {
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

pub fn submitHandle(
    text_session_handle: c.HowlRenderTextSessionHandle,
    prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle,
    execution_in: ?*const c.HowlRenderSubmitExecution,
    result_out: ?*c.HowlRenderSubmitResult,
) callconv(.c) c_int {
    if (result_out) |out| out.* = submit_result.failedSubmitResult();
    const owner = handle_owner.textSessionOwner(text_session_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const execution = execution_in orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const prepared = prepared_handle.PreparedHandle.fromHandle(prepared_surface_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    return switch (owner.submitPreparedHandle(prepared, submit_result.submitExecutionIn(execution.*))) {
        .rendered => |result| blk: {
            if (result_out) |out| out.* = submit_result.submitResultOut(result);
            break :blk c.HOWL_RENDER_SUBMIT_RENDERED;
        },
        .needs_prepare => c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE,
        .failed => c.HOWL_RENDER_SUBMIT_FAILED,
    };
}
