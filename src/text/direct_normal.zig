const std = @import("std");
const atlas_cache = @import("raster/atlas.zig");
const cluster = @import("shape/cluster.zig");
const render = @import("../libhowl_render.zig");
const direct_scene = @import("../grid/direct.zig");
const font_session = @import("../session/session.zig");
const lane = @import("lane.zig");
const prepare_counters = @import("prepare_counters.zig");
const provider = @import("provider.zig");
const raster_operation = @import("raster/operation.zig");
const rasterizer = @import("raster/rasterizer.zig");
const scene = @import("../scene.zig");
const scene_damage = @import("../grid/damage.zig");
const scene_rects = @import("../grid/rects.zig");
const sprite_key = @import("raster/key.zig");

const RenderableCell = render.RenderableCell;
const CellText = render.CellText;
const FontSession = font_session.FontSession;
const FontFaceRecord = font_session.FontFaceRecord;
const LookupGlyphResult = provider.LookupGlyphResult;

pub const Product = struct {
    damage: direct_scene.Damage,
    outputs: []rasterizer.RasterSpriteOutput = &.{},
    outputs_owned: bool = false,

    pub fn deinit(self: *Product, allocator: std.mem.Allocator) void {
        if (!self.outputs_owned) return;
        for (self.outputs) |*out| out.deinit();
        allocator.free(self.outputs);
        self.outputs = &.{};
        self.outputs_owned = false;
    }
};

pub const Policy = enum {
    require_all_normal,
    skip_complex,
};

pub const Source = union(enum) {
    raw_cells: []const render.CellInput,
    inputs: []const cluster.CellTextInput,
    prepared: struct {
        cells: []const render.RenderableCell,
        text_cache: render.LineTextCache,
    },
};

