const std = @import("std");
const pipeline = @import("pipeline.zig");
const surface_types = @import("surface.zig");

const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    pub fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
}

pub const SubmitDecision = union(enum) {
    submit: pipeline.PreparedFrame,
    stale: pipeline.SnapshotToken,
    needs_full_prepare: pipeline.FullPrepareReason,
    idle,
};

pub const QueueMetrics = struct {
    snapshot_publishes: u64 = 0,
    snapshot_clean_drops: u64 = 0,
    prepare_requests: u64 = 0,
    prepare_coalesces: u64 = 0,
    prepare_forced_full: u64 = 0,
    prepare_takes: u64 = 0,
    prepared_publishes: u64 = 0,
    prepared_coalesces: u64 = 0,
    submit_takes: u64 = 0,
    submit_valid: u64 = 0,
    submit_rejected: u64 = 0,
    full_prepare_requests: u64 = 0,
    submitted_accepts: u64 = 0,
    presents: u64 = 0,
    target_invalidations: u64 = 0,
};

const TerminalSurface = struct {
    const PrepareMailbox = pipeline.LatestMailbox(pipeline.RenderRequest);
    const SubmitMailbox = pipeline.LatestMailbox(pipeline.PreparedFrame);

    mutex: ThreadMutex = .{},
    prepare_mailbox: PrepareMailbox = .{},
    submit_mailbox: SubmitMailbox = .{},
    latest_token: ?pipeline.SnapshotToken = null,
    submitted_frame: ?pipeline.SubmittedFrame = null,
    target_epoch: u64 = 0,
    metrics: QueueMetrics = .{},

    fn bindTargetEpoch(self: *TerminalSurface, target_epoch: u64) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.target_epoch == target_epoch) return;
        self.target_epoch = target_epoch;
        if (self.submitted_frame) |*frame| frame.content_valid = false;
        self.metrics.target_invalidations +%= 1;
    }

    fn publishSnapshot(self: *TerminalSurface, token: pipeline.SnapshotToken) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.latest_token = token;
        self.metrics.snapshot_publishes +%= 1;
        if (token.damage_kind == .none) {
            self.metrics.snapshot_clean_drops +%= 1;
            return;
        }
        const request_token = self.prepareTokenForCurrentRetainedState(token);
        const effective_token = request_token;
        if (effective_token.damage_kind == .full and token.damage_kind != .full) self.metrics.prepare_forced_full +%= 1;
        if (self.prepare_mailbox.hasPending()) self.metrics.prepare_coalesces +%= 1;
        self.metrics.prepare_requests +%= 1;
        const request = pipeline.RenderRequest{
            .token = effective_token,
            .known_target_epoch = self.target_epoch,
            .allow_retained_reuse = true,
        };
        self.prepare_mailbox.publish(request);
    }

    fn takePrepare(self: *TerminalSurface) ?pipeline.RenderRequest {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const request = self.prepare_mailbox.takeLatest() orelse return null;
        self.metrics.prepare_takes +%= 1;
        return request;
    }

    fn publishPrepared(self: *TerminalSurface, prepared: pipeline.PreparedFrame) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.submit_mailbox.hasPending()) self.metrics.prepared_coalesces +%= 1;
        self.metrics.prepared_publishes +%= 1;
        self.submit_mailbox.publish(prepared);
    }

    fn takeValidatedSubmit(self: *TerminalSurface) SubmitDecision {
        lockMutex(&self.mutex);
        const prepared = self.submit_mailbox.takeLatest() orelse {
            self.mutex.unlock();
            return .idle;
        };
        self.metrics.submit_takes +%= 1;
        self.mutex.unlock();
        if (self.isStalePrepared(prepared.token)) return .{ .stale = prepared.token };

        const validation = self.validatePrepared(prepared);
        if (validation == .valid) {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            self.metrics.submit_valid +%= 1;
            return .{ .submit = prepared };
        }

        const reason = fullPrepareReason(validation);
        lockMutex(&self.mutex);
        self.metrics.submit_rejected +%= 1;
        self.mutex.unlock();
        self.requestFullPrepare(prepared.token);
        return .{ .needs_full_prepare = reason };
    }

    fn requestFullPrepare(self: *TerminalSurface, fallback: pipeline.SnapshotToken) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const token = forceFull(self.latest_token orelse fallback);
        if (self.prepare_mailbox.hasPending()) self.metrics.prepare_coalesces +%= 1;
        self.metrics.full_prepare_requests +%= 1;
        self.metrics.prepare_requests +%= 1;
        _ = self.prepare_mailbox.publish(.{
            .token = token,
            .known_target_epoch = self.target_epoch,
            .allow_retained_reuse = false,
        });
    }

    fn validatePrepared(self: *const TerminalSurface, prepared: pipeline.PreparedFrame) pipeline.SubmitValidation {
        const surface: *TerminalSurface = @constCast(self);
        lockMutex(&surface.mutex);
        defer surface.mutex.unlock();
        const submitted = self.submitted_frame orelse {
            return if (prepared.requiresRetainedBase()) .missing_retained_base else .valid;
        };
        return pipeline.validatePreparedFrame(prepared, submitted);
    }

    fn acceptSubmitted(self: *TerminalSurface, frame: pipeline.SubmittedFrame) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.submitted_frame = frame;
        self.target_epoch = frame.target_epoch;
        self.dropPrepareAtOrBefore(frame.token);
        self.metrics.submitted_accepts +%= 1;
    }

    fn markPresented(self: *TerminalSurface) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.submitted_frame != null) self.metrics.presents +%= 1;
    }

    fn takeMetrics(self: *TerminalSurface) QueueMetrics {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const out = self.metrics;
        self.metrics = .{};
        return out;
    }

    fn prepareTokenForCurrentRetainedState(self: *const TerminalSurface, token: pipeline.SnapshotToken) pipeline.SnapshotToken {
        if (!token.requiresRetainedBase()) return token;
        const submitted = self.submitted_frame orelse return forceFull(token);
        if (!submitted.content_valid) return forceFull(token);
        if (submitted.token.geometry_epoch != token.geometry_epoch) return forceFull(token);
        if (submitted.token.snapshot_seq != token.damage_base_seq) return forceFull(token);
        return token;
    }

    fn forceFull(token: pipeline.SnapshotToken) pipeline.SnapshotToken {
        return .{
            .snapshot_seq = token.snapshot_seq,
            .dirty_epoch = token.dirty_epoch,
            .geometry_epoch = token.geometry_epoch,
            .damage_base_seq = 0,
            .damage_kind = .full,
        };
    }

    fn isStalePrepared(self: *const TerminalSurface, token: pipeline.SnapshotToken) bool {
        const surface: *TerminalSurface = @constCast(self);
        lockMutex(&surface.mutex);
        defer surface.mutex.unlock();
        const latest = self.latest_token orelse return false;
        return latest.isNewerThan(token);
    }

    fn dropPrepareAtOrBefore(self: *TerminalSurface, token: pipeline.SnapshotToken) void {
        self.prepare_mailbox.dropAtOrBefore(token);
    }

};

