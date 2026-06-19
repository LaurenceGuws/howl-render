const std = @import("std");
const c = @import("howl_render_c");
const builtin = @import("builtin");
const render = @import("../text/draw_primitives.zig");
const direct_normal = @import("../text/direct_normal.zig");
const direct_draw = @import("../grid/direct.zig");
const prepare_counters = @import("../text/prepare_counters.zig");
const atlas_cache = @import("../text/raster/atlas.zig");
const cluster = @import("../text/shape/cluster.zig");
const font_resolver = @import("../text/resolver.zig");
const face_selection = @import("../text/face_selection.zig");
const grouping = @import("../text/shape/grouping.zig");
const provider = @import("../text/provider.zig");
const raster_operation = @import("../text/raster/operation.zig");
const rasterizer = @import("../text/raster/rasterizer.zig");
const draw_list = @import("../text/draw_list.zig");
const text_damage = @import("../text/damage.zig");
const rect_primitives = @import("../text/rect_primitives.zig");
const shape_run = @import("../text/shape/run.zig");
const lane = @import("../text/lane.zig");

pub const TextSurfacePreparer = struct {
    allocator: std.mem.Allocator,
    counters: prepare_counters.TextPrepareCounters = .{},
    atlas: atlas_cache.OwnedAtlasCache,
    shaper: shape_run.Shaper,
    sprite_rasterizer: rasterizer.Rasterizer,
    glyph_lookup: provider.LookupGlyphOp,
    glyph_raster: raster_operation.RasterizeGlyphOp,
    cluster_scratch: cluster.RetainedScratch = .{},
    direct_normal: direct_normal.Scratch = .{},
    resolver_scratch: font_resolver.RetainedScratch = .{},
    draw_list_scratch: draw_list.RetainedDrawScratch = .{},

    pub fn init(allocator: std.mem.Allocator) TextSurfacePreparer {
        return initCapacity(allocator, 4096) catch unreachable;
    }

    pub fn initCapacity(allocator: std.mem.Allocator, atlas_capacity: atlas_cache.AtlasCapacity) !TextSurfacePreparer {
        return initWithProvider(allocator, atlas_capacity, provider.defaultProvider());
    }

    pub fn initWithShaper(allocator: std.mem.Allocator, atlas_capacity: atlas_cache.AtlasCapacity, shaper: shape_run.Shaper) !TextSurfacePreparer {
        return initWithProvider(allocator, atlas_capacity, .{ .shaper = shaper });
    }

    pub fn initWithProvider(allocator: std.mem.Allocator, atlas_capacity: atlas_cache.AtlasCapacity, provider_value: provider.TextProvider) !TextSurfacePreparer {
        return .{
            .allocator = allocator,
            .atlas = try atlas_cache.OwnedAtlasCache.init(allocator, atlas_capacity),
            .shaper = provider_value.shaper,
            .sprite_rasterizer = provider_value.rasterizer,
            .glyph_lookup = provider_value.glyph_lookup,
            .glyph_raster = provider_value.glyph_raster,
        };
    }

    pub fn deinit(self: *TextSurfacePreparer) void {
        self.draw_list_scratch.deinit(self.allocator);
        self.resolver_scratch.deinit(self.allocator);
        self.cluster_scratch.deinit(self.allocator);
        self.direct_normal.deinit(self.allocator);
        self.atlas.deinit();
        self.* = undefined;
    }

    pub fn ensureClusterScratchCapacity(self: *TextSurfacePreparer, max_items: u32, max_codepoints: u32) !void {
        try self.cluster_scratch.configure(self.allocator, max_items, max_codepoints);
    }

    pub fn ensureResolverScratchCapacity(self: *TextSurfacePreparer, max_clusters: u32) !void {
        try self.resolver_scratch.configure(self.allocator, max_clusters);
    }

    pub fn clearAtlas(self: *TextSurfacePreparer) void {
        self.atlas.len = 0;
        self.atlas.next_slot = 0;
    }

    pub fn prepareCellsWithFaceSelection(
        self: *TextSurfacePreparer,
        cells: []const render.CellInput,
        grid_metrics: render.CellGridMetrics,
        selection: face_selection.FaceSelection,
        options: PrepareOptions,
    ) !OwnedPreparedTextSurface {
        var lane_report = lane.LaneReport{};
        if (try self.prepareDirectNormal(.{ .raw_cells = cells }, .require_all_normal, grid_metrics, selection, options, &lane_report, null)) |direct| {
            return self.finishNormalOnlySurface(direct, lane_report, options.draw_list.cursor);
        }
        const cell_count = count32(cells);
        try self.ensureClusterScratchCapacity(cell_count, countCellInputCodepoints(cells));
        var sparse = try cluster.buildSparseCellsWithDamageScratch(self.allocator, &self.cluster_scratch, cells, grid_metrics, options.draw_list.damage);
        errdefer sparse.deinit();
        return self.preparePreparedTextSurface(sparse.text_cache, sparse.renderable, grid_metrics, selection, options);
    }

    pub fn prepareCellTextInputsWithFaceSelection(
        self: *TextSurfacePreparer,
        inputs: []const cluster.CellTextInput,
        grid_metrics: render.CellGridMetrics,
        selection: face_selection.FaceSelection,
        options: PrepareOptions,
    ) !OwnedPreparedTextSurface {
        var lane_report = lane.LaneReport{};
        if (try self.prepareDirectNormal(.{ .inputs = inputs }, .require_all_normal, grid_metrics, selection, options, &lane_report, null)) |direct| {
            return self.finishNormalOnlySurface(direct, lane_report, options.draw_list.cursor);
        }
        const input_count = count32(inputs);
        var input_codepoints: u32 = 0;
        for (inputs) |input| input_codepoints += @intCast(@max(input.codepoints.len, 1));
        try self.ensureClusterScratchCapacity(input_count, input_codepoints);
        var text_cache = try cluster.buildLineTextCacheFromInputsScratch(self.allocator, &self.cluster_scratch, inputs);
        errdefer text_cache.deinit();
        var renderable = try cluster.buildRenderableCellsFromInputs(self.allocator, inputs, text_cache.view());
        errdefer renderable.deinit();
        return self.preparePreparedTextSurface(text_cache, renderable, grid_metrics, selection, options);
    }

    fn preparePreparedTextSurface(
        self: *TextSurfacePreparer,
        text_cache: cluster.OwnedLineTextCache,
        renderable: cluster.OwnedRenderableCells,
        grid_metrics: render.CellGridMetrics,
        selection: face_selection.FaceSelection,
        options: PrepareOptions,
    ) !OwnedPreparedTextSurface {
        return self.preparePreparedTextSurfaceWithExpectedComplexCells(text_cache, renderable, grid_metrics, selection, options, null);
    }

    fn preparePreparedTextSurfaceWithExpectedComplexCells(
        self: *TextSurfacePreparer,
        text_cache: cluster.OwnedLineTextCache,
        renderable: cluster.OwnedRenderableCells,
        grid_metrics: render.CellGridMetrics,
        selection: face_selection.FaceSelection,
        options: PrepareOptions,
        expected_complex_cells: ?u64,
    ) !OwnedPreparedTextSurface {
        var owned_text_cache = text_cache;
        errdefer owned_text_cache.deinit();
        var owned_renderable = renderable;
        errdefer owned_renderable.deinit();
        var clusters = try cluster.extractClustersWithDamageScratch(
            self.allocator,
            &self.cluster_scratch,
            owned_renderable.cells,
            owned_text_cache.view(),
            grid_metrics,
            options.draw_list.damage,
        );
        errdefer clusters.deinit();
        try self.ensureResolverScratchCapacity(count32(clusters.clusters));
        var final_lane_report = lane.LaneReport.init(owned_text_cache.view(), owned_renderable.cells, clusters.clusters);
        if (expected_complex_cells) |expected| {
            std.debug.assert(final_lane_report.complex_cells == expected);
            std.debug.assert(final_lane_report.complex_cells != 0);
        }
        const direct = (try self.prepareDirectNormal(
            .{ .prepared = .{ .cells = owned_renderable.cells, .text_cache = owned_text_cache.view() } },
            .skip_complex,
            grid_metrics,
            selection,
            options,
            &final_lane_report,
            null,
        )).?;

        if (final_lane_report.complex_cells == 0) {
            std.debug.assert(expected_complex_cells == null);
            owned_text_cache.deinit();
            clusters.deinit();
            owned_renderable.deinit();
            return self.finishNormalOnlySurface(direct, final_lane_report, options.draw_list.cursor);
        }

        if (expected_complex_cells != null) std.debug.assert(final_lane_report.complex_cells != 0);

        return self.prepareComplexSurface(
            .{
                .text_cache = owned_text_cache,
                .renderable = owned_renderable,
                .clusters = clusters,
                .direct = direct,
                .lane_report = final_lane_report,
            },
            grid_metrics,
            selection,
            options,
        );
    }

    fn prepareComplexSurface(
        self: *TextSurfacePreparer,
        prepared: PreparedComplexSurface,
        grid_metrics: render.CellGridMetrics,
        selection: face_selection.FaceSelection,
        options: PrepareOptions,
    ) !OwnedPreparedTextSurface {
        var final_prepared = prepared;
        errdefer final_prepared.deinit(self.allocator);
        var complex = try self.selectComplexCells(&final_prepared, grid_metrics, options.draw_list.damage);
        defer complex.deinit();

        try self.resolveShapeAndGroupComplex(&final_prepared, complex, grid_metrics, selection);
        var text_draw_list = try self.buildComplexDrawList(&final_prepared, complex.cells, grid_metrics, selection.cell_metrics, options.draw_list);
        errdefer text_draw_list.deinit();
        var raster_plan = try self.rasterizeComplexDrawList(&text_draw_list);
        errdefer raster_plan.deinit();
        const complex_sprite_cache_hits = text_draw_list.draw_list.sprite_draws.len - text_draw_list.draw_list.raster_requests.len;

        const merged = try self.mergePreparedDrawList(final_prepared.direct, final_prepared.renderable.cells, grid_metrics, selection.cell_metrics, options.draw_list.cursor, &text_draw_list, &raster_plan);
        final_prepared.direct.outputs = &.{};
        final_prepared.direct.outputs_owned = false;

        self.applyComplexDrawListCounters(&final_prepared, &text_draw_list, &merged, complex_sprite_cache_hits);
        final_prepared.deinit(self.allocator);

        return .{
            .draw_list = merged.draw_list,
            .raster_plan = merged.raster_plan,
        };
    }

    fn selectComplexCells(self: *TextSurfacePreparer, prepared: *const PreparedComplexSurface, grid_metrics: render.CellGridMetrics, damage: text_damage.DamageInput) !cluster.ComplexSelection {
        var complex = try cluster.selectComplexWithDamageScratch(
            self.allocator,
            &self.cluster_scratch,
            prepared.renderable.cells,
            prepared.text_cache.view(),
            prepared.clusters.clusters,
            grid_metrics,
            damage,
        );
        errdefer complex.deinit();
        std.debug.assert(@as(u64, @intCast(complex.cells.len)) == prepared.lane_report.complex_cells);
        std.debug.assert(@as(u64, @intCast(complex.clusters.len)) == prepared.lane_report.complex_clusters);
        return complex;
    }

    fn resolveShapeAndGroupComplex(self: *TextSurfacePreparer, prepared: *PreparedComplexSurface, complex: cluster.ComplexSelection, grid_metrics: render.CellGridMetrics, selection: face_selection.FaceSelection) !void {
        prepared.runs = try resolveComplexRuns(self, prepared.text_cache.view(), complex.clusters, grid_metrics, selection, &prepared.lane_report, complex.cells);
        prepared.shaped_runs = try shapeComplexRuns(
            self,
            prepared.runs.?.runs,
            prepared.text_cache.view(),
            complex.clusters,
            selection.cell_metrics,
            &prepared.lane_report,
            complex.cells,
        );
        prepared.grouped = try groupComplexRuns(
            self,
            prepared.shaped_runs.?.runs,
            prepared.runs.?.sprite_routes,
            complex.clusters,
            selection.cell_metrics,
            &prepared.lane_report,
            prepared.text_cache.view(),
            complex.cells,
        );
    }

    fn buildComplexDrawList(self: *TextSurfacePreparer, prepared: *PreparedComplexSurface, cells: []const render.RenderableCell, grid_metrics: render.CellGridMetrics, cell_metrics: render.CellMetrics, options: draw_list.DrawListOptions) !draw_list.BorrowedTextDrawList {
        const text_draw_list = try draw_list.buildBorrowedDrawListWithAtlasCacheOptions(
            self.allocator,
            &self.draw_list_scratch,
            cells,
            prepared.grouped.?.groups.groups,
            prepared.runs.?.missing,
            cell_metrics,
            grid_metrics,
            &self.atlas,
            options,
        );
        for (text_draw_list.draw_list.sprite_draws) |draw| prepared.lane_report.recordLegacyDrawListSpriteDraw(prepared.text_cache.view(), cells, draw);
        return text_draw_list;
    }

    fn rasterizeComplexDrawList(self: *TextSurfacePreparer, text_draw_list: *const draw_list.BorrowedTextDrawList) !rasterizer.OwnedRasterPlan {
        const raster_plan = try rasterizer.rasterizeRequestsWithRasterizer(self.allocator, self.sprite_rasterizer, text_draw_list.draw_list.raster_requests);
        return raster_plan;
    }

    fn applyComplexDrawListCounters(self: *TextSurfacePreparer, prepared: *PreparedComplexSurface, text_draw_list: *const draw_list.BorrowedTextDrawList, merged: *const PreparedDrawListMerge, complex_sprite_cache_hits: usize) void {
        prepared.lane_report.assertValid();
        var counters = prepare_counters.TextPrepareCounters{
            .cell_texts = prepared.lane_report.visible_cells,
            .clusters = prepared.lane_report.normal_clusters + prepared.lane_report.complex_clusters,
            .resolved_runs = @intCast(prepared.runs.?.runs.len),
            .shaped_runs = @intCast(prepared.shaped_runs.?.runs.len),
            .glyph_groups = @intCast(prepared.grouped.?.groups.groups.len),
            .sprite_cache_hits = @intCast((self.direct_normal.sprite_draws.items.len - self.direct_normal.raster_reqs.items.len) + complex_sprite_cache_hits),
            .sprite_cache_misses = @intCast(self.direct_normal.raster_reqs.items.len + text_draw_list.draw_list.raster_requests.len),
            .rasterized_sprites = @intCast(merged.raster_plan.outputs.len),
            .missing_glyphs = @intCast(merged.draw_list.draw_list.missing.len),
        };
        for (prepared.shaped_runs.?.runs) |run| counters.shaped_glyphs += @intCast(run.glyphs.len);
        applyCounters(&self.counters, counters);
    }

    fn mergePreparedDrawList(
        self: *TextSurfacePreparer,
        direct: direct_normal.Product,
        cells: []const render.RenderableCell,
        grid_metrics: render.CellGridMetrics,
        cell_metrics: render.CellMetrics,
        cursor: ?render.CursorPresentation,
        text_draw_list: *draw_list.BorrowedTextDrawList,
        raster_plan: *rasterizer.OwnedRasterPlan,
    ) !PreparedDrawListMerge {
        const damage: text_damage.NormalizedDamage = .{
            .full = direct.damage.full,
            .dirty_rows = direct.damage.dirty_rows,
            .dirty_cols_start = direct.damage.dirty_cols_start,
            .dirty_cols_end = direct.damage.dirty_cols_end,
        };
        const merged_clear_draws = try buildClearDraws(self.allocator, cells, cell_metrics, grid_metrics, damage);
        errdefer self.allocator.free(merged_clear_draws);
        const merged_cursor_draws = try buildCursorDraws(self.allocator, cursor, cell_metrics, damage);
        errdefer self.allocator.free(merged_cursor_draws);
        const merged_background_draws = try mergeFirstCellSlices(render.TextBackgroundDraw, self.allocator, self.direct_normal.background_draws.items, text_draw_list.draw_list.background_draws);
        errdefer self.allocator.free(merged_background_draws);
        const merged_sprite_draws = try mergeFirstCellSlices(render.TextSpriteDraw, self.allocator, self.direct_normal.sprite_draws.items, text_draw_list.draw_list.sprite_draws);
        errdefer self.allocator.free(merged_sprite_draws);
        const merged_decoration_draws = try mergeFirstCellSlices(render.TextDecorationDraw, self.allocator, self.direct_normal.decoration_draws.items, text_draw_list.draw_list.decoration_draws);
        errdefer self.allocator.free(merged_decoration_draws);
        const merged_missing = try mergeSlices(render.MissingGlyph, self.allocator, self.direct_normal.missing.items, text_draw_list.draw_list.missing);
        errdefer self.allocator.free(merged_missing);
        var merged_raster_plan = try mergeRasterPlans(self.allocator, direct.outputs, direct.outputs_owned, raster_plan);
        errdefer merged_raster_plan.deinit();

        const merged_draw_list = draw_list.OwnedTextDrawList{
            .allocator = self.allocator,
            .draw_list = .{
                .full_redraw = direct.damage.full,
                .clear_draws = merged_clear_draws,
                .background_draws = merged_background_draws,
                .sprite_draws = merged_sprite_draws,
                .decoration_draws = merged_decoration_draws,
                .cursor_draws = merged_cursor_draws,
                .raster_requests = text_draw_list.draw_list.raster_requests,
                .missing = merged_missing,
            },
            .cursor_presentation = cursor,
        };
        text_draw_list.draw_list.raster_requests = &.{};
        text_draw_list.draw_list.missing = &.{};
        return .{ .draw_list = merged_draw_list, .raster_plan = merged_raster_plan };
    }

    fn finishNormalOnlySurface(self: *TextSurfacePreparer, direct: direct_normal.Product, lane_report: lane.LaneReport, cursor: ?render.CursorPresentation) OwnedPreparedTextSurface {
        var final_lane_report = lane_report;
        final_lane_report.assertValid();
        const counters = direct_normal.counters(&self.direct_normal, final_lane_report, direct);
        applyCounters(&self.counters, counters);
        return .{
            .draw_list = blk: {
                var owned = direct_draw.borrowDrawList(self.allocator, direct.damage, &self.direct_normal);
                owned.cursor_presentation = cursor;
                break :blk owned;
            },
            .raster_plan = .{ .allocator = self.allocator, .outputs = direct.outputs, .owned = direct.outputs_owned },
        };
    }

    fn prepareDirectNormal(
        self: *TextSurfacePreparer,
        source: direct_normal.Source,
        policy: direct_normal.Policy,
        grid_metrics: render.CellGridMetrics,
        selection: face_selection.FaceSelection,
        options: PrepareOptions,
        lane_report: *lane.LaneReport,
        rejected_complex_cells: ?*u64,
    ) !?direct_normal.Product {
        const product = try direct_normal.prepare(
            .{
                .allocator = self.allocator,
                .atlas = &self.atlas,
                .glyph_lookup = self.glyph_lookup,
                .glyph_raster = self.glyph_raster,
                .scratch = &self.direct_normal,
            },
            source,
            policy,
            grid_metrics,
            selection,
            options.draw_list.damage,
            options.draw_list.cursor,
            lane_report,
            rejected_complex_cells,
        );
        return product;
    }

    fn countCellInputCodepoints(cells: []const render.CellInput) u32 {
        var total: u32 = 0;
        for (cells) |cell| total += @as(u32, 1) + cell.combining_len;
        return total;
    }
};

