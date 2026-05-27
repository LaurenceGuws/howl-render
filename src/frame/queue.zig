const std = @import("std");
const abi = @import("../ffi_types.zig");
const graphics_log = @import("../graphics_log.zig");
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

const TerminalSurface = struct {
    const SubmitMailbox = pipeline.LatestMailbox(pipeline.PreparedFrame);

    mutex: ThreadMutex = .{},
    submit_mailbox: SubmitMailbox = .{},
    submitted_frame: ?pipeline.SubmittedFrame = null,

    fn publishPrepared(self: *TerminalSurface, prepared: pipeline.PreparedFrame) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.submit_mailbox.publish(prepared);
    }

    fn takeValidatedSubmitWithLatest(self: *TerminalSurface, latest_token: ?pipeline.SnapshotToken) SubmitDecision {
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
        std.debug.assert(frame.token.snapshot_seq != 0);
        self.submitted_frame = frame;
    }

    fn pendingState(self: *const TerminalSurface) struct {
        submit_pending: bool,
    } {
        const surface: *TerminalSurface = @constCast(self);
        lockMutex(&surface.mutex);
        defer surface.mutex.unlock();
        return .{
            .submit_pending = surface.submit_mailbox.hasPending(),
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
    history_count: u64,
    scroll_row: u64,
    snapshot_seq: u64,
    dirty_epoch: u64,
    is_alternate_screen: bool,
    graphics_publication_seq: u64,
    graphics_dirty_generation: u64,
    graphics_image_count: u32,
    graphics_placement_count: u32,
    graphics_virtual_placement_count: u32,
    graphics_placeholder_run_count: u32,
    graphics_is_alternate_screen: bool,
    dirty_rows: []const u8,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
};

pub const PublicationSource = struct {
    cols: u16,
    rows: u16,
    history_count: u64,
    scroll_row: u64,
    snapshot_seq: u64,
    dirty_epoch: u64,
    is_alternate_screen: bool,
    cells: []abi.FfiVtCell,
    cursor: surface_types.CursorInfo,
    colors: abi.FfiVtRenderColorState,
    selection: abi.FfiVtSelection,
    graphics: abi.FfiVtGraphicsMeta,
    graphics_images: []abi.FfiVtGraphicsImage = &.{},
    graphics_placements: []abi.FfiVtGraphicsPlacement = &.{},
    graphics_virtual_placements: []abi.FfiVtGraphicsVirtualPlacement = &.{},
    graphics_placeholder_runs: []abi.FfiVtGraphicsPlaceholderRun = &.{},
    graphics_payload_bytes: []u8 = &.{},
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
        if (self.graphics_images.len > 0) allocator.free(self.graphics_images);
        if (self.graphics_placements.len > 0) allocator.free(self.graphics_placements);
        if (self.graphics_virtual_placements.len > 0) allocator.free(self.graphics_virtual_placements);
        if (self.graphics_placeholder_runs.len > 0) allocator.free(self.graphics_placeholder_runs);
        if (self.graphics_payload_bytes.len > 0) allocator.free(self.graphics_payload_bytes);
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
        const graphics_images = try allocator.dupe(abi.FfiVtGraphicsImage, self.graphics_images);
        errdefer allocator.free(graphics_images);
        const graphics_placements = try allocator.dupe(abi.FfiVtGraphicsPlacement, self.graphics_placements);
        errdefer allocator.free(graphics_placements);
        const graphics_virtual_placements = try allocator.dupe(abi.FfiVtGraphicsVirtualPlacement, self.graphics_virtual_placements);
        errdefer allocator.free(graphics_virtual_placements);
        const graphics_placeholder_runs = try allocator.dupe(abi.FfiVtGraphicsPlaceholderRun, self.graphics_placeholder_runs);
        errdefer allocator.free(graphics_placeholder_runs);
        const graphics_payload_bytes = try allocator.dupe(u8, self.graphics_payload_bytes);
        errdefer allocator.free(graphics_payload_bytes);

        return .{
            .cols = self.cols,
            .rows = self.rows,
            .history_count = self.history_count,
            .scroll_row = self.scroll_row,
            .snapshot_seq = self.snapshot_seq,
            .dirty_epoch = self.dirty_epoch,
            .is_alternate_screen = self.is_alternate_screen,
            .cells = cells,
            .cursor = self.cursor,
            .colors = self.colors,
            .selection = self.selection,
            .graphics = self.graphics,
            .graphics_images = graphics_images,
            .graphics_placements = graphics_placements,
            .graphics_virtual_placements = graphics_virtual_placements,
            .graphics_placeholder_runs = graphics_placeholder_runs,
            .graphics_payload_bytes = graphics_payload_bytes,
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
            .history_count = self.history_count,
            .scroll_row = self.scroll_row,
            .snapshot_seq = self.snapshot_seq,
            .dirty_epoch = self.dirty_epoch,
            .is_alternate_screen = self.is_alternate_screen,
            .graphics_publication_seq = self.graphics.publication_seq,
            .graphics_dirty_generation = self.graphics.dirty_generation,
            .graphics_image_count = self.graphics.image_count,
            .graphics_placement_count = self.graphics.placement_count,
            .graphics_virtual_placement_count = self.graphics.virtual_placement_count,
            .graphics_placeholder_run_count = self.graphics.placeholder_run_count,
            .graphics_is_alternate_screen = self.graphics.is_alternate_screen != 0,
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
    history_count: u64,
    scroll_row: u64,
    snapshot_seq: u64,
    is_alternate_screen: bool,
    cursor: surface_types.CursorInfo,
    colors: abi.FfiVtRenderColorState,
    selection: abi.FfiVtSelection,
    graphics: abi.FfiVtGraphicsMeta,
    graphics_images: []const abi.FfiVtGraphicsImage = &.{},
    graphics_placements: []const abi.FfiVtGraphicsPlacement = &.{},
    graphics_virtual_placements: []const abi.FfiVtGraphicsVirtualPlacement = &.{},
    graphics_placeholder_runs: []const abi.FfiVtGraphicsPlaceholderRun = &.{},
    graphics_payload_bytes: []const u8 = &.{},
};

pub const PendingState = struct {
    source_pending: bool,
    prepare_pending: bool,
    submit_pending: bool,
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
        source.history_count = meta.history_count;
        source.snapshot_seq = meta.snapshot_seq;
        source.dirty_epoch = dirty_epoch;
        source.is_alternate_screen = meta.is_alternate_screen;
        source.cursor = meta.cursor;
        source.colors = meta.colors;
        source.selection = meta.selection;
        source.graphics = meta.graphics;
        if (hasGraphics(meta.graphics) or meta.graphics_payload_bytes.len != 0) {
            graphics_log.event(
                "render-publish-copy",
                "snapshot_seq={d} dirty_epoch={d} publication_seq={d} graphics_dirty={d} images={d} placements={d} virtuals={d} placeholders={d} payload_len={d} alt={d}",
                .{
                    meta.snapshot_seq,
                    dirty_epoch,
                    meta.graphics.publication_seq,
                    meta.graphics.dirty_generation,
                    meta.graphics.image_count,
                    meta.graphics.placement_count,
                    meta.graphics.virtual_placement_count,
                    meta.graphics.placeholder_run_count,
                    meta.graphics_payload_bytes.len,
                    meta.graphics.is_alternate_screen,
                },
            );
        }
        try validateDirtySource(source.rows, source.cols, source.dirty_rows, source.dirty_cols_start, source.dirty_cols_end);
        try validateGraphicsSource(
            meta.is_alternate_screen,
            meta.graphics,
            meta.graphics_images,
            meta.graphics_placements,
            meta.graphics_virtual_placements,
            meta.graphics_placeholder_runs,
            meta.graphics_payload_bytes,
        );
        try validatePlaceholderRunBounds(source.rows, source.cols, meta.graphics_placeholder_runs);
        source.graphics_images = try self.allocator.dupe(abi.FfiVtGraphicsImage, meta.graphics_images);
        errdefer self.allocator.free(source.graphics_images);
        source.graphics_placements = try self.allocator.dupe(abi.FfiVtGraphicsPlacement, meta.graphics_placements);
        errdefer self.allocator.free(source.graphics_placements);
        source.graphics_virtual_placements = try self.allocator.dupe(abi.FfiVtGraphicsVirtualPlacement, meta.graphics_virtual_placements);
        errdefer self.allocator.free(source.graphics_virtual_placements);
        source.graphics_placeholder_runs = try self.allocator.dupe(abi.FfiVtGraphicsPlaceholderRun, meta.graphics_placeholder_runs);
        errdefer self.allocator.free(source.graphics_placeholder_runs);
        source.graphics_payload_bytes = try self.allocator.dupe(u8, meta.graphics_payload_bytes);
        errdefer self.allocator.free(source.graphics_payload_bytes);
        return self.acceptSource(source, submitted_token, geometry_epoch);
    }

    fn acceptSource(self: *PublicationState, source: PublicationSource, submitted_token: ?pipeline.SnapshotToken, geometry_epoch: u64) VtPublishResult {
        canonicalizeDirtyMetadata(source.rows, source.dirty_rows, source.dirty_cols_start, source.dirty_cols_end);
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

    fn retryTakenPrepare(self: *PublicationState, token: pipeline.SnapshotToken) bool {
        if (self.pending != null) return false;
        const active = if (self.active) |*active| active else return false;
        if (!active.taken) return false;
        if (!sameSnapshotToken(active.request.token, token)) return false;
        active.taken = false;
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
            .damage_base_seq = if (publication.damage_kind == .partial)
                if (submitted_token) |token_value| token_value.snapshot_seq else 0
            else
                0,
            .damage_kind = publication.damage_kind,
        };
        self.dropActive();
        self.active = .{
            .publication = publication,
            .request = .{ .token = token, .allow_retained_reuse = true },
        };
        if (hasGraphics(publication.source.graphics) or publication.source.graphics_payload_bytes.len != 0) {
            graphics_log.event(
                "render-prepare-activate",
                "snapshot_seq={d} dirty_epoch={d} damage={s} base_seq={d} publication_seq={d} graphics_dirty={d} images={d} placements={d} virtuals={d} placeholders={d} payload_len={d}",
                .{
                    token.snapshot_seq,
                    token.dirty_epoch,
                    @tagName(token.damage_kind),
                    token.damage_base_seq,
                    publication.source.graphics.publication_seq,
                    publication.source.graphics.dirty_generation,
                    publication.source.graphics.image_count,
                    publication.source.graphics.placement_count,
                    publication.source.graphics.virtual_placement_count,
                    publication.source.graphics.placeholder_run_count,
                    publication.source.graphics_payload_bytes.len,
                },
            );
        }
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
            if (colorPresentationChanged(prior, source)) return .full;
            if (graphicsPublicationChanged(prior, source)) return .full;
            if (damage_kind == .partial and !prior_matches_submitted) return .full;
            return damage_kind;
        }
        if (cursorPresentationChanged(prior, source)) return .full;
        if (colorPresentationChanged(prior, source)) return .full;
        if (graphicsPublicationChanged(prior, source)) return .full;
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
            .history_count = 0,
            .scroll_row = 0,
            .snapshot_seq = 0,
            .dirty_epoch = 0,
            .is_alternate_screen = false,
            .cells = slot.cells,
            .cursor = std.mem.zeroes(surface_types.CursorInfo),
            .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
            .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
            .graphics = std.mem.zeroes(abi.FfiVtGraphicsMeta),
            .graphics_images = &.{},
            .graphics_placements = &.{},
            .graphics_virtual_placements = &.{},
            .graphics_placeholder_runs = &.{},
            .graphics_payload_bytes = &.{},
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
        const history_count = source.history_count;
        const snapshot_seq = source.snapshot_seq;
        const dirty_epoch = source.dirty_epoch;
        const is_alternate_screen = source.is_alternate_screen;
        const cursor = source.cursor;
        const colors = source.colors;
        const selected = source.selection;
        const graphics = source.graphics;
        const graphics_images = source.graphics_images;
        const graphics_placements = source.graphics_placements;
        const graphics_virtual_placements = source.graphics_virtual_placements;
        const graphics_placeholder_runs = source.graphics_placeholder_runs;
        const graphics_payload_bytes = source.graphics_payload_bytes;
        const cursor_phase_visible = source.cursor_phase_visible;
        source.* = self.retainedSource(source.cols, source.rows);
        source.history_count = history_count;
        source.scroll_row = scroll_row;
        source.snapshot_seq = snapshot_seq;
        source.dirty_epoch = dirty_epoch;
        source.is_alternate_screen = is_alternate_screen;
        source.cursor = cursor;
        source.colors = colors;
        source.selection = selected;
        source.graphics = graphics;
        source.graphics_images = graphics_images;
        source.graphics_placements = graphics_placements;
        source.graphics_virtual_placements = graphics_virtual_placements;
        source.graphics_placeholder_runs = graphics_placeholder_runs;
        source.graphics_payload_bytes = graphics_payload_bytes;
        source.cursor_phase_visible = cursor_phase_visible;
    }
};

