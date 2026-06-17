const std = @import("std");
const tokens = @import("../tokens.zig");

pub fn sameSnapshotToken(a: tokens.SnapshotToken, b: tokens.SnapshotToken) bool {
    return a.snapshot_seq == b.snapshot_seq and a.dirty_epoch == b.dirty_epoch and a.geometry_epoch == b.geometry_epoch and a.damage_base_seq == b.damage_base_seq and a.damage_kind == b.damage_kind;
}

test "snapshot token equality includes every prepared-source discriminator" {
    const token: tokens.SnapshotToken = .{ .snapshot_seq = 1, .dirty_epoch = 2, .geometry_epoch = 3, .damage_base_seq = 4, .damage_kind = .partial };
    try std.testing.expect(sameSnapshotToken(token, token));
    try std.testing.expect(!sameSnapshotToken(token, .{ .snapshot_seq = 1, .dirty_epoch = 2, .geometry_epoch = 3, .damage_base_seq = 4, .damage_kind = .full }));
}