const PreparedDrawListMerge = struct {
    draw_list: draw_list.OwnedTextDrawList,
    raster_plan: rasterizer.OwnedRasterPlan,
};

const PreparedComplexSurface = struct {
    text_cache: cluster.OwnedLineTextCache,
    renderable: cluster.OwnedRenderableCells,
    clusters: cluster.OwnedClusters,
    direct: direct_normal.Product,
    lane_report: lane.LaneReport,
    runs: ?font_resolver.OwnedResolvedRuns = null,
    shaped_runs: ?shape_run.OwnedShapedRuns = null,
    grouped: ?PreparedGroups = null,

    fn deinit(self: *PreparedComplexSurface, allocator: std.mem.Allocator) void {
        if (self.grouped) |*grouped| grouped.deinit();
        if (self.shaped_runs) |*shaped_runs| shaped_runs.deinit();
        if (self.runs) |*runs| runs.deinit();
        self.direct.deinit(allocator);
        self.clusters.deinit();
        self.renderable.deinit();
        self.text_cache.deinit();
        self.* = undefined;
    }
};

const PreparedGroups = struct {
    font_groups: grouping.OwnedGlyphGroups,
    sprite_groups: grouping.OwnedGlyphGroups,
    groups: grouping.OwnedGlyphGroups,

    fn deinit(self: *PreparedGroups) void {
        self.groups.deinit();
        self.sprite_groups.deinit();
        self.font_groups.deinit();
        self.* = undefined;
    }
};

