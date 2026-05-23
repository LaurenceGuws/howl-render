const std = @import("std");
const abi = @import("../ffi_types.zig");
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
};

const TerminalSurface = struct {
    const SubmitMailbox = pipeline.LatestMailbox(pipeline.PreparedFrame);

    mutex: ThreadMutex = .{},
    submit_mailbox: SubmitMailbox = .{},
    submitted_frame: ?pipeline.SubmittedFrame = null,
    present_pending: bool = false,
    present_snapshot_seq: u64 = 0,
    metrics: QueueMetrics = .{},

    fn noteSnapshotPublish(self: *TerminalSurface, result: VtPublishResult, coalesced: bool) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (!result.published) {
            self.metrics.snapshot_clean_drops +%= 1;
            return;
        }
        self.metrics.snapshot_publishes +%= 1;
        self.metrics.prepare_requests +%= 1;
        if (coalesced) self.metrics.prepare_coalesces +%= 1;
    }

    fn notePrepareForcedFull(self: *TerminalSurface) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.metrics.prepare_forced_full +%= 1;
    }

    fn notePrepareTake(self: *TerminalSurface) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.metrics.prepare_takes +%= 1;
    }

    fn noteFullPrepareRequest(self: *TerminalSurface) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.metrics.full_prepare_requests +%= 1;
        self.metrics.prepare_requests +%= 1;
    }

    fn publishPrepared(self: *TerminalSurface, prepared: pipeline.PreparedFrame) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.submit_mailbox.hasPending()) self.metrics.prepared_coalesces +%= 1;
        self.metrics.prepared_publishes +%= 1;
        self.submit_mailbox.publish(prepared);
    }

    fn takeValidatedSubmitWithLatest(self: *TerminalSurface, latest_token: ?pipeline.SnapshotToken) SubmitDecision {
        lockMutex(&self.mutex);
        const prepared = self.submit_mailbox.takeLatest() orelse {
            self.mutex.unlock();
            return .idle;
        };
        self.metrics.submit_takes +%= 1;
        self.mutex.unlock();
        if (self.isStalePrepared(latest_token, prepared.token)) return .{ .stale = prepared.token };

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
        return .{ .needs_full_prepare = reason };
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
        self.present_pending = true;
        self.present_snapshot_seq = frame.token.snapshot_seq;
        self.metrics.submitted_accepts +%= 1;
    }

    fn retirePresented(self: *TerminalSurface) u64 {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (!self.present_pending) return 0;
        const snapshot_seq = self.present_snapshot_seq;
        std.debug.assert(snapshot_seq != 0);
        self.present_pending = false;
        self.present_snapshot_seq = 0;
        if (self.submitted_frame != null) self.metrics.presents +%= 1;
        return snapshot_seq;
    }

    fn takeMetrics(self: *TerminalSurface) QueueMetrics {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const out = self.metrics;
        self.metrics = .{};
        return out;
    }

    fn pendingState(self: *const TerminalSurface) struct {
        submit_pending: bool,
        present_pending: bool,
    } {
        const surface: *TerminalSurface = @constCast(self);
        lockMutex(&surface.mutex);
        defer surface.mutex.unlock();
        return .{
            .submit_pending = surface.submit_mailbox.hasPending(),
            .present_pending = surface.present_pending,
        };
    }

    fn prepareTokenForRetainedState(token: pipeline.SnapshotToken, submitted_token: ?pipeline.SnapshotToken) pipeline.SnapshotToken {
        if (!token.requiresRetainedBase()) return token;
        const submitted = submitted_token orelse return forceFull(token);
        if (submitted.geometry_epoch != token.geometry_epoch) return forceFull(token);
        if (submitted.snapshot_seq != token.damage_base_seq) return forceFull(token);
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

    fn isStalePrepared(self: *const TerminalSurface, latest_token: ?pipeline.SnapshotToken, token: pipeline.SnapshotToken) bool {
        _ = self;
        const latest = latest_token orelse return false;
        return latest.isNewerThan(token);
    }
};

pub const VtSnapshot = struct {
    cols: u16,
    rows: u16,
    scroll_row: u64,
    snapshot_seq: u64,
    dirty_epoch: u64,
    is_alternate_screen: bool,
    dirty_rows: []const u8,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
};

pub const PublicationSource = struct {
    cols: u16,
    rows: u16,
    scroll_row: u64,
    snapshot_seq: u64,
    dirty_epoch: u64,
    is_alternate_screen: bool,
    cells: []abi.FfiVtCell,
    cursor: surface_types.CursorInfo,
    selection: abi.FfiVtSelection,
    cursor_phase_visible: bool,
    dirty_rows: []u8 = &.{},
    dirty_cols_start: []u16 = &.{},
    dirty_cols_end: []u16 = &.{},
    retained_storage: bool = false,

    pub fn deinit(self: *PublicationSource, allocator: std.mem.Allocator) void {
        if (!self.retained_storage) {
            allocator.free(self.cells);
            if (self.dirty_rows.len > 0) allocator.free(self.dirty_rows);
            if (self.dirty_cols_start.len > 0) allocator.free(self.dirty_cols_start);
            if (self.dirty_cols_end.len > 0) allocator.free(self.dirty_cols_end);
        }
        self.* = undefined;
    }

    pub fn clone(self: *const PublicationSource, allocator: std.mem.Allocator) !PublicationSource {
        const cells = try allocator.dupe(abi.FfiVtCell, self.cells);
        errdefer allocator.free(cells);
        const dirty_rows = try allocator.dupe(u8, self.dirty_rows);
        errdefer allocator.free(dirty_rows);
        const dirty_cols_start = try allocator.dupe(u16, self.dirty_cols_start);
        errdefer allocator.free(dirty_cols_start);
        const dirty_cols_end = try allocator.dupe(u16, self.dirty_cols_end);
        errdefer allocator.free(dirty_cols_end);

        return .{
            .cols = self.cols,
            .rows = self.rows,
            .scroll_row = self.scroll_row,
            .snapshot_seq = self.snapshot_seq,
            .dirty_epoch = self.dirty_epoch,
            .is_alternate_screen = self.is_alternate_screen,
            .cells = cells,
            .cursor = self.cursor,
            .selection = self.selection,
            .cursor_phase_visible = self.cursor_phase_visible,
            .dirty_rows = dirty_rows,
            .dirty_cols_start = dirty_cols_start,
            .dirty_cols_end = dirty_cols_end,
            .retained_storage = false,
        };
    }

    pub fn snapshot(self: *const PublicationSource) VtSnapshot {
        return .{
            .cols = self.cols,
            .rows = self.rows,
            .scroll_row = self.scroll_row,
            .snapshot_seq = self.snapshot_seq,
            .dirty_epoch = self.dirty_epoch,
            .is_alternate_screen = self.is_alternate_screen,
            .dirty_rows = self.dirty_rows,
            .dirty_cols_start = self.dirty_cols_start,
            .dirty_cols_end = self.dirty_cols_end,
        };
    }
};

