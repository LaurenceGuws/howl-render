const std = @import("std");
const event = @import("event.zig");

pub const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    pub fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

pub fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
}

pub const SubmittedSurface = struct {
    mutex: ThreadMutex = .{},
    submitted_token: ?event.SubmittedSurfaceToken = null,

    pub fn validatePrepared(self: *const SubmittedSurface, prepared: event.PreparedSurfaceToken) event.SubmitValidation {
        const submitted_owner: *SubmittedSurface = @constCast(self);
        lockMutex(&submitted_owner.mutex);
        defer submitted_owner.mutex.unlock();
        const submitted = self.submitted_token orelse {
            return if (prepared.requiresRetainedBase()) .missing_retained_base else .valid;
        };
        return event.validatePreparedSurfaceToken(prepared, submitted);
    }

    pub fn acceptSubmitted(self: *SubmittedSurface, submitted: event.SubmittedSurfaceToken) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        std.debug.assert(submitted.token.snapshot_seq != 0);
        if (self.submitted_token) |prior| std.debug.assert(!prior.token.isNewerThan(submitted.token));
        self.submitted_token = submitted;
    }

    pub fn submittedToken(self: *const SubmittedSurface) ?event.SnapshotToken {
        const submitted_owner: *SubmittedSurface = @constCast(self);
        lockMutex(&submitted_owner.mutex);
        defer submitted_owner.mutex.unlock();
        return if (self.submitted_token) |submitted| submitted.token else null;
    }

    pub fn prepareTokenForRetainedState(token: event.SnapshotToken, submitted_token: ?event.SnapshotToken) event.SnapshotToken {
        if (!token.requiresRetainedBase()) return token;
        const submitted = submitted_token orelse return forceFull(token);
        if (submitted.geometry_epoch != token.geometry_epoch) return forceFull(token);
        if (submitted.snapshot_seq != token.damage_base_seq) return forceFull(token);
        return token;
    }

    pub fn forceFull(token: event.SnapshotToken) event.SnapshotToken {
        return .{
            .snapshot_seq = token.snapshot_seq,
            .dirty_epoch = token.dirty_epoch,
            .geometry_epoch = token.geometry_epoch,
            .damage_base_seq = 0,
            .damage_kind = .full,
        };
    }

    pub fn isStalePrepared(self: *const SubmittedSurface, latest_token: ?event.SnapshotToken, token: event.SnapshotToken) bool {
        _ = self;
        const latest = latest_token orelse return false;
        return latest.isNewerThan(token);
    }
};

test "submitted owner validates retained base before GPU mutation" {
    var submitted = SubmittedSurface{};
    submitted.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });
    const validation = submitted.validatePrepared(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial },
        .required_base_seq = 1,
    });

    try std.testing.expectEqual(event.SubmitValidation.valid, validation);
}

test "submitted owner keeps submitted identity as retained base only" {
    var submitted = SubmittedSurface{};
    const token = event.SubmittedSurfaceToken{
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
    var submitted = SubmittedSurface{};
    const stale = submitted.isStalePrepared(
        .{ .snapshot_seq = 3, .dirty_epoch = 3, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
        .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    );
    try std.testing.expect(stale);
}

test "submitted surface starts without submitted token" {
    var submitted = SubmittedSurface{};
    try std.testing.expect(submitted.submittedToken() == null);
}

test "submitted surface token monotonicity keeps latest submission" {
    var submitted = SubmittedSurface{};
    submitted.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 4, .dirty_epoch = 4, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });
    submitted.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 5, .dirty_epoch = 5, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });

    try std.testing.expect(submitted.submittedToken() != null);
    try std.testing.expectEqual(@as(u64, 5), submitted.submittedToken().?.snapshot_seq);
}
