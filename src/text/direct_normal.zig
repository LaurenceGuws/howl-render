const std = @import("std");
const atlas_cache = @import("raster/cache.zig");
const cluster = @import("shape/cluster.zig");
const contract = @import("contract.zig");
const direct_scene = @import("direct_scene.zig");
const font_session = @import("font/session.zig");
const lane = @import("classify/lane.zig");
const prepare_counters = @import("prepare_counters.zig");
const provider = @import("font/provider.zig");
const raster_operation = @import("raster/operation.zig");
const rasterizer = @import("raster/rasterizer.zig");
const scene = @import("scene.zig");
const sprite_key = @import("raster/key.zig");
const source_vt = @import("../source/vt.zig");
const publication_cell_map = @import("../source/publication_cell_map.zig");

pub const Product = struct {
    damage: direct_scene.Damage,
    outputs: []rasterizer.RasterSpriteOutput = &.{},
    outputs_owned: bool = false,
    timings: Timings = .{},

    pub fn deinit(self: *Product, allocator: std.mem.Allocator) void {
        if (!self.outputs_owned) return;
        for (self.outputs) |*out| out.deinit();
        allocator.free(self.outputs);
        self.outputs = &.{};
        self.outputs_owned = false;
    }
};

pub const Timings = struct {
    scan_us: u64 = 0,
    backgrounds_us: u64 = 0,
    clears_us: u64 = 0,
    decorations_us: u64 = 0,
    cursor_us: u64 = 0,
    raster_us: u64 = 0,
};

pub const Policy = enum {
    require_all_normal,
    skip_complex,
};

pub const Source = union(enum) {
    raw_cells: []const contract.CellInput,
    publication: struct {
        cells: []const source_vt.SourceCell,
        theme: publication_cell_map.FrameTheme,
    },
    inputs: []const cluster.CellTextInput,
    prepared: struct {
        cells: []const contract.RenderableCell,
        text_cache: contract.LineTextCache,
    },
};

pub const Scratch = struct {
    renderable: std.ArrayListUnmanaged(contract.RenderableCell) = .{ .items = &.{}, .capacity = 0 },
    missing: std.ArrayListUnmanaged(contract.MissingGlyph) = .{ .items = &.{}, .capacity = 0 },
    sprite_draws: std.ArrayListUnmanaged(contract.TextSpriteDraw) = .{ .items = &.{}, .capacity = 0 },
    background_draws: std.ArrayListUnmanaged(contract.TextBackgroundDraw) = .{ .items = &.{}, .capacity = 0 },
    clear_draws: std.ArrayListUnmanaged(contract.TextClearDraw) = .{ .items = &.{}, .capacity = 0 },
    decoration_draws: std.ArrayListUnmanaged(contract.TextDecorationDraw) = .{ .items = &.{}, .capacity = 0 },
    cursor_draws: std.ArrayListUnmanaged(contract.TextCursorDraw) = .{ .items = &.{}, .capacity = 0 },
    raster_reqs: std.ArrayListUnmanaged(raster_operation.RasterizeRequest) = .{ .items = &.{}, .capacity = 0 },

    pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        self.raster_reqs.deinit(allocator);
        self.cursor_draws.deinit(allocator);
        self.decoration_draws.deinit(allocator);
        self.clear_draws.deinit(allocator);
        self.background_draws.deinit(allocator);
        self.sprite_draws.deinit(allocator);
        self.missing.deinit(allocator);
        self.renderable.deinit(allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Scratch, allocator: std.mem.Allocator, visible_count: u32, cell_count: u32, rows: u16) !void {
        std.debug.assert(cell_count >= visible_count);
        try self.renderable.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.missing.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.sprite_draws.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.background_draws.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.clear_draws.ensureTotalCapacity(allocator, @intCast(rows));
        try self.decoration_draws.ensureTotalCapacity(allocator, @intCast(cell_count * 2));
        try self.cursor_draws.ensureTotalCapacity(allocator, 4);
        try self.raster_reqs.ensureTotalCapacity(allocator, @intCast(cell_count));
        self.renderable.clearRetainingCapacity();
        self.missing.clearRetainingCapacity();
        self.sprite_draws.clearRetainingCapacity();
        self.background_draws.clearRetainingCapacity();
        self.clear_draws.clearRetainingCapacity();
        self.decoration_draws.clearRetainingCapacity();
        self.cursor_draws.clearRetainingCapacity();
        self.raster_reqs.clearRetainingCapacity();
    }
};

