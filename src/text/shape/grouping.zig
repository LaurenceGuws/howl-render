const std = @import("std");
const render = @import("../draw_primitives.zig");
const font_resolver = @import("../resolver.zig");
const shape_run = @import("run.zig");
const sprite_key = @import("../raster/key.zig");
const symbol_map = @import("../symbol_map.zig");

pub const OwnedGlyphGroups = struct {
    allocator: std.mem.Allocator,
    groups: []render.GlyphGroup,
    owned: bool = true,

    pub fn deinit(self: *OwnedGlyphGroups) void {
        if (self.owned) self.allocator.free(self.groups);
        self.* = undefined;
    }
};

pub const GroupingPolicy = struct {
    cursor_cell: ?u32 = null,
    suppress_ligature_at_cursor: bool = false,
};

pub fn groupShapedRunsWithPolicy(
    allocator: std.mem.Allocator,
    shaped_runs: []const shape_run.OwnedShapedRun,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
    policy: GroupingPolicy,
) !OwnedGlyphGroups {
    var count: u32 = 0;
    for (shaped_runs) |run| {
        const glyph_len = count32(run.glyphs);
        var idx: u32 = 0;
        while (idx < glyph_len) {
            count += 1;
            const cluster_index = run.glyphs[@intCast(idx)].cluster_index;
            idx += 1;
            while (idx < glyph_len and run.glyphs[@intCast(idx)].cluster_index == cluster_index) : (idx += 1) {}
        }
    }

    const groups = try allocator.alloc(render.GlyphGroup, @intCast(count));
    errdefer allocator.free(groups);
    var out_idx: u32 = 0;

    for (shaped_runs) |run| {
        const glyph_len = count32(run.glyphs);
        var idx: u32 = 0;
        while (idx < glyph_len) {
            const cluster_index = run.glyphs[@intCast(idx)].cluster_index;
            const cluster_idx = cluster_index;
            std.debug.assert(cluster_idx < count32(clusters));
            const cluster = clusters[@intCast(cluster_idx)];
            const start = idx;
            idx += 1;
            while (idx < glyph_len and run.glyphs[@intCast(idx)].cluster_index == cluster_index) : (idx += 1) {}
            const glyph_slice = run.glyphs[@intCast(start)..@intCast(idx)];
            const next_cluster_exclusive = if (idx < glyph_len)
                run.glyphs[@intCast(idx)].cluster_index
            else
                run.run.run.cluster_start + run.run.run.cluster_count;
            const inferred_cell_span = applyGroupingPolicy(cellSpanForClusterRange(clusters, cluster_idx, next_cluster_exclusive), cluster.first_cell, policy);
            groups[@intCast(out_idx)] = .{
                .first_cell = cluster.first_cell,
                .first_cp = cluster.first_cp,
                .cell_span = inferred_cell_span,
                .glyphs = glyph_slice,
                .placement = groupPlacement(glyph_slice, cell_metrics, inferred_cell_span),
                .sprite_key = sprite_key.hashGlyphSequence(run.run.run.font.face_id, glyph_slice, inferred_cell_span, cell_metrics),
                .kind = classifyFontGroup(cluster, glyph_slice, inferred_cell_span),
            };
            out_idx += 1;
        }
    }

    std.debug.assert(out_idx == count32(groups));
    return .{ .allocator = allocator, .groups = groups };
}

fn applyGroupingPolicy(cell_span: u8, first_cell: u32, policy: GroupingPolicy) u8 {
    if (!policy.suppress_ligature_at_cursor) return cell_span;
    const cursor_cell = policy.cursor_cell orelse return cell_span;
    if (cursor_cell <= first_cell) return cell_span;
    const end_cell = first_cell + @as(u32, @max(cell_span, 1));
    if (cursor_cell >= end_cell) return cell_span;
    return @intCast(@max(cursor_cell - first_cell, 1));
}

fn groupPlacement(glyphs: []const render.GlyphInstance, cell_metrics: render.CellMetrics, cell_span: u8) render.GlyphPlacement {
    var advance_px: f32 = 0;
    for (glyphs) |glyph| advance_px += glyph.x_advance_px;
    const min_advance: f32 = @floatFromInt(@as(u32, @max(cell_span, 1)) * @as(u32, cell_metrics.cell_w_px));
    return .{ .advance_px = @max(advance_px, min_advance) };
}