pub const VtPublishResult = struct {
    published: bool,
    queued: bool,
    damage_kind: pipeline.DamageKind,
    snapshot_seq: u64,
    geometry_epoch: u64,
};

pub const PublicationSlot = struct {
    cells: []abi.FfiVtCell,
    dirty_rows: []u8,
    dirty_cols_start: []u16,
    dirty_cols_end: []u16,
};

pub const ReservedSourceMeta = struct {
    scroll_row: u64,
    snapshot_seq: u64,
    is_alternate_screen: bool,
    cursor: surface_types.CursorInfo,
    selection: abi.FfiVtSelection,
};

pub const PendingState = struct {
    source_pending: bool,
    prepare_pending: bool,
    submit_pending: bool,
    present_pending: bool,
};

pub const PrepareConsume = struct {
    request: pipeline.RenderRequest,
    layout: surface_types.PrepareLayout,
    state: PublicationSource,
};

const Publication = struct {
    source: PublicationSource,
    damage_kind: pipeline.DamageKind = .none,

    fn deinit(self: *Publication, allocator: std.mem.Allocator) void {
        self.source.deinit(allocator);
        self.* = undefined;
    }
};

const ActivePrepare = struct {
    publication: Publication,
    request: pipeline.RenderRequest,
    taken: bool = false,

    fn deinit(self: *ActivePrepare, allocator: std.mem.Allocator) void {
        self.publication.deinit(allocator);
        self.* = undefined;
    }
};

