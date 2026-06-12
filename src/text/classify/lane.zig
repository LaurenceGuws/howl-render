const std = @import("std");
const contract = @import("../contract.zig");
const symbol_map = @import("symbol_map.zig");

pub const TextLane = enum(u1) {
    normal,
    complex,
};

pub const RenderableClass = enum(u3) {
    normal,
    multi_codepoint,
    emoji_presentation,
    special_sprite,
    icon_codepoint,
    curly_underline,

    pub fn lane(self: RenderableClass) TextLane {
        return switch (self) {
            .normal => .normal,
            .multi_codepoint,
            .emoji_presentation,
            .special_sprite,
            .icon_codepoint,
            .curly_underline,
            => .complex,
        };
    }

    pub fn complexReason(self: RenderableClass) ?ComplexLaneReason {
        return switch (self) {
            .normal => null,
            .multi_codepoint => .multi_codepoint,
            .emoji_presentation => .emoji_presentation,
            .special_sprite => .special_sprite,
            .icon_codepoint => .icon_codepoint,
            .curly_underline => .curly_underline,
        };
    }
};

pub const ComplexLaneReason = enum(u3) {
    multi_codepoint,
    emoji_presentation,
    special_sprite,
    icon_codepoint,
    curly_underline,
};

pub const LaneClass = struct {
    lane: TextLane,
    complex_reason: ?ComplexLaneReason = null,

    pub fn normal() LaneClass {
        return .{ .lane = .normal };
    }

    pub fn complex(reason: ComplexLaneReason) LaneClass {
        return .{ .lane = .complex, .complex_reason = reason };
    }

    pub fn assertValid(self: LaneClass) void {
        switch (self.lane) {
            .normal => std.debug.assert(self.complex_reason == null),
            .complex => std.debug.assert(self.complex_reason != null),
        }
    }

    pub fn renderableClass(self: LaneClass) RenderableClass {
        self.assertValid();
        return switch (self.lane) {
            .normal => .normal,
            .complex => switch (self.complex_reason.?) {
                .multi_codepoint => .multi_codepoint,
                .emoji_presentation => .emoji_presentation,
                .special_sprite => .special_sprite,
                .icon_codepoint => .icon_codepoint,
                .curly_underline => .curly_underline,
            },
        };
    }
};

pub const LegacyStageCounts = struct {
    normal: u64 = 0,
    complex: u64 = 0,
};

pub const LegacyPathReport = struct {
    resolved_clusters: LegacyStageCounts = .{},
    shaped_clusters: LegacyStageCounts = .{},
    grouped_groups: LegacyStageCounts = .{},
    scene_sprite_draws: LegacyStageCounts = .{},
};