fn validateGraphicsSource(
    publication_is_alternate_screen: bool,
    meta: abi.FfiVtGraphicsMeta,
    images: []const abi.FfiVtGraphicsImage,
    placements: []const abi.FfiVtGraphicsPlacement,
    virtual_placements: []const abi.FfiVtGraphicsVirtualPlacement,
    placeholder_runs: []const abi.FfiVtGraphicsPlaceholderRun,
    payload_bytes: []const u8,
) !void {
    if (meta.is_alternate_screen > 1) return error.InvalidGraphicsMetadata;
    if ((meta.is_alternate_screen != 0) != publication_is_alternate_screen) return error.InvalidGraphicsMetadata;
    if (meta.image_count != images.len) return error.InvalidGraphicsMetadata;
    if (meta.placement_count != placements.len) return error.InvalidGraphicsMetadata;
    if (meta.virtual_placement_count != virtual_placements.len) return error.InvalidGraphicsMetadata;
    if (meta.placeholder_run_count != placeholder_runs.len) return error.InvalidGraphicsMetadata;
    if (placeholder_runs.len != 0 and hasGeneratedPlaceholderPlacement(placements)) return error.InvalidGraphicsMetadata;
    try validateGraphicsReferences(images, placements, virtual_placements, placeholder_runs);
    try validateGraphicsPayloadSource(images, payload_bytes);
}

pub fn hasGeneratedPlaceholderPlacement(placements: []const abi.FfiVtGraphicsPlacement) bool {
    for (placements) |placement| {
        if (placement.flags & abi.HOWL_VT_GRAPHICS_PLACEMENT_GENERATED_PLACEHOLDER != 0) return true;
    }
    return false;
}