const PublicationState = struct {
    const RetainedSlot = struct {
        cells: []abi.FfiVtCell = &.{},
        dirty_rows: []u8 = &.{},
        dirty_cols_start: []u16 = &.{},
        dirty_cols_end: []u16 = &.{},
        cols_capacity: u16 = 0,
        rows_capacity: u16 = 0,

        fn deinit(self: *RetainedSlot, allocator: std.mem.Allocator) void {
            if (self.cells.len > 0) allocator.free(self.cells);
            if (self.dirty_rows.len > 0) allocator.free(self.dirty_rows);
            if (self.dirty_cols_start.len > 0) allocator.free(self.dirty_cols_start);
            if (self.dirty_cols_end.len > 0) allocator.free(self.dirty_cols_end);
            self.* = .{};
        }

        fn ensureCapacity(self: *RetainedSlot, allocator: std.mem.Allocator, cols: u16, rows: u16) !void {
            std.debug.assert(cols > 0);
            std.debug.assert(rows > 0);
            if (self.cols_capacity >= cols and self.rows_capacity >= rows) return;

            const cell_count = slotCellCount(cols, rows);
            const cells = try allocator.alloc(abi.FfiVtCell, cell_count);
            errdefer allocator.free(cells);
            const dirty_rows = try allocator.alloc(u8, rows);
            errdefer allocator.free(dirty_rows);
            const dirty_cols_start = try allocator.alloc(u16, rows);
            errdefer allocator.free(dirty_cols_start);
            const dirty_cols_end = try allocator.alloc(u16, rows);
            errdefer allocator.free(dirty_cols_end);

            self.deinit(allocator);
            self.cells = cells;
            self.dirty_rows = dirty_rows;
            self.dirty_cols_start = dirty_cols_start;
            self.dirty_cols_end = dirty_cols_end;
            self.cols_capacity = cols;
            self.rows_capacity = rows;
        }

        fn canHold(self: *const RetainedSlot, cols: u16, rows: u16) bool {
            return self.cols_capacity >= cols and self.rows_capacity >= rows;
        }

        fn publicationSlot(self: *const RetainedSlot, cols: u16, rows: u16) PublicationSlot {
            std.debug.assert(self.canHold(cols, rows));
            return .{
                .cells = self.cells[0..slotCellCount(cols, rows)],
                .dirty_rows = self.dirty_rows[0..rows],
                .dirty_cols_start = self.dirty_cols_start[0..rows],
                .dirty_cols_end = self.dirty_cols_end[0..rows],
            };
        }
    };

    allocator: std.mem.Allocator,
    retained_slot: RetainedSlot = .{},
    reserved: ?PublicationSource = null,
    pending: ?Publication = null,
    active: ?ActivePrepare = null,
    blink_refresh_pending: bool = false,

    fn init(allocator: std.mem.Allocator) PublicationState {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *PublicationState) void {
        if (self.reserved) |*source| source.deinit(self.allocator);
        self.reserved = null;
        if (self.pending) |*publication| publication.deinit(self.allocator);
        self.pending = null;
        if (self.active) |*active| active.deinit(self.allocator);
        self.active = null;
        self.blink_refresh_pending = false;
        self.retained_slot.deinit(self.allocator);
    }

    fn syncReservedSlotCapacity(self: *PublicationState, cols: u16, rows: u16) !void {
        std.debug.assert(cols > 0);
        std.debug.assert(rows > 0);
        try self.retained_slot.ensureCapacity(self.allocator, cols, rows);
        self.refreshRetainedSlotViews();
    }

    fn reserveSourceSlot(self: *PublicationState, cols: u16, rows: u16) !PublicationSlot {
        std.debug.assert(cols > 0);
        std.debug.assert(rows > 0);
        if (self.reserved != null) return error.PublishSlotBusy;
        if (self.retainedSlotInUse()) return error.PublishSlotBusy;
        if (!self.retained_slot.canHold(cols, rows)) return error.PublishSlotOutOfRange;

        self.reserved = self.retainedSource(cols, rows);
        return self.retained_slot.publicationSlot(cols, rows);
    }

    fn cancelReservedSource(self: *PublicationState) void {
        self.reserved = null;
    }

    fn commitReservedSource(self: *PublicationState, meta: ReservedSourceMeta, dirty_epoch: u64, submitted_token: ?pipeline.SnapshotToken, geometry_epoch: u64) !VtPublishResult {
        var source = self.reserved orelse return error.MissingPublishSlot;
        self.reserved = null;
        source.scroll_row = meta.scroll_row;
        source.snapshot_seq = meta.snapshot_seq;
        source.dirty_epoch = dirty_epoch;
        source.is_alternate_screen = meta.is_alternate_screen;
        source.cursor = meta.cursor;
        source.selection = meta.selection;
        return self.acceptSource(source, submitted_token, geometry_epoch);
    }

    fn acceptSource(self: *PublicationState, source: PublicationSource, submitted_token: ?pipeline.SnapshotToken, geometry_epoch: u64) VtPublishResult {
        const snapshot = source.snapshot();
        const damage_kind = self.classify(source, submitted_token);
        const published = damage_kind != .none;
        if (!published) {
            var dropped = source;
            dropped.deinit(self.allocator);
        } else {
            var queued_source = source;
            if (source.retained_storage) {
                queued_source = source.clone(self.allocator) catch {
                    var dropped = source;
                    dropped.deinit(self.allocator);
                    return .{
                        .published = false,
                        .queued = false,
                        .damage_kind = .none,
                        .snapshot_seq = snapshot.snapshot_seq,
                        .geometry_epoch = geometry_epoch,
                    };
                };
            }
            self.replacePending(.{ .source = queued_source, .damage_kind = damage_kind });
        }
        return .{
            .published = published,
            .queued = published,
            .damage_kind = damage_kind,
            .snapshot_seq = snapshot.snapshot_seq,
            .geometry_epoch = geometry_epoch,
        };
    }

    fn takePrepareRequest(self: *PublicationState, geometry_epoch: u64, submitted_token: ?pipeline.SnapshotToken) ?pipeline.RenderRequest {
        if (self.active == null or (self.active.?.taken and self.pending != null)) {
            self.blink_refresh_pending = false;
            self.activatePending(geometry_epoch, submitted_token);
        }
        const active = self.active orelse return null;
        if (active.taken) {
            if (!self.blink_refresh_pending) return null;
            self.blink_refresh_pending = false;
            const prior_token = self.active.?.request.token;
            self.active.?.request = .{
                .token = .{
                    .snapshot_seq = prior_token.snapshot_seq,
                    .dirty_epoch = prior_token.dirty_epoch,
                    .geometry_epoch = geometry_epoch,
                    .damage_base_seq = 0,
                    .damage_kind = .full,
                },
                .allow_retained_reuse = false,
            };
        }
        self.active.?.taken = true;
        return self.active.?.request;
    }

    fn consumePrepare(self: *PublicationState, layout: surface_types.PrepareLayout, token: pipeline.SnapshotToken) !PrepareConsume {
        const active = self.active orelse return error.MissingPublishedSource;
        if (!sameSnapshotToken(active.request.token, token)) return error.MismatchedPublishedSource;
        return .{
            .request = active.request,
            .layout = layout,
            .state = active.publication.source,
        };
    }

    fn latestToken(self: *const PublicationState) ?pipeline.SnapshotToken {
        if (self.pending) |publication| {
            return .{
                .snapshot_seq = publication.source.snapshot_seq,
                .dirty_epoch = publication.source.dirty_epoch,
                .geometry_epoch = 0,
                .damage_base_seq = 0,
                .damage_kind = publication.damage_kind,
            };
        }
        if (self.active) |active| return active.request.token;
        return null;
    }

    fn requestFullPrepare(self: *PublicationState) bool {
        if (self.pending != null) {
            self.dropActive();
            return false;
        }
        if (self.active == null) return false;
        self.active.?.request = .{
            .token = TerminalSurface.forceFull(self.active.?.request.token),
            .allow_retained_reuse = false,
        };
        self.active.?.taken = false;
        return true;
    }

    fn setCursorBlinkVisible(self: *PublicationState, visible: bool) bool {
        var changed = false;
        if (self.reserved) |*source| changed = setSourceCursorBlinkVisible(source, visible) or changed;
        if (self.pending) |*publication| changed = setSourceCursorBlinkVisible(&publication.source, visible) or changed;
        if (self.active) |*active| changed = setSourceCursorBlinkVisible(&active.publication.source, visible) or changed;
        return changed;
    }

    fn requestBlinkRefresh(self: *PublicationState) void {
        if (self.pending != null) return;
        const active = self.active orelse return;
        if (!active.taken) return;
        self.blink_refresh_pending = true;
    }

    fn retireAtOrBefore(self: *PublicationState, token: pipeline.SnapshotToken) void {
        if (self.pending) |*publication| {
            if (publication.source.snapshot_seq <= token.snapshot_seq) {
                publication.deinit(self.allocator);
                self.pending = null;
            }
        }
        if (self.active) |*active| {
            if (!active.request.token.isNewerThan(token)) {
                active.deinit(self.allocator);
                self.active = null;
            }
        }
    }

    fn retirePendingAtOrBefore(self: *PublicationState, token: pipeline.SnapshotToken) void {
        if (self.pending) |*publication| {
            if (publication.source.snapshot_seq <= token.snapshot_seq) {
                publication.deinit(self.allocator);
                self.pending = null;
            }
        }
    }

    fn sourcePending(self: *const PublicationState) bool {
        return self.pending != null or self.reserved != null;
    }

    fn preparePending(self: *const PublicationState) bool {
        if (self.blink_refresh_pending) return true;
        if (self.active) |active| return !active.taken;
        return false;
    }

    fn replacePending(self: *PublicationState, publication: Publication) void {
        if (self.pending) |*prior| prior.deinit(self.allocator);
        self.pending = publication;
        self.blink_refresh_pending = false;
    }

    fn dropActive(self: *PublicationState) void {
        if (self.active) |*active| active.deinit(self.allocator);
        self.active = null;
        self.blink_refresh_pending = false;
    }

    fn activatePending(self: *PublicationState, geometry_epoch: u64, submitted_token: ?pipeline.SnapshotToken) void {
        const publication = self.pending orelse return;
        self.pending = null;
        const token = pipeline.SnapshotToken{
            .snapshot_seq = publication.source.snapshot_seq,
            .dirty_epoch = publication.source.dirty_epoch,
            .geometry_epoch = geometry_epoch,
            .damage_base_seq = if (submitted_token) |token_value| token_value.snapshot_seq else 0,
            .damage_kind = publication.damage_kind,
        };
        self.dropActive();
        self.active = .{
            .publication = publication,
            .request = .{ .token = token, .allow_retained_reuse = true },
        };
    }

    fn classify(self: *const PublicationState, source: PublicationSource, submitted_token: ?pipeline.SnapshotToken) pipeline.DamageKind {
        const snapshot = source.snapshot();
        const damage_kind = classifyDirty(snapshot);
        const prior = self.priorSource() orelse return damage_kind;
        const prior_snapshot = prior.snapshot();
        const prior_matches_submitted = if (submitted_token) |token|
            prior_snapshot.snapshot_seq == token.snapshot_seq
        else
            false;
        if (snapshot.snapshot_seq == prior_snapshot.snapshot_seq) {
            if (samePublicationSource(prior, source)) return .none;
            if (cursorPresentationChanged(prior, source)) return .full;
            if (damage_kind == .partial and !prior_matches_submitted) return .full;
            return damage_kind;
        }
        if (cursorPresentationChanged(prior, source)) return .full;
        if (snapshot.cols != prior_snapshot.cols or snapshot.rows != prior_snapshot.rows) return .full;
        if (snapshot.is_alternate_screen != prior_snapshot.is_alternate_screen) return .full;
        if (snapshot.scroll_row != prior_snapshot.scroll_row) return .full;
        if (damage_kind == .partial and !prior_matches_submitted) return .full;
        return damage_kind;
    }

    fn priorSource(self: *const PublicationState) ?PublicationSource {
        if (self.reserved) |source| {
            if (source.snapshot_seq != 0) return source;
        }
        if (self.pending) |publication| return publication.source;
        if (self.active) |active| return active.publication.source;
        return null;
    }

    fn retainedSource(self: *const PublicationState, cols: u16, rows: u16) PublicationSource {
        const slot = self.retained_slot.publicationSlot(cols, rows);
        return .{
            .cols = cols,
            .rows = rows,
            .scroll_row = 0,
            .snapshot_seq = 0,
            .dirty_epoch = 0,
            .is_alternate_screen = false,
            .cells = slot.cells,
            .cursor = std.mem.zeroes(surface_types.CursorInfo),
            .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
            .cursor_phase_visible = true,
            .dirty_rows = slot.dirty_rows,
            .dirty_cols_start = slot.dirty_cols_start,
            .dirty_cols_end = slot.dirty_cols_end,
            .retained_storage = true,
        };
    }

    fn retainedSlotInUse(self: *const PublicationState) bool {
        if (self.reserved) |source| if (source.retained_storage) return true;
        if (self.pending) |publication| if (publication.source.retained_storage) return true;
        if (self.active) |active| if (active.publication.source.retained_storage) return true;
        return false;
    }

    fn refreshRetainedSlotViews(self: *PublicationState) void {
        if (self.reserved) |*source| {
            if (source.retained_storage) self.refreshRetainedSource(source);
        }
        if (self.pending) |*publication| {
            if (publication.source.retained_storage) self.refreshRetainedSource(&publication.source);
        }
        if (self.active) |*active| {
            if (active.publication.source.retained_storage) self.refreshRetainedSource(&active.publication.source);
        }
    }

    fn refreshRetainedSource(self: *PublicationState, source: *PublicationSource) void {
        const scroll_row = source.scroll_row;
        const snapshot_seq = source.snapshot_seq;
        const dirty_epoch = source.dirty_epoch;
        const is_alternate_screen = source.is_alternate_screen;
        const cursor = source.cursor;
        const selected = source.selection;
        const cursor_phase_visible = source.cursor_phase_visible;
        source.* = self.retainedSource(source.cols, source.rows);
        source.scroll_row = scroll_row;
        source.snapshot_seq = snapshot_seq;
        source.dirty_epoch = dirty_epoch;
        source.is_alternate_screen = is_alternate_screen;
        source.cursor = cursor;
        source.selection = selected;
        source.cursor_phase_visible = cursor_phase_visible;
    }
};