pub const VtSnapshot = struct {
    cols: u16,
    rows: u16,
    scrollback_offset: u64,
    snapshot_seq: u64,
    is_alternate_screen: bool,
    damage_kind: pipeline.DamageKind,
};

pub const VtPublishResult = struct {
    published: bool,
    queued: bool,
    damage_kind: pipeline.DamageKind,
    snapshot_seq: u64,
    geometry_epoch: u64,
};

pub const PendingState = struct {
    source_pending: bool,
    prepare_pending: bool,
    submit_pending: bool,
    target_valid: bool,
};

const Publication = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    scrollback_offset: u64 = 0,
    snapshot_seq: u64 = 0,
    is_alternate_screen: bool = false,
    damage_kind: pipeline.DamageKind = .none,

    fn copyFrom(self: *Publication, snapshot: VtSnapshot, damage_kind: pipeline.DamageKind) void {
        self.cols = snapshot.cols;
        self.rows = snapshot.rows;
        self.scrollback_offset = snapshot.scrollback_offset;
        self.snapshot_seq = snapshot.snapshot_seq;
        self.is_alternate_screen = snapshot.is_alternate_screen;
        self.damage_kind = damage_kind;
    }
};

const PublicationState = struct {
    publication: ?Publication = null,
    pending: bool = false,

    fn acceptSnapshot(self: *PublicationState, snapshot: VtSnapshot, geometry_epoch: u64) VtPublishResult {
        const damage_kind = self.classify(snapshot);
        const published = damage_kind != .none;
        if (published) {
            if (self.publication == null) self.publication = .{};
            self.publication.?.copyFrom(snapshot, damage_kind);
            self.pending = true;
        }
        return .{
            .published = published,
            .queued = self.pending,
            .damage_kind = damage_kind,
            .snapshot_seq = snapshot.snapshot_seq,
            .geometry_epoch = geometry_epoch,
        };
    }

    fn takePendingToken(self: *PublicationState, geometry_epoch: u64, submitted_token: ?pipeline.SnapshotToken) ?pipeline.SnapshotToken {
        if (!self.pending) return null;
        const publication = self.publication orelse return null;
        self.pending = false;
        return .{
            .snapshot_seq = publication.snapshot_seq,
            .dirty_epoch = publication.snapshot_seq,
            .geometry_epoch = geometry_epoch,
            .damage_base_seq = if (submitted_token) |token| token.snapshot_seq else 0,
            .damage_kind = publication.damage_kind,
        };
    }

    fn classify(self: *const PublicationState, snapshot: VtSnapshot) pipeline.DamageKind {
        const prior = self.publication orelse return snapshot.damage_kind;
        if (snapshot.snapshot_seq == prior.snapshot_seq) return .none;
        if (snapshot.cols != prior.cols or snapshot.rows != prior.rows) return .full;
        if (snapshot.is_alternate_screen != prior.is_alternate_screen) return .full;
        if (snapshot.scrollback_offset != prior.scrollback_offset) return .full;
        return snapshot.damage_kind;
    }
};