fn resolveComplexRuns(
    self: *TextSurfacePreparer,
    text_cache: render.LineTextCache,
    clusters: []const render.CellCluster,
    grid_metrics: render.CellGridMetrics,
    selection: face_selection.FaceSelection,
    lane_report: *lane.LaneReport,
    cells: []const render.RenderableCell,
) !font_resolver.OwnedResolvedRuns {
    const runs = try font_resolver.resolveClusters(self.allocator, &self.resolver_scratch, selection, clusters, text_cache, grid_metrics);
    for (runs.runs) |run| lane_report.recordLegacyResolvedRunWithCells(text_cache, cells, clusters, run);
    return runs;
}

fn shapeComplexRuns(
    self: *TextSurfacePreparer,
    runs: []const render.ResolvedRun,
    text_cache: render.LineTextCache,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
    lane_report: *lane.LaneReport,
    cells: []const render.RenderableCell,
) !shape_run.OwnedShapedRuns {
    const shaped_runs = try shape_run.shapeResolvedRunsWithShaper(self.allocator, self.shaper, runs, text_cache, clusters, cell_metrics);
    for (shaped_runs.runs) |run| lane_report.recordLegacyShapedRunWithCells(text_cache, cells, clusters, run.run);
    return shaped_runs;
}

fn groupComplexRuns(
    self: *TextSurfacePreparer,
    shaped_runs: []const shape_run.OwnedShapedRun,
    sprite_routes: []const font_resolver.SpriteRouteHit,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
    lane_report: *lane.LaneReport,
    text_cache: render.LineTextCache,
    cells: []const render.RenderableCell,
) !PreparedGroups {
    var font_groups = try grouping.groupShapedRunsWithPolicy(self.allocator, shaped_runs, clusters, cell_metrics, .{});
    errdefer font_groups.deinit();
    var sprite_groups = try grouping.groupSpriteRoutes(self.allocator, sprite_routes, clusters, cell_metrics);
    errdefer sprite_groups.deinit();
    const groups = try grouping.concatGroups(self.allocator, font_groups.groups, sprite_groups.groups);
    for (groups.groups) |group| lane_report.recordLegacyGroup(text_cache, cells, group);
    return .{ .font_groups = font_groups, .sprite_groups = sprite_groups, .groups = groups };
}