fn validateGraphicsReferences(
    images: []const abi.FfiVtGraphicsImage,
    placements: []const abi.FfiVtGraphicsPlacement,
    virtual_placements: []const abi.FfiVtGraphicsVirtualPlacement,
    placeholder_runs: []const abi.FfiVtGraphicsPlaceholderRun,
) !void {
    for (placements) |placement| {
        if (!graphicsImageExists(images, placement.image_id)) return error.InvalidGraphicsMetadata;
    }
    for (virtual_placements) |placement| {
        if (!graphicsImageExists(images, placement.image_id)) return error.InvalidGraphicsMetadata;
        if (placement.source_width == 0) return error.InvalidGraphicsMetadata;
        if (placement.source_height == 0) return error.InvalidGraphicsMetadata;
        if (placement.columns == 0) return error.InvalidGraphicsMetadata;
        if (placement.rows == 0) return error.InvalidGraphicsMetadata;
    }
    for (placeholder_runs, 0..) |run, idx| {
        if (run.columns == 0) return error.InvalidGraphicsMetadata;
        const virtual_placement_count = std.math.cast(u32, virtual_placements.len) orelse return error.InvalidGraphicsMetadata;
        if (run.virtual_placement_index >= virtual_placement_count) return error.InvalidGraphicsMetadata;
        if (run.run_order != std.math.cast(u32, idx) orelse return error.InvalidGraphicsMetadata) return error.InvalidGraphicsMetadata;
        const virtual_placement = virtual_placements[run.virtual_placement_index];
        if (run.image_id != virtual_placement.image_id) return error.InvalidGraphicsMetadata;
        if (run.placement_id != virtual_placement.placement_id) return error.InvalidGraphicsMetadata;
    }
}

fn validatePlaceholderRunBounds(rows: u16, cols: u16, placeholder_runs: []const abi.FfiVtGraphicsPlaceholderRun) !void {
    for (placeholder_runs) |run| {
        if (run.cell_row >= rows) return error.InvalidGraphicsMetadata;
        if (run.cell_col >= cols) return error.InvalidGraphicsMetadata;
        const end_col = std.math.add(u32, run.cell_col, run.columns) catch return error.InvalidGraphicsMetadata;
        if (end_col > @as(u32, cols)) return error.InvalidGraphicsMetadata;
    }
}

fn graphicsImageExists(images: []const abi.FfiVtGraphicsImage, image_id: u32) bool {
    for (images) |image| {
        if (image.image_id == image_id) return true;
    }
    return false;
}

fn validateGraphicsPayloadSource(images: []const abi.FfiVtGraphicsImage, payload_bytes: []const u8) !void {
    const total = try totalGraphicsPayloadLen(images);
    if (total != payload_bytes.len) return error.InvalidGraphicsPayload;
}

fn totalGraphicsPayloadLen(images: []const abi.FfiVtGraphicsImage) !usize {
    var total: u64 = 0;
    for (images) |image| {
        total = std.math.add(u64, total, image.payload_len) catch return error.InvalidGraphicsPayload;
    }
    return std.math.cast(usize, total) orelse return error.InvalidGraphicsPayload;
}

pub fn validatePublicationSourceBoundary(source: PublicationSource) !void {
    if (source.cols == 0) return error.InvalidSurfaceSource;
    if (source.rows == 0) return error.InvalidSurfaceSource;
    const cell_count = slotCellCountChecked(source.cols, source.rows) catch return error.InvalidSurfaceSource;
    if (source.cells.len != cell_count) return error.InvalidSurfaceSource;
    try validateDirtySource(source.rows, source.cols, source.dirty_rows, source.dirty_cols_start, source.dirty_cols_end);
    try validateGraphicsSource(
        source.is_alternate_screen,
        source.graphics,
        source.graphics_images,
        source.graphics_placements,
        source.graphics_virtual_placements,
        source.graphics_placeholder_runs,
        source.graphics_payload_bytes,
    );
    try validatePlaceholderRunBounds(source.rows, source.cols, source.graphics_placeholder_runs);
}

fn validateDirtySource(
    rows: u16,
    cols: u16,
    dirty_rows: []const u8,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
) !void {
    if (dirty_rows.len != rows) return error.InvalidSurfaceSource;
    if (dirty_cols_start.len != rows) return error.InvalidSurfaceSource;
    if (dirty_cols_end.len != rows) return error.InvalidSurfaceSource;

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const dirty = dirty_rows[row];
        const start_col = dirty_cols_start[row];
        const end_col = dirty_cols_end[row];
        if (dirty == 0) {
            continue;
        }
        if (dirty != 1) return error.InvalidSurfaceSource;
        if (start_col == cols and end_col == 0) continue;
        if (start_col >= cols) return error.InvalidSurfaceSource;
        if (end_col >= cols) return error.InvalidSurfaceSource;
        if (end_col < start_col) return error.InvalidSurfaceSource;
    }
}

fn canonicalizeDirtyMetadata(
    rows: u16,
    dirty_rows: []const u8,
    dirty_cols_start: []u16,
    dirty_cols_end: []u16,
) void {
    std.debug.assert(dirty_rows.len == rows);
    std.debug.assert(dirty_cols_start.len == rows);
    std.debug.assert(dirty_cols_end.len == rows);

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        if (dirty_rows[row] != 0) continue;
        dirty_cols_start[row] = 0;
        dirty_cols_end[row] = 0;
    }
}

fn cursorPresentationChanged(prior: PublicationSource, current: PublicationSource) bool {
    if (prior.cursor.visible != current.cursor.visible) return true;
    if (prior.cursor.row != current.cursor.row or prior.cursor.col != current.cursor.col) return true;
    if (prior.cursor.shape != current.cursor.shape) return true;
    if (prior.cursor.blink != current.cursor.blink) return true;
    if ((prior.cursor.blink or current.cursor.blink) and prior.cursor_phase_visible != current.cursor_phase_visible) return true;
    return false;
}

fn colorPresentationChanged(prior: PublicationSource, current: PublicationSource) bool {
    return !std.mem.eql(u8, std.mem.asBytes(&prior.colors), std.mem.asBytes(&current.colors));
}

fn graphicsPublicationChanged(prior: PublicationSource, current: PublicationSource) bool {
    return !std.mem.eql(u8, std.mem.asBytes(&prior.graphics), std.mem.asBytes(&current.graphics));
}

fn hasGraphics(meta: abi.FfiVtGraphicsMeta) bool {
    return meta.image_count != 0 or
        meta.placement_count != 0 or
        meta.virtual_placement_count != 0 or
        meta.placeholder_run_count != 0;
}

fn setSourceCursorBlinkVisible(source: *PublicationSource, visible: bool) bool {
    if (!source.cursor.blink or source.cursor_phase_visible == visible) return false;
    source.cursor_phase_visible = visible;
    return true;
}

fn slotCellCount(cols: u16, rows: u16) usize {
    return @as(usize, cols) * @as(usize, rows);
}