fn cursorPresentationChanged(prior: PublicationSource, current: PublicationSource) bool {
    if (prior.cursor.visible != current.cursor.visible) return true;
    if (prior.cursor.row != current.cursor.row or prior.cursor.col != current.cursor.col) return true;
    if (prior.cursor.shape != current.cursor.shape) return true;
    if (prior.cursor.blink != current.cursor.blink) return true;
    if ((prior.cursor.blink or current.cursor.blink) and prior.cursor_phase_visible != current.cursor_phase_visible) return true;
    return false;
}

fn setSourceCursorBlinkVisible(source: *PublicationSource, visible: bool) bool {
    if (!source.cursor.blink or source.cursor_phase_visible == visible) return false;
    source.cursor_phase_visible = visible;
    return true;
}

fn slotCellCount(cols: u16, rows: u16) usize {
    return @as(usize, cols) * @as(usize, rows);
}

fn sameSnapshotToken(a: pipeline.SnapshotToken, b: pipeline.SnapshotToken) bool {
    return a.snapshot_seq == b.snapshot_seq and
        a.dirty_epoch == b.dirty_epoch and
        a.geometry_epoch == b.geometry_epoch and
        a.damage_base_seq == b.damage_base_seq and
        a.damage_kind == b.damage_kind;
}

fn samePublicationSource(a: PublicationSource, b: PublicationSource) bool {
    return a.cols == b.cols and
        a.rows == b.rows and
        a.scroll_row == b.scroll_row and
        a.snapshot_seq == b.snapshot_seq and
        a.is_alternate_screen == b.is_alternate_screen and
        std.mem.eql(u8, std.mem.asBytes(&a.selection), std.mem.asBytes(&b.selection)) and
        a.cursor_phase_visible == b.cursor_phase_visible and
        a.cursor.row == b.cursor.row and
        a.cursor.col == b.cursor.col and
        a.cursor.visible == b.cursor.visible and
        a.cursor.shape == b.cursor.shape and
        a.cursor.blink == b.cursor.blink and
        std.mem.eql(u8, std.mem.sliceAsBytes(a.cells), std.mem.sliceAsBytes(b.cells)) and
        std.mem.eql(u8, a.dirty_rows, b.dirty_rows) and
        std.mem.eql(u16, a.dirty_cols_start, b.dirty_cols_start) and
        std.mem.eql(u16, a.dirty_cols_end, b.dirty_cols_end);
}

fn classifyDirty(snapshot: VtSnapshot) pipeline.DamageKind {
    std.debug.assert(snapshot.dirty_rows.len == snapshot.rows);
    std.debug.assert(snapshot.dirty_cols_start.len == snapshot.rows);
    std.debug.assert(snapshot.dirty_cols_end.len == snapshot.rows);
    var any_dirty = false;
    var all_rows_dirty = snapshot.rows != 0;
    var row: u16 = 0;
    while (row < snapshot.rows) : (row += 1) {
        if (snapshot.dirty_rows[row] == 0) {
            all_rows_dirty = false;
            continue;
        }
        any_dirty = true;
        if (snapshot.dirty_cols_start[row] != 0) {
            all_rows_dirty = false;
        }
        if (snapshot.dirty_cols_end[row] != snapshot.cols -| 1) {
            all_rows_dirty = false;
        }
    }
    if (!any_dirty) return .none;
    if (all_rows_dirty) return .full;
    return .partial;
}