pub const OwnedPreparedTextSurface = struct {
    draw_list: draw_list.OwnedTextDrawList,
    raster_plan: rasterizer.OwnedRasterPlan,

    pub fn deinit(self: *OwnedPreparedTextSurface) void {
        self.raster_plan.deinit();
        self.draw_list.deinit();
        self.* = undefined;
    }
};

fn applyCounters(total: *prepare_counters.TextPrepareCounters, delta: prepare_counters.TextPrepareCounters) void {
    total.cell_texts += delta.cell_texts;
    total.clusters += delta.clusters;
    total.resolved_runs += delta.resolved_runs;
    total.shaped_runs += delta.shaped_runs;
    total.shaped_glyphs += delta.shaped_glyphs;
    total.glyph_groups += delta.glyph_groups;
    total.sprite_cache_hits += delta.sprite_cache_hits;
    total.sprite_cache_misses += delta.sprite_cache_misses;
    total.rasterized_sprites += delta.rasterized_sprites;
    total.missing_glyphs += delta.missing_glyphs;
}

fn textForCluster(text_cache: render.LineTextCache, cluster_value: render.CellCluster) render.CellText {
    const idx = cluster_value.text_id.value;
    std.debug.assert(idx < count32(text_cache.texts));
    return text_cache.texts[@intCast(idx)];
}

