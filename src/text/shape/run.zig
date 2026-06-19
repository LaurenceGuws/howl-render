const std = @import("std");
const render = @import("../../grid/scene.zig");
const cluster_shape = @import("cluster.zig");

pub const ShapeRunRequest = struct {
    run: render.ResolvedRun,
    clusters: []const render.CellCluster,
};

pub const ShapeRunResult = struct {
    glyphs: []const render.GlyphInstance,
};

pub const ShapeRunFn = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    run: render.ResolvedRun,
    text_cache: render.LineTextCache,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
) anyerror!OwnedShapedRun;

pub const Shaper = struct {
    ctx: *anyopaque,
    shape_run: ShapeRunFn,

    pub fn shapeRun(
        self: Shaper,
        allocator: std.mem.Allocator,
        run: render.ResolvedRun,
        text_cache: render.LineTextCache,
        clusters: []const render.CellCluster,
        cell_metrics: render.CellMetrics,
    ) !OwnedShapedRun {
        return self.shape_run(self.ctx, allocator, run, text_cache, clusters, cell_metrics);
    }
};

pub const OwnedShapedRun = struct {
    allocator: std.mem.Allocator,
    run: render.ResolvedRun,
    glyphs: []render.GlyphInstance,

    pub fn deinit(self: *OwnedShapedRun) void {
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }
};

pub const OwnedShapedRuns = struct {
    allocator: std.mem.Allocator,
    runs: []OwnedShapedRun,
    owned: bool = true,

    pub fn deinit(self: *OwnedShapedRuns) void {
        if (self.owned) {
            for (self.runs) |*run| run.deinit();
            self.allocator.free(self.runs);
        }
        self.* = undefined;
    }
};

pub const OwnedProvisionalRuns = struct {
    allocator: std.mem.Allocator,
    runs: []render.ResolvedRun,

    pub fn deinit(self: *OwnedProvisionalRuns) void {
        self.allocator.free(self.runs);
        self.* = undefined;
    }
};

pub const RetainedProvisionalRunScratch = struct {
    runs: []render.ResolvedRun = &.{},
    max_runs: u32 = 0,

    pub fn deinit(self: *RetainedProvisionalRunScratch, allocator: std.mem.Allocator) void {
        if (self.runs.len > 0) allocator.free(self.runs);
        self.* = undefined;
    }

    pub fn configure(self: *RetainedProvisionalRunScratch, allocator: std.mem.Allocator, max_runs: u32) !void {
        if (max_runs <= self.max_runs) return;
        const runs = try allocator.alloc(render.ResolvedRun, @intCast(max_runs));
        if (self.runs.len > 0) allocator.free(self.runs);
        self.runs = runs;
        self.max_runs = max_runs;
    }

    fn require(self: RetainedProvisionalRunScratch, run_count: u32) !void {
        if (run_count > self.max_runs) return error.ClusterScratchOverflow;
    }
};

pub fn emptyResult() ShapeRunResult {
    return .{ .glyphs = &.{} };
}

pub fn buildProvisionalRuns(allocator: std.mem.Allocator, clusters: []const render.CellCluster, face_id: render.FontFaceId) !OwnedProvisionalRuns {
    if (clusters.len == 0) {
        return .{ .allocator = allocator, .runs = try allocator.alloc(render.ResolvedRun, 0) };
    }

    var scratch = RetainedProvisionalRunScratch{};
    defer scratch.deinit(allocator);
    try scratch.configure(allocator, count32(clusters));
    return buildProvisionalRunsScratch(allocator, &scratch, clusters, face_id);
}

pub fn buildProvisionalRunsScratch(allocator: std.mem.Allocator, scratch: *RetainedProvisionalRunScratch, clusters: []const render.CellCluster, face_id: render.FontFaceId) !OwnedProvisionalRuns {
    if (clusters.len == 0) {
        return .{ .allocator = allocator, .runs = try allocator.alloc(render.ResolvedRun, 0) };
    }
    try scratch.require(count32(clusters));

    var prev = clusters[0];
    var start: u32 = 0;
    var run_count: u32 = 0;
    for (clusters[1..], 1..) |current_cluster, idx| {
        if (current_cluster.style != prev.style or current_cluster.presentation != prev.presentation) {
            scratch.runs[@intCast(run_count)] = resolvedRun(start, @intCast(idx - start), face_id, prev.style, prev.presentation);
            run_count += 1;
            start = @intCast(idx);
        }
        prev = current_cluster;
    }
    scratch.runs[@intCast(run_count)] = resolvedRun(start, @intCast(clusters.len - start), face_id, prev.style, prev.presentation);
    run_count += 1;

    return .{ .allocator = allocator, .runs = try allocator.dupe(render.ResolvedRun, scratch.runs[0..@intCast(run_count)]) };
}

