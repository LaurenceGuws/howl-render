const std = @import("std");
const contract = @import("contract.zig");
const font_resolve = @import("resolve.zig");
const font_session = @import("session.zig");
const symbol_map = @import("classify/symbol_map.zig");

pub const ResolveCellRequest = struct {
    text: contract.CellText,
    style: contract.FontStyle,
    presentation: contract.TextPresentation,
};

pub const ResolveCellResult = union(enum) {
    hit: contract.ResolvedRun,
    miss: contract.MissingGlyph,
    sprite_route: contract.SpecialSpriteRoute,
};

pub const OwnedResolvedRuns = struct {
    allocator: std.mem.Allocator,
    runs: []contract.ResolvedRun,
    missing: []contract.MissingGlyph,
    sprite_routes: []SpriteRouteHit,
    owned: bool = true,

    pub fn deinit(self: *OwnedResolvedRuns) void {
        if (self.owned) {
            self.allocator.free(self.runs);
            self.allocator.free(self.missing);
            self.allocator.free(self.sprite_routes);
        }
        self.* = undefined;
    }
};

pub const ResolvedClusterFace = struct {
    cluster_index: u32,
    face_id: contract.FontFaceId,
};

pub const OwnedResolvedClusterFaces = struct {
    allocator: std.mem.Allocator,
    faces: []ResolvedClusterFace,
    missing: []contract.MissingGlyph,
    owned: bool = true,

    pub fn deinit(self: *OwnedResolvedClusterFaces) void {
        if (self.owned) {
            self.allocator.free(self.faces);
            self.allocator.free(self.missing);
        }
        self.* = undefined;
    }
};

pub const SpriteRouteHit = struct {
    cluster_index: u32,
    route: contract.SpecialSpriteRoute,
};

const ResolveMemoKey = struct {
    text_id: u32,
    style: contract.FontStyle,
    presentation: contract.TextPresentation,
};

const ResolveMemoValue = union(enum) {
    hit: font_session.FontFaceRecord,
    miss,
};

const ResolveMemoEntry = struct {
    key: ResolveMemoKey,
    value: ResolveMemoValue,
};

pub const RetainedScratch = struct {
    runs: std.ArrayListUnmanaged(contract.ResolvedRun) = .empty,
    cluster_faces: std.ArrayListUnmanaged(ResolvedClusterFace) = .empty,
    missing: std.ArrayListUnmanaged(contract.MissingGlyph) = .empty,
    sprite_routes: std.ArrayListUnmanaged(SpriteRouteHit) = .empty,
    memo: std.ArrayListUnmanaged(ResolveMemoEntry) = .empty,
    max_clusters: u32 = 0,

    pub fn deinit(self: *RetainedScratch, allocator: std.mem.Allocator) void {
        self.memo.deinit(allocator);
        self.sprite_routes.deinit(allocator);
        self.missing.deinit(allocator);
        self.cluster_faces.deinit(allocator);
        self.runs.deinit(allocator);
        self.* = undefined;
    }

    pub fn configure(self: *RetainedScratch, allocator: std.mem.Allocator, max_clusters: u32) !void {
        if (self.max_clusters >= max_clusters) return;
        const capacity: usize = @intCast(max_clusters);
        try self.runs.ensureTotalCapacity(allocator, capacity);
        try self.cluster_faces.ensureTotalCapacity(allocator, capacity);
        try self.missing.ensureTotalCapacity(allocator, capacity);
        try self.sprite_routes.ensureTotalCapacity(allocator, capacity);
        try self.memo.ensureTotalCapacity(allocator, capacity);
        self.max_clusters = max_clusters;
    }

    fn reset(self: *RetainedScratch, cluster_count: u32) !void {
        if (cluster_count > self.max_clusters) return error.ResolveScratchOverflow;
        self.runs.clearRetainingCapacity();
        self.cluster_faces.clearRetainingCapacity();
        self.missing.clearRetainingCapacity();
        self.sprite_routes.clearRetainingCapacity();
        self.memo.clearRetainingCapacity();
    }
};

