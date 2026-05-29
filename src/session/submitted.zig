const std = @import("std");
const tokens = @import("../surface/tokens.zig");

pub const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    pub fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

pub fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
}

pub const SubmitDecision = union(enum) {
    submit: tokens.PreparedSurfaceToken,
    stale: tokens.SnapshotToken,
    needs_full_prepare: tokens.FullPrepareReason,
    idle,
};

pub const Submitted = struct {
    const SubmitMailbox = tokens.LatestMailbox(tokens.PreparedSurfaceToken);

    mutex: ThreadMutex = .{},
    submit_mailbox: SubmitMailbox = .{},
    submitted_token: ?tokens.SubmittedSurfaceToken = null,

    pub fn publishPrepared(self: *Submitted, prepared: tokens.PreparedSurfaceToken) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.submit_mailbox.publish(prepared);
    }

    pub fn takeValidatedSubmitWithLatest(
        self: *Submitted,
        latest_token: ?tokens.SnapshotToken,
    ) SubmitDecision {
        lockMutex(&self.mutex);
        const prepared = self.submit_mailbox.takeLatest() orelse {
            self.mutex.unlock();
            return .idle;
        };
        self.mutex.unlock();
        if (self.isStalePrepared(latest_token, prepared.token)) return .{ .stale = prepared.token };

        const validation = self.validatePrepared(prepared);
        if (validation == .valid) return .{ .submit = prepared };

        const reason = fullPrepareReason(validation);
        return .{ .needs_full_prepare = reason };
    }

    pub fn validatePrepared(
        self: *const Submitted,
        prepared: tokens.PreparedSurfaceToken,
    ) tokens.SubmitValidation {
        const submitted_owner: *Submitted = @constCast(self);
        lockMutex(&submitted_owner.mutex);
        defer submitted_owner.mutex.unlock();
        const submitted = self.submitted_token orelse {
            return if (prepared.requiresRetainedBase()) .missing_retained_base else .valid;
        };
        return tokens.validatePreparedSurfaceToken(prepared, submitted);
    }

    pub fn acceptSubmitted(self: *Submitted, submitted: tokens.SubmittedSurfaceToken) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        std.debug.assert(submitted.token.snapshot_seq != 0);
        self.submitted_token = submitted;
    }

    pub fn pendingState(self: *const Submitted) struct { submit_pending: bool } {
        const submitted_owner: *Submitted = @constCast(self);
        lockMutex(&submitted_owner.mutex);
        defer submitted_owner.mutex.unlock();
        return .{ .submit_pending = submitted_owner.submit_mailbox.hasPending() };
    }

    pub fn submittedToken(self: *Submitted) ?tokens.SnapshotToken {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        return if (self.submitted_token) |submitted| submitted.token else null;
    }

    pub fn prepareTokenForRetainedState(
        token: tokens.SnapshotToken,
        submitted_token: ?tokens.SnapshotToken,
    ) tokens.SnapshotToken {
        if (!token.requiresRetainedBase()) return token;
        const submitted = submitted_token orelse return forceFull(token);
        if (submitted.geometry_epoch != token.geometry_epoch) return forceFull(token);
        if (submitted.snapshot_seq != token.damage_base_seq) return forceFull(token);
        return token;
    }

    pub fn forceFull(token: tokens.SnapshotToken) tokens.SnapshotToken {
        return .{
            .snapshot_seq = token.snapshot_seq,
            .dirty_epoch = token.dirty_epoch,
            .geometry_epoch = token.geometry_epoch,
            .damage_base_seq = 0,
            .damage_kind = .full,
        };
    }

    pub fn fullPrepareReason(validation: tokens.SubmitValidation) tokens.FullPrepareReason {
        return switch (validation) {
            .valid => unreachable,
            .stale_geometry => .geometry_changed,
            .missing_retained_base => .retained_base_missing,
            .stale_retained_base => .retained_base_stale,
        };
    }

    fn isStalePrepared(
        self: *const Submitted,
        latest_token: ?tokens.SnapshotToken,
        token: tokens.SnapshotToken,
    ) bool {
        _ = self;
        const latest = latest_token orelse return false;
        return latest.isNewerThan(token);
    }
};

test "submitted owner validates submit candidates before GPU mutation" {
    var submitted = Submitted{};
    submitted.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });
    submitted.publishPrepared(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial },
        .required_base_seq = 1,
    });

    const decision = submitted.takeValidatedSubmitWithLatest(null);
    switch (decision) {
        .submit => |prepared| try std.testing.expectEqual(@as(u64, 2), prepared.token.snapshot_seq),
        else => return error.TestUnexpectedResult,
    }
}

test "submitted owner keeps submitted identity as retained base only" {
    var submitted = Submitted{};
    const token = tokens.SubmittedSurfaceToken{
        .token = .{ .snapshot_seq = 7, .dirty_epoch = 9, .geometry_epoch = 2, .damage_base_seq = 0, .damage_kind = .full },
        .atlas_epoch = 11,
        .surface_epoch = 13,
    };

    submitted.acceptSubmitted(token);

    try std.testing.expect(submitted.submitted_token != null);
    try std.testing.expectEqual(token.token.snapshot_seq, submitted.submitted_token.?.token.snapshot_seq);
    try std.testing.expectEqual(token.token.dirty_epoch, submitted.submitted_token.?.token.dirty_epoch);
    try std.testing.expectEqual(token.token.geometry_epoch, submitted.submitted_token.?.token.geometry_epoch);
    try std.testing.expectEqual(token.atlas_epoch, submitted.submitted_token.?.atlas_epoch);
    try std.testing.expectEqual(token.surface_epoch, submitted.submitted_token.?.surface_epoch);
}

test "submitted owner reports stale submit when newer snapshot already won" {
    var submitted = Submitted{};
    submitted.publishPrepared(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });

    const decision = submitted.takeValidatedSubmitWithLatest(.{
        .snapshot_seq = 3,
        .dirty_epoch = 3,
        .geometry_epoch = 1,
        .damage_base_seq = 0,
        .damage_kind = .full,
    });
    switch (decision) {
        .stale => |token| try std.testing.expectEqual(@as(u64, 2), token.snapshot_seq),
        else => return error.TestUnexpectedResult,
    }
}

test "submitted owner has no source publication state" {
    var submitted = Submitted{};
    try std.testing.expect(submitted.submittedToken() == null);
    try std.testing.expect(!submitted.pendingState().submit_pending);
}