fn testSnapshot(
    rows: u16,
    cols: u16,
    scroll_row: u64,
    snapshot_seq: u64,
    dirty_rows: []const u8,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
) VtSnapshot {
    return .{
        .cols = cols,
        .rows = rows,
        .scroll_row = scroll_row,
        .snapshot_seq = snapshot_seq,
        .dirty_epoch = snapshot_seq,
        .is_alternate_screen = false,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

pub const Flow = struct {
    surface: TerminalSurface = .{},
    allocator: std.mem.Allocator,
    render_px: surface_types.PixelSize = .{ .width = 0, .height = 0 },
    grid_px: surface_types.PixelSize = .{ .width = 0, .height = 0 },
    cell_px: surface_types.CellSize = .{ .width = 0, .height = 0 },
    geometry_epoch: u64 = 0,
    source_dirty_epoch: u64 = 0,
    cursor_blink_visible: bool = true,
    publication_state: PublicationState,

    pub fn init(allocator: std.mem.Allocator) Flow {
        return .{ .allocator = allocator, .publication_state = PublicationState.init(allocator) };
    }

    pub fn deinit(self: *Flow) void {
        self.publication_state.deinit();
    }

    pub fn acceptSource(self: *Flow, source: PublicationSource) VtPublishResult {
        var owned = source;
        std.debug.assert(owned.cols > 0);
        std.debug.assert(owned.rows > 0);
        owned.dirty_epoch = self.nextSourceDirtyEpoch();
        owned.cursor_phase_visible = self.cursor_blink_visible;
        const had_queued_publication = self.publication_state.pending != null or self.publication_state.active != null;
        const result = self.publication_state.acceptSource(owned, self.submittedToken(), self.geometry_epoch);
        self.surface.noteSnapshotPublish(result, had_queued_publication and result.published);
        return result;
    }

    pub fn setCursorBlinkVisible(self: *Flow, visible: bool) bool {
        if (self.cursor_blink_visible == visible) return false;
        self.cursor_blink_visible = visible;
        if (self.publication_state.setCursorBlinkVisible(visible)) {
            self.publication_state.requestBlinkRefresh();
        }
        return true;
    }

    pub fn reservePublishSlot(self: *Flow, cols: u16, rows: u16) !PublicationSlot {
        std.debug.assert(cols > 0);
        std.debug.assert(rows > 0);
        return try self.publication_state.reserveSourceSlot(cols, rows);
    }

    pub fn commitPublishSlot(self: *Flow, meta: ReservedSourceMeta) !VtPublishResult {
        std.debug.assert(meta.snapshot_seq != 0);
        const had_queued_publication = self.publication_state.pending != null or self.publication_state.active != null;
        const result = try self.publication_state.commitReservedSource(meta, self.nextSourceDirtyEpoch(), self.submittedToken(), self.geometry_epoch);
        self.surface.noteSnapshotPublish(result, had_queued_publication and result.published);
        return result;
    }

    pub fn cancelPublishSlot(self: *Flow) void {
        self.publication_state.cancelReservedSource();
    }

    pub fn rejectPublishSlot(self: *Flow, snapshot_seq: u64) VtPublishResult {
        std.debug.assert(snapshot_seq != 0);
        self.publication_state.cancelReservedSource();
        return .{
            .published = false,
            .queued = false,
            .damage_kind = .none,
            .snapshot_seq = snapshot_seq,
            .geometry_epoch = self.geometry_epoch,
        };
    }

    pub fn acceptSnapshot(self: *Flow, snapshot: VtSnapshot) VtPublishResult {
        const source = testSourceFromSnapshot(self.allocator, snapshot) catch unreachable;
        return self.acceptSource(source);
    }

    pub fn syncGeometry(self: *Flow, layout: surface_types.Geometry) !surface_types.GeometryResponse {
        const changed = self.geometry_epoch == 0 or
            self.render_px.width != layout.render_px.width or
            self.render_px.height != layout.render_px.height or
            self.grid_px.width != layout.grid_px.width or
            self.grid_px.height != layout.grid_px.height or
            self.cell_px.width != layout.cell_px.width or
            self.cell_px.height != layout.cell_px.height;
        if (changed) {
            const cols = @max(1, @divTrunc(layout.grid_px.width, @max(layout.cell_px.width, 1)));
            const rows = @max(1, @divTrunc(layout.grid_px.height, @max(layout.cell_px.height, 1)));
            try self.publication_state.syncReservedSlotCapacity(cols, rows);
            self.geometry_epoch +%= 1;
            self.render_px = layout.render_px;
            self.grid_px = layout.grid_px;
            self.cell_px = layout.cell_px;
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
        const request = self.publication_state.takePrepareRequest(self.geometry_epoch, submitted_token) orelse return null;
        const effective_token = TerminalSurface.prepareTokenForRetainedState(request.token, submitted_token);
        if (effective_token.damage_kind == .full and request.token.damage_kind != .full) self.surface.notePrepareForcedFull();
        if (!sameSnapshotToken(effective_token, request.token)) {
            self.publication_state.active.?.request = .{ .token = effective_token, .allow_retained_reuse = request.allow_retained_reuse };
        }
        self.surface.notePrepareTake();
        return self.publication_state.active.?.request;
    }

    pub fn consumePrepare(self: *Flow, token: pipeline.SnapshotToken) !PrepareConsume {
        const layout = self.prepareLayout(token.geometry_epoch);
        return self.publication_state.consumePrepare(layout, token);
    }

    fn prepareLayout(self: *const Flow, geometry_epoch: u64) surface_types.PrepareLayout {
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
        const decision = self.surface.takeValidatedSubmitWithLatest(self.publication_state.latestToken());
        switch (decision) {
            .stale => |token| self.publication_state.retireAtOrBefore(token),
            .needs_full_prepare => {
                if (self.publication_state.requestFullPrepare()) self.surface.noteFullPrepareRequest();
            },
            else => {},
        }
        return decision;
    }

    pub fn acceptSubmitted(self: *Flow, frame: pipeline.SubmittedFrame) void {
        if (frame.token.geometry_epoch != self.geometry_epoch) {
            if (self.publication_state.requestFullPrepare()) self.surface.noteFullPrepareRequest();
            return;
        }
        self.publication_state.retirePendingAtOrBefore(frame.token);
        self.surface.acceptSubmitted(frame);
    }

    pub fn retirePresented(self: *Flow) u64 {
        return self.surface.retirePresented();
    }

    pub fn pendingState(self: *const Flow) PendingState {
        const pending = self.surface.pendingState();
        return .{
            .source_pending = self.publication_state.sourcePending(),
            .prepare_pending = self.publication_state.preparePending(),
            .submit_pending = pending.submit_pending,
            .present_pending = pending.present_pending,
        };
    }

    pub fn takeMetrics(self: *Flow) QueueMetrics {
        return self.surface.takeMetrics();
    }

    fn nextSourceDirtyEpoch(self: *Flow) u64 {
        self.source_dirty_epoch +%= 1;
        if (self.source_dirty_epoch == 0) self.source_dirty_epoch = 1;
        return self.source_dirty_epoch;
    }

    fn submittedToken(self: *Flow) ?pipeline.SnapshotToken {
        lockMutex(&self.surface.mutex);
        defer self.surface.mutex.unlock();
        return if (self.surface.submitted_frame) |frame| frame.token else null;
    }
};

fn testSourceFromSnapshot(allocator: std.mem.Allocator, snapshot: VtSnapshot) !PublicationSource {
    const cell_count: u32 = @as(u32, snapshot.cols) * @as(u32, snapshot.rows);
    const cells = try allocator.alloc(abi.FfiVtCell, @intCast(cell_count));
    @memset(cells, std.mem.zeroes(abi.FfiVtCell));
    const dirty_rows = try allocator.alloc(u8, snapshot.rows);
    errdefer allocator.free(dirty_rows);
    for (dirty_rows, 0..) |*dst, i| dst.* = snapshot.dirty_rows[i];
    const dirty_cols_start = try allocator.dupe(u16, snapshot.dirty_cols_start);
    errdefer allocator.free(dirty_cols_start);
    const dirty_cols_end = try allocator.dupe(u16, snapshot.dirty_cols_end);
    errdefer allocator.free(dirty_cols_end);
    return .{
        .cols = snapshot.cols,
        .rows = snapshot.rows,
        .scroll_row = snapshot.scroll_row,
        .snapshot_seq = snapshot.snapshot_seq,
        .dirty_epoch = snapshot.dirty_epoch,
        .is_alternate_screen = snapshot.is_alternate_screen,
        .cells = cells,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

fn ownedTestSource(allocator: std.mem.Allocator, snapshot_seq: u64, codepoint: u21) !PublicationSource {
    const cells = try allocator.alloc(abi.FfiVtCell, 1);
    cells[0] = std.mem.zeroes(abi.FfiVtCell);
    cells[0].codepoint = codepoint;
    const dirty_rows = try allocator.alloc(u8, 1);
    dirty_rows[0] = 1;
    const dirty_cols_start = try allocator.dupe(u16, &[_]u16{0});
    errdefer allocator.free(dirty_cols_start);
    const dirty_cols_end = try allocator.dupe(u16, &[_]u16{0});
    errdefer allocator.free(dirty_cols_end);
    return .{
        .cols = 1,
        .rows = 1,
        .scroll_row = 0,
        .snapshot_seq = snapshot_seq,
        .dirty_epoch = snapshot_seq,
        .is_alternate_screen = false,
        .cells = cells,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

fn fullPrepareReason(validation: pipeline.SubmitValidation) pipeline.FullPrepareReason {
    return switch (validation) {
        .valid => unreachable,
        .stale_geometry => .geometry_changed,
        .missing_retained_base => .retained_base_missing,
        .stale_retained_base => .retained_base_stale,
    };
}

test "surface validates submit candidates before GPU mutation" {
    var surface = TerminalSurface{};
    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });
    surface.publishPrepared(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial },
        .required_base_seq = 1,
    });

    const decision = surface.takeValidatedSubmitWithLatest(null);
    switch (decision) {
        .submit => |prepared| try std.testing.expectEqual(@as(u64, 2), prepared.token.snapshot_seq),
        else => return error.TestUnexpectedResult,
    }
    const metrics_snapshot = surface.takeMetrics();
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.prepared_publishes);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.submit_takes);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.submit_valid);
}