pub const Scratch = struct {
    missing: std.ArrayListUnmanaged(render.MissingGlyph) = .{ .items = &.{}, .capacity = 0 },
    sprite_draws: std.ArrayListUnmanaged(render.TextSpriteDraw) = .{ .items = &.{}, .capacity = 0 },
    background_draws: std.ArrayListUnmanaged(render.TextBackgroundDraw) = .{ .items = &.{}, .capacity = 0 },
    clear_draws: std.ArrayListUnmanaged(render.TextClearDraw) = .{ .items = &.{}, .capacity = 0 },
    decoration_draws: std.ArrayListUnmanaged(render.TextDecorationDraw) = .{ .items = &.{}, .capacity = 0 },
    cursor_draws: std.ArrayListUnmanaged(render.TextCursorDraw) = .{ .items = &.{}, .capacity = 0 },
    raster_reqs: std.ArrayListUnmanaged(raster_operation.RasterizeRequest) = .{ .items = &.{}, .capacity = 0 },
    clear_row_colors: std.ArrayListUnmanaged(render.Rgba8) = .{ .items = &.{}, .capacity = 0 },
    clear_row_matches: std.ArrayListUnmanaged(bool) = .{ .items = &.{}, .capacity = 0 },
    background_merge_live: bool = false,
    background_merge_end_cell: u32 = 0,

    pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        self.clear_row_matches.deinit(allocator);
        self.clear_row_colors.deinit(allocator);
        self.raster_reqs.deinit(allocator);
        self.cursor_draws.deinit(allocator);
        self.decoration_draws.deinit(allocator);
        self.clear_draws.deinit(allocator);
        self.background_draws.deinit(allocator);
        self.sprite_draws.deinit(allocator);
        self.missing.deinit(allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Scratch, allocator: std.mem.Allocator, visible_count: u32, cell_count: u32, rows: u16) !void {
        std.debug.assert(cell_count >= visible_count);
        try self.missing.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.sprite_draws.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.background_draws.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.clear_draws.ensureTotalCapacity(allocator, @intCast(rows));
        try self.decoration_draws.ensureTotalCapacity(allocator, @intCast(cell_count * 2));
        try self.cursor_draws.ensureTotalCapacity(allocator, 4);
        try self.raster_reqs.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.clear_row_colors.ensureTotalCapacity(allocator, @intCast(rows));
        try self.clear_row_matches.ensureTotalCapacity(allocator, @intCast(rows));
        self.missing.clearRetainingCapacity();
        self.sprite_draws.clearRetainingCapacity();
        self.background_draws.clearRetainingCapacity();
        self.clear_draws.clearRetainingCapacity();
        self.decoration_draws.clearRetainingCapacity();
        self.cursor_draws.clearRetainingCapacity();
        self.raster_reqs.clearRetainingCapacity();
        self.clear_row_colors.items.len = rows;
        self.clear_row_matches.items.len = rows;
        for (self.clear_row_colors.items) |*color| color.* = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
        @memset(self.clear_row_matches.items, false);
        self.background_merge_live = false;
        self.background_merge_end_cell = 0;
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
    grid_metrics: render.GridMetrics,
    session: font_session.FontSession,
    damage_input: scene_damage.DamageInput,
    cursor: ?render.CursorPresentation,
    lane_report: *lane.LaneReport,
    rejected_complex_cells_out: ?*u64,
) !?Product {
    const damage = direct_scene.Damage.init(damage_input, grid_metrics.rows);
    const decoration_layout = scene_rects.rectDecorationLayout(session.metrics, grid_metrics);
    const source_len = sourceLen(source);
    var rejected_complex_cells: u64 = 0;
    try driver.scratch.reset(driver.allocator, source_len, source_len, grid_metrics.rows);
    const appended_visible = try appendVisible(driver, source, damage, grid_metrics, decoration_layout, session, policy, lane_report, &rejected_complex_cells);
    if (!appended_visible) {
        std.debug.assert(policy == .require_all_normal);
        std.debug.assert(rejected_complex_cells != 0);
        if (rejected_complex_cells_out) |out| out.* = rejected_complex_cells;
        assertNoPartialDrawState(driver.scratch);
        lane_report.assertValid();
        return null;
    }
    std.debug.assert(rejected_complex_cells == 0);
    if (rejected_complex_cells_out) |out| out.* = 0;
    direct_scene.appendClears(
        &driver.scratch.clear_draws,
        driver.scratch.clear_row_colors.items,
        driver.scratch.clear_row_matches.items,
        session.metrics,
        grid_metrics,
        damage,
    );
    direct_scene.appendCursor(&driver.scratch.cursor_draws, cursor, session.metrics, damage);
    const product = try finishScene(driver, damage, lane_report);
    return product;
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

const ScratchCheckpoint = struct {
    missing_len: usize,
    sprite_draws_len: usize,
    background_draws_len: usize,
    clear_draws_len: usize,
    decoration_draws_len: usize,
    cursor_draws_len: usize,
    raster_reqs_len: usize,
};

fn appendVisible(
    driver: Driver,
    source: Source,
    damage: direct_scene.Damage,
    grid_metrics: render.GridMetrics,
    decoration_layout: scene_rects.RectDecorationLayout,
    session: font_session.FontSession,
    policy: Policy,
    lane_report: *lane.LaneReport,
    rejected_complex_cells: *u64,
) !bool {
    rejected_complex_cells.* = 0;
    const lane_report_start = lane_report.*;
    const scratch_start = checkpointScratch(driver.scratch);
    var rejecting = false;

    var idx: u32 = 0;
    while (idx < sourceLen(source)) : (idx += 1) {
        const candidate = sourceCandidate(source, idx, damage, grid_metrics);
        const candidate_value = candidate orelse continue;
        if (rejecting) {
            if (candidate_value.choice.renderableClass() != .normal) rejected_complex_cells.* += 1;
            continue;
        }
        switch (candidateDecision(policy, lane_report, candidate_value)) {
            .include => {
                try appendRenderable(driver, candidate_value.item.renderable, candidate_value.item.text, damage, grid_metrics, decoration_layout, session, lane_report);
            },
            .skip => continue,
            .reject => {
                std.debug.assert(policy == .require_all_normal);
                rejected_complex_cells.* = 1;
                lane_report.* = lane_report_start;
                restoreScratch(driver.scratch, scratch_start);
                std.debug.assert(scratchEmpty(driver.scratch));
                lane_report.assertValid();
                rejecting = true;
            },
        }
    }
    if (rejecting) {
        std.debug.assert(rejected_complex_cells.* != 0);
        std.debug.assert(scratchEmpty(driver.scratch));
        lane_report.assertValid();
        return false;
    }
    std.debug.assert(rejected_complex_cells.* == 0);
    lane_report.assertValid();
    return true;
}

fn candidateDecision(policy: Policy, lane_report: *lane.LaneReport, candidate: Candidate) Decision {
    const class = candidate.choice.renderableClass();
    const action = actions[@intFromEnum(policy)][@intFromEnum(class)];
    if (action == .include and policy == .require_all_normal) recordLane(lane_report, candidate.item.text);
    return action;
}

fn sourceCandidate(source: Source, idx: u32, damage: direct_scene.Damage, grid_metrics: render.GridMetrics) ?Candidate {
    const item = sourceItem(source, idx) orelse return null;
    if (!cluster.includeDamage(grid_metrics, damageInput(damage), item.renderable)) return null;
    return .{ .item = item, .choice = lane.classifyRenderableCell(item.renderable, item.text) };
}

fn sourceLen(source: Source) u32 {
    return switch (source) {
        .raw_cells => |cells| @intCast(cells.len),
        .inputs => |inputs| @intCast(inputs.len),
        .prepared => |prepared| @intCast(prepared.cells.len),
    };
}

fn sourceItem(source: Source, idx: u32) ?cluster.RenderableText {
    return switch (source) {
        .raw_cells => |cells| cluster.sourceRenderableTextFromCells(cells, idx),
        .inputs => |inputs| cluster.sourceRenderableTextFromInputs(inputs, idx),
        .prepared => |prepared| cluster.sourceRenderableTextFromPrepared(prepared.cells, prepared.text_cache, idx),
    };
}

fn damageInput(damage: direct_scene.Damage) scene_damage.DamageInput {
    return .{
        .full = damage.full,
        .dirty_rows = damage.dirty_rows,
        .dirty_cols_start = damage.dirty_cols_start,
        .dirty_cols_end = damage.dirty_cols_end,
    };
}

fn recordLane(lane_report: *lane.LaneReport, text: render.CellText) void {
    lane_report.visible_cells += 1;
    lane_report.normal_cells += 1;
    if (!blankText(text)) lane_report.normal_clusters += 1;
}

fn appendRenderable(
    driver: Driver,
    renderable: render.RenderableCell,
    text: render.CellText,
    damage: direct_scene.Damage,
    grid_metrics: render.GridMetrics,
    decoration_layout: scene_rects.RectDecorationLayout,
    session: font_session.FontSession,
    lane_report: *lane.LaneReport,
) !void {
    direct_scene.appendRenderableRects(
        &driver.scratch.background_draws,
        &driver.scratch.background_merge_live,
        &driver.scratch.background_merge_end_cell,
        driver.scratch.clear_row_colors.items,
        driver.scratch.clear_row_matches.items,
        &driver.scratch.decoration_draws,
        renderable,
        session.metrics,
        grid_metrics,
        decoration_layout,
        damage,
    );

    try renderableAppend(driver, renderable, text, grid_metrics, session, lane_report);
}

fn renderableAppend(
    driver: Driver,
    renderable: render.RenderableCell,
    text: render.CellText,
    grid_metrics: render.GridMetrics,
    session: font_session.FontSession,
    lane_report: *lane.LaneReport,
) !void {
    if (blankFastReturn(driver, text)) return;

    const face = resolveFaceOrAppendMissing(driver, renderable, text, session) orelse return;
    appendResolvedGlyph(driver, renderable, text, grid_metrics, session, lane_report, face);
}

fn resolveFaceOrAppendMissing(driver: Driver, renderable: render.RenderableCell, text: render.CellText, session: font_session.FontSession) ?font_session.FontFaceRecord {
    const face = resolveFace(session, renderable, text) orelse {
        driver.scratch.missing.appendAssumeCapacity(.{ .codepoint = text.first_cp, .style = renderable.style, .presentation = renderable.presentation, .reason = .no_fallback_face });
        return null;
    };
    return face;
}

const ResolvedGlyphKey = struct {
    lookup: provider.LookupGlyphResult,
    span: u8,
    key: render.SpriteKey,
};

fn appendResolvedGlyph(
    driver: Driver,
    renderable: render.RenderableCell,
    text: render.CellText,
    grid_metrics: render.GridMetrics,
    session: font_session.FontSession,
    lane_report: *lane.LaneReport,
    face: font_session.FontFaceRecord,
) void {
    const lookup = lookupGlyph(driver, text, session, face);
    const resolved = deriveResolvedGlyphKey(renderable, session, face, lookup);
    const residency = reserveAtlasOrAppendPendingRaster(driver, session, face, resolved);
    spriteAppend(driver, renderable, grid_metrics, session, lane_report, resolved.lookup, residency, resolved.span);
}

fn lookupGlyph(driver: Driver, text: CellText, session: FontSession, face: FontFaceRecord) LookupGlyphResult {
    return driver.glyph_lookup.lookupGlyph(face.id, text.first_cp, session.metrics);
}

fn deriveResolvedGlyphKey(renderable: RenderableCell, session: FontSession, face: FontFaceRecord, lookup: LookupGlyphResult) ResolvedGlyphKey {
    const span = @max(renderable.cell_span, 1);
    const key = sprite_key.hashGlyphLocal(face.id, lookup.glyph_id, span, session.metrics);
    return .{ .lookup = lookup, .span = span, .key = key };
}

fn reserveAtlasOrAppendPendingRaster(driver: Driver, session: font_session.FontSession, face: font_session.FontFaceRecord, resolved: ResolvedGlyphKey) atlas_cache.ReserveResult {
    const residency = driver.atlas.reserve(resolved.key, false);
    if (residency.pending) {
        driver.scratch.raster_reqs.appendAssumeCapacity(.{
            .face_id = face.id.value,
            .glyph_id = resolved.lookup.glyph_id,
            .atlas_key = resolved.key.value,
            .cell_metrics = session.metrics,
            .cell_span = resolved.span,
        });
    }
    return residency;
}

fn blankFastReturn(driver: Driver, text: render.CellText) bool {
    const sprite_draw_count = driver.scratch.sprite_draws.items.len;
    if (text.first_cp == 0 or text.first_cp == '\t') {
        std.debug.assert(driver.scratch.sprite_draws.items.len == sprite_draw_count);
        return true;
    }
    return false;
}

fn spriteAppend(
    driver: Driver,
    renderable: render.RenderableCell,
    grid_metrics: render.GridMetrics,
    session: font_session.FontSession,
    lane_report: *lane.LaneReport,
    lookup: provider.LookupGlyphResult,
    residency: atlas_cache.ReserveResult,
    span: u8,
) void {
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
        .color = scene.spriteDrawColor(renderable),
        .first_cell = renderable.first_cell,
        .cell_span = span,
    });
    lane_report.direct_normal_draws += 1;
}