pub fn groupSpriteRoutes(
    allocator: std.mem.Allocator,
    routes: []const font_resolver.SpriteRouteHit,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
) !OwnedGlyphGroups {
    const groups = try allocator.alloc(render.GlyphGroup, routes.len);
    errdefer allocator.free(groups);
    for (routes, 0..) |route, idx| {
        const cluster_idx = route.cluster_index;
        std.debug.assert(cluster_idx < count32(clusters));
        const cluster = clusters[@intCast(cluster_idx)];
        const cell_span = spriteRouteCellSpan(route.route, clusters, cluster_idx);
        groups[idx] = .{
            .first_cell = cluster.first_cell,
            .first_cp = cluster.first_cp,
            .cell_span = cell_span,
            .glyphs = &.{},
            .placement = groupPlacement(&.{}, cell_metrics, cell_span),
            .sprite_key = routeSpriteKey(route.route, cluster, cell_span, cell_metrics),
            .kind = classifySpriteRoute(route.route),
        };
    }
    return .{ .allocator = allocator, .groups = groups };
}

pub fn concatGroups(allocator: std.mem.Allocator, font_groups: []const render.GlyphGroup, sprite_groups: []const render.GlyphGroup) !OwnedGlyphGroups {
    const groups = try allocator.alloc(render.GlyphGroup, font_groups.len + sprite_groups.len);
    errdefer allocator.free(groups);
    @memcpy(groups[0..font_groups.len], font_groups);
    @memcpy(groups[font_groups.len..], sprite_groups);
    std.sort.block(render.GlyphGroup, groups, {}, lessByCell);

    var out_len: u32 = 0;
    var covered_until: u32 = 0;
    for (groups) |group| {
        if (out_len > 0 and group.first_cell < covered_until) continue;
        groups[@intCast(out_len)] = group;
        out_len += 1;
        covered_until = group.first_cell + @as(u32, @max(group.cell_span, 1));
    }
    return .{ .allocator = allocator, .groups = try allocator.realloc(groups, @intCast(out_len)) };
}

fn lessByCell(_: void, a: render.GlyphGroup, b: render.GlyphGroup) bool {
    return a.first_cell < b.first_cell;
}

fn classifyFontGroup(cluster: render.CellCluster, glyphs: []const render.GlyphInstance, cell_span: u8) render.GlyphGroupKind {
    if (cluster.presentation == .emoji) return .emoji;
    if (cell_span > 1) return .ligature;
    if (glyphs.len > 1) return .ligature;
    if (symbol_map.isIconCodepoint(cluster.first_cp)) return .icon;
    return .normal;
}

fn cellSpanForClusterRange(clusters: []const render.CellCluster, start_idx: u32, end_exclusive: u32) u8 {
    std.debug.assert(start_idx < count32(clusters));
    const clamped_end = std.math.clamp(end_exclusive, start_idx + 1, clusterCount(clusters));
    const first = clusters[@intCast(start_idx)];
    const last = clusters[@intCast(clamped_end - 1)];
    const end_cell = last.first_cell + @as(u32, last.cell_span);
    return @intCast(@max(end_cell - first.first_cell, 1));
}

fn classifySpriteRoute(route: render.SpecialSpriteRoute) render.GlyphGroupKind {
    return switch (route) {
        .blank => .normal,
        .box, .block, .braille, .powerline, .legacy_computing => .box_fallback,
    };
}

fn routeSpriteKey(route: render.SpecialSpriteRoute, cluster: render.CellCluster, cell_span: u8, cell_metrics: render.CellMetrics) render.SpriteKey {
    var h = std.hash.Wyhash.init(0x484f574c);
    const route_int: u8 = @intFromEnum(route);
    h.update(std.mem.asBytes(&route_int));
    h.update(std.mem.asBytes(&cluster.first_cp));
    h.update(std.mem.asBytes(&cell_span));
    h.update(std.mem.asBytes(&cell_metrics.cell_w_px));
    h.update(std.mem.asBytes(&cell_metrics.cell_h_px));
    h.update(std.mem.asBytes(&cell_metrics.baseline_px));
    const box = boxDrawingRasterMetrics(cell_metrics);
    h.update(std.mem.asBytes(&box.light_stroke_px));
    h.update(std.mem.asBytes(&box.heavy_stroke_px));
    return .{ .value = h.final() };
}

fn spriteRouteCellSpan(route: render.SpecialSpriteRoute, clusters: []const render.CellCluster, cluster_idx: u32) u8 {
    const cluster = clusters[@intCast(cluster_idx)];
    if (route != .powerline) return cluster.cell_span;
    var end_cell = cluster.first_cell + @as(u32, cluster.cell_span);
    var idx = cluster_idx + 1;
    const cluster_len = count32(clusters);
    while (idx < cluster_len) : (idx += 1) {
        const next = clusters[@intCast(idx)];
        if (next.first_cell != end_cell) break;
        if (!isPowerlineFollower(next)) break;
        end_cell += @as(u32, next.cell_span);
    }
    const span = @max(end_cell - cluster.first_cell, 1);
    return @intCast(@min(span, std.math.maxInt(u8)));
}

