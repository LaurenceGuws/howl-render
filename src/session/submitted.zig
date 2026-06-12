const std = @import("std");
const tokens = @import("../geometry/tokens.zig");

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

pub const SubmittedWorkState = struct {
    submit_pending: bool,
};

pub const Submitted = struct {
    mutex: ThreadMutex = .{},
    submitted_token: ?tokens.SubmittedSurfaceToken = null,

    pub fn validatePrepared(self: *const Submitted, prepared: tokens.PreparedSurfaceToken) tokens.SubmitValidation {
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

    pub fn workState(self: *const Submitted) SubmittedWorkState {
        const submitted_owner: *Submitted = @constCast(self);
        lockMutex(&submitted_owner.mutex);
        defer submitted_owner.mutex.unlock();
        return .{ .submit_pending = false };
    }

    pub fn submittedToken(self: *Submitted) ?tokens.SnapshotToken {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        return if (self.submitted_token) |submitted| submitted.token else null;
    }

    pub fn prepareTokenForRetainedState(token: tokens.SnapshotToken, submitted_token: ?tokens.SnapshotToken) tokens.SnapshotToken {
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

    pub fn isStalePrepared(self: *const Submitted, latest_token: ?tokens.SnapshotToken, token: tokens.SnapshotToken) bool {
        _ = self;
        const latest = latest_token orelse return false;
        return latest.isNewerThan(token);
    }
};

test "submitted owner validates retained base before GPU mutation" {
    var submitted = Submitted{};
    submitted.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });
    const validation = submitted.validatePrepared(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial },
        .required_base_seq = 1,
    });

    try std.testing.expectEqual(tokens.SubmitValidation.valid, validation);
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
    const stale = submitted.isStalePrepared(
        .{ .snapshot_seq = 3, .dirty_epoch = 3, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
        .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    );
    try std.testing.expect(stale);
}

test "submitted owner has no source publication state" {
    var submitted = Submitted{};
    try std.testing.expect(submitted.submittedToken() == null);
    try std.testing.expect(!submitted.workState().submit_pending);
}