pub const LaneReport = struct {
    visible_cells: u64 = 0,
    normal_cells: u64 = 0,
    complex_cells: u64 = 0,
    complex_multi_codepoint_cells: u64 = 0,
    complex_emoji_cells: u64 = 0,
    complex_special_sprite_cells: u64 = 0,
    complex_icon_cells: u64 = 0,
    complex_curly_underline_cells: u64 = 0,
    normal_clusters: u64 = 0,
    complex_clusters: u64 = 0,
    direct_normal_draws: u64 = 0,
    direct_normal_raster_misses: u64 = 0,
    legacy: LegacyPathReport = .{},

    pub fn init(text_cache: contract.LineTextCache, cells: []const contract.RenderableCell, clusters: []const contract.CellCluster) LaneReport {
        var report = LaneReport{};
        for (cells) |cell| report.recordRenderableCell(cell, textForRenderableCell(text_cache, cell));
        for (clusters) |cluster| report.recordCluster(cells, cluster, textForCluster(text_cache, cluster));
        report.assertValid();
        return report;
    }

    pub fn surfaceFullyNormalInput(self: LaneReport) bool {
        return self.complex_cells == 0;
    }

    pub fn surfaceStayedOutOfLegacyPath(self: LaneReport) bool {
        return self.surfaceFullyNormalInput() and
            self.legacy.resolved_clusters.normal == 0 and
            self.legacy.shaped_clusters.normal == 0 and
            self.legacy.grouped_groups.normal == 0 and
            self.legacy.scene_sprite_draws.normal == 0;
    }

    pub fn recordLegacyResolvedRun(self: *LaneReport, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, run: contract.ResolvedRun) void {
        recordLegacyRunClusters(&self.legacy.resolved_clusters, text_cache, &.{}, clusters, run);
    }

    pub fn recordLegacyShapedRun(self: *LaneReport, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, run: contract.ResolvedRun) void {
        recordLegacyRunClusters(&self.legacy.shaped_clusters, text_cache, &.{}, clusters, run);
    }

    pub fn recordLegacyResolvedRunWithCells(
        self: *LaneReport,
        text_cache: contract.LineTextCache,
        cells: []const contract.RenderableCell,
        clusters: []const contract.CellCluster,
        run: contract.ResolvedRun,
    ) void {
        recordLegacyRunClusters(&self.legacy.resolved_clusters, text_cache, cells, clusters, run);
    }

    pub fn recordLegacyShapedRunWithCells(
        self: *LaneReport,
        text_cache: contract.LineTextCache,
        cells: []const contract.RenderableCell,
        clusters: []const contract.CellCluster,
        run: contract.ResolvedRun,
    ) void {
        recordLegacyRunClusters(&self.legacy.shaped_clusters, text_cache, cells, clusters, run);
    }

    pub fn recordLegacyGroup(self: *LaneReport, text_cache: contract.LineTextCache, cells: []const contract.RenderableCell, group: contract.GlyphGroup) void {
        const choice = classifyRenderableCell(cellForFirstCell(cells, group.first_cell), textForFirstCell(text_cache, cells, group.first_cell));
        recordLegacyChoice(&self.legacy.grouped_groups, choice);
    }

    pub fn recordLegacySceneSpriteDraw(self: *LaneReport, text_cache: contract.LineTextCache, cells: []const contract.RenderableCell, draw: contract.TextSpriteDraw) void {
        const choice = classifyRenderableCell(cellForFirstCell(cells, draw.first_cell), textForFirstCell(text_cache, cells, draw.first_cell));
        recordLegacyChoice(&self.legacy.scene_sprite_draws, choice);
    }

    pub fn assertValid(self: LaneReport) void {
        std.debug.assert(self.visible_cells == self.normal_cells + self.complex_cells);
        const classified_complex_cells = self.complex_multi_codepoint_cells + self.complex_emoji_cells +
            self.complex_special_sprite_cells + self.complex_icon_cells + self.complex_curly_underline_cells;
        std.debug.assert(self.complex_cells == classified_complex_cells);
        std.debug.assert(self.normal_clusters + self.complex_clusters <= self.visible_cells);
    }

    fn recordRenderableCell(self: *LaneReport, cell: contract.RenderableCell, text: contract.CellText) void {
        const choice = classifyRenderableCell(cell, text);
        self.visible_cells += 1;
        switch (choice.lane) {
            .normal => self.normal_cells += 1,
            .complex => {
                self.complex_cells += 1;
                self.recordComplexReason(choice.complex_reason.?);
            },
        }
    }

    fn recordCluster(self: *LaneReport, cells: []const contract.RenderableCell, cluster: contract.CellCluster, text: contract.CellText) void {
        const choice = classifyClusterInCells(cells, cluster, text);
        switch (choice.lane) {
            .normal => self.normal_clusters += 1,
            .complex => self.complex_clusters += 1,
        }
    }

    fn recordComplexReason(self: *LaneReport, reason: ComplexLaneReason) void {
        switch (reason) {
            .multi_codepoint => self.complex_multi_codepoint_cells += 1,
            .emoji_presentation => self.complex_emoji_cells += 1,
            .special_sprite => self.complex_special_sprite_cells += 1,
            .icon_codepoint => self.complex_icon_cells += 1,
            .curly_underline => self.complex_curly_underline_cells += 1,
        }
    }
};

pub fn normalRenderableCell(cell: contract.RenderableCell, text: contract.CellText) bool {
    assertTextInvariants(text);
    return classifyRenderable(cell, text) == .normal;
}

pub fn complexRenderableCellReason(cell: contract.RenderableCell, text: contract.CellText) ?ComplexLaneReason {
    assertTextInvariants(text);
    return classifyRenderable(cell, text).complexReason();
}

pub fn classifyRenderable(cell: contract.RenderableCell, text: contract.CellText) RenderableClass {
    assertTextInvariants(text);
    return renderableClass(cell, text);
}

pub fn classifyRenderableCell(cell: contract.RenderableCell, text: contract.CellText) LaneClass {
    const class = classifyRenderable(cell, text);
    const choice = if (class == .normal) LaneClass.normal() else LaneClass.complex(class.complexReason().?);
    choice.assertValid();
    return choice;
}