fn assertNoPartialDrawState(scratch: *const Scratch) void {
    std.debug.assert(scratchEmpty(scratch));
}

fn checkpointScratch(scratch: *const Scratch) ScratchCheckpoint {
    return .{
        .missing_len = scratch.missing.items.len,
        .sprite_draws_len = scratch.sprite_draws.items.len,
        .background_draws_len = scratch.background_draws.items.len,
        .clear_draws_len = scratch.clear_draws.items.len,
        .decoration_draws_len = scratch.decoration_draws.items.len,
        .cursor_draws_len = scratch.cursor_draws.items.len,
        .raster_reqs_len = scratch.raster_reqs.items.len,
    };
}

fn restoreScratch(scratch: *Scratch, checkpoint: ScratchCheckpoint) void {
    scratch.missing.items.len = checkpoint.missing_len;
    scratch.sprite_draws.items.len = checkpoint.sprite_draws_len;
    scratch.background_draws.items.len = checkpoint.background_draws_len;
    scratch.clear_draws.items.len = checkpoint.clear_draws_len;
    scratch.decoration_draws.items.len = checkpoint.decoration_draws_len;
    scratch.cursor_draws.items.len = checkpoint.cursor_draws_len;
    scratch.raster_reqs.items.len = checkpoint.raster_reqs_len;
    scratch.background_merge_live = false;
    scratch.background_merge_end_cell = 0;
    @memset(scratch.clear_row_matches.items, false);
    for (scratch.clear_row_colors.items) |*color| color.* = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
}