fn cloneSlice(comptime T: type, allocator: std.mem.Allocator, src: []const T) ![]T {
    const out = try allocator.alloc(T, src.len);
    @memcpy(out, src);
    return out;
}

fn mergeSlices(comptime T: type, allocator: std.mem.Allocator, lhs: []const T, rhs: []const T) ![]T {
    const out = try allocator.alloc(T, lhs.len + rhs.len);
    @memcpy(out[0..lhs.len], lhs);
    @memcpy(out[lhs.len..], rhs);
    return out;
}

fn mergeFirstCellSlices(comptime T: type, allocator: std.mem.Allocator, lhs: []const T, rhs: []const T) ![]T {
    const out = try allocator.alloc(T, lhs.len + rhs.len);
    const lhs_len = count32(lhs);
    const rhs_len = count32(rhs);
    var li: u32 = 0;
    var ri: u32 = 0;
    var oi: u32 = 0;
    while (li < lhs_len and ri < rhs_len) {
        if (@field(lhs[@intCast(li)], "first_cell") <= @field(rhs[@intCast(ri)], "first_cell")) {
            out[@intCast(oi)] = lhs[@intCast(li)];
            li += 1;
        } else {
            out[@intCast(oi)] = rhs[@intCast(ri)];
            ri += 1;
        }
        oi += 1;
    }
    while (li < lhs_len) : (li += 1) {
        out[@intCast(oi)] = lhs[@intCast(li)];
        oi += 1;
    }
    while (ri < rhs_len) : (ri += 1) {
        out[@intCast(oi)] = rhs[@intCast(ri)];
        oi += 1;
    }
    assertSortedByFirstCell(T, out);
    return out;
}

fn buildClearDraws(
    allocator: std.mem.Allocator,
    cells: []const render.RenderableCell,
    cell_metrics: render.CellMetrics,
    grid_metrics: render.CellGridMetrics,
    damage: text_damage.NormalizedDamage,
) ![]render.TextClearDraw {
    var draws: std.ArrayListUnmanaged(render.TextClearDraw) = .empty;
    defer draws.deinit(allocator);
    try draws.ensureTotalCapacity(allocator, grid_metrics.rows);
    rect_primitives.appendClearDrawsUnmanaged(&draws, cells, cell_metrics, grid_metrics, damage);
    return draws.toOwnedSlice(allocator);
}