pub fn shapeResolvedRunsWithShaper(
    allocator: std.mem.Allocator,
    shaper: Shaper,
    runs: []const render.ResolvedRun,
    text_cache: render.LineTextCache,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
) !OwnedShapedRuns {
    const shaped = try allocator.alloc(OwnedShapedRun, runs.len);
    errdefer allocator.free(shaped);

    var initialized: u32 = 0;
    errdefer {
        for (shaped[0..@intCast(initialized)]) |*run| run.deinit();
    }

    for (runs, 0..) |run, idx| {
        shaped[idx] = try shaper.shapeRun(allocator, run, text_cache, clusters, cell_metrics);
        initialized += 1;
    }

    return .{ .allocator = allocator, .runs = shaped };
}

pub fn defaultShaper() Shaper {
    return .{ .ctx = undefined, .shape_run = shapeRunThunk };
}

fn shapeRunThunk(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    run: render.ResolvedRun,
    text_cache: render.LineTextCache,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
) anyerror!OwnedShapedRun {
    return shapeRun(allocator, run, text_cache, clusters, cell_metrics);
}

pub fn shapeRun(
    allocator: std.mem.Allocator,
    run: render.ResolvedRun,
    text_cache: render.LineTextCache,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
) !OwnedShapedRun {
    const window = runClusterWindow(run, clusters);
    const glyphs = try allocator.alloc(render.GlyphInstance, @intCast(window.end - window.start));
    errdefer allocator.free(glyphs);

    for (clusters[@intCast(window.start)..@intCast(window.end)], 0..) |cluster, idx| {
        const text = textForCluster(text_cache, cluster);
        glyphs[idx] = .{
            .face_id = run.run.font.face_id,
            .glyph_id = text.first_cp,
            .cluster_index = window.start + @as(u32, @intCast(idx)),
            .x_offset_px = 0,
            .y_offset_px = 0,
            .x_advance_px = @floatFromInt(@as(u32, @max(cluster.cell_span, 1)) * @as(u32, cell_metrics.cell_w_px)),
        };
    }

    return .{ .allocator = allocator, .run = run, .glyphs = glyphs };
}

fn textForCluster(text_cache: render.LineTextCache, cluster: render.CellCluster) render.CellText {
    const idx = cluster.text_id.value;
    std.debug.assert(idx < count32(text_cache.texts));
    return text_cache.texts[@intCast(idx)];
}

fn resolvedRun(cluster_start: u32, cluster_count: u32, face_id: render.FontFaceId, style: render.FontStyle, presentation: render.TextPresentation) render.ResolvedRun {
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

const RunClusterWindow = struct {
    start: u32,
    end: u32,
};

fn runClusterWindow(run: render.ResolvedRun, clusters: []const render.CellCluster) RunClusterWindow {
    const start = run.run.cluster_start;
    const count = run.run.cluster_count;
    const clusters_len = clusterCount(clusters);

    std.debug.assert(start <= clusters_len);
    std.debug.assert(count <= clusters_len - start);

    return .{ .start = start, .end = start + count };
}

fn clusterCount(clusters: []const render.CellCluster) u32 {
    return @intCast(clusters.len);
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

test "stub shaper emits one glyph per cluster with run face" {
    const clusters = [_]render.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'a', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'b', .style = .regular, .presentation = .any },
    };
    const text_cache = render.LineTextCache{ .texts = &.{
        .{ .id = .{ .value = 0 }, .first_cp = 'a', .codepoints = &.{'a'} },
        .{ .id = .{ .value = 1 }, .first_cp = 'b', .codepoints = &.{'b'} },
    } };
    const run = render.ResolvedRun{ .run = .{
        .cluster_start = 0,
        .cluster_count = 2,
        .font = .{ .face_id = .{ .value = 9 }, .style = .regular, .presentation = .any },
    } };
    var shaped = try shapeRun(std.testing.allocator, run, text_cache, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer shaped.deinit();
    try std.testing.expectEqual(@as(u32, 2), count32(shaped.glyphs));
    try std.testing.expectEqual(@as(u32, 9), shaped.glyphs[0].face_id.value);
    try std.testing.expectEqual(@as(u32, 'b'), shaped.glyphs[1].glyph_id);
}

test "cell inputs build text cache renderable cells clusters and runs" {
    const allocator = std.testing.allocator;
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 'B', .fg = white, .bg = black },
        .{ .codepoint = 'C', .fg = white, .bg = black, .continuation = true },
    };

    var cache = try cluster_shape.buildLineTextCacheFromCells(allocator, &cells);
    defer cache.deinit();
    var renderable = try cluster_shape.buildRenderableCellsFromCells(allocator, &cells, cache.view());
    defer renderable.deinit();
    var clusters = try cluster_shape.extractClusters(allocator, renderable.cells, cache.view());
    defer clusters.deinit();
    var runs = try buildProvisionalRuns(allocator, clusters.clusters, .{ .value = 1 });
    defer runs.deinit();

    try std.testing.expectEqual(@as(u32, 3), count32(cache.texts));
    try std.testing.expectEqual(@as(u32, 2), count32(clusters.clusters));
    try std.testing.expectEqual(@as(u32, 1), count32(runs.runs));
    try std.testing.expectEqual(@as(u32, 2), runs.runs[0].run.cluster_count);
    try std.testing.expectEqual(render.SemanticColorKind.default, renderable.cells[0].semantic_fg.kind);
    try std.testing.expectEqual(render.SemanticColorKind.default, renderable.cells[0].semantic_bg.kind);
}

