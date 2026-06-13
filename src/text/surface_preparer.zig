const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");
const direct_normal = @import("direct_normal.zig");
const direct_scene = @import("direct_scene.zig");
const prepare_counters = @import("prepare_counters.zig");
const atlas_cache = @import("raster/atlas.zig");
const cluster = @import("shape/cluster.zig");
const font_resolver = @import("resolver.zig");
const font_session = @import("session.zig");
const ft_hb_provider = @import("ft_hb/provider.zig");
const grouping = @import("shape/grouping.zig");
const provider = @import("provider.zig");
const raster_operation = @import("raster/operation.zig");
const rasterizer = @import("raster/rasterizer.zig");
const scene = @import("scene.zig");
const scene_damage = @import("scene_damage.zig");
const shape_run = @import("shape/run.zig");
const lane = @import("lane.zig");
const source_vt = @import("../vt_publication/abi.zig");
const source_publication = @import("../vt_publication/publication.zig");
const source_theme = @import("../vt_publication/theme.zig");

pub const PrepareTimings = struct {
    direct_normal_us: u64 = 0,
    direct_normal_scan_us: u64 = 0,
    direct_normal_backgrounds_us: u64 = 0,
    direct_normal_clears_us: u64 = 0,
    direct_normal_decorations_us: u64 = 0,
    direct_normal_cursor_us: u64 = 0,
    direct_normal_raster_us: u64 = 0,
    input_us: u64 = 0,
    session_preparer_us: u64 = 0,
    session_prepare_cells_us: u64 = 0,
    sparse_us: u64 = 0,
    clusters_us: u64 = 0,
    resolve_us: u64 = 0,
    shape_us: u64 = 0,
    group_us: u64 = 0,
    scene_us: u64 = 0,
    raster_us: u64 = 0,
    atlas_us: u64 = 0,
};

fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedUs(start_ns: u64) u64 {
    return @divTrunc(monotonicNs() -| start_ns, std.time.ns_per_us);
}

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
    scene_scratch: scene.RetainedScratch = .{},

    pub fn init(allocator: std.mem.Allocator) TextSurfacePreparer {
        return initCapacity(allocator, 4096) catch unreachable;
    }

    pub fn initCapacity(allocator: std.mem.Allocator, atlas_capacity: atlas_cache.AtlasCapacity) !TextSurfacePreparer {
        return initWithProvider(allocator, atlas_capacity, provider.defaultProvider());
    }

    pub fn initWithShaper(allocator: std.mem.Allocator, atlas_capacity: atlas_cache.AtlasCapacity, shaper: shape_run.Shaper) !TextSurfacePreparer {
        return initWithProvider(allocator, atlas_capacity, .{ .shaper = shaper });
    }

    pub fn initWithProvider(allocator: std.mem.Allocator, atlas_capacity: atlas_cache.AtlasCapacity, text_provider: provider.TextProvider) !TextSurfacePreparer {
        return .{
            .allocator = allocator,
            .atlas = try atlas_cache.OwnedAtlasCache.init(allocator, atlas_capacity),
            .shaper = text_provider.shaper,
            .sprite_rasterizer = text_provider.rasterizer,
            .glyph_lookup = text_provider.glyph_lookup,
            .glyph_raster = text_provider.glyph_raster,
        };
    }

    pub fn deinit(self: *TextSurfacePreparer) void {
        self.scene_scratch.deinit(self.allocator);
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

    pub fn prepareCellsWithSessionOptions(
        self: *TextSurfacePreparer,
        cells: []const contract.CellInput,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: PrepareOptions,
    ) !OwnedPreparedTextSurface {
        var lane_report = lane.LaneReport{};
        var timings = PrepareTimings{};
        if (try self.prepareDirectNormal(.{ .raw_cells = cells }, .require_all_normal, grid_metrics, session, options, &lane_report, &timings, null)) |direct| {
            return self.finishNormalOnlySurface(direct, lane_report, timings);
        }
        const sparse_start_ns = monotonicNs();
        const cell_count = count32(cells);
        try self.ensureClusterScratchCapacity(cell_count, countCellInputCodepoints(cells));
        var sparse = try cluster.buildSparseCellsWithDamageScratch(self.allocator, &self.cluster_scratch, cells, grid_metrics, options.scene.damage);
        timings.sparse_us = elapsedUs(sparse_start_ns);
        errdefer sparse.deinit();
        return self.preparePreparedTextSurface(sparse.text_cache, sparse.renderable, grid_metrics, session, options, timings);
    }

    pub fn prepareCellTextInputsWithSessionOptions(
        self: *TextSurfacePreparer,
        inputs: []const cluster.CellTextInput,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: PrepareOptions,
    ) !OwnedPreparedTextSurface {
        var lane_report = lane.LaneReport{};
        var timings = PrepareTimings{};
        if (try self.prepareDirectNormal(.{ .inputs = inputs }, .require_all_normal, grid_metrics, session, options, &lane_report, &timings, null)) |direct| {
            return self.finishNormalOnlySurface(direct, lane_report, timings);
        }
        const input_count = count32(inputs);
        var input_codepoints: u32 = 0;
        for (inputs) |input| input_codepoints += @intCast(@max(input.codepoints.len, 1));
        try self.ensureClusterScratchCapacity(input_count, input_codepoints);
        var text_cache = try cluster.buildLineTextCacheFromInputsScratch(self.allocator, &self.cluster_scratch, inputs);
        errdefer text_cache.deinit();
        var renderable = try cluster.buildRenderableCellsFromInputs(self.allocator, inputs, text_cache.view());
        errdefer renderable.deinit();
        return self.preparePreparedTextSurface(text_cache, renderable, grid_metrics, session, options, .{});
    }

    pub fn preparePublicationWithSessionOptions(
        self: *TextSurfacePreparer,
        source: source_publication.PublicationSource,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: PrepareOptions,
        theme: source_theme.SurfaceTheme,
    ) !?OwnedPreparedTextSurface {
        var lane_report = lane.LaneReport{};
        var timings = PrepareTimings{};
        var publication_complex_cells: u64 = 0;
        if (try self.prepareDirectNormal(.{ .publication = .{ .cells = source.cells, .theme = theme } }, .require_all_normal, grid_metrics, session, options, &lane_report, &timings, &publication_complex_cells)) |direct| {
            return self.finishNormalOnlySurface(direct, lane_report, timings);
        }
        const cell_count = count32(source.cells);
        try self.ensureClusterScratchCapacity(cell_count, countPublicationCodepoints(source.cells));
        // If publication failed direct-normal, it must continue through the shared shaped-scene owner.
        std.debug.assert(publication_complex_cells != 0);
        const sparse_start_ns = monotonicNs();
        var sparse = try cluster.buildSparsePublicationCellsWithDamageScratch(self.allocator, &self.cluster_scratch, source.cells, theme, grid_metrics, options.scene.damage);
        timings.sparse_us = elapsedUs(sparse_start_ns);
        errdefer sparse.deinit();
        return try self.preparePreparedTextSurfaceWithExpectedComplexCells(sparse.text_cache, sparse.renderable, grid_metrics, session, options, timings, publication_complex_cells);
    }

    fn preparePreparedTextSurface(
        self: *TextSurfacePreparer,
        text_cache: cluster.OwnedLineTextCache,
        renderable: cluster.OwnedRenderableCells,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: PrepareOptions,
        initial_timings: PrepareTimings,
    ) !OwnedPreparedTextSurface {
        return self.preparePreparedTextSurfaceWithExpectedComplexCells(text_cache, renderable, grid_metrics, session, options, initial_timings, null);
    }

    fn preparePreparedTextSurfaceWithExpectedComplexCells(
        self: *TextSurfacePreparer,
        text_cache: cluster.OwnedLineTextCache,
        renderable: cluster.OwnedRenderableCells,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: PrepareOptions,
        initial_timings: PrepareTimings,
        expected_complex_cells: ?u64,
    ) !OwnedPreparedTextSurface {
        var timings = initial_timings;
        var owned_text_cache = text_cache;
        errdefer owned_text_cache.deinit();
        var owned_renderable = renderable;
        errdefer owned_renderable.deinit();
        const clusters_start_ns = monotonicNs();
        var clusters = try cluster.extractClustersWithDamageScratch(
            self.allocator,
            &self.cluster_scratch,
            owned_renderable.cells,
            owned_text_cache.view(),
            grid_metrics,
            options.scene.damage,
        );
        timings.clusters_us = elapsedUs(clusters_start_ns);
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
            session,
            options,
            &final_lane_report,
            &timings,
            null,
        )).?;

        if (final_lane_report.complex_cells == 0) {
            std.debug.assert(expected_complex_cells == null);
            owned_text_cache.deinit();
            clusters.deinit();
            owned_renderable.deinit();
            return self.finishNormalOnlySurface(direct, final_lane_report, timings);
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
            session,
            options,
            &timings,
        );
    }

    fn prepareComplexSurface(
        self: *TextSurfacePreparer,
        prepared: PreparedComplexSurface,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: PrepareOptions,
        timings: *PrepareTimings,
    ) !OwnedPreparedTextSurface {
        var final_prepared = prepared;
        errdefer final_prepared.deinit(self.allocator);
        var complex = try self.selectComplexCells(&final_prepared, grid_metrics, options.scene.damage);
        defer complex.deinit();

        try self.resolveShapeAndGroupComplex(&final_prepared, complex, grid_metrics, session, timings);
        var text_scene = try self.buildComplexScene(&final_prepared, complex.cells, grid_metrics, session.metrics, options.scene, timings);
        errdefer text_scene.deinit();
        var raster_plan = try self.rasterizeComplexScene(&text_scene, timings);
        errdefer raster_plan.deinit();
        const complex_sprite_cache_hits = text_scene.scene.sprite_draws.len - text_scene.scene.raster_requests.len;

        const merged = try self.mergePreparedScene(final_prepared.direct, final_prepared.renderable.cells, grid_metrics, session.metrics, options.scene.cursor, &text_scene, &raster_plan);
        final_prepared.direct.outputs = &.{};
        final_prepared.direct.outputs_owned = false;

        self.applyComplexCounters(&final_prepared, &text_scene, &merged, complex_sprite_cache_hits);
        final_prepared.deinit(self.allocator);

        return .{
            .scene = merged.scene,
            .raster_plan = merged.raster_plan,
            .timings = timings.*,
        };
    }

    fn selectComplexCells(self: *TextSurfacePreparer, prepared: *const PreparedComplexSurface, grid_metrics: contract.GridMetrics, damage: scene_damage.DamageInput) !cluster.ComplexSelection {
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

    fn resolveShapeAndGroupComplex(self: *TextSurfacePreparer, prepared: *PreparedComplexSurface, complex: cluster.ComplexSelection, grid_metrics: contract.GridMetrics, session: font_session.FontSession, timings: *PrepareTimings) !void {
        prepared.runs = try resolveComplexRuns(self, prepared.text_cache.view(), complex.clusters, grid_metrics, session, timings, &prepared.lane_report, complex.cells);
        prepared.shaped_runs = try shapeComplexRuns(
            self,
            prepared.runs.?.runs,
            prepared.text_cache.view(),
            complex.clusters,
            session.metrics,
            timings,
            &prepared.lane_report,
            complex.cells,
        );
        prepared.grouped = try groupComplexRuns(
            self,
            prepared.shaped_runs.?.runs,
            prepared.runs.?.sprite_routes,
            complex.clusters,
            session.metrics,
            timings,
            &prepared.lane_report,
            prepared.text_cache.view(),
            complex.cells,
        );
    }

    fn buildComplexScene(self: *TextSurfacePreparer, prepared: *PreparedComplexSurface, cells: []const contract.RenderableCell, grid_metrics: contract.GridMetrics, cell_metrics: contract.CellMetrics, options: scene.BuildOptions, timings: *PrepareTimings) !scene.BorrowedTextScene {
        const scene_start_ns = monotonicNs();
        const text_scene = try scene.buildBorrowedSceneWithAtlasCacheOptions(
            self.allocator,
            &self.scene_scratch,
            cells,
            prepared.grouped.?.groups.groups,
            prepared.runs.?.missing,
            cell_metrics,
            grid_metrics,
            &self.atlas,
            options,
        );
        timings.scene_us = elapsedUs(scene_start_ns);
        for (text_scene.scene.sprite_draws) |draw| prepared.lane_report.recordLegacySceneSpriteDraw(prepared.text_cache.view(), cells, draw);
        return text_scene;
    }

    fn rasterizeComplexScene(self: *TextSurfacePreparer, text_scene: *const scene.BorrowedTextScene, timings: *PrepareTimings) !rasterizer.OwnedRasterPlan {
        const raster_start_ns = monotonicNs();
        const raster_plan = try rasterizer.rasterizeRequestsWithRasterizer(self.allocator, self.sprite_rasterizer, text_scene.scene.raster_requests);
        timings.raster_us = elapsedUs(raster_start_ns);
        return raster_plan;
    }

    fn applyComplexCounters(self: *TextSurfacePreparer, prepared: *PreparedComplexSurface, text_scene: *const scene.BorrowedTextScene, merged: *const PreparedSceneMerge, complex_sprite_cache_hits: usize) void {
        prepared.lane_report.assertValid();
        var counters = prepare_counters.TextPrepareCounters{
            .cell_texts = prepared.lane_report.visible_cells,
            .clusters = prepared.lane_report.normal_clusters + prepared.lane_report.complex_clusters,
            .resolved_runs = @intCast(prepared.runs.?.runs.len),
            .shaped_runs = @intCast(prepared.shaped_runs.?.runs.len),
            .glyph_groups = @intCast(prepared.grouped.?.groups.groups.len),
            .sprite_cache_hits = @intCast((self.direct_normal.sprite_draws.items.len - self.direct_normal.raster_reqs.items.len) + complex_sprite_cache_hits),
            .sprite_cache_misses = @intCast(self.direct_normal.raster_reqs.items.len + text_scene.scene.raster_requests.len),
            .rasterized_sprites = @intCast(merged.raster_plan.outputs.len),
            .missing_glyphs = @intCast(merged.scene.scene.missing.len),
        };
        for (prepared.shaped_runs.?.runs) |run| counters.shaped_glyphs += @intCast(run.glyphs.len);
        applyCounters(&self.counters, counters);
    }

    fn mergePreparedScene(
        self: *TextSurfacePreparer,
        direct: direct_normal.Product,
        cells: []const contract.RenderableCell,
        grid_metrics: contract.GridMetrics,
        cell_metrics: contract.CellMetrics,
        cursor: ?scene.CursorInput,
        text_scene: *scene.BorrowedTextScene,
        raster_plan: *rasterizer.OwnedRasterPlan,
    ) !PreparedSceneMerge {
        const damage: scene_damage.NormalizedDamage = .{
            .full = direct.damage.full,
            .dirty_rows = direct.damage.dirty_rows,
            .dirty_cols_start = direct.damage.dirty_cols_start,
            .dirty_cols_end = direct.damage.dirty_cols_end,
        };
        const merged_clear_draws = try buildClearDraws(self.allocator, cells, cell_metrics, grid_metrics, damage);
        errdefer self.allocator.free(merged_clear_draws);
        const merged_cursor_draws = try buildCursorDraws(self.allocator, cursor, cell_metrics, damage);
        errdefer self.allocator.free(merged_cursor_draws);
        const merged_background_draws = try mergeFirstCellSlices(contract.TextBackgroundDraw, self.allocator, self.direct_normal.background_draws.items, text_scene.scene.background_draws);
        errdefer self.allocator.free(merged_background_draws);
        const merged_sprite_draws = try mergeFirstCellSlices(contract.TextSpriteDraw, self.allocator, self.direct_normal.sprite_draws.items, text_scene.scene.sprite_draws);
        errdefer self.allocator.free(merged_sprite_draws);
        const merged_decoration_draws = try mergeFirstCellSlices(contract.TextDecorationDraw, self.allocator, self.direct_normal.decoration_draws.items, text_scene.scene.decoration_draws);
        errdefer self.allocator.free(merged_decoration_draws);
        const merged_missing = try mergeSlices(contract.MissingGlyph, self.allocator, self.direct_normal.missing.items, text_scene.scene.missing);
        errdefer self.allocator.free(merged_missing);
        var merged_raster_plan = try mergeRasterPlans(self.allocator, direct.outputs, direct.outputs_owned, raster_plan);
        errdefer merged_raster_plan.deinit();

        const merged_scene = scene.OwnedTextScene{
            .allocator = self.allocator,
            .scene = .{
                .full_redraw = direct.damage.full,
                .clear_draws = merged_clear_draws,
                .background_draws = merged_background_draws,
                .sprite_draws = merged_sprite_draws,
                .decoration_draws = merged_decoration_draws,
                .cursor_draws = merged_cursor_draws,
                .raster_requests = text_scene.scene.raster_requests,
                .missing = merged_missing,
            },
        };
        text_scene.scene.raster_requests = &.{};
        text_scene.scene.missing = &.{};
        return .{ .scene = merged_scene, .raster_plan = merged_raster_plan };
    }

    fn finishNormalOnlySurface(self: *TextSurfacePreparer, direct: direct_normal.Product, lane_report: lane.LaneReport, timings: PrepareTimings) OwnedPreparedTextSurface {
        var final_lane_report = lane_report;
        final_lane_report.assertValid();
        const counters = direct_normal.counters(&self.direct_normal, final_lane_report, direct);
        applyCounters(&self.counters, counters);
        return .{
            .scene = direct_scene.borrowScene(self.allocator, direct.damage, &self.direct_normal),
            .raster_plan = .{ .allocator = self.allocator, .outputs = direct.outputs, .owned = direct.outputs_owned },
            .timings = timings,
        };
    }

    fn prepareDirectNormal(
        self: *TextSurfacePreparer,
        source: direct_normal.Source,
        policy: direct_normal.Policy,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: PrepareOptions,
        lane_report: *lane.LaneReport,
        timings: *PrepareTimings,
        rejected_complex_cells: ?*u64,
    ) !?direct_normal.Product {
        const start_ns = monotonicNs();
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
            session,
            options.scene.damage,
            options.scene.cursor,
            lane_report,
            rejected_complex_cells,
        );
        timings.direct_normal_us += elapsedUs(start_ns);
        if (product) |direct| {
            timings.direct_normal_scan_us += direct.timings.scan_us;
            timings.direct_normal_backgrounds_us += direct.timings.backgrounds_us;
            timings.direct_normal_clears_us += direct.timings.clears_us;
            timings.direct_normal_decorations_us += direct.timings.decorations_us;
            timings.direct_normal_cursor_us += direct.timings.cursor_us;
            timings.direct_normal_raster_us += direct.timings.raster_us;
        }
        return product;
    }

    fn countCellInputCodepoints(cells: []const contract.CellInput) u32 {
        var total: u32 = 0;
        for (cells) |cell| total += @as(u32, 1) + cell.combining_len;
        return total;
    }

    fn countPublicationCodepoints(cells: []const source_vt.SourceCell) u32 {
        var total: u32 = 0;
        for (cells) |cell| total += @as(u32, 1) + cell.combining_len;
        return total;
    }
};