fn buildCursorDraws(allocator: std.mem.Allocator, cursor: ?render.CursorPresentation, cell_metrics: render.CellMetrics, damage: text_damage.NormalizedDamage) ![]render.TextCursorDraw {
    var draws: std.ArrayListUnmanaged(render.TextCursorDraw) = .empty;
    defer draws.deinit(allocator);
    try draws.ensureTotalCapacity(allocator, 4);
    rect_primitives.appendCursorDrawsUnmanaged(&draws, cursor, damage, cell_metrics);
    return draws.toOwnedSlice(allocator);
}

fn assertSortedByFirstCell(comptime T: type, items: []const T) void {
    if (items.len <= 1) return;
    var index: usize = 1;
    while (index < items.len) : (index += 1) {
        std.debug.assert(@field(items[index - 1], "first_cell") <= @field(items[index], "first_cell"));
    }
}

fn mergeRasterPlans(
    allocator: std.mem.Allocator,
    direct_outputs: []rasterizer.RasterSpriteOutput,
    direct_outputs_owned: bool,
    complex_plan: *rasterizer.OwnedRasterPlan,
) !rasterizer.OwnedRasterPlan {
    const out = try allocator.alloc(rasterizer.RasterSpriteOutput, direct_outputs.len + complex_plan.outputs.len);
    @memcpy(out[0..direct_outputs.len], direct_outputs);
    @memcpy(out[direct_outputs.len..], complex_plan.outputs);
    if (direct_outputs_owned) allocator.free(direct_outputs);
    const complex_outputs = complex_plan.outputs;
    complex_plan.outputs = &.{};
    complex_plan.owned = false;
    allocator.free(complex_outputs);
    return .{ .allocator = allocator, .outputs = out };
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

pub const PrepareOptions = struct {
    draw_list: draw_list.DrawListOptions = .{},
};

test "text preparation prepares cell inputs into clusters and runs" {
    var engine = TextSurfacePreparer.init(std.testing.allocator);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellsWithFaceSelection(&cells, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.draw_list.draw_list.sprite_draws));
    try std.testing.expectEqual(@as(u32, 2), count32(analysis.raster_plan.outputs));
    try std.testing.expectEqual(@as(u64, 2), engine.counters.cell_texts);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.glyph_groups);
}

test "text preparation records sprite routes through resolver" {
    var engine = TextSurfacePreparer.init(std.testing.allocator);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 0x2500, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellsWithFaceSelection(&cells, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.draw_list.draw_list.sprite_draws));
    try std.testing.expectEqual(@as(u32, 2), count32(analysis.raster_plan.outputs));
    try std.testing.expectEqual(@as(u32, 1), analysis.draw_list.draw_list.sprite_draws[1].first_cell);
    try std.testing.expect(analysis.draw_list.draw_list.sprite_draws[1].placement.advance_px > 0);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.glyph_groups);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.sprite_cache_misses);
}

test "text preparation draw list is grid positioned" {
    var engine = TextSurfacePreparer.init(std.testing.allocator);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black },
        .{ .codepoint = 'c', .fg = white, .bg = black },
        .{ .codepoint = 'd', .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellsWithFaceSelection(&cells, .{ .cols = 2, .rows = 2 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 4), count32(analysis.draw_list.draw_list.sprite_draws));
    try std.testing.expectEqual(@as(i32, 0), analysis.draw_list.draw_list.sprite_draws[2].x_px);
    try std.testing.expectEqual(@as(i32, 1), analysis.draw_list.draw_list.sprite_draws[2].y_px);
}

test "text preparation rerasterizes pending atlas entries across prepares" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{.{ .codepoint = 'z', .fg = white, .bg = black }};
    var first = try engine.prepareCellsWithFaceSelection(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    const first_slot = first.draw_list.draw_list.sprite_draws[0].sprite.slot;
    first.deinit();
    var second = try engine.prepareCellsWithFaceSelection(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer second.deinit();
    try std.testing.expectEqual(first_slot, second.draw_list.draw_list.sprite_draws[0].sprite.slot);
    try std.testing.expectEqual(@as(u32, 1), count32(second.raster_plan.outputs));
    try std.testing.expectEqual(@as(u32, 1), engine.atlas.len);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.sprite_cache_hits);
    try std.testing.expect(!engine.atlas.get(.{ .value = second.draw_list.draw_list.sprite_draws[0].sprite.key.value }).?.rendered);
}

test "text preparation rerasterizes sprites after cell metrics change" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{.{ .codepoint = 0x2588, .fg = white, .bg = black }};
    var first = try engine.prepareCellsWithFaceSelection(
        &cells,
        .{ .cols = 1, .rows = 1 },
        .{ .primary_face = .{ .value = 1 }, .cell_metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 } },
        .{},
    );
    const first_key = first.draw_list.draw_list.sprite_draws[0].sprite.key.value;
    first.deinit();
    var second = try engine.prepareCellsWithFaceSelection(
        &cells,
        .{ .cols = 1, .rows = 1 },
        .{ .primary_face = .{ .value = 1 }, .cell_metrics = .{ .cell_w_px = 16, .cell_h_px = 32, .baseline_px = 24 } },
        .{},
    );
    defer second.deinit();
    try std.testing.expect(first_key != second.draw_list.draw_list.sprite_draws[0].sprite.key.value);
    try std.testing.expectEqual(@as(u32, 1), count32(second.raster_plan.outputs));
    try std.testing.expectEqual(@as(u16, 16), second.raster_plan.outputs[0].width_px);
    try std.testing.expectEqual(@as(u16, 32), second.raster_plan.outputs[0].height_px);
}