pub fn resolveClusters(
    allocator: std.mem.Allocator,
    scratch: *RetainedScratch,
    session: font_session.FontSession,
    clusters: []const contract.CellCluster,
    text_cache: contract.LineTextCache,
    grid_metrics: contract.GridMetrics,
) !OwnedResolvedRuns {
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const cluster_count = count32(clusters);
    try scratch.reset(cluster_count);
    var idx: u32 = 0;
    while (idx < cluster_count) {
        const cluster = clusters[@intCast(idx)];
        const route = symbol_map.builtinRoute(cluster.first_cp);
        if (route) |r| {
            scratch.sprite_routes.appendAssumeCapacity(.{ .cluster_index = idx, .route = r });
            idx += 1;
            continue;
        }

        const text = textForCluster(text_cache, cluster);
        const face = (try resolveFaceMemoized(scratch, session, cluster, text)) orelse {
            scratch.missing.appendAssumeCapacity(.{
                .codepoint = cluster.first_cp,
                .style = cluster.style,
                .presentation = cluster.presentation,
                .reason = .no_fallback_face,
            });
            idx += 1;
            continue;
        };

        const start = idx;
        idx += 1;
        while (idx < cluster_count) : (idx += 1) {
            const next = clusters[@intCast(idx)];
            if (symbol_map.builtinRoute(next.first_cp) != null) break;
            if (next.first_cell / cols != cluster.first_cell / cols) break;
            const next_face = (try resolveFaceMemoized(scratch, session, next, textForCluster(text_cache, next))) orelse break;
            if (next_face.id.value != face.id.value or next.style != cluster.style or next.presentation != cluster.presentation) break;
        }

        scratch.runs.appendAssumeCapacity(resolvedRun(@intCast(start), @intCast(idx - start), face.id, cluster.style, cluster.presentation));
    }

    const runs = try allocator.dupe(contract.ResolvedRun, scratch.runs.items);
    errdefer allocator.free(runs);
    const missing_list = try allocator.dupe(contract.MissingGlyph, scratch.missing.items);
    errdefer allocator.free(missing_list);
    const sprite_routes = try allocator.dupe(SpriteRouteHit, scratch.sprite_routes.items);
    return .{ .allocator = allocator, .runs = runs, .missing = missing_list, .sprite_routes = sprite_routes };
}

pub fn resolveClusterFaces(
    allocator: std.mem.Allocator,
    scratch: *RetainedScratch,
    session: font_session.FontSession,
    clusters: []const contract.CellCluster,
    text_cache: contract.LineTextCache,
) !OwnedResolvedClusterFaces {
    try scratch.reset(count32(clusters));

    for (clusters, 0..) |cluster, idx| {
        const text = textForCluster(text_cache, cluster);
        const face = (try resolveFaceMemoized(scratch, session, cluster, text)) orelse {
            scratch.missing.appendAssumeCapacity(.{
                .codepoint = cluster.first_cp,
                .style = cluster.style,
                .presentation = cluster.presentation,
                .reason = .no_fallback_face,
            });
            continue;
        };
        scratch.cluster_faces.appendAssumeCapacity(.{ .cluster_index = @intCast(idx), .face_id = face.id });
    }

    const faces = try allocator.dupe(ResolvedClusterFace, scratch.cluster_faces.items);
    errdefer allocator.free(faces);
    const missing_list = try allocator.dupe(contract.MissingGlyph, scratch.missing.items);
    return .{ .allocator = allocator, .faces = faces, .missing = missing_list };
}

fn resolveFace(session: font_session.FontSession, cluster: contract.CellCluster, text: contract.CellText) ?font_session.FontFaceRecord {
    if (session.findSymbol(cluster.first_cp)) |face| return face;
    if (session.findStyle(cluster.style, cluster.presentation, text)) |face| return face;
    return session.findFallback(cluster.style, cluster.presentation, text);
}

fn resolveFaceMemoized(scratch: *RetainedScratch, session: font_session.FontSession, cluster: contract.CellCluster, text: contract.CellText) !?font_session.FontFaceRecord {
    const key = ResolveMemoKey{
        .text_id = text.id.value,
        .style = cluster.style,
        .presentation = cluster.presentation,
    };
    for (scratch.memo.items) |entry| {
        if (memoKeyEql(entry.key, key)) return switch (entry.value) {
            .hit => |face| face,
            .miss => null,
        };
    }

    if (scratch.memo.items.len >= scratch.memo.capacity) return error.ResolveScratchOverflow;
    const value = if (resolveFace(session, cluster, text)) |face|
        ResolveMemoValue{ .hit = face }
    else
        .miss;
    scratch.memo.appendAssumeCapacity(.{ .key = key, .value = value });
    return switch (value) {
        .hit => |face| face,
        .miss => null,
    };
}

fn memoKeyEql(lhs: ResolveMemoKey, rhs: ResolveMemoKey) bool {
    return lhs.text_id == rhs.text_id and lhs.style == rhs.style and lhs.presentation == rhs.presentation;
}