test "cell inputs preserve style and presentation into renderables clusters and runs" {
    const allocator = std.testing.allocator;
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{
        .{ .codepoint = 'A', .style = .bold, .presentation = .text, .fg = white, .bg = black },
        .{ .codepoint = 'B', .style = .italic, .presentation = .emoji, .fg = white, .bg = black },
    };

    var cache = try cluster_shape.buildLineTextCacheFromCells(allocator, &cells);
    defer cache.deinit();
    var renderable = try cluster_shape.buildRenderableCellsFromCells(allocator, &cells, cache.view());
    defer renderable.deinit();
    var clusters = try cluster_shape.extractClusters(allocator, renderable.cells, cache.view());
    defer clusters.deinit();
    var runs = try buildProvisionalRuns(allocator, clusters.clusters, .{ .value = 9 });
    defer runs.deinit();

    try std.testing.expectEqual(render.FontStyle.bold, renderable.cells[0].style);
    try std.testing.expectEqual(render.TextPresentation.text, renderable.cells[0].presentation);
    try std.testing.expectEqual(render.FontStyle.italic, renderable.cells[1].style);
    try std.testing.expectEqual(render.TextPresentation.emoji, renderable.cells[1].presentation);

    try std.testing.expectEqual(render.FontStyle.bold, clusters.clusters[0].style);
    try std.testing.expectEqual(render.TextPresentation.text, clusters.clusters[0].presentation);
    try std.testing.expectEqual(render.FontStyle.italic, clusters.clusters[1].style);
    try std.testing.expectEqual(render.TextPresentation.emoji, clusters.clusters[1].presentation);

    try std.testing.expectEqual(@as(usize, 2), runs.runs.len);
    try std.testing.expectEqual(render.FontStyle.bold, runs.runs[0].run.font.style);
    try std.testing.expectEqual(render.TextPresentation.text, runs.runs[0].run.font.presentation);
    try std.testing.expectEqual(render.FontStyle.italic, runs.runs[1].run.font.style);
    try std.testing.expectEqual(render.TextPresentation.emoji, runs.runs[1].run.font.presentation);
}

test "retained provisional run scratch bounds run planning" {
    const allocator = std.testing.allocator;
    var scratch = RetainedProvisionalRunScratch{};
    defer scratch.deinit(allocator);
    try scratch.configure(allocator, 1);
    const clusters = [_]render.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'A', .style = .bold, .presentation = .text },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'B', .style = .italic, .presentation = .emoji },
    };

    try std.testing.expectError(error.ClusterScratchOverflow, buildProvisionalRunsScratch(allocator, &scratch, &clusters, .{ .value = 1 }));
}

test "stub shaper advances wide clusters by their terminal span" {
    const clusters = [_]render.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 2, .first_cp = 0x4f60, .style = .regular, .presentation = .any },
    };
    const text_cache = render.LineTextCache{ .texts = &.{.{ .id = .{ .value = 0 }, .first_cp = 0x4f60, .codepoints = &.{0x4f60} }} };
    const run = render.ResolvedRun{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = 9 }, .style = .regular, .presentation = .any },
    } };
    var shaped = try shapeRun(std.testing.allocator, run, text_cache, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer shaped.deinit();
    try std.testing.expectEqual(@as(f32, 16), shaped.glyphs[0].x_advance_px);
}

test "stub shaper accepts run that ends exactly at cluster slice end" {
    const clusters = [_]render.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'a', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 2, .first_cp = 0x4f60, .style = .regular, .presentation = .any },
    };
    const text_cache = render.LineTextCache{ .texts = &.{
        .{ .id = .{ .value = 0 }, .first_cp = 'a', .codepoints = &.{'a'} },
        .{ .id = .{ .value = 1 }, .first_cp = 0x4f60, .codepoints = &.{0x4f60} },
    } };
    const run = render.ResolvedRun{ .run = .{
        .cluster_start = 1,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = 3 }, .style = .regular, .presentation = .any },
    } };

    var shaped = try shapeRun(std.testing.allocator, run, text_cache, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer shaped.deinit();

    try std.testing.expectEqual(@as(u32, 1), count32(shaped.glyphs));
    try std.testing.expectEqual(@as(u32, 1), shaped.glyphs[0].cluster_index);
    try std.testing.expectEqual(@as(f32, 16), shaped.glyphs[0].x_advance_px);
}