const PreparedSceneMerge = struct {
    scene: scene.OwnedTextScene,
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
    text_cache: contract.LineTextCache,
    clusters: []const contract.CellCluster,
    grid_metrics: contract.GridMetrics,
    session: font_session.FontSession,
    timings: *PrepareTimings,
    lane_report: *lane.LaneReport,
    cells: []const contract.RenderableCell,
) !font_resolver.OwnedResolvedRuns {
    const resolve_start_ns = monotonicNs();
    const runs = try font_resolver.resolveClusters(self.allocator, &self.resolver_scratch, session, clusters, text_cache, grid_metrics);
    timings.resolve_us = elapsedUs(resolve_start_ns);
    for (runs.runs) |run| lane_report.recordLegacyResolvedRunWithCells(text_cache, cells, clusters, run);
    return runs;
}

fn shapeComplexRuns(
    self: *TextSurfacePreparer,
    runs: []const contract.ResolvedRun,
    text_cache: contract.LineTextCache,
    clusters: []const contract.CellCluster,
    cell_metrics: contract.CellMetrics,
    timings: *PrepareTimings,
    lane_report: *lane.LaneReport,
    cells: []const contract.RenderableCell,
) !shape_run.OwnedShapedRuns {
    const shape_start_ns = monotonicNs();
    const shaped_runs = try shape_run.shapeResolvedRunsWithShaper(self.allocator, self.shaper, runs, text_cache, clusters, cell_metrics);
    timings.shape_us = elapsedUs(shape_start_ns);
    for (shaped_runs.runs) |run| lane_report.recordLegacyShapedRunWithCells(text_cache, cells, clusters, run.run);
    return shaped_runs;
}