fn boxDrawingRasterMetrics(cell_metrics: render.CellMetrics) render.BoxDrawingRasterMetrics {
    const light = if (cell_metrics.box_thickness_px == 0) @as(u16, 2) else cell_metrics.box_thickness_px;
    return .{ .light_stroke_px = light, .heavy_stroke_px = @intCast(@min(@as(u32, light) * 2, std.math.maxInt(u16))) };
}

fn isPowerlineFollower(cluster: render.CellCluster) bool {
    return cluster.first_cp == ' ' or cluster.first_cp == 0;
}

fn clusterCount(clusters: []const render.CellCluster) u32 {
    return @intCast(clusters.len);
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

test "group shaped run creates one group per glyph cluster" {
    const clusters = [_]render.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 4, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
    };
    const text_cache = render.LineTextCache{ .texts = &.{.{ .id = .{ .value = 0 }, .first_cp = 'x', .codepoints = &.{'x'} }} };
    var shaped = try shape_run.shapeRun(std.testing.allocator, .{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = 5 }, .style = .regular, .presentation = .any },
    } }, text_cache, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer shaped.deinit();
    var groups = try groupShapedRunsWithPolicy(std.testing.allocator, &.{shaped}, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{});
    defer groups.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(groups.groups));
    try std.testing.expectEqual(@as(u32, 4), groups.groups[0].first_cell);
    try std.testing.expect(groups.groups[0].sprite_key.value != 0);
}

test "grouping merges multiple glyphs for one cluster" {
    const clusters = [_]render.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'i', .style = .regular, .presentation = .any },
    };
    const shaped_run = shape_run.OwnedShapedRun{
        .allocator = std.testing.allocator,
        .run = .{ .run = .{ .cluster_start = 0, .cluster_count = 1, .font = .{ .face_id = .{ .value = 1 }, .style = .regular, .presentation = .any } } },
        .glyphs = try std.testing.allocator.dupe(render.GlyphInstance, &.{
            .{ .face_id = .{ .value = 1 }, .glyph_id = 10, .cluster_index = 0, .x_advance_px = 5 },
            .{ .face_id = .{ .value = 1 }, .glyph_id = 11, .cluster_index = 0, .x_offset_px = 1, .x_advance_px = 0 },
        }),
    };
    defer {
        var owned = shaped_run;
        owned.deinit();
    }
    var groups = try groupShapedRunsWithPolicy(std.testing.allocator, &.{shaped_run}, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{});
    defer groups.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(groups.groups));
    try std.testing.expectEqual(@as(u32, 2), count32(groups.groups[0].glyphs));
    try std.testing.expectEqual(render.GlyphGroupKind.ligature, groups.groups[0].kind);
}

test "grouping classifies emoji icon and sprite route groups" {
    const emoji_cluster = render.CellCluster{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 2, .first_cp = 0x1f601, .style = .regular, .presentation = .emoji };
    const icon_cluster = render.CellCluster{ .text_id = .{ .value = 1 }, .first_cell = 2, .cell_span = 1, .first_cp = 0xe0b0, .style = .regular, .presentation = .any };
    const glyphs = [_]render.GlyphInstance{.{ .face_id = .{ .value = 1 }, .glyph_id = 1, .cluster_index = 0 }};
    try std.testing.expectEqual(render.GlyphGroupKind.emoji, classifyFontGroup(emoji_cluster, &glyphs, emoji_cluster.cell_span));
    try std.testing.expectEqual(render.GlyphGroupKind.icon, classifyFontGroup(icon_cluster, &glyphs, icon_cluster.cell_span));

    var sprite_groups = try groupSpriteRoutes(
        std.testing.allocator,
        &.{.{ .cluster_index = 1, .route = .box }},
        &.{ emoji_cluster, icon_cluster },
        .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
    );
    defer sprite_groups.deinit();
    try std.testing.expectEqual(render.GlyphGroupKind.box_fallback, sprite_groups.groups[0].kind);
    try std.testing.expect(sprite_groups.groups[0].sprite_key.value != 0);
}

test "powerline sprite route absorbs adjacent spacer cells" {
    const clusters = [_]render.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 0xe0b0, .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = ' ', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
    };
    var sprite_groups = try groupSpriteRoutes(std.testing.allocator, &.{.{ .cluster_index = 0, .route = .powerline }}, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer sprite_groups.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(sprite_groups.groups));
    try std.testing.expectEqual(@as(u8, 2), sprite_groups.groups[0].cell_span);
    try std.testing.expectEqual(@as(f32, 16), sprite_groups.groups[0].placement.advance_px);
}