fn slotCellCountChecked(cols: u16, rows: u16) !usize {
    return std.math.mul(usize, cols, rows);
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
        a.history_count == b.history_count and
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
        std.mem.eql(u8, std.mem.asBytes(&a.colors), std.mem.asBytes(&b.colors)) and
        std.mem.eql(u8, std.mem.asBytes(&a.graphics), std.mem.asBytes(&b.graphics)) and
        std.mem.eql(u8, std.mem.sliceAsBytes(a.graphics_images), std.mem.sliceAsBytes(b.graphics_images)) and
        std.mem.eql(u8, std.mem.sliceAsBytes(a.graphics_placements), std.mem.sliceAsBytes(b.graphics_placements)) and
        std.mem.eql(u8, std.mem.sliceAsBytes(a.graphics_virtual_placements), std.mem.sliceAsBytes(b.graphics_virtual_placements)) and
        std.mem.eql(u8, std.mem.sliceAsBytes(a.graphics_placeholder_runs), std.mem.sliceAsBytes(b.graphics_placeholder_runs)) and
        std.mem.eql(u8, a.graphics_payload_bytes, b.graphics_payload_bytes) and
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
        .history_count = scroll_row,
        .scroll_row = scroll_row,
        .snapshot_seq = snapshot_seq,
        .dirty_epoch = snapshot_seq,
        .is_alternate_screen = false,
        .graphics_publication_seq = 0,
        .graphics_dirty_generation = 0,
        .graphics_image_count = 0,
        .graphics_placement_count = 0,
        .graphics_virtual_placement_count = 0,
        .graphics_placeholder_run_count = 0,
        .graphics_is_alternate_screen = false,
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
        return self.publication_state.acceptSource(owned, self.submittedToken(), self.geometry_epoch);
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
        return try self.publication_state.commitReservedSource(meta, self.nextSourceDirtyEpoch(), self.submittedToken(), self.geometry_epoch);
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
        if (!sameSnapshotToken(effective_token, request.token)) {
            self.publication_state.active.?.request = .{ .token = effective_token, .allow_retained_reuse = request.allow_retained_reuse };
        }
        return self.publication_state.active.?.request;
    }

    pub fn consumePrepare(self: *Flow, token: pipeline.SnapshotToken) !PrepareConsume {
        const layout = self.prepareLayout(token.geometry_epoch);
        return self.publication_state.consumePrepare(layout, token);
    }

    pub fn retryTakenPrepare(self: *Flow, token: pipeline.SnapshotToken) bool {
        return self.publication_state.retryTakenPrepare(token);
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
            .grid_px = self.grid_px,
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
            .needs_full_prepare => _ = self.publication_state.requestFullPrepare(),
            else => {},
        }
        return decision;
    }

    pub fn acceptSubmitted(self: *Flow, frame: pipeline.SubmittedFrame) void {
        if (frame.token.geometry_epoch != self.geometry_epoch) {
            _ = self.publication_state.requestFullPrepare();
            return;
        }
        self.publication_state.retirePendingAtOrBefore(frame.token);
        self.surface.acceptSubmitted(frame);
    }

    pub fn pendingState(self: *const Flow) PendingState {
        const pending = self.surface.pendingState();
        return .{
            .source_pending = self.publication_state.sourcePending(),
            .prepare_pending = self.publication_state.preparePending(),
            .submit_pending = pending.submit_pending,
        };
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
    @memset(dirty_rows, 0);
    for (snapshot.dirty_rows, 0..) |src, i| {
        if (i >= dirty_rows.len) break;
        dirty_rows[i] = src;
    }
    const dirty_cols_start = try allocator.alloc(u16, snapshot.rows);
    errdefer allocator.free(dirty_cols_start);
    @memset(dirty_cols_start, 0);
    for (snapshot.dirty_cols_start, 0..) |src, i| {
        if (i >= dirty_cols_start.len) break;
        dirty_cols_start[i] = src;
    }
    const dirty_cols_end = try allocator.alloc(u16, snapshot.rows);
    errdefer allocator.free(dirty_cols_end);
    @memset(dirty_cols_end, 0);
    for (snapshot.dirty_cols_end, 0..) |src, i| {
        if (i >= dirty_cols_end.len) break;
        dirty_cols_end[i] = src;
    }
    return .{
        .cols = snapshot.cols,
        .rows = snapshot.rows,
        .history_count = snapshot.history_count,
        .scroll_row = snapshot.scroll_row,
        .snapshot_seq = snapshot.snapshot_seq,
        .dirty_epoch = snapshot.dirty_epoch,
        .is_alternate_screen = snapshot.is_alternate_screen,
        .cells = cells,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = .{
            .image_count = snapshot.graphics_image_count,
            .placement_count = snapshot.graphics_placement_count,
            .virtual_placement_count = snapshot.graphics_virtual_placement_count,
            .is_alternate_screen = if (snapshot.graphics_is_alternate_screen) 1 else 0,
            .publication_seq = snapshot.graphics_publication_seq,
            .dirty_generation = snapshot.graphics_dirty_generation,
        },
        .graphics_payload_bytes = &.{},
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
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = snapshot_seq,
        .dirty_epoch = snapshot_seq,
        .is_alternate_screen = false,
        .cells = cells,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = std.mem.zeroes(abi.FfiVtGraphicsMeta),
        .graphics_payload_bytes = &.{},
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
}

test "surface keeps submitted identity as retained base only" {
    var surface = TerminalSurface{};
    const frame = pipeline.SubmittedFrame{
        .token = .{ .snapshot_seq = 7, .dirty_epoch = 9, .geometry_epoch = 2, .damage_base_seq = 0, .damage_kind = .full },
        .atlas_epoch = 11,
        .surface_epoch = 13,
    };

    surface.acceptSubmitted(frame);

    try std.testing.expect(surface.submitted_frame != null);
    try std.testing.expectEqual(frame.token.snapshot_seq, surface.submitted_frame.?.token.snapshot_seq);
    try std.testing.expectEqual(frame.token.dirty_epoch, surface.submitted_frame.?.token.dirty_epoch);
    try std.testing.expectEqual(frame.token.geometry_epoch, surface.submitted_frame.?.token.geometry_epoch);
    try std.testing.expectEqual(frame.atlas_epoch, surface.submitted_frame.?.atlas_epoch);
    try std.testing.expectEqual(frame.surface_epoch, surface.submitted_frame.?.surface_epoch);
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

test "failed taken prepare is retryable without blink refresh" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    const source = try ownedTestSource(std.heap.c_allocator, 11, 'A');
    _ = flow.acceptSource(source);

    const request = flow.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expect(!flow.pendingState().prepare_pending);

    try std.testing.expect(flow.retryTakenPrepare(request.token));
    try std.testing.expect(flow.pendingState().prepare_pending);

    const retry = flow.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expect(sameSnapshotToken(request.token, retry.token));
}

test "full prepare after submitted frame carries no retained base" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    var first = try ownedTestSource(std.heap.c_allocator, 1, 'A');
    first.cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .block, .blink = false };
    _ = flow.acceptSource(first);
    const first_request = flow.prepare() orelse return error.TestUnexpectedResult;
    flow.acceptSubmitted(.{ .token = first_request.token });

    var second = try ownedTestSource(std.heap.c_allocator, 2, 'A');
    second.dirty_rows[0] = 0;
    second.dirty_cols_start[0] = 0;
    second.dirty_cols_end[0] = 0;
    second.cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .beam, .blink = false };
    _ = flow.acceptSource(second);

    const request = flow.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pipeline.DamageKind.full, request.token.damage_kind);
    try std.testing.expectEqual(@as(u64, 0), request.token.damage_base_seq);
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
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 3,
        .dirty_epoch = 3,
        .is_alternate_screen = false,
        .cells = clean_cells,
        .cursor = .{ .visible = true, .row = 0, .col = 1, .shape = .beam, .blink = false },
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = std.mem.zeroes(abi.FfiVtGraphicsMeta),
        .graphics_payload_bytes = &.{},
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

test "color state change republishes clean later vt snapshot" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    var first = try ownedTestSource(std.heap.c_allocator, 2, 'A');
    first.colors.foreground = .{ .r = 1, .g = 2, .b = 3 };
    first.colors.background = .{ .r = 4, .g = 5, .b = 6 };
    first.colors.cursor = .{ .r = 7, .g = 8, .b = 9 };
    first.colors.palette[1] = .{ .r = 10, .g = 11, .b = 12 };
    try std.testing.expect(flow.acceptSource(first).published);
    _ = flow.prepare() orelse return error.TestUnexpectedResult;

    var second = try ownedTestSource(std.heap.c_allocator, 3, 'A');
    second.dirty_rows[0] = 0;
    second.colors.foreground = .{ .r = 9, .g = 8, .b = 7 };
    second.colors.background = .{ .r = 4, .g = 5, .b = 6 };
    second.colors.cursor = .{ .r = 7, .g = 8, .b = 9 };
    second.colors.palette[1] = .{ .r = 10, .g = 11, .b = 12 };
    const published = flow.acceptSource(second);
    try std.testing.expect(published.published);
    try std.testing.expectEqual(pipeline.DamageKind.full, published.damage_kind);
}