fn groupComplexRuns(
    self: *TextSurfacePreparer,
    shaped_runs: []const shape_run.OwnedShapedRun,
    sprite_routes: []const font_resolver.SpriteRouteHit,
    clusters: []const contract.CellCluster,
    cell_metrics: contract.CellMetrics,
    timings: *PrepareTimings,
    lane_report: *lane.LaneReport,
    text_cache: contract.LineTextCache,
    cells: []const contract.RenderableCell,
) !PreparedGroups {
    const group_start_ns = monotonicNs();
    var font_groups = try grouping.groupShapedRunsWithPolicy(self.allocator, shaped_runs, clusters, cell_metrics, .{});
    errdefer font_groups.deinit();
    var sprite_groups = try grouping.groupSpriteRoutes(self.allocator, sprite_routes, clusters, cell_metrics);
    errdefer sprite_groups.deinit();
    const groups = try grouping.concatGroups(self.allocator, font_groups.groups, sprite_groups.groups);
    timings.group_us = elapsedUs(group_start_ns);
    for (groups.groups) |group| lane_report.recordLegacyGroup(text_cache, cells, group);
    return .{ .font_groups = font_groups, .sprite_groups = sprite_groups, .groups = groups };
}

pub const OwnedPreparedTextSurface = struct {
    scene: scene.OwnedTextScene,
    raster_plan: rasterizer.OwnedRasterPlan,
    timings: PrepareTimings = .{},

    pub fn deinit(self: *OwnedPreparedTextSurface) void {
        self.raster_plan.deinit();
        self.scene.deinit();
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

fn textForCluster(text_cache: contract.LineTextCache, cluster_value: contract.CellCluster) contract.CellText {
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
    cells: []const contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: scene_damage.NormalizedDamage,
) ![]contract.TextClearDraw {
    var draws: std.ArrayListUnmanaged(contract.TextClearDraw) = .empty;
    defer draws.deinit(allocator);
    try draws.ensureTotalCapacity(allocator, grid_metrics.rows);
    scene.appendClearDrawsUnmanaged(&draws, cells, cell_metrics, grid_metrics, damage);
    return draws.toOwnedSlice(allocator);
}

fn buildCursorDraws(allocator: std.mem.Allocator, cursor: ?scene.CursorInput, cell_metrics: contract.CellMetrics, damage: scene_damage.NormalizedDamage) ![]contract.TextCursorDraw {
    var draws: std.ArrayListUnmanaged(contract.TextCursorDraw) = .empty;
    defer draws.deinit(allocator);
    try draws.ensureTotalCapacity(allocator, 4);
    scene.appendCursorDrawsUnmanaged(&draws, cursor, damage, cell_metrics);
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
    scene: scene.BuildOptions = .{},
};

fn testPublicationCell(codepoint: u32) source_vt.SourceCell {
    return .{
        .codepoint = codepoint,
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
        .link_id = 0,
    };
}

fn testOneRowPublicationSource(cells: []source_vt.SourceCell, colors: source_vt.SourceColors) source_publication.PublicationSource {
    std.debug.assert(cells.len <= std.math.maxInt(u16));
    return .{
        .cols = @intCast(cells.len),
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells,
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = colors,
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = &.{},
        .dirty_cols_start = &.{},
        .dirty_cols_end = &.{},
        .retained_storage = true,
    };
}

fn testPublicationColors() source_vt.SourceColors {
    var colors = std.mem.zeroes(source_vt.SourceColors);
    colors.foreground = .{ .r = 0xf0, .g = 0xf1, .b = 0xf2 };
    colors.background = .{ .r = 0x10, .g = 0x11, .b = 0x12 };
    colors.cursor = .{ .r = 0xff, .g = 0xff, .b = 0xff };
    colors.palette[2] = .{ .r = 0x20, .g = 0x21, .b = 0x22 };
    colors.palette[3] = .{ .r = 0x30, .g = 0x31, .b = 0x32 };
    colors.palette[4] = .{ .r = 0x40, .g = 0x41, .b = 0x42 };
    colors.palette[5] = .{ .r = 0x50, .g = 0x51, .b = 0x52 };
    return colors;
}

test "text preparation prepares cell inputs into clusters and runs" {
    var engine = TextSurfacePreparer.init(std.testing.allocator);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 2), count32(analysis.raster_plan.outputs));
    try std.testing.expectEqual(@as(u64, 2), engine.counters.cell_texts);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.glyph_groups);
}