pub const Flow = struct {
    surface: TerminalSurface = .{},
    render_px: surface_types.PixelSize = .{ .width = 0, .height = 0 },
    grid_px: surface_types.PixelSize = .{ .width = 0, .height = 0 },
    cell_px: surface_types.CellSize = .{ .width = 0, .height = 0 },
    geometry_epoch: u64 = 0,
    publication_state: PublicationState = .{},

    pub fn acceptSnapshot(self: *Flow, snapshot: VtSnapshot) VtPublishResult {
        std.debug.assert(snapshot.cols > 0);
        std.debug.assert(snapshot.rows > 0);
        return self.publication_state.acceptSnapshot(snapshot, self.geometry_epoch);
    }

    pub fn syncGeometry(self: *Flow, layout: surface_types.Geometry) surface_types.GeometryResponse {
        const changed = self.geometry_epoch == 0 or
            self.render_px.width != layout.render_px.width or
            self.render_px.height != layout.render_px.height or
            self.grid_px.width != layout.grid_px.width or
            self.grid_px.height != layout.grid_px.height or
            self.cell_px.width != layout.cell_px.width or
            self.cell_px.height != layout.cell_px.height;
        if (changed) {
            self.geometry_epoch +%= 1;
            self.render_px = layout.render_px;
            self.grid_px = layout.grid_px;
            self.cell_px = layout.cell_px;
            self.surface.bindTargetEpoch(self.geometry_epoch);
        }
        return .{
            .changed = changed,
            .render_px = self.render_px,
            .grid_px = self.grid_px,
            .cell_px = self.cell_px,
            .geometry_epoch = self.geometry_epoch,
        };
    }

    pub fn prepare(self: *Flow) ?pipeline.RenderRequest {
        const submitted_token = blk: {
            lockMutex(&self.surface.mutex);
            defer self.surface.mutex.unlock();
            break :blk if (self.surface.submitted_frame) |frame| frame.token else null;
        };
        if (self.publication_state.takePendingToken(self.geometry_epoch, submitted_token)) |token| {
            self.surface.publishSnapshot(token);
        }
        return self.surface.takePrepare();
    }

    pub fn prepareLayout(self: *const Flow, geometry_epoch: u64) surface_types.PrepareLayout {
        std.debug.assert(self.geometry_epoch != 0);
        std.debug.assert(self.geometry_epoch == geometry_epoch);
        std.debug.assert(self.render_px.width > 0);
        std.debug.assert(self.render_px.height > 0);
        std.debug.assert(self.cell_px.width > 0);
        std.debug.assert(self.cell_px.height > 0);
        return .{
            .render_px = self.render_px,
            .cell_px = self.cell_px,
        };
    }

    pub fn publishPrepared(self: *Flow, prepared: pipeline.PreparedFrame) void {
        self.surface.publishPrepared(prepared);
    }

    pub fn submit(self: *Flow) SubmitDecision {
        return self.surface.takeValidatedSubmit();
    }

    pub fn acceptSubmitted(self: *Flow, frame: pipeline.SubmittedFrame) void {
        if (frame.token.geometry_epoch != self.geometry_epoch) {
            self.surface.requestFullPrepare(frame.token);
            return;
        }
        self.surface.acceptSubmitted(frame);
    }

    pub fn markPresented(self: *Flow) void {
        self.surface.markPresented();
    }

    pub fn pendingState(self: *const Flow) PendingState {
        const pending = blk: {
            const surface: *TerminalSurface = @constCast(&self.surface);
            lockMutex(&surface.mutex);
            defer surface.mutex.unlock();
            break :blk .{
                .prepare_pending = surface.prepare_mailbox.hasPending(),
                .submit_pending = surface.submit_mailbox.hasPending(),
                .target_valid = if (surface.submitted_frame) |frame| frame.content_valid else false,
            };
        };
        return .{
            .source_pending = self.publication_state.pending,
            .prepare_pending = pending.prepare_pending,
            .submit_pending = pending.submit_pending,
            .target_valid = pending.target_valid,
        };
    }

    pub fn takeMetrics(self: *Flow) QueueMetrics {
        return self.surface.takeMetrics();
    }
};