test "text preparation rerasterizes sprites after box thickness change" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{.{ .codepoint = 0x256d, .fg = white, .bg = black }};
    var first = try engine.prepareCellsWithFaceSelection(
        &cells,
        .{ .cols = 1, .rows = 1 },
        .{ .primary_face = .{ .value = 1 }, .cell_metrics = .{ .cell_w_px = 18, .cell_h_px = 18, .baseline_px = 14, .box_thickness_px = 1 } },
        .{},
    );
    const first_key = first.draw_list.draw_list.sprite_draws[0].sprite.key.value;
    first.deinit();
    var second = try engine.prepareCellsWithFaceSelection(
        &cells,
        .{ .cols = 1, .rows = 1 },
        .{ .primary_face = .{ .value = 1 }, .cell_metrics = .{ .cell_w_px = 18, .cell_h_px = 18, .baseline_px = 14, .box_thickness_px = 3 } },
        .{},
    );
    defer second.deinit();
    try std.testing.expect(first_key != second.draw_list.draw_list.sprite_draws[0].sprite.key.value);
    try std.testing.expectEqual(@as(u32, 1), count32(second.raster_plan.outputs));
}

test "text preparation accepts configurable shaper" {
    const Stub = struct {
        hits: u8 = 0,

        fn shape(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            run: render.ResolvedRun,
            text_cache: render.LineTextCache,
            clusters: []const render.CellCluster,
            cell_metrics: render.CellMetrics,
        ) anyerror!shape_run.OwnedShapedRun {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;
            return shape_run.shapeRun(allocator, run, text_cache, clusters, cell_metrics);
        }
    };

    var stub = Stub{};
    var engine = try TextSurfacePreparer.initWithShaper(std.testing.allocator, 8, .{ .ctx = &stub, .shape_run = Stub.shape });
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const combining = [_]u32{ 'q', 0x0332 };
    const inputs = [_]cluster.CellTextInput{.{ .codepoints = &combining, .fg = white, .bg = black }};
    var analysis = try engine.prepareCellTextInputsWithFaceSelection(&inputs, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();
    try std.testing.expectEqual(@as(u8, 1), stub.hits);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
}

test "text preparation accepts unified provider rasterizer" {
    const Stub = struct {
        hits: u8 = 0,

        fn raster(ctx: *anyopaque, allocator: std.mem.Allocator, req: render.SpriteRasterRequest) anyerror!rasterizer.RasterSpriteOutput {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;
            return rasterizer.placeholderRaster(allocator, req);
        }
    };
    var stub = Stub{};
    var engine = try TextSurfacePreparer.initWithProvider(std.testing.allocator, 8, .{ .rasterizer = .{ .ctx = &stub, .rasterize_sprite = Stub.raster } });
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{.{ .codepoint = 0x2500, .fg = white, .bg = black }};
    var analysis = try engine.prepareCellsWithFaceSelection(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();
    try std.testing.expectEqual(@as(u8, 1), stub.hits);
}

test "text preparation options produce draw list cursor draws" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{.{ .codepoint = 'c', .fg = white, .bg = black }};
    var analysis = try engine.prepareCellsWithFaceSelection(&cells, .{ .cols = 1, .rows = 1 }, .{
        .primary_face = .{ .value = 1 },
        .cell_metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
    }, .{
        .draw_list = .{ .cursor = .{
            .focused = true,
            .visible = true,
            .blink = false,
            .shape = .block,
            .cursor_opacity = 255,
            .text_blink_opacity = 255,
            .cursor_color = .{ .kind = .rgb, .value = 0xffffff },
            .cursor_text_color = .{ .kind = .default, .value = 0 },
            .default_foreground = .{ .r = 255, .g = 255, .b = 255 },
            .default_background = .{ .r = 0, .g = 0, .b = 0 },
            .primary_extent = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 },
            .extra_cursors = [_]render.ExtraCursorPresentation{undefined} ** 256,
            .extra_cursor_count = 0,
            .trail = .{ .rects = [_]render.CursorTrailRect{undefined} ** 16, .count = 0 },
        } },
    });
    defer analysis.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(analysis.draw_list.draw_list.cursor_draws));
    try std.testing.expectEqual(@as(u16, 8), analysis.draw_list.draw_list.cursor_draws[0].width_px);
    try std.testing.expect(analysis.draw_list.cursor_presentation != null);
}

test "text preparation partial damage clears use empty default background truth" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const transparent_bg = render.Rgba8{ .r = 0x44, .g = 0x55, .b = 0x66, .a = 0 };
    const cells = [_]render.CellInput{.{ .codepoint = ' ', .fg = white, .bg = transparent_bg, .empty = true }};
    var analysis = try engine.prepareCellsWithFaceSelection(&cells, .{ .cols = 1, .rows = 1 }, .{}, .{
        .draw_list = .{ .damage = .{ .full = false, .dirty_rows = &[_]bool{true}, .dirty_cols_start = &[_]u16{0}, .dirty_cols_end = &[_]u16{0} } },
    });
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 1), count32(analysis.draw_list.draw_list.clear_draws));
    try std.testing.expectEqual(@as(u32, 0), count32(analysis.draw_list.draw_list.background_draws));
    try std.testing.expectEqual(@as(u32, 0), count32(analysis.draw_list.draw_list.sprite_draws));
    try std.testing.expectEqual(transparent_bg.r, analysis.draw_list.draw_list.clear_draws[0].color.r);
    try std.testing.expectEqual(transparent_bg.g, analysis.draw_list.draw_list.clear_draws[0].color.g);
    try std.testing.expectEqual(transparent_bg.b, analysis.draw_list.draw_list.clear_draws[0].color.b);
    try std.testing.expectEqual(@as(u8, 255), analysis.draw_list.draw_list.clear_draws[0].color.a);
}