test "text preparation records sprite routes through resolver" {
    var engine = TextSurfacePreparer.init(std.testing.allocator);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 0x2500, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 2), count32(analysis.raster_plan.outputs));
    try std.testing.expectEqual(@as(u32, 1), analysis.scene.scene.sprite_draws[1].first_cell);
    try std.testing.expect(analysis.scene.scene.sprite_draws[1].placement.advance_px > 0);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.glyph_groups);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.sprite_cache_misses);
}

test "text preparation scene is grid positioned" {
    var engine = TextSurfacePreparer.init(std.testing.allocator);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black },
        .{ .codepoint = 'c', .fg = white, .bg = black },
        .{ .codepoint = 'd', .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 2, .rows = 2 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 4), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(i32, 0), analysis.scene.scene.sprite_draws[2].x_px);
    try std.testing.expectEqual(@as(i32, 1), analysis.scene.scene.sprite_draws[2].y_px);
}

test "text preparation rerasterizes pending atlas entries across prepares" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{.{ .codepoint = 'z', .fg = white, .bg = black }};
    var first = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    const first_slot = first.scene.scene.sprite_draws[0].sprite.slot;
    first.deinit();
    var second = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer second.deinit();
    try std.testing.expectEqual(first_slot, second.scene.scene.sprite_draws[0].sprite.slot);
    try std.testing.expectEqual(@as(u32, 1), count32(second.raster_plan.outputs));
    try std.testing.expectEqual(@as(u32, 1), engine.atlas.len);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.sprite_cache_hits);
    try std.testing.expect(!engine.atlas.get(.{ .value = second.scene.scene.sprite_draws[0].sprite.key.value }).?.rendered);
}

test "text preparation rerasterizes sprites after cell metrics change" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{.{ .codepoint = 0x2588, .fg = white, .bg = black }};
    var first = try engine.prepareCellsWithSessionOptions(
        &cells,
        .{ .cols = 1, .rows = 1 },
        .{ .primary_face = .{ .value = 1 }, .metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 } },
        .{},
    );
    const first_key = first.scene.scene.sprite_draws[0].sprite.key.value;
    first.deinit();
    var second = try engine.prepareCellsWithSessionOptions(
        &cells,
        .{ .cols = 1, .rows = 1 },
        .{ .primary_face = .{ .value = 1 }, .metrics = .{ .cell_w_px = 16, .cell_h_px = 32, .baseline_px = 24 } },
        .{},
    );
    defer second.deinit();
    try std.testing.expect(first_key != second.scene.scene.sprite_draws[0].sprite.key.value);
    try std.testing.expectEqual(@as(u32, 1), count32(second.raster_plan.outputs));
    try std.testing.expectEqual(@as(u16, 16), second.raster_plan.outputs[0].width_px);
    try std.testing.expectEqual(@as(u16, 32), second.raster_plan.outputs[0].height_px);
}

test "text preparation rerasterizes sprites after box thickness change" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{.{ .codepoint = 0x256d, .fg = white, .bg = black }};
    var first = try engine.prepareCellsWithSessionOptions(
        &cells,
        .{ .cols = 1, .rows = 1 },
        .{ .primary_face = .{ .value = 1 }, .metrics = .{ .cell_w_px = 18, .cell_h_px = 18, .baseline_px = 14, .box_thickness_px = 1 } },
        .{},
    );
    const first_key = first.scene.scene.sprite_draws[0].sprite.key.value;
    first.deinit();
    var second = try engine.prepareCellsWithSessionOptions(
        &cells,
        .{ .cols = 1, .rows = 1 },
        .{ .primary_face = .{ .value = 1 }, .metrics = .{ .cell_w_px = 18, .cell_h_px = 18, .baseline_px = 14, .box_thickness_px = 3 } },
        .{},
    );
    defer second.deinit();
    try std.testing.expect(first_key != second.scene.scene.sprite_draws[0].sprite.key.value);
    try std.testing.expectEqual(@as(u32, 1), count32(second.raster_plan.outputs));
}