pub fn normalCluster(cluster: contract.CellCluster, text: contract.CellText) bool {
    assertTextInvariants(text);
    return complexClusterReason(cluster, text) == null;
}

pub fn complexClusterReason(cluster: contract.CellCluster, text: contract.CellText) ?ComplexLaneReason {
    assertTextInvariants(text);
    const class = textClass(text, cluster.presentation) orelse return null;
    return class.complexReason();
}

pub fn classifyCluster(cluster: contract.CellCluster, text: contract.CellText) LaneClass {
    const normal = normalCluster(cluster, text);
    const complex_reason = complexClusterReason(cluster, text);
    std.debug.assert(normal != (complex_reason != null));
    const choice = if (normal) LaneClass.normal() else LaneClass.complex(complex_reason.?);
    choice.assertValid();
    return choice;
}

pub fn classifyClusterInCells(cells: []const contract.RenderableCell, cluster: contract.CellCluster, text: contract.CellText) LaneClass {
    if (renderableCellForFirstCell(cells, cluster.first_cell)) |cell| {
        std.debug.assert(cell.text_id.value == cluster.text_id.value);
        const choice = classifyRenderableCell(cell, text);
        choice.assertValid();
        return choice;
    }
    return classifyCluster(cluster, text);
}

fn normalText(text: contract.CellText, presentation: contract.TextPresentation) bool {
    const route = symbol_map.builtinRoute(text.first_cp);
    return text.codepoints.len == 1 and
        presentation != .emoji and
        (route == null or route.? == .blank);
}

fn renderableClass(cell: contract.RenderableCell, text: contract.CellText) RenderableClass {
    if (textClass(text, cell.presentation)) |class| return class;
    if (cell.underline and cell.underline_style == .curly) return .curly_underline;
    return .normal;
}

fn textClass(text: contract.CellText, presentation: contract.TextPresentation) ?RenderableClass {
    if (presentation == .emoji) return .emoji_presentation;
    if (symbol_map.builtinRoute(text.first_cp)) |route| {
        if (route != .blank) return .special_sprite;
    }
    if (symbol_map.isIconCodepoint(text.first_cp)) return .icon_codepoint;
    if (text.codepoints.len != 1) return .multi_codepoint;
    return null;
}

fn assertTextInvariants(text: contract.CellText) void {
    std.debug.assert(text.codepoints.len > 0);
    std.debug.assert(text.codepoints[0] == text.first_cp);
}

fn recordLegacyRunClusters(
    counts: *LegacyStageCounts,
    text_cache: contract.LineTextCache,
    cells: []const contract.RenderableCell,
    clusters: []const contract.CellCluster,
    run: contract.ResolvedRun,
) void {
    const window = runClusterWindow(run, clusters);
    for (clusters[@intCast(window.start)..@intCast(window.end)]) |cluster| {
        const choice = classifyClusterInCells(cells, cluster, textForCluster(text_cache, cluster));
        recordLegacyChoice(counts, choice);
    }
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

fn recordLegacyChoice(counts: *LegacyStageCounts, choice: LaneClass) void {
    switch (choice.lane) {
        .normal => counts.normal += 1,
        .complex => counts.complex += 1,
    }
}

fn textForRenderableCell(text_cache: contract.LineTextCache, cell: contract.RenderableCell) contract.CellText {
    const idx = cell.text_id.value;
    std.debug.assert(idx < count32(text_cache.texts));
    return text_cache.texts[@intCast(idx)];
}

fn textForCluster(text_cache: contract.LineTextCache, cluster: contract.CellCluster) contract.CellText {
    const idx = cluster.text_id.value;
    std.debug.assert(idx < count32(text_cache.texts));
    return text_cache.texts[@intCast(idx)];
}

fn cellForFirstCell(cells: []const contract.RenderableCell, first_cell: u32) contract.RenderableCell {
    return renderableCellForFirstCell(cells, first_cell) orelse unreachable;
}

fn renderableCellForFirstCell(cells: []const contract.RenderableCell, first_cell: u32) ?contract.RenderableCell {
    var lo: u32 = 0;
    var hi = count32(cells);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cell = cells[@intCast(mid)];
        if (cell.first_cell < first_cell) {
            lo = mid + 1;
            continue;
        }
        if (cell.first_cell > first_cell) {
            hi = mid;
            continue;
        }
        return cell;
    }
    return null;
}

