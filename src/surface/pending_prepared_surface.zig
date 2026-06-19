const std = @import("std");
const tokens = @import("../tokens.zig");
const submitted_surface = @import("../submitted_surface.zig");
const prepared_handle = @import("handle.zig");

const RdrSfcHandle = ?*anyopaque;

pub const TakeSubmitDecision = union(enum) {
    idle,
    stale,
    needs_full_prepare,
    submit: *prepared_handle.PreparedHandle,
    failed,
};

pub const PendingPreparedSurface = struct {
    rdr_sfc_handle: RdrSfcHandle = null,
    prepared_candidate: ?*prepared_handle.PreparedHandle = null,
    prepared_handles: std.ArrayList(*prepared_handle.PreparedHandle) = .empty,

    pub fn deinit(self: *PendingPreparedSurface, allocator: std.mem.Allocator) void {
        self.rdr_sfc_handle = null;
        self.clearCandidate();
        for (self.prepared_handles.items) |prepared| prepared.destroy();
        self.prepared_handles.deinit(allocator);
        self.* = .{};
    }

    pub fn registerHandle(self: *PendingPreparedSurface, allocator: std.mem.Allocator, prepared: *prepared_handle.PreparedHandle) !void {
        std.debug.assert(!prepared.registered);
        try self.prepared_handles.append(allocator, prepared);
        prepared.registered = true;
    }

    pub fn detachRegisteredHandle(self: *PendingPreparedSurface, prepared: *prepared_handle.PreparedHandle) void {
        if (!prepared.registered) return;
        self.clearCachedHandle(prepared);
        for (self.prepared_handles.items, 0..) |registered, index| {
            if (registered != prepared) continue;
            self.prepared_handles.items[index] = prepared_handle.destroyedSentinel();
            prepared.registered = false;
            return;
        }
        std.debug.panic("prepared handle registration missing during destroy", .{});
    }

    pub fn acceptPrepared(self: *PendingPreparedSurface, prepared: *prepared_handle.PreparedHandle) void {
        std.debug.assert(prepared.isLive());
        std.debug.assert(prepared.state == .prepared);
        std.debug.assert(self.prepared_candidate == null);
        std.debug.assert(self.rdr_sfc_handle == null);
        self.prepared_candidate = prepared;
        self.rdr_sfc_handle = @ptrCast(prepared);
    }

    pub fn clearCachedHandle(self: *PendingPreparedSurface, prepared: *prepared_handle.PreparedHandle) void {
        const handle: RdrSfcHandle = @ptrCast(prepared);
        if (self.rdr_sfc_handle == handle) self.rdr_sfc_handle = null;
        if (self.prepared_candidate == prepared) self.prepared_candidate = null;
    }

    pub fn clearCandidate(self: *PendingPreparedSurface) void {
        const prepared = self.prepared_candidate orelse {
            self.rdr_sfc_handle = null;
            return;
        };
        self.prepared_candidate = null;
        self.rdr_sfc_handle = null;
        prepared.release();
    }

    pub fn invalidateForRenderState(self: *PendingPreparedSurface, snapshot_seq: u64) void {
        std.debug.assert(snapshot_seq != 0);
        const prepared = self.prepared_candidate orelse return;
        if (prepared.preparedSurfaceToken().token.snapshot_seq == snapshot_seq) return;
        self.clearCandidate();
    }

    pub fn submitPending(self: *const PendingPreparedSurface) bool {
        return self.prepared_candidate != null;
    }

    pub fn registeredHandleCount(self: *const PendingPreparedSurface) usize {
        return self.prepared_handles.items.len;
    }

    pub fn takeSubmitHandle(self: *PendingPreparedSurface, latest_token: ?tokens.SnapshotToken, submitted: *submitted_surface.SubmittedSurface) TakeSubmitDecision {
        const prepared = self.prepared_candidate orelse return .idle;
        const opaque_handle = self.rdr_sfc_handle orelse return .failed;
        if (@as(RdrSfcHandle, @ptrCast(prepared)) != opaque_handle) return .failed;
        if (!prepared.isLive()) {
            self.clearCandidate();
            return .failed;
        }
        if (prepared.state != .prepared) return .failed;
        const prepared_token = prepared.preparedSurfaceToken();
        if (submitted.isStalePrepared(latest_token, prepared_token.token)) {
            self.clearCandidate();
            return .stale;
        }
        const validation = submitted.validatePrepared(prepared_token);
        if (validation != .valid) {
            self.clearCandidate();
            return .needs_full_prepare;
        }
        prepared.state = .submit_ready;
        return .{ .submit = prepared };
    }

    pub fn submittedTokenForHandle(self: *PendingPreparedSurface, prepared: *prepared_handle.PreparedHandle) ?tokens.SnapshotToken {
        if (self.rdr_sfc_handle != @as(RdrSfcHandle, @ptrCast(prepared))) return null;
        if (self.prepared_candidate != prepared) return null;
        if (!prepared.isLive()) {
            self.clearCandidate();
            return null;
        }
        if (prepared.state != .submit_ready) return null;
        return prepared.preparedSurfaceToken().token;
    }
};