test "text preparation accepts configurable shaper" {
    const Stub = struct {
        hits: u8 = 0,

        fn shape(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            run: contract.ResolvedRun,
            text_cache: contract.LineTextCache,
            clusters: []const contract.CellCluster,
            cell_metrics: contract.CellMetrics,
        ) anyerror!shape_run.OwnedShapedRun {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;
            return shape_run.shapeRun(allocator, run, text_cache, clusters, cell_metrics);
        }
    };

    var stub = Stub{};
    var engine = try TextSurfacePreparer.initWithShaper(std.testing.allocator, 8, .{ .ctx = &stub, .shape_run = Stub.shape });
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const combining = [_]u32{ 'q', 0x0332 };
    const inputs = [_]cluster.CellTextInput{.{ .codepoints = &combining, .fg = white, .bg = black }};
    var analysis = try engine.prepareCellTextInputsWithSessionOptions(&inputs, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();
    try std.testing.expectEqual(@as(u8, 1), stub.hits);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
}

test "text preparation accepts unified provider rasterizer" {
    const Stub = struct {
        hits: u8 = 0,

        fn raster(ctx: *anyopaque, allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) anyerror!rasterizer.RasterSpriteOutput {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;
            return rasterizer.placeholderRaster(allocator, req);
        }
    };
    var stub = Stub{};
    var engine = try TextSurfacePreparer.initWithProvider(std.testing.allocator, 8, .{ .rasterizer = .{ .ctx = &stub, .rasterize_sprite = Stub.raster } });
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{.{ .codepoint = 0x2500, .fg = white, .bg = black }};
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();
    try std.testing.expectEqual(@as(u8, 1), stub.hits);
}

test "text preparation options produce scene cursor draws" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{.{ .codepoint = 'c', .fg = white, .bg = black }};
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{
        .primary_face = .{ .value = 1 },
        .metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
    }, .{
        .scene = .{ .cursor = .{ .cell_col = 0, .cell_row = 0, .shape = .block, .color = white } },
    });
    defer analysis.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.cursor_draws));
    try std.testing.expectEqual(@as(u16, 8), analysis.scene.scene.cursor_draws[0].width_px);
}

test "text preparation partial damage clears use empty default background truth" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const transparent_bg = contract.Rgba8{ .r = 0x44, .g = 0x55, .b = 0x66, .a = 0 };
    const cells = [_]contract.CellInput{.{ .codepoint = ' ', .fg = white, .bg = transparent_bg, .empty = true }};
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{}, .{
        .scene = .{ .damage = .{ .full = false, .dirty_rows = &[_]bool{true}, .dirty_cols_start = &[_]u16{0}, .dirty_cols_end = &[_]u16{0} } },
    });
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.clear_draws));
    try std.testing.expectEqual(@as(u32, 0), count32(analysis.scene.scene.background_draws));
    try std.testing.expectEqual(@as(u32, 0), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(transparent_bg.r, analysis.scene.scene.clear_draws[0].color.r);
    try std.testing.expectEqual(transparent_bg.g, analysis.scene.scene.clear_draws[0].color.g);
    try std.testing.expectEqual(transparent_bg.b, analysis.scene.scene.clear_draws[0].color.b);
    try std.testing.expectEqual(@as(u8, 255), analysis.scene.scene.clear_draws[0].color.a);
}

test "text preparation publication clears use empty default background truth" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    var colors = std.mem.zeroes(source_vt.SourceColors);
    colors.background = .{ .r = 0x44, .g = 0x55, .b = 0x66 };
    var cells = [_]source_vt.SourceCell{.{
        .codepoint = ' ',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
        .link_id = 0,
    }};
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};
    const source = source_publication.PublicationSource{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = colors,
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
        .retained_storage = true,
    };

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 0), count32(analysis.scene.scene.clear_draws));
    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.background_draws));
    try std.testing.expectEqual(@as(u32, 0), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(colors.background.r, analysis.scene.scene.background_draws[0].color.r);
    try std.testing.expectEqual(colors.background.g, analysis.scene.scene.background_draws[0].color.g);
    try std.testing.expectEqual(colors.background.b, analysis.scene.scene.background_draws[0].color.b);
    try std.testing.expectEqual(@as(u8, 255), analysis.scene.scene.background_draws[0].color.a);
}

test "text preparation publication ascii stays on direct normal path" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    var cells = [_]source_vt.SourceCell{
        .{
            .codepoint = 'A',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 0, .value = 0 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
            .link_id = 0,
        },
        .{
            .codepoint = 'B',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 0, .value = 0 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
            .link_id = 0,
        },
    };
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{1};
    const source = source_publication.PublicationSource{
        .cols = 2,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = std.mem.zeroes(source_vt.SourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
        .retained_storage = true,
    };

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(source.colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 2), count32(analysis.raster_plan.outputs));
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.shaped_runs);
}

test "text preparation publication styled indexed ascii stays on direct normal path" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const colors = testPublicationColors();
    var cells = [_]source_vt.SourceCell{testPublicationCell('S')};
    cells[0].fg_color = .{ .kind = 1, .value = 2 };
    cells[0].bg_color = .{ .kind = 1, .value = 3 };
    cells[0].attrs = .{ .bold = 1, .dim = 1, .italic = 1, .underline = 1, .underline_color_set = 0, .blink = 1, .inverse = 1, .invisible = 0, .strikethrough = 0, .selected = 0 };
    const source = testOneRowPublicationSource(cells[0..], colors);

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.background_draws));
    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.decoration_draws));
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.shaped_runs);
    try std.testing.expectEqual(colors.palette[3].r, analysis.scene.scene.sprite_draws[0].color.r);
    try std.testing.expectEqual(colors.palette[3].g, analysis.scene.scene.sprite_draws[0].color.g);
    try std.testing.expectEqual(colors.palette[3].b, analysis.scene.scene.sprite_draws[0].color.b);
    try std.testing.expectEqual(@as(u8, 102), analysis.scene.scene.sprite_draws[0].color.a);
    try std.testing.expectEqual(colors.palette[2].r, analysis.scene.scene.background_draws[0].color.r);
    try std.testing.expectEqual(colors.palette[2].g, analysis.scene.scene.background_draws[0].color.g);
    try std.testing.expectEqual(colors.palette[2].b, analysis.scene.scene.background_draws[0].color.b);
}

