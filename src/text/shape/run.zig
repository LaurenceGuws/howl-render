const std = @import("std");
const contract = @import("../contract.zig");

pub const ShapeRunRequest = struct {
    run: contract.ResolvedRun,
    clusters: []const contract.CellCluster,
};

pub const ShapeRunResult = struct {
    glyphs: []const contract.GlyphInstance,
};

pub const ShapeRunFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, run: contract.ResolvedRun, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, cell_metrics: contract.CellMetrics) anyerror!OwnedShapedRun;

pub const Shaper = struct {
    ctx: *anyopaque,
    shape_run: ShapeRunFn,

    pub fn shapeRun(self: Shaper, allocator: std.mem.Allocator, run: contract.ResolvedRun, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, cell_metrics: contract.CellMetrics) !OwnedShapedRun {
        return self.shape_run(self.ctx, allocator, run, text_cache, clusters, cell_metrics);
    }
};

pub const OwnedShapedRun = struct {
    allocator: std.mem.Allocator,
    run: contract.ResolvedRun,
    glyphs: []contract.GlyphInstance,

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

pub fn emptyResult() ShapeRunResult {
    return .{ .glyphs = &.{} };
}

pub fn shapeResolvedRunsWithShaper(allocator: std.mem.Allocator, shaper: Shaper, runs: []const contract.ResolvedRun, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, cell_metrics: contract.CellMetrics) !OwnedShapedRuns {
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

fn shapeRunThunk(_: *anyopaque, allocator: std.mem.Allocator, run: contract.ResolvedRun, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, cell_metrics: contract.CellMetrics) anyerror!OwnedShapedRun {
    return shapeRun(allocator, run, text_cache, clusters, cell_metrics);
}

pub fn shapeRun(allocator: std.mem.Allocator, run: contract.ResolvedRun, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, cell_metrics: contract.CellMetrics) !OwnedShapedRun {
    const window = runClusterWindow(run, clusters);
    const glyphs = try allocator.alloc(contract.GlyphInstance, @intCast(window.end - window.start));
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

fn textForCluster(text_cache: contract.LineTextCache, cluster: contract.CellCluster) contract.CellText {
    const idx = cluster.text_id.value;
    std.debug.assert(idx < count32(text_cache.texts));
    return text_cache.texts[@intCast(idx)];
}

const RunClusterWindow = struct {
    start: u32,
    end: u32,
};

fn runClusterWindow(run: contract.ResolvedRun, clusters: []const contract.CellCluster) RunClusterWindow {
    const start = run.run.cluster_start;
    const count = run.run.cluster_count;
    const clusters_len = clusterCount(clusters);

    std.debug.assert(start <= clusters_len);
    std.debug.assert(count <= clusters_len - start);

    return .{ .start = start, .end = start + count };
}

fn clusterCount(clusters: []const contract.CellCluster) u32 {
    return @intCast(clusters.len);
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

test "stub shaper emits one glyph per cluster with run face" {
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'a', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'b', .style = .regular, .presentation = .any },
    };
    const text_cache = contract.LineTextCache{ .texts = &.{
        .{ .id = .{ .value = 0 }, .first_cp = 'a', .codepoints = &.{'a'} },
        .{ .id = .{ .value = 1 }, .first_cp = 'b', .codepoints = &.{'b'} },
    } };
    const run = contract.ResolvedRun{ .run = .{
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

test "stub shaper advances wide clusters by their terminal span" {
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 2, .first_cp = 0x4f60, .style = .regular, .presentation = .any },
    };
    const text_cache = contract.LineTextCache{ .texts = &.{.{ .id = .{ .value = 0 }, .first_cp = 0x4f60, .codepoints = &.{0x4f60} }} };
    const run = contract.ResolvedRun{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = 9 }, .style = .regular, .presentation = .any },
    } };
    var shaped = try shapeRun(std.testing.allocator, run, text_cache, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer shaped.deinit();
    try std.testing.expectEqual(@as(f32, 16), shaped.glyphs[0].x_advance_px);
}

test "stub shaper accepts run that ends exactly at cluster slice end" {
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'a', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 2, .first_cp = 0x4f60, .style = .regular, .presentation = .any },
    };
    const text_cache = contract.LineTextCache{ .texts = &.{
        .{ .id = .{ .value = 0 }, .first_cp = 'a', .codepoints = &.{'a'} },
        .{ .id = .{ .value = 1 }, .first_cp = 0x4f60, .codepoints = &.{0x4f60} },
    } };
    const run = contract.ResolvedRun{ .run = .{
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
