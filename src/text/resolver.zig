const std = @import("std");
const surface = @import("../surface.zig");
const font_session = @import("../session/session.zig");
const symbol_map = @import("symbol_map.zig");

pub const ResolveStage = enum(u5) {
    blank,
    style_policy,
    codepoint_override,
    sprite_route,
    symbol_map,
    loaded_exact_match,
    regular_style_retry,
    configured_fallback,
    discovery_fallback,
    emoji_fallback,
    regular_any_presentation,
    missing_glyph,
};

pub const ResolveRequest = struct {
    codepoint: u32,
    style: surface.FontStyle,
    presentation: surface.TextPresentation,
    text_id: ?surface.CellTextId = null,
};

pub const ResolveHit = struct {
    stage: ResolveStage,
    face_id: u32,
    glyph_id: u32,
};

pub const ResolveMiss = struct {
    stage: ResolveStage,
    missing: surface.MissingGlyph,
};

pub const ResolveResult = union(enum) {
    hit: ResolveHit,
    miss: ResolveMiss,
};

pub const ResolveCounters = struct {
    missing_glyphs: u64 = 0,
    fallback_hits: u64 = 0,
    fallback_misses: u64 = 0,
    shaped_clusters: u64 = 0,
    resolved_runs: u64 = 0,
    sprite_routes: u64 = 0,
    face_checks: u64 = 0,
    face_cache_hits: u64 = 0,
    shape_requests: u64 = 0,
    shape_cache_hits: u64 = 0,
};

pub const ResolveObservability = struct {
    counters: ResolveCounters = .{},
    stage: ResolveStage = .style_policy,
};

pub const ResolveFallbackFaceFn = *const fn (ctx: *anyopaque, req: ResolveRequest) ResolveResult;

pub const ResolveFallbackFaceOp = struct {
    ctx: *anyopaque,
    call: ResolveFallbackFaceFn,

    pub fn resolve(self: ResolveFallbackFaceOp, req: ResolveRequest) ResolveResult {
        return self.call(self.ctx, req);
    }
};
pub const ResolveCellRequest = struct {
    text: surface.CellText,
    style: surface.FontStyle,
    presentation: surface.TextPresentation,
};

pub const ResolveCellResult = union(enum) {
    hit: surface.ResolvedRun,
    miss: surface.MissingGlyph,
    sprite_route: surface.SpecialSpriteRoute,
};

pub const OwnedResolvedRuns = struct {
    allocator: std.mem.Allocator,
    runs: []surface.ResolvedRun,
    missing: []surface.MissingGlyph,
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
    face_id: surface.FontFaceId,
};

pub const OwnedResolvedClusterFaces = struct {
    allocator: std.mem.Allocator,
    faces: []ResolvedClusterFace,
    missing: []surface.MissingGlyph,
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
    route: surface.SpecialSpriteRoute,
};

const ResolveMemoKey = struct {
    text_id: u32,
    style: surface.FontStyle,
    presentation: surface.TextPresentation,
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
    runs: std.ArrayListUnmanaged(surface.ResolvedRun) = .empty,
    cluster_faces: std.ArrayListUnmanaged(ResolvedClusterFace) = .empty,
    missing: std.ArrayListUnmanaged(surface.MissingGlyph) = .empty,
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
    clusters: []const surface.CellCluster,
    text_cache: surface.LineTextCache,
    grid_metrics: surface.GridMetrics,
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

    const runs = try allocator.dupe(surface.ResolvedRun, scratch.runs.items);
    errdefer allocator.free(runs);
    const missing_list = try allocator.dupe(surface.MissingGlyph, scratch.missing.items);
    errdefer allocator.free(missing_list);
    const sprite_routes = try allocator.dupe(SpriteRouteHit, scratch.sprite_routes.items);
    return .{ .allocator = allocator, .runs = runs, .missing = missing_list, .sprite_routes = sprite_routes };
}

pub fn resolveClusterFaces(
    allocator: std.mem.Allocator,
    scratch: *RetainedScratch,
    session: font_session.FontSession,
    clusters: []const surface.CellCluster,
    text_cache: surface.LineTextCache,
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
    const missing_list = try allocator.dupe(surface.MissingGlyph, scratch.missing.items);
    return .{ .allocator = allocator, .faces = faces, .missing = missing_list };
}