test "text preparation publication non inverse indexed ascii stays on direct normal path" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const colors = testPublicationColors();
    var cells = [_]source_vt.SourceCell{testPublicationCell('N')};
    cells[0].fg_color = .{ .kind = 1, .value = 4 };
    cells[0].bg_color = .{ .kind = 1, .value = 5 };
    const source = testOneRowPublicationSource(cells[0..], colors);

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.background_draws));
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.shaped_runs);
    try std.testing.expectEqual(colors.palette[4].r, analysis.scene.scene.sprite_draws[0].color.r);
    try std.testing.expectEqual(colors.palette[4].g, analysis.scene.scene.sprite_draws[0].color.g);
    try std.testing.expectEqual(colors.palette[4].b, analysis.scene.scene.sprite_draws[0].color.b);
    try std.testing.expectEqual(colors.palette[5].r, analysis.scene.scene.background_draws[0].color.r);
    try std.testing.expectEqual(colors.palette[5].g, analysis.scene.scene.background_draws[0].color.g);
    try std.testing.expectEqual(colors.palette[5].b, analysis.scene.scene.background_draws[0].color.b);
}

test "text preparation publication zero codepoint stays on direct normal path without sprite draw" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const colors = testPublicationColors();
    var cells = [_]source_vt.SourceCell{testPublicationCell(0)};
    const source = testOneRowPublicationSource(cells[0..], colors);

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 0), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 0), count32(analysis.raster_plan.outputs));
    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.background_draws));
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.shaped_runs);
    try std.testing.expectEqual(colors.background.r, analysis.scene.scene.background_draws[0].color.r);
    try std.testing.expectEqual(colors.background.g, analysis.scene.scene.background_draws[0].color.g);
    try std.testing.expectEqual(colors.background.b, analysis.scene.scene.background_draws[0].color.b);
}

test "text preparation publication styled indexed zero codepoint stays on direct normal path" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const colors = testPublicationColors();
    var cells = [_]source_vt.SourceCell{testPublicationCell(0)};
    cells[0].fg_color = .{ .kind = 1, .value = 2 };
    cells[0].bg_color = .{ .kind = 1, .value = 3 };
    cells[0].attrs = .{ .bold = 1, .dim = 1, .italic = 1, .underline = 1, .underline_color_set = 0, .blink = 1, .inverse = 1, .invisible = 0, .strikethrough = 0, .selected = 0 };
    const source = testOneRowPublicationSource(cells[0..], colors);

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 0), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.background_draws));
    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.decoration_draws));
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.shaped_runs);
    try std.testing.expectEqual(colors.palette[2].r, analysis.scene.scene.background_draws[0].color.r);
    try std.testing.expectEqual(colors.palette[2].g, analysis.scene.scene.background_draws[0].color.g);
    try std.testing.expectEqual(colors.palette[2].b, analysis.scene.scene.background_draws[0].color.b);
    try std.testing.expectEqual(colors.palette[3].r, analysis.scene.scene.decoration_draws[0].color.r);
    try std.testing.expectEqual(colors.palette[3].g, analysis.scene.scene.decoration_draws[0].color.g);
    try std.testing.expectEqual(colors.palette[3].b, analysis.scene.scene.decoration_draws[0].color.b);
}

test "text preparation publication unsupported space and rgb keep fallback scratch clean" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const colors = testPublicationColors();
    var cells = [_]source_vt.SourceCell{ testPublicationCell(' '), testPublicationCell('R') };
    cells[1].fg_color = .{ .kind = 2, .value = 0x123456 };
    const source = testOneRowPublicationSource(cells[0..], colors);

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.shaped_runs);
    try std.testing.expectEqual(@as(u8, 0x12), analysis.scene.scene.sprite_draws[0].color.r);
    try std.testing.expectEqual(@as(u8, 0x34), analysis.scene.scene.sprite_draws[0].color.g);
    try std.testing.expectEqual(@as(u8, 0x56), analysis.scene.scene.sprite_draws[0].color.b);
}

test "text preparation publication tab stays on generic fallback without partial direct scratch" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const colors = testPublicationColors();
    var cells = [_]source_vt.SourceCell{ testPublicationCell('A'), testPublicationCell('\t') };
    const source = testOneRowPublicationSource(cells[0..], colors);

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 1), count32(analysis.raster_plan.outputs));
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.shaped_runs);
}

test "text preparation publication other control stays on generic fallback without partial direct scratch" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const colors = testPublicationColors();
    var cells = [_]source_vt.SourceCell{ testPublicationCell('A'), testPublicationCell(0x1f) };
    const source = testOneRowPublicationSource(cells[0..], colors);

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 2), count32(analysis.raster_plan.outputs));
    try std.testing.expectEqual(@as(u32, 0), count32(analysis.scene.scene.missing));
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.shaped_runs);
    try std.testing.expectEqual(@as(u32, 0), analysis.scene.scene.sprite_draws[0].first_cell);
    try std.testing.expectEqual(@as(u32, 1), analysis.scene.scene.sprite_draws[1].first_cell);
}

test "text preparation publication unsupported curly falls back without partial direct scratch" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const colors = testPublicationColors();
    var cells = [_]source_vt.SourceCell{ testPublicationCell('A'), testPublicationCell('C') };
    cells[1].attrs.underline = 1;
    cells[1].underline_style = 2;
    const source = testOneRowPublicationSource(cells[0..], colors);

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(colors))).?;
    defer analysis.deinit();

    try std.testing.expect(count32(analysis.scene.scene.sprite_draws) >= 2);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.glyph_groups);
}

test "text preparation publication unsupported combining falls back without partial direct scratch" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const colors = testPublicationColors();
    var cells = [_]source_vt.SourceCell{ testPublicationCell('A'), testPublicationCell('M') };
    cells[1].combining_len = 1;
    cells[1].combining = .{ 0x0332, 0, 0 };
    const source = testOneRowPublicationSource(cells[0..], colors);

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.glyph_groups);
}