test "powerline spacer absorption lets concat drop covered space group" {
    const powerline = render.GlyphGroup{ .first_cell = 0, .cell_span = 2, .glyphs = &.{}, .sprite_key = .{ .value = 1 }, .kind = .box_fallback };
    const space = render.GlyphGroup{ .first_cell = 1, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 2 }, .kind = .normal };
    var merged = try concatGroups(std.testing.allocator, &.{space}, &.{powerline});
    defer merged.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(merged.groups));
    try std.testing.expectEqual(@as(u32, 0), merged.groups[0].first_cell);
    try std.testing.expectEqual(@as(u8, 2), merged.groups[0].cell_span);
}

test "grouping preserves multicell span as ligature-shaped group" {
    const clusters = [_]render.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 2, .cell_span = 2, .first_cp = 'x', .style = .regular, .presentation = .any },
    };
    const text_cache = render.LineTextCache{ .texts = &.{.{ .id = .{ .value = 0 }, .first_cp = 'x', .codepoints = &.{'x'} }} };
    var shaped = try shape_run.shapeRun(std.testing.allocator, .{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = 5 }, .style = .regular, .presentation = .any },
    } }, text_cache, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer shaped.deinit();
    var groups = try groupShapedRunsWithPolicy(std.testing.allocator, &.{shaped}, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{});
    defer groups.deinit();
    try std.testing.expectEqual(@as(u8, 2), groups.groups[0].cell_span);
    try std.testing.expectEqual(render.GlyphGroupKind.ligature, groups.groups[0].kind);
}

test "grouping classifies multiple glyphs in one cell as ligature group" {
    const cluster = render.CellCluster{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any };
    const glyphs = [_]render.GlyphInstance{
        .{ .face_id = .{ .value = 1 }, .glyph_id = 10, .cluster_index = 0 },
        .{ .face_id = .{ .value = 1 }, .glyph_id = 11, .cluster_index = 0 },
    };
    try std.testing.expectEqual(render.GlyphGroupKind.ligature, classifyFontGroup(cluster, &glyphs, cluster.cell_span));
}

test "concat drops groups covered by previous multicell group" {
    const groups = [_]render.GlyphGroup{
        .{ .first_cell = 0, .cell_span = 2, .glyphs = &.{}, .sprite_key = .{ .value = 1 }, .kind = .ligature },
        .{ .first_cell = 1, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 2 }, .kind = .normal },
        .{ .first_cell = 2, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 3 }, .kind = .normal },
    };
    var merged = try concatGroups(std.testing.allocator, &groups, &.{});
    defer merged.deinit();
    try std.testing.expectEqual(@as(u32, 2), count32(merged.groups));
    try std.testing.expectEqual(@as(u32, 0), merged.groups[0].first_cell);
    try std.testing.expectEqual(@as(u32, 2), merged.groups[1].first_cell);
}

test "grouping infers multicell span from next cluster boundary" {
    const clusters = [_]render.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'f', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'i', .style = .regular, .presentation = .any },
    };
    const shaped_run = shape_run.OwnedShapedRun{
        .allocator = std.testing.allocator,
        .run = .{ .run = .{ .cluster_start = 0, .cluster_count = 2, .font = .{ .face_id = .{ .value = 1 }, .style = .regular, .presentation = .any } } },
        .glyphs = try std.testing.allocator.dupe(render.GlyphInstance, &.{
            .{ .face_id = .{ .value = 1 }, .glyph_id = 20, .cluster_index = 0, .x_advance_px = 10 },
        }),
    };
    defer {
        var owned = shaped_run;
        owned.deinit();
    }
    var groups = try groupShapedRunsWithPolicy(std.testing.allocator, &.{shaped_run}, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{});
    defer groups.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(groups.groups));
    try std.testing.expectEqual(@as(u8, 2), groups.groups[0].cell_span);
    try std.testing.expectEqual(render.GlyphGroupKind.ligature, groups.groups[0].kind);
}

test "grouping policy can suppress ligature span across cursor" {
    const clusters = [_]render.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'f', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'i', .style = .regular, .presentation = .any },
    };
    const shaped_run = shape_run.OwnedShapedRun{
        .allocator = std.testing.allocator,
        .run = .{ .run = .{ .cluster_start = 0, .cluster_count = 2, .font = .{ .face_id = .{ .value = 1 }, .style = .regular, .presentation = .any } } },
        .glyphs = try std.testing.allocator.dupe(render.GlyphInstance, &.{
            .{ .face_id = .{ .value = 1 }, .glyph_id = 20, .cluster_index = 0, .x_advance_px = 10 },
        }),
    };
    defer {
        var owned = shaped_run;
        owned.deinit();
    }
    var groups = try groupShapedRunsWithPolicy(
        std.testing.allocator,
        &.{shaped_run},
        &clusters,
        .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
        .{ .cursor_cell = 1, .suppress_ligature_at_cursor = true },
    );
    defer groups.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(groups.groups));
    try std.testing.expectEqual(@as(u8, 1), groups.groups[0].cell_span);
}
