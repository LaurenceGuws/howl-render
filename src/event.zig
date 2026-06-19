const std = @import("std");

pub const DamageKind = enum(u2) {
    none = 0,
    partial = 1,
    full = 3,
};

pub const SnapshotToken = struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    layout_epoch: u64,
    damage_base_seq: u64,
    damage_kind: DamageKind,

    pub fn requiresRetainedBase(self: SnapshotToken) bool {
        return self.damage_kind == .partial;
    }

    pub fn isNewerThan(self: SnapshotToken, other: SnapshotToken) bool {
        if (self.snapshot_seq != other.snapshot_seq) return self.snapshot_seq > other.snapshot_seq;
        return self.dirty_epoch > other.dirty_epoch;
    }
};

pub const RenderRequest = struct {
    token: SnapshotToken,
    allow_retained_reuse: bool = true,

    pub fn mustPrepareFull(self: RenderRequest, retained: ?SubmittedSurfaceToken) bool {
        if (!self.allow_retained_reuse or !self.token.requiresRetainedBase()) return self.token.damage_kind == .full;
        const submitted = retained orelse return true;
        return validatePreparedSurfaceToken(.{
            .token = self.token,
            .required_base_seq = self.token.damage_base_seq,
        }, submitted) != .valid;
    }
};

pub const PreparedSurfaceToken = struct {
    token: SnapshotToken,
    required_base_seq: u64 = 0,

    pub fn requiresRetainedBase(self: PreparedSurfaceToken) bool {
        return self.token.requiresRetainedBase();
    }
};

pub const SubmittedSurfaceToken = struct {
    token: SnapshotToken,
    atlas_epoch: u64 = 0,
    surface_epoch: u64 = 0,
};

pub const SubmitValidation = enum {
    valid,
    stale_layout,
    missing_retained_base,
    stale_retained_base,
};

pub fn validatePreparedSurfaceToken(prepared: PreparedSurfaceToken, submitted: SubmittedSurfaceToken) SubmitValidation {
    if (!prepared.requiresRetainedBase()) return .valid;
    if (prepared.token.layout_epoch != submitted.token.layout_epoch) return .stale_layout;
    if (prepared.required_base_seq != submitted.token.snapshot_seq) return .stale_retained_base;
    return .valid;
}

test "snapshot token classifies retained-base damage" {
    const full = SnapshotToken{ .snapshot_seq = 1, .dirty_epoch = 1, .layout_epoch = 1, .damage_base_seq = 0, .damage_kind = .full };
    const partial = SnapshotToken{ .snapshot_seq = 2, .dirty_epoch = 2, .layout_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial };

    try std.testing.expect(!full.requiresRetainedBase());
    try std.testing.expect(partial.requiresRetainedBase());
    try std.testing.expect(partial.isNewerThan(full));
}

test "prepared partial surface token validates retained target base" {
    const submitted = SubmittedSurfaceToken{
        .token = .{ .snapshot_seq = 10, .dirty_epoch = 10, .layout_epoch = 3, .damage_base_seq = 0, .damage_kind = .full },
    };
    const prepared = PreparedSurfaceToken{
        .token = .{ .snapshot_seq = 11, .dirty_epoch = 11, .layout_epoch = 3, .damage_base_seq = 10, .damage_kind = .partial },
        .required_base_seq = 10,
    };

    try std.testing.expectEqual(SubmitValidation.valid, validatePreparedSurfaceToken(prepared, submitted));
}

test "prepared partial surface token rejects stale retained base state" {
    const submitted = SubmittedSurfaceToken{
        .token = .{ .snapshot_seq = 10, .dirty_epoch = 10, .layout_epoch = 3, .damage_base_seq = 0, .damage_kind = .full },
    };

    try std.testing.expectEqual(SubmitValidation.stale_retained_base, validatePreparedSurfaceToken(.{
        .token = .{ .snapshot_seq = 12, .dirty_epoch = 12, .layout_epoch = 3, .damage_base_seq = 11, .damage_kind = .partial },
        .required_base_seq = 11,
    }, submitted));
}

test "prepared full surface token validates across layout change" {
    const submitted = SubmittedSurfaceToken{
        .token = .{ .snapshot_seq = 10, .dirty_epoch = 10, .layout_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    };
    const prepared = PreparedSurfaceToken{
        .token = .{ .snapshot_seq = 11, .dirty_epoch = 11, .layout_epoch = 2, .damage_base_seq = 0, .damage_kind = .full },
    };

    try std.testing.expectEqual(SubmitValidation.valid, validatePreparedSurfaceToken(prepared, submitted));
}