test "text preparation publication unsupported link reaches generic path without partial scratch" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const colors = testPublicationColors();
    var cells = [_]source_vt.SourceCell{testPublicationCell('L')};
    cells[0].link_id = 9;
    const source = testOneRowPublicationSource(cells[0..], colors);

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 1), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.shaped_runs);
}

test "text preparation direct-renders pure normal cell text inputs" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const a = [_]u32{'a'};
    const b = [_]u32{'b'};
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &a, .fg = white, .bg = black },
        .{ .codepoints = &b, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellTextInputsWithSessionOptions(&inputs, .{ .cols = 2, .rows = 1 }, .{}, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 2), count32(analysis.raster_plan.outputs));
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.shaped_runs);
}

test "text preparation keeps mixed cell text normals out of legacy path" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const a = [_]u32{'a'};
    const combining = [_]u32{ 'i', 0x0332 };
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &a, .fg = white, .bg = black },
        .{ .codepoints = &combining, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellTextInputsWithSessionOptions(&inputs, .{ .cols = 2, .rows = 1 }, .{}, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
}

test "text preparation marks curly underline cells complex before shaping" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black, .underline = true, .underline_style = .curly },
    };
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 3), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 0), count32(analysis.scene.scene.decoration_draws));
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.glyph_groups);
}

test "text preparation sizes cluster scratch for multi codepoint cell inputs" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'x', .combining_len = 3, .combining = .{ 0x0305, 0x030D, 0x030E }, .fg = white, .bg = black },
        .{ .codepoint = 'y', .combining_len = 3, .combining = .{ 0x0310, 0x0312, 0x033D }, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expect(count32(analysis.scene.scene.sprite_draws) != 0);
}

test "text preparation keeps icon codepoints out of the normal lane" {
    const Stub = struct {
        fn shape(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            run: contract.ResolvedRun,
            text_cache: contract.LineTextCache,
            clusters: []const contract.CellCluster,
            cell_metrics: contract.CellMetrics,
        ) anyerror!shape_run.OwnedShapedRun {
            _ = text_cache;
            _ = cell_metrics;
            std.debug.assert(clusters.len >= 1);
            const glyphs = try allocator.alloc(contract.GlyphInstance, 1);
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
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const icon = [_]u32{0xf101};
    const blank = [_]u32{' '};
    const ascii = [_]u32{'a'};
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &icon, .fg = white, .bg = black },
        .{ .codepoints = &blank, .fg = white, .bg = black },
        .{ .codepoints = &ascii, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellTextInputsWithSessionOptions(&inputs, .{ .cols = 3, .rows = 1 }, .{ .metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u16, 16), analysis.scene.scene.sprite_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 2), analysis.scene.scene.sprite_draws[0].cell_span);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.glyph_groups);
}

test "text preparation prepares publication cells through shared full pipeline surface" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    var cells = [_]source_vt.SourceCell{
        .{
            .codepoint = 'A',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 0, .value = 0 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
            .link_id = 0,
        },
        .{
            .codepoint = 0x2716,
            .combining_len = 1,
            .combining = .{ 0xFE0F, 0, 0 },
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 0, .value = 0 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
            .link_id = 0,
        },
    };
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{1};
    const source = source_publication.PublicationSource{
        .cols = 2,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = std.mem.zeroes(source_vt.SourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
        .retained_storage = true,
    };

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(source.colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 2), count32(analysis.raster_plan.outputs));
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.missing_glyphs);
}

test "text preparation publication complex rejection falls back once" {
    var engine = try TextSurfacePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    var cells = [_]source_vt.SourceCell{
        .{
            .codepoint = 'A',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 0, .value = 0 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
            .link_id = 0,
        },
        .{
            .codepoint = 0x2716,
            .combining_len = 1,
            .combining = .{ 0xFE0F, 0, 0 },
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 0, .value = 0 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
            .link_id = 0,
        },
    };
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{1};
    const source = source_publication.PublicationSource{
        .cols = 2,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = std.mem.zeroes(source_vt.SourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
        .retained_storage = true,
    };

    var analysis = (try engine.preparePublicationWithSessionOptions(source, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{}, source_theme.themeFromPublicationColors(source.colors))).?;
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(analysis.scene.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 2), count32(analysis.raster_plan.outputs));
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
            run: contract.ResolvedRun,
            text_cache: contract.LineTextCache,
            clusters: []const contract.CellCluster,
            cell_metrics: contract.CellMetrics,
        ) anyerror!shape_run.OwnedShapedRun {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.last_face_id = run.run.font.face_id.value;
            return self.inner.shapeRun(allocator, run, text_cache, clusters, cell_metrics);
        }
    };

    const Backend = struct {
        fn has(ctx: *anyopaque, face_id: contract.FontFaceId, cp: u32) bool {
            _ = ctx;
            if (face_id.value == 1) return cp >= 'a' and cp <= 'z';
            return true;
        }
    };
    var dummy: u8 = 0;
    var ft_hb = ft_hb_provider.FtHbSource{ .ctx = &dummy, .has_codepoint = Backend.has };
    var text_provider = ft_hb.textProvider();
    var shaper = FallbackShaper{ .inner = text_provider.shaper };
    text_provider.shaper = .{ .ctx = &shaper, .shape_run = FallbackShaper.shape };
    var engine = try TextSurfacePreparer.initWithProvider(std.testing.allocator, 16, text_provider);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const combining = [_]u32{ 'i', 0x0332 };
    const inputs = [_]cluster.CellTextInput{.{ .codepoints = &combining, .fg = white, .bg = black }};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    var analysis = try engine.prepareCellTextInputsWithSessionOptions(&inputs, .{ .cols = 1, .rows = 1 }, ft_hb.textProvider().applyToSession(.{ .faces = &faces }), .{});
    defer analysis.deinit();
    try std.testing.expectEqual(@as(u32, 2), shaper.last_face_id);
}