fn scratchEmpty(scratch: *const Scratch) bool {
    std.debug.assert(scratch.missing.items.len == 0);
    std.debug.assert(scratch.sprite_draws.items.len == 0);
    std.debug.assert(scratch.background_draws.items.len == 0);
    std.debug.assert(scratch.clear_draws.items.len == 0);
    std.debug.assert(scratch.decoration_draws.items.len == 0);
    std.debug.assert(scratch.cursor_draws.items.len == 0);
    std.debug.assert(scratch.raster_reqs.items.len == 0);
    return true;
}

fn finishScene(driver: Driver, damage: direct_scene.Damage, lane_report: *lane.LaneReport) !Product {
    var outputs: []rasterizer.RasterSpriteOutput = &.{};
    var outputs_owned = false;
    if (driver.scratch.raster_reqs.items.len > 0) {
        lane_report.direct_normal_raster_misses = @intCast(driver.scratch.raster_reqs.items.len);
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
    }
    return .{ .damage = damage, .outputs = outputs, .outputs_owned = outputs_owned };
}

fn resolveFace(session: font_session.FontSession, cell: render.RenderableCell, text: render.CellText) ?font_session.FontFaceRecord {
    if (isPlainAsciiText(text)) return session.primary();
    return session.findStyle(cell.style, cell.presentation, text) orelse session.findFallback(cell.style, cell.presentation, text);
}