test "graphics publication change republishes clean later vt snapshot" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    var first = try ownedTestSource(std.heap.c_allocator, 2, 'A');
    first.graphics.publication_seq = 1;
    first.graphics.dirty_generation = 1;
    first.graphics.image_count = 1;
    try std.testing.expect(flow.acceptSource(first).published);
    _ = flow.prepare() orelse return error.TestUnexpectedResult;

    var second = try ownedTestSource(std.heap.c_allocator, 3, 'A');
    second.dirty_rows[0] = 0;
    second.graphics.publication_seq = 2;
    second.graphics.dirty_generation = 2;
    second.graphics.image_count = 1;
    const published = flow.acceptSource(second);
    try std.testing.expect(published.published);
    try std.testing.expectEqual(pipeline.DamageKind.full, published.damage_kind);
}

test "graphics screen identity change republishes same snapshot" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    var first = try ownedTestSource(std.heap.c_allocator, 2, 'A');
    first.graphics.is_alternate_screen = 0;
    try std.testing.expect(flow.acceptSource(first).published);
    _ = flow.prepare() orelse return error.TestUnexpectedResult;

    var second = try ownedTestSource(std.heap.c_allocator, 2, 'A');
    second.dirty_rows[0] = 0;
    second.graphics.is_alternate_screen = 1;
    const published = flow.acceptSource(second);
    try std.testing.expect(published.published);
    try std.testing.expectEqual(pipeline.DamageKind.full, published.damage_kind);
}

test "graphics publication change replaces retained copied item metadata" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    var first = try ownedTestSource(std.heap.c_allocator, 2, 'A');
    first.graphics.publication_seq = 1;
    first.graphics.dirty_generation = 1;
    first.graphics.image_count = 1;
    first.graphics.placement_count = 1;
    first.graphics_images = try std.heap.c_allocator.dupe(abi.FfiVtGraphicsImage, &.{.{
        .image_id = 7,
        .image_number = 1,
        .format = 24,
        .width = 2,
        .height = 1,
        .payload_len = 4,
    }});
    first.graphics_payload_bytes = try std.heap.c_allocator.dupe(u8, "AAAA");
    first.graphics_placements = try std.heap.c_allocator.dupe(abi.FfiVtGraphicsPlacement, &.{.{
        .image_id = 7,
        .placement_id = 4,
        .z_index = 0,
        .anchor = .{ .kind = 1, .value = 1 },
        .anchor_col = 2,
        .source_x = 0,
        .source_y = 0,
        .source_width = 2,
        .source_height = 1,
        .cell_x_offset = 0,
        .cell_y_offset = 0,
        .columns = 4,
        .rows = 2,
        .dest_left_cell_px = 3,
        .dest_top_cell_px = 5,
        .dest_right_cell_px = 35,
        .dest_bottom_cell_px = 37,
        .dest_grid_columns = 4,
        .dest_grid_rows = 2,
        .effective_columns = 4,
        .effective_rows = 2,
    }});
    try std.testing.expect(flow.acceptSource(first).published);
    _ = flow.prepare() orelse return error.TestUnexpectedResult;

    var second = try ownedTestSource(std.heap.c_allocator, 3, 'A');
    second.dirty_rows[0] = 0;
    second.dirty_cols_start[0] = 0;
    second.dirty_cols_end[0] = 0;
    second.graphics.publication_seq = 2;
    second.graphics.dirty_generation = 2;
    second.graphics.image_count = 1;
    second.graphics.placement_count = 1;
    second.graphics_images = try std.heap.c_allocator.dupe(abi.FfiVtGraphicsImage, &.{.{
        .image_id = 8,
        .image_number = 2,
        .format = 24,
        .width = 3,
        .height = 1,
        .payload_len = 8,
    }});
    second.graphics_payload_bytes = try std.heap.c_allocator.dupe(u8, "BBBBBBBB");
    second.graphics_placements = try std.heap.c_allocator.dupe(abi.FfiVtGraphicsPlacement, &.{.{
        .image_id = 8,
        .placement_id = 5,
        .z_index = 1,
        .anchor = .{ .kind = 1, .value = 2 },
        .anchor_col = 3,
        .source_x = 1,
        .source_y = 0,
        .source_width = 3,
        .source_height = 1,
        .cell_x_offset = 1,
        .cell_y_offset = 0,
        .columns = 5,
        .rows = 2,
        .dest_left_cell_px = 1,
        .dest_top_cell_px = 2,
        .dest_right_cell_px = 41,
        .dest_bottom_cell_px = 34,
        .dest_grid_columns = 5,
        .dest_grid_rows = 2,
        .effective_columns = 5,
        .effective_rows = 2,
    }});

    const published = flow.acceptSource(second);
    try std.testing.expect(published.published);
    try std.testing.expectEqual(pipeline.DamageKind.full, published.damage_kind);

    const request = flow.prepare() orelse return error.TestUnexpectedResult;
    const prepare = try flow.consumePrepare(request.token);
    try std.testing.expectEqual(@as(u64, 2), prepare.state.graphics.publication_seq);
    try std.testing.expectEqual(@as(usize, 1), prepare.state.graphics_images.len);
    try std.testing.expectEqual(@as(usize, 1), prepare.state.graphics_placements.len);
    try std.testing.expectEqual(@as(u32, 8), prepare.state.graphics_images[0].image_id);
    try std.testing.expectEqual(@as(u32, 5), prepare.state.graphics_placements[0].placement_id);
    try std.testing.expectEqual(@as(u32, 1), prepare.state.graphics_placements[0].dest_left_cell_px);
    try std.testing.expectEqual(@as(u32, 2), prepare.state.graphics_placements[0].dest_top_cell_px);
    try std.testing.expectEqual(@as(u32, 41), prepare.state.graphics_placements[0].dest_right_cell_px);
    try std.testing.expectEqual(@as(u32, 34), prepare.state.graphics_placements[0].dest_bottom_cell_px);
    try std.testing.expectEqual(@as(u32, 5), prepare.state.graphics_placements[0].dest_grid_columns);
    try std.testing.expectEqual(@as(u32, 2), prepare.state.graphics_placements[0].dest_grid_rows);
    try std.testing.expectEqualStrings("BBBBBBBB", prepare.state.graphics_payload_bytes);
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
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = std.mem.zeroes(abi.FfiVtGraphicsMeta),
        .graphics_payload_bytes = &.{},
    });
    try std.testing.expect(published.published);

    const request = flow.prepare() orelse return error.TestUnexpectedResult;
    flow.acceptSubmitted(.{ .token = request.token });

    _ = try flow.reservePublishSlot(1, 1);
}