fn clusterCount(clusters: []const contract.CellCluster) u32 {
    return @intCast(clusters.len);
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

fn textForFirstCell(text_cache: contract.LineTextCache, cells: []const contract.RenderableCell, first_cell: u32) contract.CellText {
    return textForRenderableCell(text_cache, cellForFirstCell(cells, first_cell));
}

test "lane classifies single-codepoint text as normal" {
    const text = contract.CellText{ .id = .{ .value = 1 }, .first_cp = 'A', .codepoints = &.{'A'} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .bold,
        .presentation = .text,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const choice = classifyRenderableCell(cell, text);
    try std.testing.expectEqual(TextLane.normal, choice.lane);
    try std.testing.expectEqual(@as(?ComplexLaneReason, null), choice.complex_reason);
}

test "lane keeps wide single-codepoint text in normal lane" {
    const text = contract.CellText{ .id = .{ .value = 2 }, .first_cp = 0x4f60, .codepoints = &.{0x4f60} };
    const cluster = contract.CellCluster{
        .text_id = text.id,
        .first_cell = 4,
        .cell_span = 2,
        .first_cp = text.first_cp,
        .style = .regular,
        .presentation = .any,
    };
    const choice = classifyCluster(cluster, text);
    try std.testing.expectEqual(TextLane.normal, choice.lane);
}

test "lane marks multi-codepoint text as complex" {
    const text = contract.CellText{ .id = .{ .value = 3 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } };
    const cluster = contract.CellCluster{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .first_cp = text.first_cp,
        .style = .regular,
        .presentation = .any,
    };
    const choice = classifyCluster(cluster, text);
    try std.testing.expectEqual(TextLane.complex, choice.lane);
    try std.testing.expectEqual(ComplexLaneReason.multi_codepoint, choice.complex_reason.?);
}

test "lane marks emoji presentation as complex" {
    const text = contract.CellText{ .id = .{ .value = 4 }, .first_cp = 0x1f642, .codepoints = &.{0x1f642} };
    const cluster = contract.CellCluster{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .first_cp = text.first_cp,
        .style = .regular,
        .presentation = .emoji,
    };
    const choice = classifyCluster(cluster, text);
    try std.testing.expectEqual(TextLane.complex, choice.lane);
    try std.testing.expectEqual(ComplexLaneReason.emoji_presentation, choice.complex_reason.?);
}

test "lane marks generated sprite routes as complex" {
    const text = contract.CellText{ .id = .{ .value = 5 }, .first_cp = 0x2500, .codepoints = &.{0x2500} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const choice = classifyRenderableCell(cell, text);
    try std.testing.expectEqual(TextLane.complex, choice.lane);
    try std.testing.expectEqual(ComplexLaneReason.special_sprite, choice.complex_reason.?);
}

test "lane marks shared and fallback special sprite routes as complex" {
    for ([_]u32{ 0x2500, 0x257f, 0x2580, 0x259f, 0x2801, 0x28ff, 0xe0b0, 0xe0bf, 0xe0d6, 0xe0d7, 0x1fb00, 0x1fb3b, 0x1fb3c, 0x1fb67, 0x1fb68, 0x1fb6f, 0x1fb70, 0x1fb7b, 0x1fb7c, 0x1fb8b, 0x1fb8c, 0x1fb93, 0x1fb9f, 0x1fba0, 0x1fbae, 0x1cd00, 0x1cde5, 0x1fbe6, 0x1fbe7, 0xf5d0, 0xf60d }) |cp| {
        const text = contract.CellText{ .id = .{ .value = 10 }, .first_cp = cp, .codepoints = &.{cp} };
        const cell = contract.RenderableCell{
            .text_id = text.id,
            .first_cell = 0,
            .cell_span = 1,
            .style = .regular,
            .presentation = .any,
            .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        };
        const choice = classifyRenderableCell(cell, text);
        try std.testing.expectEqual(TextLane.complex, choice.lane);
        try std.testing.expectEqual(ComplexLaneReason.special_sprite, choice.complex_reason.?);
    }
}

test "lane marks icon codepoints as complex" {
    const text = contract.CellText{ .id = .{ .value = 9 }, .first_cp = 0xf101, .codepoints = &.{0xf101} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const choice = classifyRenderableCell(cell, text);
    try std.testing.expectEqual(TextLane.complex, choice.lane);
    try std.testing.expectEqual(ComplexLaneReason.icon_codepoint, choice.complex_reason.?);
}

test "lane marks curly underline cells as complex" {
    const text = contract.CellText{ .id = .{ .value = 7 }, .first_cp = 'u', .codepoints = &.{'u'} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .underline = true,
        .underline_style = .curly,
    };
    const choice = classifyRenderableCell(cell, text);
    try std.testing.expectEqual(TextLane.complex, choice.lane);
    try std.testing.expectEqual(ComplexLaneReason.curly_underline, choice.complex_reason.?);
}

test "lane keeps blank route in normal lane" {
    const text = contract.CellText{ .id = .{ .value = 6 }, .first_cp = 0, .codepoints = &.{0} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const choice = classifyRenderableCell(cell, text);
    try std.testing.expectEqual(TextLane.normal, choice.lane);
}

test "lane report allows visible blank cells without clusters" {
    const text = contract.CellText{ .id = .{ .value = 0 }, .first_cp = 0, .codepoints = &.{0} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const report = LaneReport.init(.{ .texts = &.{text} }, &.{cell}, &.{});
    try std.testing.expectEqual(@as(u64, 1), report.visible_cells);
    try std.testing.expectEqual(@as(u64, 1), report.normal_cells);
    try std.testing.expectEqual(@as(u64, 0), report.normal_clusters);
}

test "lane report flags legacy leakage for normal runs" {
    const text = contract.CellText{ .id = .{ .value = 0 }, .first_cp = 'A', .codepoints = &.{'A'} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const cluster = contract.CellCluster{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .first_cp = text.first_cp,
        .style = .regular,
        .presentation = .any,
    };
    var report = LaneReport.init(.{ .texts = &.{text} }, &.{cell}, &.{cluster});
    report.recordLegacyResolvedRun(.{ .texts = &.{text} }, &.{cluster}, .{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = 1 }, .style = .regular, .presentation = .any },
    } });
    report.recordLegacyShapedRun(.{ .texts = &.{text} }, &.{cluster}, .{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = 1 }, .style = .regular, .presentation = .any },
    } });
    report.recordLegacyGroup(.{ .texts = &.{text} }, &.{cell}, .{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 1 }, .kind = .normal });
    report.recordLegacySceneSpriteDraw(
        .{ .texts = &.{text} },
        &.{cell},
        .{ .sprite = .{ .slot = 0, .key = .{ .value = 1 } }, .x_px = 0, .y_px = 0, .width_px = 8, .height_px = 16, .color = cell.fg, .first_cell = 0, .cell_span = 1 },
    );
    try std.testing.expect(report.surfaceFullyNormalInput());
    try std.testing.expectEqual(@as(u64, 1), report.legacy.resolved_clusters.normal);
    try std.testing.expectEqual(@as(u64, 1), report.legacy.shaped_clusters.normal);
    try std.testing.expectEqual(@as(u64, 1), report.legacy.grouped_groups.normal);
    try std.testing.expectEqual(@as(u64, 1), report.legacy.scene_sprite_draws.normal);
    try std.testing.expect(!report.surfaceStayedOutOfLegacyPath());
}