fn isPlainAsciiText(text: render.CellText) bool {
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

fn blankText(text: render.CellText) bool {
    for (text.codepoints) |cp| {
        if (cp != 0 and cp != ' ') return false;
    }
    return true;
}

fn testRenderableCell(first_cell: u32) render.RenderableCell {
    return .{
        .text_id = .{ .value = 1 },
        .first_cell = first_cell,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        .bg = .{ .r = 4, .g = 5, .b = 6, .a = 255 },
    };
}

fn testCellText(codepoint: u32, codepoints: []const u32) render.CellText {
    return .{
        .id = .{ .value = 1 },
        .first_cp = codepoint,
        .codepoints = codepoints,
    };
}

fn testFontSession(faces: []const font_session.FontFaceRecord) font_session.FontSession {
    return .{
        .faces = faces,
        .metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
    };
}

test "direct normal renderable append tab fast return leaves sprite raster missing and lane state unchanged" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 1, 1, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const tab = [_]u32{'\t'};
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, testRenderableCell(0), testCellText('\t', tab[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&.{}), &lane_report);

    try std.testing.expectEqual(@as(usize, 0), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.missing.items.len);
    try std.testing.expectEqual(@as(u64, 0), lane_report.direct_normal_draws);
}

test "direct normal renderable append zero codepoint fast return leaves sprite raster missing and lane state unchanged" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 1, 1, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const zero = [_]u32{0};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, testRenderableCell(0), testCellText(0, zero[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&faces), &lane_report);

    try std.testing.expectEqual(@as(usize, 0), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.missing.items.len);
    try std.testing.expectEqual(@as(u64, 0), lane_report.direct_normal_draws);
}

test "direct normal renderable append missing face appends no fallback glyph and returns early" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 1, 1, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const snowman = [_]u32{0x2603};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, testRenderableCell(0), testCellText(0x2603, snowman[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&faces), &lane_report);

    try std.testing.expectEqual(@as(usize, 1), scratch.missing.items.len);
    try std.testing.expectEqual(render.MissingGlyphReason.no_fallback_face, scratch.missing.items[0].reason);
    try std.testing.expectEqual(@as(usize, 0), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(u64, 0), lane_report.direct_normal_draws);
}