fn fullPrepareReason(validation: pipeline.SubmitValidation) pipeline.FullPrepareReason {
    return switch (validation) {
        .valid => unreachable,
        .stale_geometry => .geometry_changed,
        .missing_retained_base => .retained_base_missing,
        .stale_retained_base => .retained_base_stale,
        .stale_target => .target_changed,
    };
}

test "surface coalesces snapshots into latest prepare request" {
    var surface = TerminalSurface{};

    surface.publishSnapshot(.{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full });
    surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .full });

    const request = surface.takePrepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), request.token.snapshot_seq);
    try std.testing.expect(surface.takePrepare() == null);
    const metrics_snapshot = surface.takeMetrics();
    try std.testing.expectEqual(@as(u64, 2), metrics_snapshot.snapshot_publishes);
    try std.testing.expectEqual(@as(u64, 2), metrics_snapshot.prepare_requests);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.prepare_coalesces);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.prepare_takes);
}

test "surface turns partial snapshot full without matching retained base" {
    var surface = TerminalSurface{};
    surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial });

    const request = surface.takePrepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pipeline.DamageKind.full, request.token.damage_kind);
    try std.testing.expectEqual(@as(u64, 0), request.token.damage_base_seq);
    try std.testing.expectEqual(@as(u64, 1), surface.takeMetrics().prepare_forced_full);
}

test "surface preserves partial snapshot with matching retained base" {
    var surface = TerminalSurface{};
    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 3, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 9,
        .content_valid = true,
    });
    surface.bindTargetEpoch(9);

    surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 3, .damage_base_seq = 1, .damage_kind = .partial });

    const request = surface.takePrepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pipeline.DamageKind.partial, request.token.damage_kind);
    try std.testing.expectEqual(@as(u64, 1), request.token.damage_base_seq);
    try std.testing.expectEqual(@as(u64, 9), request.known_target_epoch);
}

test "surface turns partial snapshot full when retained content is invalid" {
    var surface = TerminalSurface{};
    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 3, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 9,
        .content_valid = false,
    });
    surface.bindTargetEpoch(9);

    surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 3, .damage_base_seq = 1, .damage_kind = .partial });

    const request = surface.takePrepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pipeline.DamageKind.full, request.token.damage_kind);
    try std.testing.expectEqual(@as(u64, 0), request.token.damage_base_seq);
    try std.testing.expectEqual(@as(u64, 9), request.known_target_epoch);
    try std.testing.expectEqual(@as(u64, 1), surface.takeMetrics().prepare_forced_full);
}

test "surface invalidates retained content when target epoch changes" {
    var surface = TerminalSurface{};
    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 7,
        .content_valid = true,
    });

    surface.bindTargetEpoch(8);
    surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial });

    const request = surface.takePrepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pipeline.DamageKind.full, request.token.damage_kind);
}

test "surface synchronous render consumes pending prepare action" {
    var surface = TerminalSurface{};
    surface.publishSnapshot(.{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full });

    const request = surface.takePrepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), request.token.snapshot_seq);
    try std.testing.expect(surface.takePrepare() == null);
}

test "surface validates submit candidates before GPU mutation" {
    var surface = TerminalSurface{};
    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 5,
        .content_valid = true,
    });
    surface.publishPrepared(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial },
        .required_base_seq = 1,
        .required_target_epoch = 5,
    });

    const decision = surface.takeValidatedSubmit();
    switch (decision) {
        .submit => |prepared| try std.testing.expectEqual(@as(u64, 2), prepared.token.snapshot_seq),
        else => return error.TestUnexpectedResult,
    }
    const metrics_snapshot = surface.takeMetrics();
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.prepared_publishes);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.submit_takes);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.submit_valid);
}

