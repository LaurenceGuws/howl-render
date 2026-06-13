const std = @import("std");
const geometry_contract = @import("../geometry/geometry_contract.zig");
const tokens = @import("../geometry/tokens.zig");
const publication_damage = @import("damage.zig");
const publication_storage = @import("source_slot.zig");
const vt_publication = @import("publication.zig");

pub const PrepareConsume = struct {
    request: tokens.RenderRequest,
    layout: geometry_contract.PrepareLayout,
    state: vt_publication.PublicationSource,
};

pub const AdmissionResult = struct {
    admitted: bool,
    damage_kind: tokens.DamageKind,
    snapshot_seq: u64,
    geometry_epoch: u64,
};

pub const PrepareRequests = struct {
    allocator: std.mem.Allocator,
    active_source: ?vt_publication.PublicationSource = null,
    active_request: tokens.RenderRequest = undefined,
    active_taken: bool = false,
    blink_refresh_pending: bool = false,

    pub fn init(allocator: std.mem.Allocator) PrepareRequests {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PrepareRequests) void {
        self.dropActive();
        self.blink_refresh_pending = false;
    }

    pub fn admitSource(self: *PrepareRequests, source: vt_publication.PublicationSource, submitted_token: ?tokens.SnapshotToken, geometry_epoch: u64) AdmissionResult {
        var owned = source;
        publication_damage.canonicalizeDirtyMetadata(owned.rows, owned.dirty_rows, owned.dirty_cols_start, owned.dirty_cols_end);
        const snapshot = owned.snapshot();
        const damage_kind = self.classify(owned, submitted_token, geometry_epoch);
        const admitted = damage_kind != .none;
        if (!admitted) {
            owned.deinit(self.allocator);
        } else {
            const allow_retained_reuse = !self.geometryChanged(geometry_epoch);
            const active_source = takeOwnedActiveSource(self.allocator, &owned) catch {
                owned.deinit(self.allocator);
                return .{
                    .admitted = false,
                    .damage_kind = .none,
                    .snapshot_seq = snapshot.snapshot_seq,
                    .geometry_epoch = geometry_epoch,
                };
            };
            const token = tokens.SnapshotToken{
                .snapshot_seq = active_source.snapshot_seq,
                .dirty_epoch = active_source.dirty_epoch,
                .geometry_epoch = geometry_epoch,
                .damage_base_seq = if (damage_kind == .partial)
                    if (submitted_token) |token_value| token_value.snapshot_seq else 0
                else
                    0,
                .damage_kind = damage_kind,
            };
            self.dropActive();
            self.active_source = active_source;
            self.active_request = .{ .token = token, .allow_retained_reuse = allow_retained_reuse };
            self.active_taken = false;
        }
        return .{
            .admitted = admitted,
            .damage_kind = damage_kind,
            .snapshot_seq = snapshot.snapshot_seq,
            .geometry_epoch = geometry_epoch,
        };
    }

    pub fn takePrepareRequest(self: *PrepareRequests, geometry_epoch: u64) ?tokens.RenderRequest {
        _ = self.active_source orelse return null;
        if (self.active_taken) {
            if (!self.blink_refresh_pending) return null;
            std.debug.assert(self.active_source != null);
            self.blink_refresh_pending = false;
            const prior_token = self.active_request.token;
            self.active_request = .{
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
        self.active_taken = true;
        return self.active_request;
    }

    pub fn consumePrepare(self: *PrepareRequests, layout: geometry_contract.PrepareLayout, token: tokens.SnapshotToken) !PrepareConsume {
        std.debug.assert(self.active_source != null);
        const source = self.active_source orelse return error.MissingPrepareSource;
        if (!publication_damage.sameSnapshotToken(self.active_request.token, token)) return error.MismatchedPrepareSource;
        std.debug.assert(publication_damage.sameSnapshotToken(self.active_request.token, token));
        return .{ .request = self.active_request, .layout = layout, .state = source };
    }

    pub fn latestToken(self: *const PrepareRequests) ?tokens.SnapshotToken {
        if (self.active_source != null) return self.active_request.token;
        return null;
    }

    pub fn requestFullPrepare(self: *PrepareRequests, force: *const fn (tokens.SnapshotToken) tokens.SnapshotToken) bool {
        if (self.active_source == null) return false;
        self.active_request = .{ .token = force(self.active_request.token), .allow_retained_reuse = false };
        self.active_taken = false;
        return true;
    }

    pub fn retryTakenPrepare(self: *PrepareRequests, token: tokens.SnapshotToken) bool {
        if (self.active_source == null) return false;
        if (!self.active_taken) return false;
        if (!publication_damage.sameSnapshotToken(self.active_request.token, token)) return false;
        std.debug.assert(publication_damage.sameSnapshotToken(self.active_request.token, token));
        self.active_taken = false;
        return true;
    }

    pub fn setCursorBlinkVisible(self: *PrepareRequests, visible: bool) bool {
        var changed = false;
        if (self.active_source) |*source| changed = publication_damage.setSourceCursorBlinkVisible(source, visible) or changed;
        return changed;
    }

    pub fn requestBlinkRefresh(self: *PrepareRequests) void {
        if (self.active_source == null) return;
        if (!self.active_taken) return;
        self.blink_refresh_pending = true;
    }

    pub fn retireAtOrBefore(self: *PrepareRequests, token: tokens.SnapshotToken) void {
        if (self.active_source == null) return;
        if (!self.active_request.token.isNewerThan(token)) self.dropActive();
    }

    pub fn refreshRetainedSlotViews(self: *PrepareRequests, slot_owner: *publication_storage.SourceSlot) void {
        if (self.active_source) |*source| {
            if (source.retained_storage) slot_owner.refreshRetainedSource(source);
        }
    }

    pub fn preparePending(self: *const PrepareRequests) bool {
        if (self.blink_refresh_pending) return true;
        if (self.active_source != null) return !self.active_taken;
        return false;
    }

    fn dropActive(self: *PrepareRequests) void {
        if (self.active_source) |*source| source.deinit(self.allocator);
        self.active_source = null;
        self.active_request = undefined;
        self.active_taken = false;
        self.blink_refresh_pending = false;
    }

    fn classify(self: *const PrepareRequests, source: vt_publication.PublicationSource, submitted_token: ?tokens.SnapshotToken, geometry_epoch: u64) tokens.DamageKind {
        const snapshot = source.snapshot();
        const damage_kind = publication_damage.classifyDirty(snapshot);
        const prior = self.priorSource() orelse return damage_kind;
        const prior_snapshot = prior.snapshot();
        const prior_matches_submitted = if (submitted_token) |token|
            prior_snapshot.snapshot_seq == token.snapshot_seq
        else
            false;
        if (self.geometryChanged(geometry_epoch)) {
            std.debug.assert(self.active_source != null);
            std.debug.assert(self.active_request.token.geometry_epoch != geometry_epoch);
            return .full;
        }
        if (snapshot.snapshot_seq == prior_snapshot.snapshot_seq) {
            if (publication_damage.samePublicationSource(prior, source)) return .none;
            if (publication_damage.cursorPresentationChanged(prior, source)) return .full;
            if (publication_damage.colorPresentationChanged(prior, source)) return .full;
            if (damage_kind == .partial and !prior_matches_submitted) return .full;
            return damage_kind;
        }
        if (publication_damage.cursorPresentationChanged(prior, source)) return .full;
        if (publication_damage.colorPresentationChanged(prior, source)) return .full;
        if (snapshot.cols != prior_snapshot.cols or snapshot.rows != prior_snapshot.rows) return .full;
        if (snapshot.is_alternate_screen != prior_snapshot.is_alternate_screen) return .full;
        if (snapshot.scroll_row != prior_snapshot.scroll_row) return .full;
        if (damage_kind == .partial and !prior_matches_submitted) return .full;
        return damage_kind;
    }

    fn geometryChanged(self: *const PrepareRequests, geometry_epoch: u64) bool {
        if (self.active_source != null) return self.active_request.token.geometry_epoch != geometry_epoch;
        return false;
    }

    fn priorSource(self: *const PrepareRequests) ?vt_publication.PublicationSource {
        if (self.active_source) |source| return source;
        return null;
    }
};

fn takeOwnedActiveSource(allocator: std.mem.Allocator, source: *vt_publication.PublicationSource) !vt_publication.PublicationSource {
    if (!source.retained_storage) return source.*;
    const cloned = try source.clone(allocator);
    std.debug.assert(!cloned.retained_storage);
    source.deinit(allocator);
    return cloned;
}

test "prepare requests keep no staged source" {
    var requests = PrepareRequests.init(std.testing.allocator);
    defer requests.deinit();
    try std.testing.expect(requests.active_source == null);
    try std.testing.expect(!requests.preparePending());
}

test "prepare requests ignore duplicate admitted source" {
    var requests = PrepareRequests.init(std.testing.allocator);
    defer requests.deinit();

    const first = requests.admitSource(try vt_publication.ownedTestSource(std.testing.allocator, 1, 'A'), null, 1);
    try std.testing.expect(first.admitted);

    const duplicate = requests.admitSource(try vt_publication.ownedTestSource(std.testing.allocator, 1, 'A'), null, 1);
    try std.testing.expect(!duplicate.admitted);
    try std.testing.expectEqual(tokens.DamageKind.none, duplicate.damage_kind);
    try std.testing.expectEqual(@as(u64, 1), requests.active_request.token.snapshot_seq);
}

test "prepare requests admit full retained-safe source when geometry changes" {
    var requests = PrepareRequests.init(std.testing.allocator);
    defer requests.deinit();

    const first_admission = requests.admitSource(try vt_publication.ownedTestSource(std.testing.allocator, 1, 'A'), null, 1);
    try std.testing.expect(first_admission.admitted);

    const submitted_request = requests.takePrepareRequest(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), submitted_request.token.geometry_epoch);

    const resize_admission = requests.admitSource(try vt_publication.ownedTestSource(std.testing.allocator, 1, 'A'), submitted_request.token, 2);
    try std.testing.expect(resize_admission.admitted);
    try std.testing.expectEqual(tokens.DamageKind.full, resize_admission.damage_kind);

    const resize_request = requests.takePrepareRequest(2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), resize_request.token.geometry_epoch);
    try std.testing.expectEqual(tokens.DamageKind.full, resize_request.token.damage_kind);
    try std.testing.expectEqual(@as(u64, 0), resize_request.token.damage_base_seq);
    try std.testing.expect(!resize_request.allow_retained_reuse);
}

