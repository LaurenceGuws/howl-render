const std = @import("std");
const tokens = @import("../surface/tokens.zig");
const geometry_contract = @import("../render/geometry_contract.zig");
const source_vt = @import("vt.zig");
const source_damage = @import("damage.zig");
const source_slot = @import("slot.zig");

pub const PendingState = struct {
    source_pending: bool,
    prepare_pending: bool,
    submit_pending: bool,
};

pub const PrepareConsume = struct {
    request: tokens.RenderRequest,
    layout: geometry_contract.PrepareLayout,
    state: source_vt.PublicationSource,
};

pub const Publication = struct {
    source: source_vt.PublicationSource,
    damage_kind: tokens.DamageKind = .none,

    fn deinit(self: *Publication, allocator: std.mem.Allocator) void {
        self.source.deinit(allocator);
        self.* = undefined;
    }
};

pub const ActivePrepare = struct {
    publication: Publication,
    request: tokens.RenderRequest,
    taken: bool = false,

    fn deinit(self: *ActivePrepare, allocator: std.mem.Allocator) void {
        self.publication.deinit(allocator);
        self.* = undefined;
    }
};

pub const PrepareRequests = struct {
    allocator: std.mem.Allocator,
    pending: ?Publication = null,
    active: ?ActivePrepare = null,
    blink_refresh_pending: bool = false,

    pub fn init(allocator: std.mem.Allocator) PrepareRequests {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PrepareRequests) void {
        if (self.pending) |*publication| publication.deinit(self.allocator);
        self.pending = null;
        if (self.active) |*active| active.deinit(self.allocator);
        self.active = null;
        self.blink_refresh_pending = false;
    }

    pub fn acceptSource(
        self: *PrepareRequests,
        source: source_vt.PublicationSource,
        submitted_token: ?tokens.SnapshotToken,
        geometry_epoch: u64,
    ) source_vt.VtSurfacePublishResult {
        var owned = source;
        source_damage.canonicalizeDirtyMetadata(
            owned.rows,
            owned.dirty_rows,
            owned.dirty_cols_start,
            owned.dirty_cols_end,
        );
        const snapshot = owned.snapshot();
        const damage_kind = self.classify(owned, submitted_token);
        const published = damage_kind != .none;
        if (!published) {
            owned.deinit(self.allocator);
        } else {
            var queued_source = owned;
            if (owned.retained_storage) {
                queued_source = owned.clone(self.allocator) catch {
                    owned.deinit(self.allocator);
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

    pub fn takePrepareRequest(
        self: *PrepareRequests,
        geometry_epoch: u64,
        submitted_token: ?tokens.SnapshotToken,
    ) ?tokens.RenderRequest {
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

    pub fn consumePrepare(
        self: *PrepareRequests,
        layout: geometry_contract.PrepareLayout,
        token: tokens.SnapshotToken,
    ) !PrepareConsume {
        const active = self.active orelse return error.MissingPublishedSource;
        if (!source_damage.sameSnapshotToken(active.request.token, token)) return error.MismatchedPublishedSource;
        return .{ .request = active.request, .layout = layout, .state = active.publication.source };
    }

    pub fn latestToken(self: *const PrepareRequests) ?tokens.SnapshotToken {
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

    pub fn requestFullPrepare(self: *PrepareRequests, force: *const fn (tokens.SnapshotToken) tokens.SnapshotToken) bool {
        if (self.pending != null) {
            self.dropActive();
            return false;
        }
        if (self.active == null) return false;
        self.active.?.request = .{
            .token = force(self.active.?.request.token),
            .allow_retained_reuse = false,
        };
        self.active.?.taken = false;
        return true;
    }

    pub fn retryTakenPrepare(self: *PrepareRequests, token: tokens.SnapshotToken) bool {
        if (self.pending != null) return false;
        const active = if (self.active) |*active| active else return false;
        if (!active.taken) return false;
        if (!source_damage.sameSnapshotToken(active.request.token, token)) return false;
        active.taken = false;
        return true;
    }

    pub fn setCursorBlinkVisible(self: *PrepareRequests, visible: bool) bool {
        var changed = false;
        if (self.pending) |*publication| {
            changed = source_damage.setSourceCursorBlinkVisible(&publication.source, visible) or changed;
        }
        if (self.active) |*active| {
            changed = source_damage.setSourceCursorBlinkVisible(&active.publication.source, visible) or changed;
        }
        return changed;
    }

    pub fn requestBlinkRefresh(self: *PrepareRequests) void {
        if (self.pending != null) return;
        const active = self.active orelse return;
        if (!active.taken) return;
        self.blink_refresh_pending = true;
    }

    pub fn retireAtOrBefore(self: *PrepareRequests, token: tokens.SnapshotToken) void {
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

    pub fn retirePendingAtOrBefore(self: *PrepareRequests, token: tokens.SnapshotToken) void {
        if (self.pending) |*publication| {
            if (publication.source.snapshot_seq <= token.snapshot_seq) {
                publication.deinit(self.allocator);
                self.pending = null;
            }
        }
    }

    pub fn sourcePending(self: *const PrepareRequests) bool {
        return self.pending != null;
    }

    pub fn retainedSlotInUse(self: *const PrepareRequests) bool {
        if (self.pending) |publication| if (publication.source.retained_storage) return true;
        if (self.active) |active| if (active.publication.source.retained_storage) return true;
        return false;
    }

    pub fn refreshRetainedSlotViews(self: *PrepareRequests, slot_owner: *source_slot.SourceSlot) void {
        if (self.pending) |*publication| {
            if (publication.source.retained_storage) {
                slot_owner.refreshRetainedSource(&publication.source);
            }
        }
        if (self.active) |*active| {
            if (active.publication.source.retained_storage) {
                slot_owner.refreshRetainedSource(&active.publication.source);
            }
        }
    }

    pub fn preparePending(self: *const PrepareRequests) bool {
        if (self.blink_refresh_pending) return true;
        if (self.active) |active| return !active.taken;
        return false;
    }

    fn replacePending(self: *PrepareRequests, publication: Publication) void {
        if (self.pending) |*prior| prior.deinit(self.allocator);
        self.pending = publication;
        self.blink_refresh_pending = false;
    }

    fn dropActive(self: *PrepareRequests) void {
        if (self.active) |*active| active.deinit(self.allocator);
        self.active = null;
        self.blink_refresh_pending = false;
    }

    fn activatePending(self: *PrepareRequests, geometry_epoch: u64, submitted_token: ?tokens.SnapshotToken) void {
        const publication = self.pending orelse return;
        self.pending = null;
        const token = tokens.SnapshotToken{
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
    }

    fn classify(
        self: *const PrepareRequests,
        source: source_vt.PublicationSource,
        submitted_token: ?tokens.SnapshotToken,
    ) tokens.DamageKind {
        const snapshot = source.snapshot();
        const damage_kind = source_damage.classifyDirty(snapshot);
        const prior = self.priorSource() orelse return damage_kind;
        const prior_snapshot = prior.snapshot();
        const prior_matches_submitted = if (submitted_token) |token|
            prior_snapshot.snapshot_seq == token.snapshot_seq
        else
            false;
        if (snapshot.snapshot_seq == prior_snapshot.snapshot_seq) {
            if (source_damage.samePublicationSource(prior, source)) return .none;
            if (source_damage.cursorPresentationChanged(prior, source)) return .full;
            if (source_damage.colorPresentationChanged(prior, source)) return .full;
            if (damage_kind == .partial and !prior_matches_submitted) return .full;
            return damage_kind;
        }
        if (source_damage.cursorPresentationChanged(prior, source)) return .full;
        if (source_damage.colorPresentationChanged(prior, source)) return .full;
        if (snapshot.cols != prior_snapshot.cols or snapshot.rows != prior_snapshot.rows) return .full;
        if (snapshot.is_alternate_screen != prior_snapshot.is_alternate_screen) return .full;
        if (snapshot.scroll_row != prior_snapshot.scroll_row) return .full;
        if (damage_kind == .partial and !prior_matches_submitted) return .full;
        return damage_kind;
    }

    fn priorSource(self: *const PrepareRequests) ?source_vt.PublicationSource {
        if (self.pending) |publication| return publication.source;
        if (self.active) |active| return active.publication.source;
        return null;
    }
};

test "prepare requests do not own submitted mailbox" {
    var requests = PrepareRequests.init(std.testing.allocator);
    defer requests.deinit();
    try std.testing.expect(!requests.sourcePending());
    try std.testing.expect(!requests.preparePending());
}