test "lane legacy run accounting accepts exact end-bound run" {
    const text_a = contract.CellText{ .id = .{ .value = 0 }, .first_cp = 'A', .codepoints = &.{'A'} };
    const text_b = contract.CellText{ .id = .{ .value = 1 }, .first_cp = 'B', .codepoints = &.{'B'} };
    const cells = [_]contract.RenderableCell{
        .{
            .text_id = text_a.id,
            .first_cell = 0,
            .cell_span = 1,
            .style = .regular,
            .presentation = .any,
            .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        },
        .{
            .text_id = text_b.id,
            .first_cell = 1,
            .cell_span = 1,
            .style = .regular,
            .presentation = .any,
            .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        },
    };
    const clusters = [_]contract.CellCluster{
        .{ .text_id = text_a.id, .first_cell = 0, .cell_span = 1, .first_cp = 'A', .style = .regular, .presentation = .any },
        .{ .text_id = text_b.id, .first_cell = 1, .cell_span = 1, .first_cp = 'B', .style = .regular, .presentation = .any },
    };

    var report = LaneReport.init(.{ .texts = &.{ text_a, text_b } }, &cells, &clusters);
    report.recordLegacyResolvedRun(.{ .texts = &.{ text_a, text_b } }, &clusters, .{ .run = .{
        .cluster_start = 1,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = 1 }, .style = .regular, .presentation = .any },
    } });

    try std.testing.expectEqual(@as(u64, 1), report.legacy.resolved_clusters.normal);
    try std.testing.expectEqual(@as(u64, 0), report.legacy.resolved_clusters.complex);
}