test "direct normal renderable append pending atlas reserve appends matching raster request and sprite draw" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 4, 4, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const ascii = [_]u32{'a'};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 7 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const renderable = testRenderableCell(0);
    const text = testCellText('a', ascii[0..]);
    const session = testFontSession(&faces);
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, renderable, text, .{ .cols = 1, .rows = 1 }, session, &lane_report);

    const lookup = driver.glyph_lookup.lookupGlyph(faces[0].id, text.first_cp, session.metrics);
    const span = @max(renderable.cell_span, 1);
    const key = sprite_key.hashGlyphLocal(faces[0].id, lookup.glyph_id, span, session.metrics);

    try std.testing.expectEqual(@as(usize, 1), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(usize, 1), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.missing.items.len);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);
    try std.testing.expectEqual(faces[0].id.value, scratch.raster_reqs.items[0].face_id);
    try std.testing.expectEqual(lookup.glyph_id, scratch.raster_reqs.items[0].glyph_id);
    try std.testing.expectEqual(key.value, scratch.raster_reqs.items[0].atlas_key);
    try std.testing.expectEqualDeep(session.metrics, scratch.raster_reqs.items[0].cell_metrics);
    try std.testing.expectEqual(span, scratch.raster_reqs.items[0].cell_span);
}

test "direct normal renderable append widened span preserves key raster request and sprite draw span" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 4, 4, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const ascii = [_]u32{'a'};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 7 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    var renderable = testRenderableCell(0);
    renderable.cell_span = 3;
    const text = testCellText('a', ascii[0..]);
    const session = testFontSession(&faces);
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    const lookup = lookupGlyph(driver, text, session, faces[0]);
    const resolved = deriveResolvedGlyphKey(renderable, session, faces[0], lookup);
    const expected_key = sprite_key.hashGlyphLocal(faces[0].id, lookup.glyph_id, renderable.cell_span, session.metrics);

    try std.testing.expectEqual(@as(u8, 3), resolved.span);
    try std.testing.expectEqual(expected_key.value, resolved.key.value);

    appendResolvedGlyph(driver, renderable, text, .{ .cols = 1, .rows = 1 }, session, &lane_report, faces[0]);

    try std.testing.expectEqual(@as(usize, 1), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(u8, 3), scratch.raster_reqs.items[0].cell_span);
    try std.testing.expectEqual(@as(usize, 1), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(u8, 3), scratch.sprite_draws.items[0].cell_span);
    try std.testing.expectEqual(@as(u32, 24), scratch.sprite_draws.items[0].width_px);
}

test "direct normal renderable append rendered atlas hit appends sprite draw without raster request" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 4, 4, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const ascii = [_]u32{'a'};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 7 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const renderable = testRenderableCell(0);
    const text = testCellText('a', ascii[0..]);
    const session = testFontSession(&faces);
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, renderable, text, .{ .cols = 1, .rows = 1 }, session, &lane_report);

    const lookup = driver.glyph_lookup.lookupGlyph(faces[0].id, text.first_cp, session.metrics);
    const span = @max(renderable.cell_span, 1);
    const key = sprite_key.hashGlyphLocal(faces[0].id, lookup.glyph_id, span, session.metrics);

    try std.testing.expectEqual(@as(usize, 1), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(usize, 1), scratch.sprite_draws.items.len);
    try std.testing.expect(atlas.markRendered(key));

    try renderableAppend(driver, renderable, text, .{ .cols = 1, .rows = 1 }, session, &lane_report);

    try std.testing.expectEqual(@as(usize, 2), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(usize, 1), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.missing.items.len);
    try std.testing.expectEqual(@as(u64, 2), lane_report.direct_normal_draws);
}

test "direct normal renderable append updates direct normal draws only on sprite append" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 4, 4, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const ascii = [_]u32{'a'};
    const zero = [_]u32{0};
    const tab = [_]u32{'\t'};
    const snowman = [_]u32{0x2603};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, testRenderableCell(0), testCellText('a', ascii[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&faces), &lane_report);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);

    try renderableAppend(driver, testRenderableCell(1), testCellText(0, zero[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&faces), &lane_report);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);

    try renderableAppend(driver, testRenderableCell(2), testCellText('\t', tab[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&faces), &lane_report);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);

    try renderableAppend(driver, testRenderableCell(3), testCellText(0x2603, snowman[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&faces), &lane_report);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);
}