test "flow commit publish slot copies graphics item metadata" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 1, .height = 1 },
        .grid_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const slot = try flow.reservePublishSlot(1, 1);
    slot.cells[0] = std.mem.zeroes(abi.FfiVtCell);
    slot.cells[0].codepoint = 'A';
    slot.dirty_rows[0] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 0;

    const images = [_]abi.FfiVtGraphicsImage{.{
        .image_id = 7,
        .image_number = 9,
        .format = 24,
        .width = 2,
        .height = 1,
        .payload_len = 4,
    }};
    const placements = [_]abi.FfiVtGraphicsPlacement{.{
        .image_id = 7,
        .placement_id = 4,
        .z_index = 0,
        .anchor = .{ .kind = 1, .value = 1 },
        .anchor_col = 2,
        .source_x = 0,
        .source_y = 0,
        .source_width = 2,
        .source_height = 1,
        .cell_x_offset = 0,
        .cell_y_offset = 0,
        .columns = 4,
        .rows = 2,
        .dest_left_cell_px = 3,
        .dest_top_cell_px = 4,
        .dest_right_cell_px = 35,
        .dest_bottom_cell_px = 36,
        .dest_grid_columns = 4,
        .dest_grid_rows = 2,
        .effective_columns = 4,
        .effective_rows = 2,
    }};
    const virtual_placements = [_]abi.FfiVtGraphicsVirtualPlacement{.{
        .image_id = 7,
        .placement_id = 9,
        .source_x = 2,
        .source_y = 4,
        .source_width = 6,
        .source_height = 8,
        .columns = 10,
        .rows = 12,
    }};
    const placeholder_runs = [_]abi.FfiVtGraphicsPlaceholderRun{.{
        .image_id = 7,
        .placement_id = 9,
        .virtual_placement_index = 0,
        .run_order = 0,
        .cell_row = 0,
        .cell_col = 0,
        .image_row = 4,
        .image_col = 5,
        .columns = 1,
    }};

    const published = try flow.commitPublishSlot(.{
        .history_count = 5,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = .{ .image_count = 1, .placement_count = 1, .virtual_placement_count = 1, .placeholder_run_count = 1, .is_alternate_screen = 0, .publication_seq = 3, .dirty_generation = 5 },
        .graphics_images = images[0..],
        .graphics_placements = placements[0..],
        .graphics_virtual_placements = virtual_placements[0..],
        .graphics_placeholder_runs = placeholder_runs[0..],
        .graphics_payload_bytes = "QUJD",
    });
    try std.testing.expect(published.published);

    const request = flow.prepare() orelse return error.TestUnexpectedResult;
    const prepare = try flow.consumePrepare(request.token);
    try std.testing.expectEqual(@as(u64, 5), prepare.state.history_count);
    try std.testing.expectEqual(@as(usize, 1), prepare.state.graphics_images.len);
    try std.testing.expectEqual(@as(usize, 1), prepare.state.graphics_placements.len);
    try std.testing.expectEqual(@as(usize, 1), prepare.state.graphics_virtual_placements.len);
    try std.testing.expectEqual(@as(u32, 7), prepare.state.graphics_images[0].image_id);
    try std.testing.expectEqual(@as(u32, 4), prepare.state.graphics_placements[0].placement_id);
    try std.testing.expectEqual(@as(u32, 9), prepare.state.graphics_virtual_placements[0].placement_id);
    try std.testing.expectEqual(@as(u32, 3), prepare.state.graphics_placements[0].dest_left_cell_px);
    try std.testing.expectEqual(@as(u32, 4), prepare.state.graphics_placements[0].dest_top_cell_px);
    try std.testing.expectEqual(@as(u32, 35), prepare.state.graphics_placements[0].dest_right_cell_px);
    try std.testing.expectEqual(@as(u32, 36), prepare.state.graphics_placements[0].dest_bottom_cell_px);
    try std.testing.expectEqual(@as(u32, 4), prepare.state.graphics_placements[0].dest_grid_columns);
    try std.testing.expectEqual(@as(u32, 2), prepare.state.graphics_placements[0].dest_grid_rows);
    try std.testing.expectEqual(@as(u64, 3), prepare.state.graphics.publication_seq);
    try std.testing.expectEqual(@as(usize, 1), prepare.state.graphics_placeholder_runs.len);
    try std.testing.expectEqual(@as(u32, 0), prepare.state.graphics_placeholder_runs[0].run_order);
    try std.testing.expectEqual(@as(u16, 0), prepare.state.graphics_placeholder_runs[0].cell_row);
    try std.testing.expectEqual(@as(u32, 5), prepare.state.graphics_placeholder_runs[0].image_col);
    try std.testing.expectEqualStrings("QUJD", prepare.state.graphics_payload_bytes);
}

test "flow commit publish slot validates graphics payload byte size" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 1, .height = 1 },
        .grid_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const slot = try flow.reservePublishSlot(1, 1);
    slot.cells[0] = std.mem.zeroes(abi.FfiVtCell);
    slot.cells[0].codepoint = 'A';
    slot.dirty_rows[0] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 0;

    const images = [_]abi.FfiVtGraphicsImage{.{
        .image_id = 1,
        .image_number = 0,
        .format = 24,
        .width = 1,
        .height = 1,
        .payload_len = 4,
    }};

    try std.testing.expectError(error.InvalidGraphicsPayload, flow.commitPublishSlot(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = .{ .image_count = 1, .placement_count = 0, .virtual_placement_count = 0, .is_alternate_screen = 0, .publication_seq = 1, .dirty_generation = 1 },
        .graphics_images = images[0..],
        .graphics_virtual_placements = &.{},
        .graphics_payload_bytes = "ABC",
    }));
}

test "flow commit publish slot validates graphics metadata counts" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 1, .height = 1 },
        .grid_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const slot = try flow.reservePublishSlot(1, 1);
    slot.cells[0] = std.mem.zeroes(abi.FfiVtCell);
    slot.cells[0].codepoint = 'A';
    slot.dirty_rows[0] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 0;

    const images = [_]abi.FfiVtGraphicsImage{.{
        .image_id = 1,
        .image_number = 0,
        .format = 24,
        .width = 1,
        .height = 1,
        .payload_len = 0,
    }};
    const placements = [_]abi.FfiVtGraphicsPlacement{std.mem.zeroes(abi.FfiVtGraphicsPlacement)};
    const virtual_placements = [_]abi.FfiVtGraphicsVirtualPlacement{std.mem.zeroes(abi.FfiVtGraphicsVirtualPlacement)};

    try std.testing.expectError(error.InvalidGraphicsMetadata, flow.commitPublishSlot(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = .{ .image_count = 0, .placement_count = 1, .virtual_placement_count = 1, .is_alternate_screen = 0, .publication_seq = 1, .dirty_generation = 1 },
        .graphics_images = images[0..],
        .graphics_placements = placements[0..],
        .graphics_virtual_placements = virtual_placements[0..],
        .graphics_payload_bytes = &.{},
    }));
}

test "flow commit publish slot rejects placeholder run publication mismatch" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 2, .height = 2 },
        .grid_px = .{ .width = 2, .height = 2 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const slot = try flow.reservePublishSlot(2, 2);
    for (slot.cells) |*cell| cell.* = std.mem.zeroes(abi.FfiVtCell);
    slot.dirty_rows[0] = 1;
    slot.dirty_rows[1] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 1;
    slot.dirty_cols_start[1] = 0;
    slot.dirty_cols_end[1] = 1;

    const images = [_]abi.FfiVtGraphicsImage{.{
        .image_id = 7,
        .image_number = 0,
        .format = 24,
        .width = 1,
        .height = 1,
        .payload_len = 0,
    }};
    const virtual_placements = [_]abi.FfiVtGraphicsVirtualPlacement{.{
        .image_id = 7,
        .placement_id = 9,
        .source_x = 0,
        .source_y = 0,
        .source_width = 1,
        .source_height = 1,
        .columns = 1,
        .rows = 1,
    }};
    const placeholder_runs = [_]abi.FfiVtGraphicsPlaceholderRun{.{
        .image_id = 7,
        .placement_id = 10,
        .virtual_placement_index = 0,
        .run_order = 0,
        .cell_row = 0,
        .cell_col = 0,
        .image_row = 0,
        .image_col = 0,
        .columns = 1,
    }};

    try std.testing.expectError(error.InvalidGraphicsMetadata, flow.commitPublishSlot(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = .{ .image_count = 1, .placement_count = 0, .virtual_placement_count = 1, .placeholder_run_count = 1, .is_alternate_screen = 0, .publication_seq = 1, .dirty_generation = 1 },
        .graphics_images = images[0..],
        .graphics_virtual_placements = virtual_placements[0..],
        .graphics_placeholder_runs = placeholder_runs[0..],
        .graphics_payload_bytes = &.{},
    }));
}

