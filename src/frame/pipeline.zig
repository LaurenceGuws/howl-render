
const std = @import("std");

const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    pub fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
}

pub const DamageKind = enum(u2) {
    none = 0,
    partial = 1,
    full = 3,
};

pub const SnapshotToken = struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
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

    pub fn mustPrepareFull(self: RenderRequest, retained: ?SubmittedFrame) bool {
        if (!self.allow_retained_reuse or !self.token.requiresRetainedBase()) return self.token.damage_kind == .full;
        const submitted = retained orelse return true;
        return validatePreparedFrame(.{
            .token = self.token,
            .required_base_seq = self.token.damage_base_seq,
        }, submitted) != .valid;
    }
};

pub const PreparedFrame = struct {
    token: SnapshotToken,
    required_base_seq: u64 = 0,

    pub fn requiresRetainedBase(self: PreparedFrame) bool {
        return self.token.requiresRetainedBase();
    }
};

pub fn PreparedFrameWith(comptime Payload: type) type {
    return struct {
        const Self = @This();

        header: PreparedFrame,
        payload: Payload,

        pub fn token(self: Self) SnapshotToken {
            return self.header.token;
        }

        pub fn requiresRetainedBase(self: Self) bool {
            return self.header.requiresRetainedBase();
        }

        pub fn validateAgainst(self: Self, submitted: SubmittedFrame) SubmitValidation {
            return validatePreparedFrame(self.header, submitted);
        }
    };
}

pub const SubmittedFrame = struct {
    token: SnapshotToken,
    atlas_epoch: u64 = 0,
    surface_epoch: u64 = 0,
};

pub const SubmitValidation = enum {
    valid,
    stale_geometry,
    missing_retained_base,
    stale_retained_base,
};

pub fn validatePreparedFrame(prepared: PreparedFrame, submitted: SubmittedFrame) SubmitValidation {
    if (!prepared.requiresRetainedBase()) return .valid;
    if (prepared.token.geometry_epoch != submitted.token.geometry_epoch) return .stale_geometry;
    if (prepared.required_base_seq != submitted.token.snapshot_seq) return .stale_retained_base;
    return .valid;
}

pub const RenderResult = union(enum) {
    presentable: SubmittedFrame,
    stale: SnapshotToken,
    needs_full_prepare: FullPrepareReason,
    surface_lost: SurfaceLostReason,
};

pub const FullPrepareReason = enum {
    retained_base_missing,
    retained_base_stale,
    geometry_changed,
};

pub const SurfaceLostReason = enum {
    surface_invalidated,
    execution_state_lost,
    surface_closed,
};

pub fn LatestMailbox(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: ThreadMutex = .{},
        item: ?T = null,

        pub fn publish(self: *Self, item: T) void {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            self.item = item;
        }

        pub fn takeLatest(self: *Self) ?T {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            const item = self.item orelse return null;
            self.item = null;
            return item;
        }

        pub fn hasPending(self: *Self) bool {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            return self.item != null;
        }

        pub fn dropAtOrBefore(self: *Self, token: SnapshotToken) void {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            const item = self.item orelse return;
            if (!item.token.isNewerThan(token)) self.item = null;
        }
    };
}

test "snapshot token classifies retained-base damage" {
    const full = SnapshotToken{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full };
    const partial = SnapshotToken{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial };

    try std.testing.expect(!full.requiresRetainedBase());
    try std.testing.expect(partial.requiresRetainedBase());
    try std.testing.expect(partial.isNewerThan(full));
}

test "prepared partial frame validates retained target base" {
    const submitted = SubmittedFrame{
        .token = .{ .snapshot_seq = 10, .dirty_epoch = 10, .geometry_epoch = 3, .damage_base_seq = 0, .damage_kind = .full },
    };
    const prepared = PreparedFrame{
        .token = .{ .snapshot_seq = 11, .dirty_epoch = 11, .geometry_epoch = 3, .damage_base_seq = 10, .damage_kind = .partial },
        .required_base_seq = 10,
    };

    try std.testing.expectEqual(SubmitValidation.valid, validatePreparedFrame(prepared, submitted));
}

test "prepared partial frame rejects stale retained base state" {
    const submitted = SubmittedFrame{
        .token = .{ .snapshot_seq = 10, .dirty_epoch = 10, .geometry_epoch = 3, .damage_base_seq = 0, .damage_kind = .full },
    };

    try std.testing.expectEqual(SubmitValidation.stale_retained_base, validatePreparedFrame(.{
        .token = .{ .snapshot_seq = 12, .dirty_epoch = 12, .geometry_epoch = 3, .damage_base_seq = 11, .damage_kind = .partial },
        .required_base_seq = 11,
    }, submitted));
}

test "prepared full frame validates across geometry change" {
    const submitted = SubmittedFrame{
        .token = .{ .snapshot_seq = 10, .dirty_epoch = 10, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    };
    const prepared = PreparedFrame{
        .token = .{ .snapshot_seq = 11, .dirty_epoch = 11, .geometry_epoch = 2, .damage_base_seq = 0, .damage_kind = .full },
    };

    try std.testing.expectEqual(SubmitValidation.valid, validatePreparedFrame(prepared, submitted));
}

test "prepared frame payload keeps validation in the header" {
    const Payload = struct { scene_id: u32 };
    const Prepared = PreparedFrameWith(Payload);
    const submitted = SubmittedFrame{
        .token = .{ .snapshot_seq = 4, .dirty_epoch = 4, .geometry_epoch = 2, .damage_base_seq = 0, .damage_kind = .full },
    };
    const prepared = Prepared{
        .header = .{
            .token = .{ .snapshot_seq = 5, .dirty_epoch = 5, .geometry_epoch = 2, .damage_base_seq = 4, .damage_kind = .partial },
            .required_base_seq = 4,
        },
        .payload = .{ .scene_id = 42 },
    };

    try std.testing.expectEqual(@as(u32, 42), prepared.payload.scene_id);
    try std.testing.expectEqual(SubmitValidation.valid, prepared.validateAgainst(submitted));
}

test "latest mailbox drops stale work" {
    const Mailbox = LatestMailbox(u32);
    var mailbox = Mailbox{};

    try std.testing.expect(!mailbox.hasPending());
    mailbox.publish(10);
    mailbox.publish(20);
    try std.testing.expect(mailbox.hasPending());

    const item = mailbox.takeLatest() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 20), item);
    try std.testing.expect(mailbox.takeLatest() == null);
}
