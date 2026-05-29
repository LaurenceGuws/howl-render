const std = @import("std");
const c = @import("ffi.zig").c;
const handle_owner = @import("handle.zig");
const prepared_owner = @import("surface/prepared_owner.zig");
const submit_result = @import("submit_result.zig");
const tokens = @import("surface/tokens.zig");

pub fn publishPrepared(
    value: c.HowlRenderTextSessionHandle,
    prepared_in: c.HowlRenderPreparedSurfaceToken,
) callconv(.c) c_int {
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepared = preparedSurfaceTokenIn(prepared_in) orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.publishPrepared(prepared);
    return c.HOWL_RENDER_CALL_OK;
}

pub fn publishPreparedHandle(
    value: c.HowlRenderTextSessionHandle,
    prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle,
) callconv(.c) c_int {
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepared = prepared_owner.Owner.fromHandle(prepared_surface_handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (!prepared.belongsToSession(owner)) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!prepared.markPublished()) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.prepared_submit_handle = null;
    owner.prepared_publish_handle = handle_owner.opaquePreparedHandle(prepared_surface_handle);
    owner.publishPrepared(prepared.preparedSurfaceToken());
    return c.HOWL_RENDER_CALL_OK;
}

pub fn takeSubmitDecision(
    value: c.HowlRenderTextSessionHandle,
    out: ?*c.HowlRenderPreparedSurfaceToken,
) callconv(.c) c_int {
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

pub fn takeSubmitHandle(
    value: c.HowlRenderTextSessionHandle,
    out: ?*c.HowlRenderPreparedSurfaceHandle,
) callconv(.c) c_int {
    const prepared_out = out orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    prepared_out.* = null;
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
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
            if (!samePreparedSurfaceToken(prepared_surface.preparedSurfaceToken(), prepared)) break :blk c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
            if (!prepared_surface.markSubmitReady()) break :blk c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
            owner.prepared_publish_handle = null;
            owner.prepared_submit_handle = prepared_handle;
            prepared_out.* = handle_owner.abiPreparedHandle(prepared_handle);
            break :blk c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT;
        },
    };
}

pub fn acceptSubmitted(
    value: c.HowlRenderTextSessionHandle,
    prepared_in: c.HowlRenderPreparedSurfaceToken,
) callconv(.c) c_int {
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
    const prepared = prepared_owner.Owner.fromHandle(prepared_surface_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const execution = execution_in orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const prepared_token = preparedSurfaceTokenIn(prepared_token_in) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    return switch (prepared.submit(owner, prepared_token, submit_result.submitExecutionIn(execution.*))) {
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

pub fn samePreparedSurfaceToken(a: tokens.PreparedSurfaceToken, b: tokens.PreparedSurfaceToken) bool {
    return a.token.snapshot_seq == b.token.snapshot_seq and
        a.token.dirty_epoch == b.token.dirty_epoch and
        a.token.geometry_epoch == b.token.geometry_epoch and
        a.token.damage_base_seq == b.token.damage_base_seq and
        a.token.damage_kind == b.token.damage_kind and
        a.required_base_seq == b.required_base_seq;
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
    if (owner.prepared_submit_handle != handle_owner.opaquePreparedHandle(prepared_surface_handle)) return c.HOWL_RENDER_SUBMIT_FAILED;
    const prepared = prepared_owner.Owner.fromHandle(prepared_surface_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    if (!prepared.isLive()) {
        owner.prepared_submit_handle = null;
        return c.HOWL_RENDER_SUBMIT_FAILED;
    }
    const submitted = prepared.preparedSurfaceToken().token;
    return switch (prepared.submitOwned(owner, submit_result.submitExecutionIn(execution.*))) {
        .rendered => |result| blk: {
            owner.prepared_submit_handle = null;
            owner.acceptSubmitted(.{ .token = submitted });
            if (result_out) |out| out.* = submit_result.submitResultOut(result);
            break :blk c.HOWL_RENDER_SUBMIT_RENDERED;
        },
        .needs_prepare => c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE,
        .failed => c.HOWL_RENDER_SUBMIT_FAILED,
    };
}