test "flow commit publish slot rejects generated placement mixed with placeholder run" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 2, .height = 2 },
        .grid_px = .{ .width = 2, .height = 2 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const slot = try flow.reservePublishSlot(2, 2);
    for (slot.cells) |*cell| cell.* = std.mem.zeroes(abi.FfiVtCell);
    slot.dirty_rows[0] = 1;
    slot.dirty_rows[1] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 1;
    slot.dirty_cols_start[1] = 0;
    slot.dirty_cols_end[1] = 1;

    const images = [_]abi.FfiVtGraphicsImage{.{
        .image_id = 7,
        .image_number = 0,
        .format = 24,
        .width = 1,
        .height = 1,
        .payload_len = 0,
    }};
    const placements = [_]abi.FfiVtGraphicsPlacement{.{
        .image_id = 7,
        .placement_id = 4,
        .z_index = -1,
        .anchor = .{ .kind = 1, .value = 0 },
        .anchor_col = 0,
        .source_x = 0,
        .source_y = 0,
        .source_width = 1,
        .source_height = 1,
        .cell_x_offset = 0,
        .cell_y_offset = 0,
        .columns = 1,
        .rows = 1,
        .dest_left_cell_px = 0,
        .dest_top_cell_px = 0,
        .dest_right_cell_px = 1,
        .dest_bottom_cell_px = 1,
        .dest_grid_columns = 1,
        .dest_grid_rows = 1,
        .effective_columns = 1,
        .effective_rows = 1,
        .flags = abi.HOWL_VT_GRAPHICS_PLACEMENT_GENERATED_PLACEHOLDER,
    }};
    const virtual_placements = [_]abi.FfiVtGraphicsVirtualPlacement{.{
        .image_id = 7,
        .placement_id = 9,
        .source_x = 0,
        .source_y = 0,
        .source_width = 1,
        .source_height = 1,
        .columns = 1,
        .rows = 1,
    }};
    const placeholder_runs = [_]abi.FfiVtGraphicsPlaceholderRun{.{
        .image_id = 7,
        .placement_id = 9,
        .virtual_placement_index = 0,
        .run_order = 0,
        .cell_row = 0,
        .cell_col = 0,
        .image_row = 0,
        .image_col = 0,
        .columns = 1,
    }};

    try std.testing.expectError(error.InvalidGraphicsMetadata, flow.commitPublishSlot(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = .{ .image_count = 1, .placement_count = 1, .virtual_placement_count = 1, .placeholder_run_count = 1, .is_alternate_screen = 0, .publication_seq = 1, .dirty_generation = 1 },
        .graphics_images = images[0..],
        .graphics_placements = placements[0..],
        .graphics_virtual_placements = virtual_placements[0..],
        .graphics_placeholder_runs = placeholder_runs[0..],
        .graphics_payload_bytes = &.{},
    }));
}

test "flow commit publish slot rejects placeholder run outside published grid" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 2, .height = 2 },
        .grid_px = .{ .width = 2, .height = 2 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const slot = try flow.reservePublishSlot(2, 2);
    for (slot.cells) |*cell| cell.* = std.mem.zeroes(abi.FfiVtCell);
    slot.dirty_rows[0] = 1;
    slot.dirty_rows[1] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 1;
    slot.dirty_cols_start[1] = 0;
    slot.dirty_cols_end[1] = 1;

    const images = [_]abi.FfiVtGraphicsImage{.{
        .image_id = 7,
        .image_number = 0,
        .format = 24,
        .width = 1,
        .height = 1,
        .payload_len = 0,
    }};
    const virtual_placements = [_]abi.FfiVtGraphicsVirtualPlacement{.{
        .image_id = 7,
        .placement_id = 9,
        .source_x = 0,
        .source_y = 0,
        .source_width = 1,
        .source_height = 1,
        .columns = 1,
        .rows = 1,
    }};
    const placeholder_runs = [_]abi.FfiVtGraphicsPlaceholderRun{.{
        .image_id = 7,
        .placement_id = 9,
        .virtual_placement_index = 0,
        .run_order = 0,
        .cell_row = 1,
        .cell_col = 1,
        .image_row = 0,
        .image_col = 0,
        .columns = 2,
    }};

    try std.testing.expectError(error.InvalidGraphicsMetadata, flow.commitPublishSlot(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = .{ .image_count = 1, .placement_count = 0, .virtual_placement_count = 1, .placeholder_run_count = 1, .is_alternate_screen = 0, .publication_seq = 1, .dirty_generation = 1 },
        .graphics_images = images[0..],
        .graphics_virtual_placements = virtual_placements[0..],
        .graphics_placeholder_runs = placeholder_runs[0..],
        .graphics_payload_bytes = &.{},
    }));
}

test "flow boundary rejects virtual placement with zero source width" {
    try expectInvalidVirtualPlacement(.source_width);
}

test "flow boundary rejects virtual placement with zero source height" {
    try expectInvalidVirtualPlacement(.source_height);
}

test "flow boundary rejects virtual placement with zero columns" {
    try expectInvalidVirtualPlacement(.columns);
}

test "flow boundary rejects virtual placement with zero rows" {
    try expectInvalidVirtualPlacement(.rows);
}

const InvalidVirtualPlacementField = enum { source_width, source_height, columns, rows };

fn expectInvalidVirtualPlacement(field: InvalidVirtualPlacementField) !void {
    var cells = [_]abi.FfiVtCell{std.mem.zeroes(abi.FfiVtCell)};
    var dirty_rows = [_]u8{1};
    var dirty_cols_start = [_]u16{0};
    var dirty_cols_end = [_]u16{0};
    var images = [_]abi.FfiVtGraphicsImage{.{ .image_id = 7, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 0 }};
    var virtual_placement = abi.FfiVtGraphicsVirtualPlacement{
        .image_id = 7,
        .placement_id = 9,
        .source_x = 0,
        .source_y = 0,
        .source_width = 1,
        .source_height = 1,
        .columns = 1,
        .rows = 1,
    };
    switch (field) {
        .source_width => virtual_placement.source_width = 0,
        .source_height => virtual_placement.source_height = 0,
        .columns => virtual_placement.columns = 0,
        .rows => virtual_placement.rows = 0,
    }
    var virtual_placements = [_]abi.FfiVtGraphicsVirtualPlacement{virtual_placement};

    const source = PublicationSource{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = .{ .image_count = 1, .placement_count = 0, .virtual_placement_count = 1, .placeholder_run_count = 0, .is_alternate_screen = 0, .publication_seq = 1, .dirty_generation = 1 },
        .graphics_images = images[0..],
        .graphics_virtual_placements = virtual_placements[0..],
        .graphics_payload_bytes = &.{},
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows[0..],
        .dirty_cols_start = dirty_cols_start[0..],
        .dirty_cols_end = dirty_cols_end[0..],
    };
    try std.testing.expectError(error.InvalidGraphicsMetadata, validatePublicationSourceBoundary(source));
}

test "flow commit publish slot rejects dirty row byte outside boolean domain" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 1, .height = 1 },
        .grid_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const slot = try flow.reservePublishSlot(1, 1);
    slot.cells[0] = std.mem.zeroes(abi.FfiVtCell);
    slot.cells[0].codepoint = 'A';
    slot.dirty_rows[0] = 2;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 0;

    try std.testing.expectError(error.InvalidSurfaceSource, flow.commitPublishSlot(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = std.mem.zeroes(abi.FfiVtGraphicsMeta),
        .graphics_payload_bytes = &.{},
    }));
}