test "prepare requests force full when partial source has stale submitted base" {
    var requests = PrepareRequests.init(std.testing.allocator);
    defer requests.deinit();

    const first = requests.admitSource(try vt_publication.ownedTestSource(std.testing.allocator, 2, 'A'), null, 1);
    try std.testing.expect(first.admitted);

    var source = try vt_publication.testSourceFromSnapshot(std.testing.allocator, .{
        .cols = 2,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 3,
        .dirty_epoch = 3,
        .is_alternate_screen = false,
        .dirty_rows = &[_]u8{1},
        .dirty_cols_start = &[_]u16{1},
        .dirty_cols_end = &[_]u16{1},
    });
    source.cells[0].codepoint = 'A';
    source.cells[1].codepoint = 'B';
    const admission = requests.admitSource(source, .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full }, 1);
    try std.testing.expect(admission.admitted);
    try std.testing.expectEqual(tokens.DamageKind.full, admission.damage_kind);
}

test "prepare requests schedule blink refresh after taken prepare" {
    var requests = PrepareRequests.init(std.testing.allocator);
    defer requests.deinit();

    var source = try vt_publication.ownedTestSource(std.testing.allocator, 1, 'A');
    source.cursor.blink = true;
    const admission = requests.admitSource(source, null, 1);
    try std.testing.expect(admission.admitted);
    _ = requests.takePrepareRequest(1) orelse return error.TestUnexpectedResult;

    requests.requestBlinkRefresh();
    const refreshed = requests.takePrepareRequest(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(tokens.DamageKind.full, refreshed.token.damage_kind);
    try std.testing.expectEqual(@as(u64, 0), refreshed.token.damage_base_seq);
    try std.testing.expect(!refreshed.allow_retained_reuse);
}

test "prepare requests reject retry token mismatch for taken prepare" {
    var requests = PrepareRequests.init(std.testing.allocator);
    defer requests.deinit();

    const admission = requests.admitSource(try vt_publication.ownedTestSource(std.testing.allocator, 3, 'A'), null, 1);
    try std.testing.expect(admission.admitted);
    const request = requests.takePrepareRequest(1) orelse return error.TestUnexpectedResult;
    const wrong = tokens.SnapshotToken{
        .snapshot_seq = request.token.snapshot_seq,
        .dirty_epoch = request.token.dirty_epoch + 1,
        .geometry_epoch = request.token.geometry_epoch,
        .damage_base_seq = request.token.damage_base_seq,
        .damage_kind = request.token.damage_kind,
    };
    try std.testing.expect(!requests.retryTakenPrepare(wrong));
    try std.testing.expect(requests.active_taken);
}

test "prepare requests retire active source at or before submitted token" {
    var requests = PrepareRequests.init(std.testing.allocator);
    defer requests.deinit();

    const admission = requests.admitSource(try vt_publication.ownedTestSource(std.testing.allocator, 5, 'A'), null, 1);
    try std.testing.expect(admission.admitted);

    requests.retireAtOrBefore(.{ .snapshot_seq = 4, .dirty_epoch = 4, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full });
    try std.testing.expect(requests.active_source != null);

    requests.retireAtOrBefore(.{ .snapshot_seq = 5, .dirty_epoch = 5, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full });
    try std.testing.expect(requests.active_source == null);
}