pub const Driver = struct {
    allocator: std.mem.Allocator,
    atlas: *atlas_cache.OwnedAtlasCache,
    glyph_lookup: provider.LookupGlyphOp,
    glyph_raster: raster_operation.RasterizeGlyphOp,
    scratch: *Scratch,
};

pub fn prepare(
    driver: Driver,
    source: Source,
    policy: Policy,
    grid_metrics: contract.GridMetrics,
    session: font_session.FontSession,
    damage_input: scene.DamageInput,
    cursor: ?scene.CursorInput,
    lane_report: *lane.LaneReport,
) !?Product {
    var timings = Timings{};
    const damage = direct_scene.Damage.init(damage_input, grid_metrics.rows);
    const source_len = sourceLen(source);
    try driver.scratch.reset(driver.allocator, source_len, source_len, grid_metrics.rows);
    const scan_start_ns = monotonicNs();
    if (!try appendVisible(driver, source, damage, grid_metrics, session, policy, lane_report)) return null;
    timings.scan_us = elapsedUs(scan_start_ns);
    const backgrounds_start_ns = monotonicNs();
    direct_scene.appendBackgrounds(&driver.scratch.background_draws, driver.scratch.renderable.items, session.metrics, grid_metrics, damage);
    timings.backgrounds_us = elapsedUs(backgrounds_start_ns);
    const clears_start_ns = monotonicNs();
    direct_scene.appendClears(&driver.scratch.clear_draws, driver.scratch.renderable.items, session.metrics, grid_metrics, damage);
    timings.clears_us = elapsedUs(clears_start_ns);
    const decorations_start_ns = monotonicNs();
    direct_scene.appendDecorations(&driver.scratch.decoration_draws, driver.scratch.renderable.items, session.metrics, grid_metrics, damage);
    timings.decorations_us = elapsedUs(decorations_start_ns);
    const cursor_start_ns = monotonicNs();
    direct_scene.appendCursor(&driver.scratch.cursor_draws, cursor, session.metrics, damage);
    timings.cursor_us = elapsedUs(cursor_start_ns);
    return try finishScene(driver, damage, lane_report, timings);
}

pub fn counters(scratch: *const Scratch, lane_report: lane.LaneReport, direct: Product) prepare_counters.TextPrepareCounters {
    return .{
        .cell_texts = lane_report.visible_cells,
        .clusters = lane_report.normal_clusters,
        .sprite_cache_hits = @intCast(scratch.sprite_draws.items.len - scratch.raster_reqs.items.len),
        .sprite_cache_misses = @intCast(scratch.raster_reqs.items.len),
        .rasterized_sprites = @intCast(direct.outputs.len),
        .missing_glyphs = @intCast(scratch.missing.items.len),
    };
}

const Decision = enum { include, skip, reject };

const actions = [2][6]Decision{
    .{ .include, .reject, .reject, .reject, .reject, .reject },
    .{ .include, .skip, .skip, .skip, .skip, .skip },
};

const Candidate = struct {
    item: cluster.RenderableText,
    choice: lane.LaneClass,
};