test "text preparation direct-renders pure normal cell text inputs" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const a = [_]u32{'a'};
    const b = [_]u32{'b'};
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &a, .fg = white, .bg = black },
        .{ .codepoints = &b, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellTextInputsWithFaceSelection(&inputs, .{ .cols = 2, .rows = 1 }, .{}, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.draw_list.draw_list.sprite_draws));
    try std.testing.expectEqual(@as(u32, 2), count32(analysis.raster_plan.outputs));
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.shaped_runs);
}

test "text preparation keeps mixed cell text normals out of legacy path" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const a = [_]u32{'a'};
    const combining = [_]u32{ 'i', 0x0332 };
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &a, .fg = white, .bg = black },
        .{ .codepoints = &combining, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellTextInputsWithFaceSelection(&inputs, .{ .cols = 2, .rows = 1 }, .{}, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.draw_list.draw_list.sprite_draws));
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
}

test "text preparation marks curly underline cells complex before shaping" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black, .underline = true, .underline_style = .curly },
    };
    var analysis = try engine.prepareCellsWithFaceSelection(&cells, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 3), count32(analysis.draw_list.draw_list.sprite_draws));
    try std.testing.expectEqual(@as(u32, 0), count32(analysis.draw_list.draw_list.decoration_draws));
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.glyph_groups);
}

test "text preparation sizes cluster scratch for multi codepoint cell inputs" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{
        .{ .codepoint = 'x', .combining_len = 3, .combining = .{ 0x0305, 0x030D, 0x030E }, .fg = white, .bg = black },
        .{ .codepoint = 'y', .combining_len = 3, .combining = .{ 0x0310, 0x0312, 0x033D }, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellsWithFaceSelection(&cells, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expect(count32(analysis.draw_list.draw_list.sprite_draws) != 0);
}

test "text preparation keeps icon codepoints out of the normal lane" {
    const Stub = struct {
        fn shape(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            run: render.ResolvedRun,
            text_cache: render.LineTextCache,
            clusters: []const render.CellCluster,
            cell_metrics: render.CellMetrics,
        ) anyerror!shape_run.OwnedShapedRun {
            _ = text_cache;
            _ = cell_metrics;
            std.debug.assert(clusters.len >= 1);
            const glyphs = try allocator.alloc(render.GlyphInstance, 1);
            glyphs[0] = .{
                .face_id = run.run.font.face_id,
                .glyph_id = clusters[0].first_cp,
                .cluster_index = 0,
                .x_advance_px = 16,
            };
            return .{ .allocator = allocator, .run = run, .glyphs = glyphs };
        }
    };

    var engine = try TextSurfacePreparer.initWithShaper(std.testing.allocator, 16, .{ .ctx = undefined, .shape_run = Stub.shape });
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const icon = [_]u32{0xf101};
    const blank = [_]u32{' '};
    const ascii = [_]u32{'a'};
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &icon, .fg = white, .bg = black },
        .{ .codepoints = &blank, .fg = white, .bg = black },
        .{ .codepoints = &ascii, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellTextInputsWithFaceSelection(&inputs, .{ .cols = 3, .rows = 1 }, .{ .cell_metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u16, 16), analysis.draw_list.draw_list.sprite_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 2), analysis.draw_list.draw_list.sprite_draws[0].cell_span);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.glyph_groups);
}

test "text preparation uses ft hb source coverage for fallback" {
    const FallbackShaper = struct {
        last_face_id: u32 = 0,
        inner: shape_run.Shaper,

        fn shape(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            run: render.ResolvedRun,
            text_cache: render.LineTextCache,
            clusters: []const render.CellCluster,
            cell_metrics: render.CellMetrics,
        ) anyerror!shape_run.OwnedShapedRun {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.last_face_id = run.run.font.face_id.value;
            return self.inner.shapeRun(allocator, run, text_cache, clusters, cell_metrics);
        }
    };

    const Backend = struct {
        fn has(ctx: *anyopaque, face_id: render.FontFaceId, cp: u32) bool {
            _ = ctx;
            if (face_id.value == 1) return cp >= 'a' and cp <= 'z';
            return true;
        }
    };
    var dummy: u8 = 0;
    var font_source = provider.FontSource{ .ctx = &dummy, .has_codepoint = Backend.has };
    var provider_value = font_source.textProvider();
    var shaper = FallbackShaper{ .inner = provider_value.shaper };
    provider_value.shaper = .{ .ctx = &shaper, .shape_run = FallbackShaper.shape };
    var engine = try TextSurfacePreparer.initWithProvider(std.testing.allocator, 16, provider_value);
    defer engine.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const combining = [_]u32{ 'i', 0x0332 };
    const inputs = [_]cluster.CellTextInput{.{ .codepoints = &combining, .fg = white, .bg = black }};
    const faces = [_]face_selection.FaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    var analysis = try engine.prepareCellTextInputsWithFaceSelection(&inputs, .{ .cols = 1, .rows = 1 }, font_source.textProvider().applyToSelection(.{ .faces = &faces }), .{});
    defer analysis.deinit();
    try std.testing.expectEqual(@as(u32, 2), shaper.last_face_id);
}