test "pending prepared surface empty slot reports idle" {
    var pending = PendingPreparedSurface{};
    var submitted = submitted_surface.SubmittedSurface{};

    try std.testing.expectEqual(TakeSubmitDecision.idle, pending.takeSubmitHandle(null, &submitted));
    try std.testing.expect(!pending.submitPending());
}

test "pending prepared surface accepts candidate and submits once" {
    const render_session = @import("../render_session.zig");
    const support = @import("../c/test_support.zig");
    const owner = render_session.TextSessionOwner.create(std.testing.allocator, .{ .surface_px = .{ .width = 8, .height = 16 } }) orelse return error.OutOfMemory;
    defer owner.destroy();
    var submitted = submitted_surface.SubmittedSurface{};
    var prepared_value = support.preparedSurface(.{ .width_px = 8, .height_px = 16 });
    prepared_value.request.token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .layout_epoch = 1, .damage_base_seq = 0, .damage_kind = .full };

    const prepared = try prepared_handle.PreparedHandle.create(owner, &prepared_value);
    owner.pending_prepared.acceptPrepared(prepared);

    try std.testing.expect(owner.pending_prepared.submitPending());
    switch (owner.pending_prepared.takeSubmitHandle(null, &submitted)) {
        .submit => |handle| try std.testing.expectEqual(prepared, handle),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(prepared_handle.PreparedHandle.State.submit_ready, prepared.state);
    try std.testing.expectEqual(TakeSubmitDecision.failed, owner.pending_prepared.takeSubmitHandle(null, &submitted));
}

test "pending prepared surface stale source clears candidate" {
    const render_session = @import("../render_session.zig");
    const support = @import("../c/test_support.zig");
    const owner = render_session.TextSessionOwner.create(std.testing.allocator, .{ .surface_px = .{ .width = 8, .height = 16 } }) orelse return error.OutOfMemory;
    defer owner.destroy();
    var submitted = submitted_surface.SubmittedSurface{};
    var prepared_value = support.preparedSurface(.{ .width_px = 8, .height_px = 16 });
    prepared_value.request.token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .layout_epoch = 1, .damage_base_seq = 0, .damage_kind = .full };

    const prepared = try prepared_handle.PreparedHandle.create(owner, &prepared_value);
    owner.pending_prepared.acceptPrepared(prepared);

    try std.testing.expectEqual(TakeSubmitDecision.stale, owner.pending_prepared.takeSubmitHandle(.{ .snapshot_seq = 2, .dirty_epoch = 2, .layout_epoch = 1, .damage_base_seq = 0, .damage_kind = .full }, &submitted));
    try std.testing.expect(!owner.pending_prepared.submitPending());
    try std.testing.expectEqual(prepared_handle.PreparedHandle.State.released, prepared.state);
}

test "pending prepared surface invalid retained base clears candidate" {
    const render_session = @import("../render_session.zig");
    const support = @import("../c/test_support.zig");
    const owner = render_session.TextSessionOwner.create(std.testing.allocator, .{ .surface_px = .{ .width = 8, .height = 16 } }) orelse return error.OutOfMemory;
    defer owner.destroy();
    var submitted = submitted_surface.SubmittedSurface{};
    submitted.acceptSubmitted(.{ .token = .{ .snapshot_seq = 9, .dirty_epoch = 9, .layout_epoch = 1, .damage_base_seq = 0, .damage_kind = .full } });
    var prepared_value = support.preparedSurface(.{ .width_px = 8, .height_px = 16, .full_redraw = false });
    prepared_value.request.token = .{ .snapshot_seq = 10, .dirty_epoch = 10, .layout_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial };

    const prepared = try prepared_handle.PreparedHandle.create(owner, &prepared_value);
    owner.pending_prepared.acceptPrepared(prepared);

    try std.testing.expectEqual(TakeSubmitDecision.needs_full_prepare, owner.pending_prepared.takeSubmitHandle(null, &submitted));
    try std.testing.expect(!owner.pending_prepared.submitPending());
    try std.testing.expectEqual(prepared_handle.PreparedHandle.State.released, prepared.state);
}

test "pending prepared surface consume clears candidate" {
    const render_session = @import("../render_session.zig");
    const support = @import("../c/test_support.zig");
    const owner = render_session.TextSessionOwner.create(std.testing.allocator, .{ .surface_px = .{ .width = 8, .height = 16 } }) orelse return error.OutOfMemory;
    defer owner.destroy();
    var submitted = submitted_surface.SubmittedSurface{};
    var prepared_value = support.preparedSurface(.{ .width_px = 8, .height_px = 16 });
    prepared_value.request.token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .layout_epoch = 1, .damage_base_seq = 0, .damage_kind = .full };

    const prepared = try prepared_handle.PreparedHandle.create(owner, &prepared_value);
    owner.pending_prepared.acceptPrepared(prepared);
    switch (owner.pending_prepared.takeSubmitHandle(null, &submitted)) {
        .submit => {},
        else => return error.TestUnexpectedResult,
    }

    prepared.consume();

    try std.testing.expect(!owner.pending_prepared.submitPending());
    try std.testing.expectEqual(prepared_handle.PreparedHandle.State.consumed, prepared.state);
}