fn resolveFace(session: font_session.FontSession, cluster: surface.CellCluster, text: surface.CellText) ?font_session.FontFaceRecord {
    if (session.findSymbol(cluster.first_cp)) |face| return face;
    if (session.findStyle(cluster.style, cluster.presentation, text)) |face| return face;
    return session.findFallback(cluster.style, cluster.presentation, text);
}

fn resolveFaceMemoized(scratch: *RetainedScratch, session: font_session.FontSession, cluster: surface.CellCluster, text: surface.CellText) !?font_session.FontFaceRecord {
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

fn textForCluster(cache: surface.LineTextCache, cluster: surface.CellCluster) surface.CellText {
    const idx = cluster.text_id.value;
    if (idx < count32(cache.texts)) return cache.texts[@intCast(idx)];
    return .{ .id = cluster.text_id, .first_cp = cluster.first_cp, .codepoints = &.{cluster.first_cp} };
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

fn resolvedRun(cluster_start: u32, cluster_count: u32, face_id: surface.FontFaceId, style: surface.FontStyle, presentation: surface.TextPresentation) surface.ResolvedRun {
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

pub fn missing(req: ResolveCellRequest, reason: surface.MissingGlyphReason) ResolveCellResult {
    return .{ .miss = .{
        .codepoint = req.text.first_cp,
        .style = req.style,
        .presentation = req.presentation,
        .reason = reason,
    } };
}

pub fn stageForRoute(route: surface.SpecialSpriteRoute) ResolveStage {
    return switch (route) {
        .blank => .blank,
        .box, .block, .braille, .powerline, .legacy_computing => .sprite_route,
    };
}

test "resolve fallback face op dispatches" {
    const Stub = struct {
        hits: u8 = 0,
        last_request: ResolveRequest = undefined,

        fn resolve(ctx: *anyopaque, req: ResolveRequest) ResolveResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;
            self.last_request = req;
            return .{ .hit = .{
                .stage = if (req.style == .regular) .loaded_exact_match else .regular_style_retry,
                .face_id = 42,
                .glyph_id = req.codepoint,
            } };
        }
    };

    var stub = Stub{};
    const resolve_op = ResolveFallbackFaceOp{ .ctx = &stub, .call = Stub.resolve };
    const resolved = resolve_op.resolve(.{
        .codepoint = 'A',
        .style = .bold,
        .presentation = .any,
        .text_id = .{ .value = 7 },
    });
    try std.testing.expectEqual(@as(u8, 1), stub.hits);
    try std.testing.expectEqual(@as(u32, 'A'), stub.last_request.codepoint);
    try std.testing.expectEqual(surface.FontStyle.bold, stub.last_request.style);
    try std.testing.expectEqual(surface.TextPresentation.any, stub.last_request.presentation);
    try std.testing.expectEqual(@as(u32, 7), stub.last_request.text_id.?.value);
    switch (resolved) {
        .hit => |hit| {
            try std.testing.expectEqual(.regular_style_retry, hit.stage);
            try std.testing.expectEqual(@as(u32, 42), hit.face_id);
            try std.testing.expectEqual(@as(u32, 'A'), hit.glyph_id);
        },
        .miss => return error.UnexpectedResolveMiss,
    }
}

test "resolver groups adjacent primary clusters and separates sprite routes" {
    const clusters = [_]surface.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'a', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'b', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .first_cp = 0x2500, .style = .regular, .presentation = .any },
    };
    const texts = [_]surface.CellText{
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
    try std.testing.expectEqual(surface.SpecialSpriteRoute.box, resolved.sprite_routes[0].route);
}

test "resolver separates shared and fallback special sprite routes before font resolution" {
    const Case = struct { cp: u32, route: surface.SpecialSpriteRoute };
    const cases = [_]Case{
        .{ .cp = 0x2500, .route = .box },
        .{ .cp = 0x257f, .route = .box },
        .{ .cp = 0x2580, .route = .block },
        .{ .cp = 0x259f, .route = .block },
        .{ .cp = 0x2801, .route = .braille },
        .{ .cp = 0x28ff, .route = .braille },
        .{ .cp = 0xe0b0, .route = .powerline },
        .{ .cp = 0xe0bf, .route = .powerline },
        .{ .cp = 0xe0d6, .route = .powerline },
        .{ .cp = 0xe0d7, .route = .powerline },
        .{ .cp = 0x1fb00, .route = .legacy_computing },
        .{ .cp = 0x1fb3b, .route = .legacy_computing },
        .{ .cp = 0x1fb3c, .route = .legacy_computing },
        .{ .cp = 0x1fb67, .route = .legacy_computing },
        .{ .cp = 0x1fb68, .route = .legacy_computing },
        .{ .cp = 0x1fb6f, .route = .legacy_computing },
        .{ .cp = 0x1fb70, .route = .legacy_computing },
        .{ .cp = 0x1fb7b, .route = .legacy_computing },
        .{ .cp = 0x1fb7c, .route = .legacy_computing },
        .{ .cp = 0x1fb8b, .route = .legacy_computing },
        .{ .cp = 0x1fb8c, .route = .legacy_computing },
        .{ .cp = 0x1fb93, .route = .legacy_computing },
        .{ .cp = 0x1fb9f, .route = .legacy_computing },
        .{ .cp = 0x1fba0, .route = .legacy_computing },
        .{ .cp = 0x1fbae, .route = .legacy_computing },
        .{ .cp = 0x1cd00, .route = .legacy_computing },
        .{ .cp = 0x1cde5, .route = .legacy_computing },
        .{ .cp = 0x1fbe6, .route = .legacy_computing },
        .{ .cp = 0x1fbe7, .route = .legacy_computing },
        .{ .cp = 0xf5d0, .route = .legacy_computing },
        .{ .cp = 0xf60d, .route = .legacy_computing },
    };

    for (cases) |case| {
        const clusters = [_]surface.CellCluster{.{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = case.cp, .style = .regular, .presentation = .any }};
        const texts = [_]surface.CellText{.{ .id = .{ .value = 0 }, .first_cp = case.cp, .codepoints = &.{case.cp} }};
        var scratch = RetainedScratch{};
        defer scratch.deinit(std.testing.allocator);
        try scratch.configure(std.testing.allocator, count32(clusters));
        var resolved = try resolveClusters(std.testing.allocator, &scratch, .{}, &clusters, .{ .texts = &texts }, .{ .cols = 1, .rows = 1 });
        defer resolved.deinit();
        try std.testing.expectEqual(@as(u32, 0), count32(resolved.runs));
        try std.testing.expectEqual(@as(u32, 1), count32(resolved.sprite_routes));
        try std.testing.expectEqual(case.route, resolved.sprite_routes[0].route);
    }
}

test "resolver falls back when primary cannot cover whole cell text" {
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    const session = font_session.FontSession{ .faces = &faces };
    const clusters = [_]surface.CellCluster{.{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'i', .style = .regular, .presentation = .any }};
    const texts = [_]surface.CellText{.{ .id = .{ .value = 0 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } }};
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
        fn has(ctx: *anyopaque, face_id: surface.FontFaceId, text: surface.CellText) bool {
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
    const clusters = [_]surface.CellCluster{.{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any }};
    const texts = [_]surface.CellText{.{ .id = .{ .value = 0 }, .first_cp = 'x', .codepoints = &.{ 'x', 0x0332 } }};
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

        fn has(ctx: *anyopaque, face_id: surface.FontFaceId, text: surface.CellText) bool {
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
    const clusters = [_]surface.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 0 }, .first_cell = 1, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 0 }, .first_cell = 2, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
    };
    const texts = [_]surface.CellText{.{ .id = .{ .value = 0 }, .first_cp = 'x', .codepoints = &.{'x'} }};
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
    const clusters = [_]surface.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'a', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'b', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .first_cp = 'c', .style = .regular, .presentation = .any },
    };
    const texts = [_]surface.CellText{
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