test "surface retires presented snapshot identity once" {
    var surface = TerminalSurface{};
    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 7, .dirty_epoch = 7, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });

    try std.testing.expectEqual(@as(u64, 7), surface.retirePresented());
    try std.testing.expectEqual(@as(u64, 0), surface.retirePresented());
}

test "surface reports stale submit when newer snapshot already won" {
    var surface = TerminalSurface{};
    surface.publishPrepared(.{ .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full } });

    const decision = surface.takeValidatedSubmitWithLatest(.{ .snapshot_seq = 3, .dirty_epoch = 3, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full });
    switch (decision) {
        .stale => |token| try std.testing.expectEqual(@as(u64, 2), token.snapshot_seq),
        else => return error.TestUnexpectedResult,
    }
}

test "flow keeps blink refresh out of source publication queue" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    var source = try ownedTestSource(std.heap.c_allocator, 7, 'A');
    source.cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .beam, .blink = true };
    const first = flow.acceptSource(source);
    try std.testing.expect(first.published);
    const first_request = flow.prepare() orelse return error.TestUnexpectedResult;
    flow.acceptSubmitted(.{ .token = first_request.token });

    try std.testing.expect(flow.setCursorBlinkVisible(false));
    const second_request = flow.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 7), second_request.token.snapshot_seq);
    try std.testing.expectEqual(pipeline.DamageKind.full, second_request.token.damage_kind);
    try std.testing.expectEqual(first_request.token.dirty_epoch, second_request.token.dirty_epoch);
    const pending = flow.pendingState();
    try std.testing.expect(!pending.source_pending);
}

test "flow redraws blinking cursor phase without a fresh vt source" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    var source = try ownedTestSource(std.heap.c_allocator, 9, 'A');
    source.cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .beam, .blink = true };
    _ = flow.acceptSource(source);

    const first_request = flow.prepare() orelse return error.TestUnexpectedResult;
    flow.acceptSubmitted(.{ .token = first_request.token });

    try std.testing.expect(flow.setCursorBlinkVisible(false));
    try std.testing.expect(flow.pendingState().prepare_pending);
    try std.testing.expect(!flow.pendingState().source_pending);

    const second_request = flow.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 9), second_request.token.snapshot_seq);
    try std.testing.expectEqual(pipeline.DamageKind.full, second_request.token.damage_kind);
    try std.testing.expectEqual(first_request.token.dirty_epoch, second_request.token.dirty_epoch);

    const prepare = try flow.consumePrepare(second_request.token);
    try std.testing.expect(!prepare.state.cursor_phase_visible);
    try std.testing.expect(prepare.state.cursor.blink);
}

test "new vt source supersedes pending blink refresh" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    var source = try ownedTestSource(std.heap.c_allocator, 2, 'A');
    source.cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .beam, .blink = true };
    _ = flow.acceptSource(source);
    const first_request = flow.prepare() orelse return error.TestUnexpectedResult;
    flow.acceptSubmitted(.{ .token = first_request.token });

    try std.testing.expect(flow.setCursorBlinkVisible(false));

    source = try ownedTestSource(std.heap.c_allocator, 3, 'B');
    source.cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .beam, .blink = true };
    const published = flow.acceptSource(source);
    try std.testing.expect(published.published);

    const request = flow.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 3), request.token.snapshot_seq);
    const prepare = try flow.consumePrepare(request.token);
    try std.testing.expectEqual(@as(u32, 'B'), prepare.state.cells[0].codepoint);
    try std.testing.expect(!prepare.state.cursor_phase_visible);
}