test "surface reports stale submit when newer snapshot already won" {
    var surface = TerminalSurface{};
    surface.publishSnapshot(.{ .snapshot_seq = 3, .dirty_epoch = 3, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full });
    surface.publishPrepared(.{ .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full } });

    const decision = surface.takeValidatedSubmit();
    switch (decision) {
        .stale => |token| try std.testing.expectEqual(@as(u64, 2), token.snapshot_seq),
        else => return error.TestUnexpectedResult,
    }
}

test "surface rejects stale submit and requests full latest prepare" {
    var surface = TerminalSurface{};
    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 5,
        .content_valid = true,
    });
    surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 2, .damage_kind = .partial });
    _ = surface.takePrepare();
    surface.publishPrepared(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 2, .damage_kind = .partial },
        .required_base_seq = 2,
        .required_target_epoch = 5,
    });

    const decision = surface.takeValidatedSubmit();
    switch (decision) {
        .needs_full_prepare => |reason| try std.testing.expectEqual(pipeline.FullPrepareReason.retained_base_stale, reason),
        else => return error.TestUnexpectedResult,
    }
    const request = surface.takePrepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), request.token.snapshot_seq);
    try std.testing.expectEqual(pipeline.DamageKind.full, request.token.damage_kind);
    const metrics_snapshot = surface.takeMetrics();
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.submit_rejected);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.full_prepare_requests);
}

test "surface drops pending prepare at submitted token" {
    var surface = TerminalSurface{};
    surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial });

    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 1,
        .content_valid = true,
    });

    try std.testing.expect(surface.takePrepare() == null);
}

test "surface metric drain keeps scheduling state" {
    var surface = TerminalSurface{};
    surface.publishSnapshot(.{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full });
    try std.testing.expectEqual(@as(u64, 1), surface.takeMetrics().prepare_requests);

    try std.testing.expect(surface.takePrepare() != null);
    try std.testing.expectEqual(@as(u64, 0), surface.takeMetrics().prepare_requests);
}

test "flow exposes source pending before queue preparation" {
    var flow = Flow{};
    _ = flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const first = flow.acceptSnapshot(.{
        .cols = 10,
        .rows = 10,
        .scrollback_offset = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .damage_kind = .full,
    });
    try std.testing.expect(first.published);
    try std.testing.expect(flow.pendingState().source_pending);
    try std.testing.expect(!flow.pendingState().prepare_pending);

    _ = flow.prepare().?;
    try std.testing.expect(!flow.pendingState().source_pending);
    try std.testing.expect(!flow.pendingState().prepare_pending);
}

test "flow preserves partial snapshot damage while prior snapshot is still pending" {
    var flow = Flow{};
    _ = flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    _ = flow.acceptSnapshot(.{
        .cols = 10,
        .rows = 10,
        .scrollback_offset = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .damage_kind = .full,
    });
    const second = flow.acceptSnapshot(.{
        .cols = 10,
        .rows = 10,
        .scrollback_offset = 0,
        .snapshot_seq = 2,
        .is_alternate_screen = false,
        .damage_kind = .partial,
    });
    try std.testing.expect(second.published);
    try std.testing.expectEqual(pipeline.DamageKind.partial, second.damage_kind);
}

test "flow forces full snapshot on viewport offset change" {
    var flow = Flow{};
    _ = flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    _ = flow.acceptSnapshot(.{
        .cols = 10,
        .rows = 10,
        .scrollback_offset = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .damage_kind = .full,
    });
    _ = flow.prepare();
    const second = flow.acceptSnapshot(.{
        .cols = 10,
        .rows = 10,
        .scrollback_offset = 1,
        .snapshot_seq = 2,
        .is_alternate_screen = false,
        .damage_kind = .partial,
    });
    try std.testing.expectEqual(pipeline.DamageKind.full, second.damage_kind);
}

test "flow drops clean snapshot" {
    var flow = Flow{};
    _ = flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    _ = flow.acceptSnapshot(.{
        .cols = 10,
        .rows = 10,
        .scrollback_offset = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .damage_kind = .full,
    });
    _ = flow.prepare();
    const second = flow.acceptSnapshot(.{
        .cols = 10,
        .rows = 10,
        .scrollback_offset = 0,
        .snapshot_seq = 2,
        .is_alternate_screen = false,
        .damage_kind = .none,
    });
    try std.testing.expect(!second.published);
    try std.testing.expectEqual(pipeline.DamageKind.none, second.damage_kind);
}
