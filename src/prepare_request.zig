const std = @import("std");
const c = @import("howl_render_c");
const handle_owner = @import("handle.zig");
const tokens = @import("geometry/tokens.zig");
const source_publication = @import("vt_publication/publication.zig");

pub fn takePrepareRequest(value: c.HowlRenderTextSessionHandle, vt_surface: ?*const c.HowlVtSurfaceResult, out: ?*c.HowlRenderPrepareRequest) callconv(.c) c_int {
    const prepare_out = out orelse return c.HOWL_RENDER_PREPARE_FAILED;
    prepare_out.* = std.mem.zeroes(c.HowlRenderPrepareRequest);
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const visible = vt_surface orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const source = source_publication.ownedSourceFromSurfaceResult(owner.allocator, visible.*, owner.cursor_blink_visible) catch return c.HOWL_RENDER_PREPARE_FAILED;
    _ = owner.prepare_requests.admitSource(source, owner.submittedToken(), owner.geometry.geometry_epoch);
    const request = owner.prepare() orelse return c.HOWL_RENDER_PREPARE_IDLE;
    prepare_out.* = prepareRequestOut(request);
    return c.HOWL_RENDER_PREPARE_READY;
}

pub fn prepareRequestOut(value: tokens.RenderRequest) c.HowlRenderPrepareRequest {
    std.debug.assert(value.token.snapshot_seq != 0);
    std.debug.assert(value.token.dirty_epoch != 0);
    std.debug.assert(value.token.geometry_epoch != 0);
    std.debug.assert(value.token.damage_kind != .none);
    return .{
        .snapshot_seq = value.token.snapshot_seq,
        .dirty_epoch = value.token.dirty_epoch,
        .geometry_epoch = value.token.geometry_epoch,
        .damage_base_seq = value.token.damage_base_seq,
        .damage_kind = @intFromEnum(value.token.damage_kind),
    };
}

pub fn prepareTokenIn(value: c.HowlRenderPrepareRequest) ?tokens.SnapshotToken {
    const damage_kind = damageKindIn(value.damage_kind) orelse return null;
    if (value.snapshot_seq == 0) return null;
    if (value.dirty_epoch == 0) return null;
    if (value.geometry_epoch == 0) return null;
    if (damage_kind == .none) return null;
    switch (damage_kind) {
        .none => unreachable,
        .full => {
            if (value.damage_base_seq != 0) return null;
        },
        .partial => {
            if (value.damage_base_seq == 0) return null;
        },
    }
    return .{
        .snapshot_seq = value.snapshot_seq,
        .dirty_epoch = value.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .damage_base_seq = value.damage_base_seq,
        .damage_kind = damage_kind,
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