test "flow commit publish slot accepts dirty row span sentinel without dirty columns" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 2, .height = 2 },
        .grid_px = .{ .width = 2, .height = 2 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const slot = try flow.reservePublishSlot(2, 2);
    slot.cells[0] = std.mem.zeroes(abi.FfiVtCell);
    slot.cells[0].codepoint = 'A';
    slot.cells[1] = std.mem.zeroes(abi.FfiVtCell);
    slot.cells[1].codepoint = 'B';
    slot.cells[2] = std.mem.zeroes(abi.FfiVtCell);
    slot.cells[2].codepoint = 'C';
    slot.cells[3] = std.mem.zeroes(abi.FfiVtCell);
    slot.cells[3].codepoint = 'D';
    slot.dirty_rows[0] = 1;
    slot.dirty_rows[1] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 1;
    slot.dirty_cols_start[1] = 2;
    slot.dirty_cols_end[1] = 0;

    const published = try flow.commitPublishSlot(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = true,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = .{ .image_count = 0, .placement_count = 0, .virtual_placement_count = 0, .is_alternate_screen = 1, .publication_seq = 1, .dirty_generation = 1 },
        .graphics_payload_bytes = &.{},
    });
    try std.testing.expect(published.published);
}

test "flow canonicalizes clean dirty metadata before equality dedupe" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();

    const dirty_rows = [_]u8{ 1, 0 };
    const first_dirty_cols_start = [_]u16{ 0, 2 };
    const first_dirty_cols_end = [_]u16{ 1, 1 };
    const second_dirty_cols_start = [_]u16{ 0, 1 };
    const second_dirty_cols_end = [_]u16{ 1, 2 };

    const first = flow.acceptSnapshot(testSnapshot(2, 3, 0, 7, &dirty_rows, &first_dirty_cols_start, &first_dirty_cols_end));
    try std.testing.expect(first.published);
    try std.testing.expectEqual(@as(u16, 0), flow.publication_state.pending.?.source.dirty_cols_start[1]);
    try std.testing.expectEqual(@as(u16, 0), flow.publication_state.pending.?.source.dirty_cols_end[1]);

    const second = flow.acceptSnapshot(testSnapshot(2, 3, 0, 7, &dirty_rows, &second_dirty_cols_start, &second_dirty_cols_end));
    try std.testing.expect(!second.published);
    try std.testing.expect(!second.queued);
    try std.testing.expectEqual(pipeline.DamageKind.none, second.damage_kind);
}

test "flow preserves dirty row spans and sentinels while canonicalizing" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();

    const dirty_rows = [_]u8{ 1, 1, 0 };
    const dirty_cols_start = [_]u16{ 1, 3, 2 };
    const dirty_cols_end = [_]u16{ 2, 0, 1 };

    const published = flow.acceptSnapshot(testSnapshot(3, 3, 0, 11, &dirty_rows, &dirty_cols_start, &dirty_cols_end));
    try std.testing.expect(published.published);

    const source = flow.publication_state.pending.?.source;
    try std.testing.expectEqual(@as(u16, 1), source.dirty_cols_start[0]);
    try std.testing.expectEqual(@as(u16, 2), source.dirty_cols_end[0]);
    try std.testing.expectEqual(@as(u16, 3), source.dirty_cols_start[1]);
    try std.testing.expectEqual(@as(u16, 0), source.dirty_cols_end[1]);
    try std.testing.expectEqual(@as(u16, 0), source.dirty_cols_start[2]);
    try std.testing.expectEqual(@as(u16, 0), source.dirty_cols_end[2]);
}

test "flow commit publish slot canonicalizes clean dirty metadata" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 3, .height = 2 },
        .grid_px = .{ .width = 3, .height = 2 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const slot = try flow.reservePublishSlot(3, 2);
    for (slot.cells) |*cell| cell.* = std.mem.zeroes(abi.FfiVtCell);
    slot.dirty_rows[0] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 1;
    slot.dirty_rows[1] = 0;
    slot.dirty_cols_start[1] = 2;
    slot.dirty_cols_end[1] = 1;

    const published = try flow.commitPublishSlot(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 13,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = std.mem.zeroes(abi.FfiVtGraphicsMeta),
        .graphics_payload_bytes = &.{},
    });
    try std.testing.expect(published.published);
    try std.testing.expectEqual(@as(u16, 0), slot.dirty_cols_start[1]);
    try std.testing.expectEqual(@as(u16, 0), slot.dirty_cols_end[1]);
    try std.testing.expectEqual(@as(u16, 0), flow.publication_state.pending.?.source.dirty_cols_start[1]);
    try std.testing.expectEqual(@as(u16, 0), flow.publication_state.pending.?.source.dirty_cols_end[1]);
}

test "flow boundary rejects invalid dirty metadata before canonicalization" {
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{3};
    const dirty_cols_end = [_]u16{1};
    var source = try testSourceFromSnapshot(std.heap.c_allocator, testSnapshot(1, 3, 0, 17, &dirty_rows, &dirty_cols_start, &dirty_cols_end));
    defer source.deinit(std.heap.c_allocator);

    try std.testing.expectError(error.InvalidSurfaceSource, validatePublicationSourceBoundary(source));
    try std.testing.expectEqual(@as(u16, 3), source.dirty_cols_start[0]);
    try std.testing.expectEqual(@as(u16, 1), source.dirty_cols_end[0]);
}

test "flow commit publish slot rejects graphics placement without image" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 1, .height = 1 },
        .grid_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const slot = try flow.reservePublishSlot(1, 1);
    slot.cells[0] = std.mem.zeroes(abi.FfiVtCell);
    slot.cells[0].codepoint = 'A';
    slot.dirty_rows[0] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 0;

    const placements = [_]abi.FfiVtGraphicsPlacement{.{
        .image_id = 99,
        .placement_id = 1,
        .z_index = 0,
        .anchor = .{ .kind = 1, .value = 0 },
        .anchor_col = 0,
        .source_x = 0,
        .source_y = 0,
        .source_width = 1,
        .source_height = 1,
        .cell_x_offset = 0,
        .cell_y_offset = 0,
        .columns = 1,
        .rows = 1,
        .dest_left_cell_px = 0,
        .dest_top_cell_px = 0,
        .dest_right_cell_px = 1,
        .dest_bottom_cell_px = 1,
        .dest_grid_columns = 1,
        .dest_grid_rows = 1,
        .effective_columns = 1,
        .effective_rows = 1,
    }};

    try std.testing.expectError(error.InvalidGraphicsMetadata, flow.commitPublishSlot(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = .{ .image_count = 0, .placement_count = 1, .virtual_placement_count = 0, .is_alternate_screen = 0, .publication_seq = 1, .dirty_generation = 1 },
        .graphics_placements = placements[0..],
        .graphics_payload_bytes = &.{},
    }));
}

test "flow commit publish slot rejects graphics screen mismatch" {
    var flow = Flow.init(std.heap.c_allocator);
    defer flow.deinit();
    _ = try flow.syncGeometry(.{
        .render_px = .{ .width = 1, .height = 1 },
        .grid_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
    });

    const slot = try flow.reservePublishSlot(1, 1);
    slot.cells[0] = std.mem.zeroes(abi.FfiVtCell);
    slot.cells[0].codepoint = 'A';
    slot.dirty_rows[0] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 0;

    try std.testing.expectError(error.InvalidGraphicsMetadata, flow.commitPublishSlot(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .graphics = .{ .image_count = 0, .placement_count = 0, .virtual_placement_count = 0, .is_alternate_screen = 1, .publication_seq = 1, .dirty_generation = 1 },
        .graphics_payload_bytes = &.{},
    }));
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