fn appendVisible(
    driver: Driver,
    source: Source,
    damage: direct_scene.Damage,
    grid_metrics: contract.GridMetrics,
    session: font_session.FontSession,
    policy: Policy,
    lane_report: *lane.LaneReport,
) !bool {
    if (policy == .require_all_normal) {
        var preflight_idx: u32 = 0;
        while (preflight_idx < sourceLen(source)) : (preflight_idx += 1) {
            const candidate = sourceCandidate(source, preflight_idx, damage, grid_metrics) orelse continue;
            if (candidate.choice.renderableClass() != .normal) {
                assertNoPartialDrawState(driver.scratch);
                return false;
            }
        }
    }

    var idx: u32 = 0;
    while (idx < sourceLen(source)) : (idx += 1) {
        const candidate = sourceCandidate(source, idx, damage, grid_metrics) orelse continue;
        switch (candidateDecision(policy, lane_report, candidate)) {
            .include => try appendRenderable(driver, candidate.item.renderable, candidate.item.text, grid_metrics, session, lane_report),
            .skip => continue,
            .reject => return false,
        }
    }
    return true;
}

fn candidateDecision(policy: Policy, lane_report: *lane.LaneReport, candidate: Candidate) Decision {
    const class = candidate.choice.renderableClass();
    const action = actions[@intFromEnum(policy)][@intFromEnum(class)];
    if (action == .include and policy == .require_all_normal) recordLane(lane_report, candidate.item.text);
    return action;
}

fn sourceCandidate(source: Source, idx: u32, damage: direct_scene.Damage, grid_metrics: contract.GridMetrics) ?Candidate {
    const item = sourceItem(source, idx) orelse return null;
    if (!cluster.includeDamage(grid_metrics, damageInput(damage), item.renderable)) return null;
    return .{ .item = item, .choice = lane.classifyRenderableCell(item.renderable, item.text) };
}

fn sourceLen(source: Source) u32 {
    return switch (source) {
        .raw_cells => |cells| @intCast(cells.len),
        .publication => |publication| @intCast(publication.cells.len),
        .inputs => |inputs| @intCast(inputs.len),
        .prepared => |prepared| @intCast(prepared.cells.len),
    };
}

fn sourceItem(source: Source, idx: u32) ?cluster.RenderableText {
    return switch (source) {
        .raw_cells => |cells| cluster.sourceRenderableTextFromCells(cells, idx),
        .publication => |publication| cluster.sourceRenderableTextFromPublication(publication.cells, publication.theme, idx),
        .inputs => |inputs| cluster.sourceRenderableTextFromInputs(inputs, idx),
        .prepared => |prepared| cluster.sourceRenderableTextFromPrepared(prepared.cells, prepared.text_cache, idx),
    };
}

fn damageInput(damage: direct_scene.Damage) scene.DamageInput {
    return .{
        .full = damage.full,
        .dirty_rows = damage.dirty_rows,
        .dirty_cols_start = damage.dirty_cols_start,
        .dirty_cols_end = damage.dirty_cols_end,
    };
}

fn recordLane(lane_report: *lane.LaneReport, text: contract.CellText) void {
    lane_report.visible_cells += 1;
    lane_report.normal_cells += 1;
    if (!blankText(text)) lane_report.normal_clusters += 1;
}

fn appendRenderable(
    driver: Driver,
    renderable: contract.RenderableCell,
    text: contract.CellText,
    grid_metrics: contract.GridMetrics,
    session: font_session.FontSession,
    lane_report: *lane.LaneReport,
) !void {
    driver.scratch.renderable.appendAssumeCapacity(renderable);
    if (text.first_cp == 0 or text.first_cp == '\t') return;

    const face = resolveFace(session, renderable, text) orelse {
        driver.scratch.missing.appendAssumeCapacity(.{ .codepoint = text.first_cp, .style = renderable.style, .presentation = renderable.presentation, .reason = .no_fallback_face });
        return;
    };

    const lookup = driver.glyph_lookup.lookupGlyph(face.id, text.first_cp, session.metrics);
    const span = @max(renderable.cell_span, 1);
    const key = sprite_key.hashGlyphLocal(face.id, lookup.glyph_id, span, session.metrics);
    const residency = driver.atlas.reserve(key, false);
    if (residency.pending) {
        driver.scratch.raster_reqs.appendAssumeCapacity(.{
            .face_id = face.id.value,
            .glyph_id = lookup.glyph_id,
            .atlas_key = key.value,
            .cell_metrics = session.metrics,
            .cell_span = span,
        });
    }

    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const col = renderable.first_cell % cols;
    const row = renderable.first_cell / cols;
    driver.scratch.sprite_draws.appendAssumeCapacity(.{
        .sprite = residency.position,
        .x_px = @as(i32, @intCast(col * @as(u32, session.metrics.cell_w_px))),
        .y_px = @as(i32, @intCast(row * @as(u32, session.metrics.cell_h_px))),
        .width_px = @intCast(@as(u32, span) * @as(u32, session.metrics.cell_w_px)),
        .height_px = session.metrics.cell_h_px,
        .placement = .{ .advance_px = @max(lookup.advance_px, @as(f32, @floatFromInt(@as(u32, span) * @as(u32, session.metrics.cell_w_px)))) },
        .color = renderable.fg,
        .first_cell = renderable.first_cell,
        .cell_span = span,
    });
    lane_report.direct_normal_draws += 1;
}