test "cursor movement republishes clean later vt snapshot" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 16, .height = 16 },
        .grid_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    const dirty = [_]u8{1};
    const dirty_start = [_]u16{0};
    const dirty_end = [_]u16{1};
    _ = flow.acceptSnapshot(testSnapshot(2, 1, 0, 2, &dirty, &dirty_start, &dirty_end));
    _ = flow.prepare() orelse return error.TestUnexpectedResult;

    const clean_cells = try std.heap.c_allocator.alloc(abi.FfiVtCell, 2);
    clean_cells[0] = std.mem.zeroes(abi.FfiVtCell);
    clean_cells[0].codepoint = 'A';
    clean_cells[1] = std.mem.zeroes(abi.FfiVtCell);
    clean_cells[1].codepoint = 'B';
    const clean_dirty_rows = try std.heap.c_allocator.dupe(u8, &[_]u8{0});
    const clean_dirty_start = try std.heap.c_allocator.dupe(u16, &[_]u16{0});
    const clean_dirty_end = try std.heap.c_allocator.dupe(u16, &[_]u16{0});
    const clean_source = PublicationSource{
        .cols = 2,
        .rows = 1,
        .scroll_row = 0,
        .snapshot_seq = 3,
        .dirty_epoch = 3,
        .is_alternate_screen = false,
        .cells = clean_cells,
        .cursor = .{ .visible = true, .row = 0, .col = 1, .shape = .beam, .blink = false },
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = clean_dirty_rows,
        .dirty_cols_start = clean_dirty_start,
        .dirty_cols_end = clean_dirty_end,
    };

    const published = flow.acceptSource(clean_source);
    try std.testing.expect(published.published);
    try std.testing.expectEqual(pipeline.DamageKind.full, published.damage_kind);
}

test "cursor shape change republishes clean later vt snapshot" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    var first = try ownedTestSource(std.heap.c_allocator, 2, 'A');
    first.cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .block, .blink = false };
    _ = flow.acceptSource(first);
    _ = flow.prepare() orelse return error.TestUnexpectedResult;

    var second = try ownedTestSource(std.heap.c_allocator, 3, 'A');
    second.dirty_rows[0] = 0;
    second.dirty_cols_start[0] = 0;
    second.dirty_cols_end[0] = 0;
    second.cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .beam, .blink = false };

    const published = flow.acceptSource(second);
    try std.testing.expect(published.published);
    try std.testing.expectEqual(pipeline.DamageKind.full, published.damage_kind);
}

test "flow coalesces snapshots into latest prepare request" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });
    const dirty_rows = [_]u8{1} ** 10;
    const dirty_cols_start = [_]u16{0} ** 10;
    const dirty_cols_end = [_]u16{9} ** 10;

    _ = flow.acceptSnapshot(testSnapshot(10, 10, 0, 1, &dirty_rows, &dirty_cols_start, &dirty_cols_end));
    _ = flow.acceptSnapshot(testSnapshot(10, 10, 0, 2, &dirty_rows, &dirty_cols_start, &dirty_cols_end));

    const request = flow.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), request.token.snapshot_seq);
    try std.testing.expect(flow.prepare() == null);
    const metrics_snapshot = flow.takeMetrics();
    try std.testing.expectEqual(@as(u64, 2), metrics_snapshot.snapshot_publishes);
    try std.testing.expectEqual(@as(u64, 2), metrics_snapshot.prepare_requests);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.prepare_coalesces);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.prepare_takes);
}

test "flow turns partial snapshot full without retained base" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });
    const dirty_rows = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 0, 0 };
    const dirty_cols_start = [_]u16{ 0, 0, 0, 0, 3, 0, 0, 0, 0, 0 };
    const dirty_cols_end = [_]u16{ 0, 0, 0, 0, 5, 0, 0, 0, 0, 0 };

    _ = flow.acceptSnapshot(testSnapshot(10, 10, 0, 2, &dirty_rows, &dirty_cols_start, &dirty_cols_end));
    const request = flow.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pipeline.DamageKind.full, request.token.damage_kind);
    try std.testing.expectEqual(@as(u64, 0), request.token.damage_base_seq);
    const metrics_snapshot = flow.takeMetrics();
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.prepare_forced_full);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.prepare_takes);
}

test "flow rejects stale submit and requests full latest prepare" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });
    const dirty_rows = [_]u8{1} ** 10;
    const dirty_cols_start = [_]u16{0} ** 10;
    const dirty_cols_end = [_]u16{9} ** 10;

    flow.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });
    _ = flow.acceptSnapshot(testSnapshot(10, 10, 0, 2, &dirty_rows, &dirty_cols_start, &dirty_cols_end));
    _ = flow.prepare();
    flow.publishPrepared(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 2, .damage_kind = .partial },
        .required_base_seq = 2,
    });

    const decision = flow.submit();
    switch (decision) {
        .needs_full_prepare => |reason| try std.testing.expectEqual(pipeline.FullPrepareReason.retained_base_stale, reason),
        else => return error.TestUnexpectedResult,
    }
    const request = flow.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), request.token.snapshot_seq);
    try std.testing.expectEqual(pipeline.DamageKind.full, request.token.damage_kind);
    const metrics_snapshot = flow.takeMetrics();
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.submit_rejected);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.full_prepare_requests);
}

test "flow drops pending prepare at submitted token" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });
    const dirty_rows = [_]u8{1} ** 10;
    const dirty_cols_start = [_]u16{0} ** 10;
    const dirty_cols_end = [_]u16{9} ** 10;
    _ = flow.acceptSnapshot(testSnapshot(10, 10, 0, 2, &dirty_rows, &dirty_cols_start, &dirty_cols_end));

    flow.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });

    try std.testing.expect(flow.prepare() == null);
}

test "flow exposes source pending before queue preparation" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });
    const dirty_rows = [_]u8{1} ** 10;
    const dirty_cols_start = [_]u16{0} ** 10;
    const dirty_cols_end = [_]u16{9} ** 10;

    const first = flow.acceptSnapshot(testSnapshot(10, 10, 0, 1, &dirty_rows, &dirty_cols_start, &dirty_cols_end));
    try std.testing.expect(first.published);
    try std.testing.expect(flow.pendingState().source_pending);
    try std.testing.expect(!flow.pendingState().prepare_pending);

    _ = flow.prepare().?;
    try std.testing.expect(!flow.pendingState().source_pending);
    try std.testing.expect(!flow.pendingState().prepare_pending);
}

