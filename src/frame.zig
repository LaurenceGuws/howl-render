const c = @import("ffi.zig").c;
const tokens = @import("surface/tokens.zig");

pub fn prepareRequestOut(value: tokens.RenderRequest) c.HowlRenderPrepareRequest {
    return .{
        .snapshot_seq = value.token.snapshot_seq,
        .dirty_epoch = value.token.dirty_epoch,
        .geometry_epoch = value.token.geometry_epoch,
        .damage_base_seq = value.token.damage_base_seq,
        .damage_kind = @intFromEnum(value.token.damage_kind),
    };
}

pub fn preparedFrameOut(value: tokens.PreparedFrame) c.HowlRenderPreparedFrame {
    return .{
        .snapshot_seq = value.token.snapshot_seq,
        .dirty_epoch = value.token.dirty_epoch,
        .geometry_epoch = value.token.geometry_epoch,
        .damage_base_seq = value.token.damage_base_seq,
        .required_base_seq = value.required_base_seq,
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

pub fn preparedFrameIn(value: c.HowlRenderPreparedFrame) ?tokens.PreparedFrame {
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

pub fn samePreparedFrame(a: tokens.PreparedFrame, b: tokens.PreparedFrame) bool {
    return a.token.snapshot_seq == b.token.snapshot_seq and
        a.token.dirty_epoch == b.token.dirty_epoch and
        a.token.geometry_epoch == b.token.geometry_epoch and
        a.token.damage_base_seq == b.token.damage_base_seq and
        a.token.damage_kind == b.token.damage_kind and
        a.required_base_seq == b.required_base_seq;
}

pub fn damageKindIn(value: u8) ?tokens.DamageKind {
    return switch (value) {
        @intFromEnum(tokens.DamageKind.none) => .none,
        @intFromEnum(tokens.DamageKind.partial) => .partial,
        @intFromEnum(tokens.DamageKind.full) => .full,
        else => null,
    };
}