fn assertNoPartialDrawState(scratch: *const Scratch) void {
    std.debug.assert(scratch.renderable.items.len == 0);
    std.debug.assert(scratch.missing.items.len == 0);
    std.debug.assert(scratch.sprite_draws.items.len == 0);
    std.debug.assert(scratch.background_draws.items.len == 0);
    std.debug.assert(scratch.clear_draws.items.len == 0);
    std.debug.assert(scratch.decoration_draws.items.len == 0);
    std.debug.assert(scratch.cursor_draws.items.len == 0);
    std.debug.assert(scratch.raster_reqs.items.len == 0);
}

fn finishScene(driver: Driver, damage: direct_scene.Damage, lane_report: *lane.LaneReport, timings: Timings) !Product {
    var outputs: []rasterizer.RasterSpriteOutput = &.{};
    var outputs_owned = false;
    var final_timings = timings;
    if (driver.scratch.raster_reqs.items.len > 0) {
        lane_report.direct_normal_raster_misses = @intCast(driver.scratch.raster_reqs.items.len);
        const raster_start_ns = monotonicNs();
        outputs = try driver.allocator.alloc(rasterizer.RasterSpriteOutput, driver.scratch.raster_reqs.items.len);
        outputs_owned = true;
        var filled: u32 = 0;
        errdefer {
            for (outputs[0..@intCast(filled)]) |*out| out.deinit();
            driver.allocator.free(outputs);
        }
        for (driver.scratch.raster_reqs.items, 0..) |req, idx| {
            var raster = try driver.glyph_raster.rasterize(driver.allocator, req);
            outputs[idx] = .{ .allocator = raster.allocator, .key = .{ .value = req.atlas_key }, .width_px = raster.width_px, .height_px = raster.height_px, .pixels = raster.alpha_mask };
            raster.alpha_mask = &.{};
            filled += 1;
        }
        final_timings.raster_us = elapsedUs(raster_start_ns);
    }
    return .{ .damage = damage, .outputs = outputs, .outputs_owned = outputs_owned, .timings = final_timings };
}

fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedUs(start_ns: u64) u64 {
    return @divTrunc(monotonicNs() -| start_ns, std.time.ns_per_us);
}

fn resolveFace(session: font_session.FontSession, cell: contract.RenderableCell, text: contract.CellText) ?font_session.FontFaceRecord {
    if (isPlainAsciiText(text)) return session.primary();
    return session.findStyle(cell.style, cell.presentation, text) orelse session.findFallback(cell.style, cell.presentation, text);
}

fn isPlainAsciiText(text: contract.CellText) bool {
    const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
    for (cps) |cp| {
        if (cp == ' ' or cp == '\t') continue;
        if (cp < 0x20 or cp >= 0x7f) return false;
    }
    return true;
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

fn blankText(text: contract.CellText) bool {
    for (text.codepoints) |cp| {
        if (cp != 0 and cp != ' ') return false;
    }
    return true;
}