test "flow reject publish slot clears reserved source" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    const geometry = try flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    _ = try flow.reservePublishSlot(1, 1);
    try std.testing.expect(flow.pendingState().source_pending);

    const result = flow.rejectPublishSlot(7);
    try std.testing.expectEqual(false, result.published);
    try std.testing.expectEqual(false, result.queued);
    try std.testing.expectEqual(pipeline.DamageKind.none, result.damage_kind);
    try std.testing.expectEqual(@as(u64, 7), result.snapshot_seq);
    try std.testing.expectEqual(geometry.geometry_epoch, result.geometry_epoch);
    try std.testing.expect(!flow.pendingState().source_pending);
}

test "flow reuses retained publish slot storage across reservations" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const first = try flow.reservePublishSlot(1, 1);
    const first_cells = first.cells.ptr;
    const first_dirty_rows = first.dirty_rows.ptr;
    const first_dirty_cols_start = first.dirty_cols_start.ptr;
    const first_dirty_cols_end = first.dirty_cols_end.ptr;
    flow.cancelPublishSlot();

    const second = try flow.reservePublishSlot(1, 1);
    try std.testing.expectEqual(first_cells, second.cells.ptr);
    try std.testing.expectEqual(first_dirty_rows, second.dirty_rows.ptr);
    try std.testing.expectEqual(first_dirty_cols_start, second.dirty_cols_start.ptr);
    try std.testing.expectEqual(first_dirty_cols_end, second.dirty_cols_end.ptr);
}

test "flow can reserve a new publish slot after submitting retained source" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 1, .height = 1 },
        .grid_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const first = try flow.reservePublishSlot(1, 1);
    first.cells[0] = std.mem.zeroes(abi.FfiVtCell);
    first.cells[0].codepoint = 'A';
    first.dirty_rows[0] = 1;
    first.dirty_cols_start[0] = 0;
    first.dirty_cols_end[0] = 0;

    const published = try flow.commitPublishSlot(.{
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
    });
    try std.testing.expect(published.published);

    const request = flow.prepare() orelse return error.TestUnexpectedResult;
    flow.acceptSubmitted(.{ .token = request.token });

    _ = try flow.reservePublishSlot(1, 1);
}

test "flow keeps latest source when publish A then B before prepare" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 1, .height = 1 },
        .grid_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    _ = flow.acceptSource(try ownedTestSource(std.heap.c_allocator, 1, 'A'));
    _ = flow.acceptSource(try ownedTestSource(std.heap.c_allocator, 2, 'B'));

    const request = flow.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), request.token.snapshot_seq);
    const prepare = try flow.consumePrepare(request.token);
    try std.testing.expectEqual(@as(u64, 2), prepare.request.token.snapshot_seq);
    try std.testing.expectEqual(@as(u32, 'B'), prepare.state.cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 1), prepare.layout.render_px.width);
}

test "flow rejects mismatched prepare token against retained source" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 1, .height = 1 },
        .grid_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    _ = flow.acceptSource(try ownedTestSource(std.heap.c_allocator, 1, 'A'));
    const request_a = flow.prepare() orelse return error.TestUnexpectedResult;
    _ = flow.acceptSource(try ownedTestSource(std.heap.c_allocator, 2, 'B'));

    const prepare_a = try flow.consumePrepare(request_a.token);
    try std.testing.expectEqual(@as(u32, 'A'), prepare_a.state.cells[0].codepoint);

    var wrong = request_a.token;
    wrong.snapshot_seq = 2;
    try std.testing.expectError(error.MismatchedPublishedSource, flow.consumePrepare(wrong));
}

test "flow forces full snapshot damage while prior snapshot is still pending" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });
    const full_dirty_rows = [_]u8{1} ** 10;
    const full_dirty_cols_start = [_]u16{0} ** 10;
    const full_dirty_cols_end = [_]u16{9} ** 10;
    const partial_dirty_rows = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 0, 0 };
    const partial_dirty_cols_start = [_]u16{ 0, 0, 0, 0, 3, 0, 0, 0, 0, 0 };
    const partial_dirty_cols_end = [_]u16{ 0, 0, 0, 0, 5, 0, 0, 0, 0, 0 };

    _ = flow.acceptSnapshot(testSnapshot(10, 10, 0, 1, &full_dirty_rows, &full_dirty_cols_start, &full_dirty_cols_end));
    const second = flow.acceptSnapshot(testSnapshot(10, 10, 0, 2, &partial_dirty_rows, &partial_dirty_cols_start, &partial_dirty_cols_end));
    try std.testing.expect(second.published);
    try std.testing.expectEqual(pipeline.DamageKind.full, second.damage_kind);
}

test "flow forces full snapshot on scroll row change" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });
    const full_dirty_rows = [_]u8{1} ** 10;
    const full_dirty_cols_start = [_]u16{0} ** 10;
    const full_dirty_cols_end = [_]u16{9} ** 10;
    const partial_dirty_rows = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 0, 0 };
    const partial_dirty_cols_start = [_]u16{ 0, 0, 0, 0, 3, 0, 0, 0, 0, 0 };
    const partial_dirty_cols_end = [_]u16{ 0, 0, 0, 0, 5, 0, 0, 0, 0, 0 };

    _ = flow.acceptSnapshot(testSnapshot(10, 10, 0, 1, &full_dirty_rows, &full_dirty_cols_start, &full_dirty_cols_end));
    _ = flow.prepare();
    const second = flow.acceptSnapshot(testSnapshot(10, 10, 1, 2, &partial_dirty_rows, &partial_dirty_cols_start, &partial_dirty_cols_end));
    try std.testing.expectEqual(pipeline.DamageKind.full, second.damage_kind);
}

test "flow drops clean snapshot" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 10, .height = 10 },
        .grid_px = .{ .width = 10, .height = 10 },
        .cell_px = .{ .width = 1, .height = 1 },
    });
    const full_dirty_rows = [_]u8{1} ** 10;
    const full_dirty_cols_start = [_]u16{0} ** 10;
    const full_dirty_cols_end = [_]u16{9} ** 10;
    const clean_dirty_rows = [_]u8{0} ** 10;
    const clean_dirty_cols_start = [_]u16{0} ** 10;
    const clean_dirty_cols_end = [_]u16{0} ** 10;

    _ = flow.acceptSnapshot(testSnapshot(10, 10, 0, 1, &full_dirty_rows, &full_dirty_cols_start, &full_dirty_cols_end));
    _ = flow.prepare();
    const second = flow.acceptSnapshot(testSnapshot(10, 10, 0, 2, &clean_dirty_rows, &clean_dirty_cols_start, &clean_dirty_cols_end));
    try std.testing.expect(!second.published);
    try std.testing.expectEqual(pipeline.DamageKind.none, second.damage_kind);
}