fn textForCluster(cache: contract.LineTextCache, cluster: contract.CellCluster) contract.CellText {
    const idx = cluster.text_id.value;
    if (idx < count32(cache.texts)) return cache.texts[@intCast(idx)];
    return .{ .id = cluster.text_id, .first_cp = cluster.first_cp, .codepoints = &.{cluster.first_cp} };
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

fn resolvedRun(cluster_start: u32, cluster_count: u32, face_id: contract.FontFaceId, style: contract.FontStyle, presentation: contract.TextPresentation) contract.ResolvedRun {
    return .{ .run = .{
        .cluster_start = cluster_start,
        .cluster_count = cluster_count,
        .font = .{
            .face_id = face_id,
            .style = style,
            .presentation = presentation,
        },
    } };
}

pub fn missing(req: ResolveCellRequest, reason: contract.MissingGlyphReason) ResolveCellResult {
    return .{ .miss = .{
        .codepoint = req.text.first_cp,
        .style = req.style,
        .presentation = req.presentation,
        .reason = reason,
    } };
}

pub fn stageForRoute(route: contract.SpecialSpriteRoute) font_resolve.ResolveStage {
    return switch (route) {
        .blank => .blank,
        .box, .block, .braille, .powerline, .legacy_computing => .sprite_route,
    };
}

test "resolver groups adjacent primary clusters and separates sprite routes" {
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'a', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'b', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .first_cp = 0x2500, .style = .regular, .presentation = .any },
    };
    const texts = [_]contract.CellText{
        .{ .id = .{ .value = 0 }, .first_cp = 'a', .codepoints = &.{'a'} },
        .{ .id = .{ .value = 1 }, .first_cp = 'b', .codepoints = &.{'b'} },
        .{ .id = .{ .value = 2 }, .first_cp = 0x2500, .codepoints = &.{0x2500} },
    };
    var scratch = RetainedScratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.configure(std.testing.allocator, count32(clusters));
    var resolved = try resolveClusters(std.testing.allocator, &scratch, .{}, &clusters, .{ .texts = &texts }, .{ .cols = 3, .rows = 1 });
    defer resolved.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(resolved.runs));
    try std.testing.expectEqual(@as(u32, 2), resolved.runs[0].run.cluster_count);
    try std.testing.expectEqual(@as(u32, 1), count32(resolved.sprite_routes));
    try std.testing.expectEqual(contract.SpecialSpriteRoute.box, resolved.sprite_routes[0].route);
}

test "resolver falls back when primary cannot cover whole cell text" {
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    const session = font_session.FontSession{ .faces = &faces };
    const clusters = [_]contract.CellCluster{.{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'i', .style = .regular, .presentation = .any }};
    const texts = [_]contract.CellText{.{ .id = .{ .value = 0 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } }};
    var scratch = RetainedScratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.configure(std.testing.allocator, count32(clusters));
    var resolved = try resolveClusters(std.testing.allocator, &scratch, session, &clusters, .{ .texts = &texts }, .{ .cols = 3, .rows = 1 });
    defer resolved.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(resolved.runs));
    try std.testing.expectEqual(@as(u32, 2), resolved.runs[0].run.font.face_id.value);
}

test "resolver uses face provider validation" {
    const Provider = struct {
        fn has(ctx: *anyopaque, face_id: contract.FontFaceId, text: contract.CellText) bool {
            _ = ctx;
            if (face_id.value == 1 and text.codepoints.len > 1) return false;
            return true;
        }
    };
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    var dummy: u8 = 0;
    const session = font_session.FontSession{ .faces = &faces, .provider = .{ .ctx = &dummy, .has_cell_text = Provider.has } };
    const clusters = [_]contract.CellCluster{.{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any }};
    const texts = [_]contract.CellText{.{ .id = .{ .value = 0 }, .first_cp = 'x', .codepoints = &.{ 'x', 0x0332 } }};
    var scratch = RetainedScratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.configure(std.testing.allocator, count32(clusters));
    var resolved = try resolveClusters(std.testing.allocator, &scratch, session, &clusters, .{ .texts = &texts }, .{ .cols = 3, .rows = 1 });
    defer resolved.deinit();
    try std.testing.expectEqual(@as(u32, 2), resolved.runs[0].run.font.face_id.value);
}

test "resolver memoizes repeated text face validation" {
    const Provider = struct {
        calls: u8 = 0,

        fn has(ctx: *anyopaque, face_id: contract.FontFaceId, text: contract.CellText) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (face_id.value == 1 and text.first_cp == 'x') return false;
            return true;
        }
    };

    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 0 }, .first_cell = 1, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 0 }, .first_cell = 2, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
    };
    const texts = [_]contract.CellText{.{ .id = .{ .value = 0 }, .first_cp = 'x', .codepoints = &.{'x'} }};
    var provider = Provider{};
    const session = font_session.FontSession{ .faces = &faces, .provider = .{ .ctx = &provider, .has_cell_text = Provider.has } };

    var scratch = RetainedScratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.configure(std.testing.allocator, count32(clusters));
    var resolved = try resolveClusters(std.testing.allocator, &scratch, session, &clusters, .{ .texts = &texts }, .{ .cols = 3, .rows = 1 });
    defer resolved.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(resolved.runs));
    try std.testing.expectEqual(@as(u32, 2), resolved.runs[0].run.font.face_id.value);
    try std.testing.expectEqual(@as(u8, 2), provider.calls);
}

test "resolver retained scratch is bounded by configured cluster limit" {
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'a', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'b', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .first_cp = 'c', .style = .regular, .presentation = .any },
    };
    const texts = [_]contract.CellText{
        .{ .id = .{ .value = 0 }, .first_cp = 'a', .codepoints = &.{'a'} },
        .{ .id = .{ .value = 1 }, .first_cp = 'b', .codepoints = &.{'b'} },
        .{ .id = .{ .value = 2 }, .first_cp = 'c', .codepoints = &.{'c'} },
    };

    var scratch = RetainedScratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.configure(std.testing.allocator, 2);
    try std.testing.expectError(
        error.ResolveScratchOverflow,
        resolveClusters(std.testing.allocator, &scratch, .{}, &clusters, .{ .texts = &texts }, .{ .cols = 3, .rows = 1 }),
    );
}
