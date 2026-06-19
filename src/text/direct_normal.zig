const std = @import("std");
const atlas_cache = @import("raster/atlas.zig");
const cluster = @import("shape/cluster.zig");
const render = @import("draw_primitives.zig");
const direct_draw = @import("../grid/direct.zig");
const face_selection = @import("face_selection.zig");
const lane = @import("lane.zig");
const prepare_counters = @import("prepare_counters.zig");
const provider = @import("provider.zig");
const raster_operation = @import("raster/operation.zig");
const rasterizer = @import("raster/rasterizer.zig");
const draw_list = @import("draw_list.zig");
const text_damage = @import("damage.zig");
const rect_primitives = @import("rect_primitives.zig");
const sprite_key = @import("raster/key.zig");

const RenderableCell = render.RenderableCell;
const CellText = render.CellText;
const FaceSelection = face_selection.FaceSelection;
const FaceRecord = face_selection.FaceRecord;
const LookupGlyphResult = provider.LookupGlyphResult;

pub const Product = struct {
    damage: direct_draw.Damage,
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
    grid_metrics: render.CellGridMetrics,
    selection: face_selection.FaceSelection,
    damage_input: text_damage.DamageInput,
    cursor: ?render.CursorPresentation,
    lane_report: *lane.LaneReport,
    rejected_complex_cells_out: ?*u64,
) !?Product {
    const damage = direct_draw.Damage.init(damage_input, grid_metrics.rows);
    const decoration_layout = rect_primitives.rectDecorationLayout(selection.cell_metrics, grid_metrics);
    const source_len = sourceLen(source);
    var rejected_complex_cells: u64 = 0;
    try driver.scratch.reset(driver.allocator, source_len, source_len, grid_metrics.rows);
    const appended_visible = try appendVisible(driver, source, damage, grid_metrics, decoration_layout, selection, policy, lane_report, &rejected_complex_cells);
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
    direct_draw.appendClears(
        &driver.scratch.clear_draws,
        driver.scratch.clear_row_colors.items,
        driver.scratch.clear_row_matches.items,
        selection.cell_metrics,
        grid_metrics,
        damage,
    );
    direct_draw.appendCursor(&driver.scratch.cursor_draws, cursor, selection.cell_metrics, damage);
    const product = try finishDrawList(driver, damage, lane_report);
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
    damage: direct_draw.Damage,
    grid_metrics: render.CellGridMetrics,
    decoration_layout: rect_primitives.RectDecorationLayout,
    selection: face_selection.FaceSelection,
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
                try appendRenderable(driver, candidate_value.item.renderable, candidate_value.item.text, damage, grid_metrics, decoration_layout, selection, lane_report);
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

fn sourceCandidate(source: Source, idx: u32, damage: direct_draw.Damage, grid_metrics: render.CellGridMetrics) ?Candidate {
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

fn damageInput(damage: direct_draw.Damage) text_damage.DamageInput {
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
    damage: direct_draw.Damage,
    grid_metrics: render.CellGridMetrics,
    decoration_layout: rect_primitives.RectDecorationLayout,
    selection: face_selection.FaceSelection,
    lane_report: *lane.LaneReport,
) !void {
    direct_draw.appendRenderableRects(
        &driver.scratch.background_draws,
        &driver.scratch.background_merge_live,
        &driver.scratch.background_merge_end_cell,
        driver.scratch.clear_row_colors.items,
        driver.scratch.clear_row_matches.items,
        &driver.scratch.decoration_draws,
        renderable,
        selection.cell_metrics,
        grid_metrics,
        decoration_layout,
        damage,
    );

    try renderableAppend(driver, renderable, text, grid_metrics, selection, lane_report);
}

fn renderableAppend(
    driver: Driver,
    renderable: render.RenderableCell,
    text: render.CellText,
    grid_metrics: render.CellGridMetrics,
    selection: face_selection.FaceSelection,
    lane_report: *lane.LaneReport,
) !void {
    if (blankFastReturn(driver, text)) return;

    const face = resolveFaceOrAppendMissing(driver, renderable, text, selection) orelse return;
    appendResolvedGlyph(driver, renderable, text, grid_metrics, selection, lane_report, face);
}

fn resolveFaceOrAppendMissing(driver: Driver, renderable: render.RenderableCell, text: render.CellText, selection: face_selection.FaceSelection) ?face_selection.FaceRecord {
    const face = resolveFace(selection, renderable, text) orelse {
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
    grid_metrics: render.CellGridMetrics,
    selection: face_selection.FaceSelection,
    lane_report: *lane.LaneReport,
    face: face_selection.FaceRecord,
) void {
    const lookup = lookupGlyph(driver, text, selection, face);
    const resolved = deriveResolvedGlyphKey(renderable, selection, face, lookup);
    const residency = reserveAtlasOrAppendPendingRaster(driver, selection, face, resolved);
    spriteAppend(driver, renderable, grid_metrics, selection, lane_report, resolved.lookup, residency, resolved.span);
}

fn lookupGlyph(driver: Driver, text: CellText, selection: FaceSelection, face: FaceRecord) LookupGlyphResult {
    return driver.glyph_lookup.lookupGlyph(face.id, text.first_cp, selection.cell_metrics);
}

fn deriveResolvedGlyphKey(renderable: RenderableCell, selection: FaceSelection, face: FaceRecord, lookup: LookupGlyphResult) ResolvedGlyphKey {
    const span = @max(renderable.cell_span, 1);
    const key = sprite_key.hashGlyphLocal(face.id, lookup.glyph_id, span, selection.cell_metrics);
    return .{ .lookup = lookup, .span = span, .key = key };
}

fn reserveAtlasOrAppendPendingRaster(driver: Driver, selection: face_selection.FaceSelection, face: face_selection.FaceRecord, resolved: ResolvedGlyphKey) atlas_cache.ReserveResult {
    const residency = driver.atlas.reserve(resolved.key, false);
    if (residency.pending) {
        driver.scratch.raster_reqs.appendAssumeCapacity(.{
            .face_id = face.id.value,
            .glyph_id = resolved.lookup.glyph_id,
            .atlas_key = resolved.key.value,
            .cell_metrics = selection.cell_metrics,
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
    grid_metrics: render.CellGridMetrics,
    selection: face_selection.FaceSelection,
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
        .x_px = @as(i32, @intCast(col * @as(u32, selection.cell_metrics.cell_w_px))),
        .y_px = @as(i32, @intCast(row * @as(u32, selection.cell_metrics.cell_h_px))),
        .width_px = @intCast(@as(u32, span) * @as(u32, selection.cell_metrics.cell_w_px)),
        .height_px = selection.cell_metrics.cell_h_px,
        .placement = .{ .advance_px = @max(lookup.advance_px, @as(f32, @floatFromInt(@as(u32, span) * @as(u32, selection.cell_metrics.cell_w_px)))) },
        .color = draw_list.spriteDrawColor(renderable),
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

fn finishDrawList(driver: Driver, damage: direct_draw.Damage, lane_report: *lane.LaneReport) !Product {
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

fn resolveFace(selection: face_selection.FaceSelection, cell: render.RenderableCell, text: render.CellText) ?face_selection.FaceRecord {
    if (isPlainAsciiText(text)) return selection.primary();
    return selection.findStyle(cell.style, cell.presentation, text) orelse selection.findFallback(cell.style, cell.presentation, text);
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

fn testFaceSelection(faces: []const face_selection.FaceRecord) face_selection.FaceSelection {
    return .{
        .faces = faces,
        .cell_metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
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

    try renderableAppend(driver, testRenderableCell(0), testCellText('\t', tab[0..]), .{ .cols = 1, .rows = 1 }, testFaceSelection(&.{}), &lane_report);

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
    const faces = [_]face_selection.FaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, testRenderableCell(0), testCellText(0, zero[0..]), .{ .cols = 1, .rows = 1 }, testFaceSelection(&faces), &lane_report);

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
    const faces = [_]face_selection.FaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, testRenderableCell(0), testCellText(0x2603, snowman[0..]), .{ .cols = 1, .rows = 1 }, testFaceSelection(&faces), &lane_report);

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
    const faces = [_]face_selection.FaceRecord{
        .{ .id = .{ .value = 7 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const renderable = testRenderableCell(0);
    const text = testCellText('a', ascii[0..]);
    const selection = testFaceSelection(&faces);
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, renderable, text, .{ .cols = 1, .rows = 1 }, selection, &lane_report);

    const lookup = driver.glyph_lookup.lookupGlyph(faces[0].id, text.first_cp, selection.cell_metrics);
    const span = @max(renderable.cell_span, 1);
    const key = sprite_key.hashGlyphLocal(faces[0].id, lookup.glyph_id, span, selection.cell_metrics);

    try std.testing.expectEqual(@as(usize, 1), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(usize, 1), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.missing.items.len);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);
    try std.testing.expectEqual(faces[0].id.value, scratch.raster_reqs.items[0].face_id);
    try std.testing.expectEqual(lookup.glyph_id, scratch.raster_reqs.items[0].glyph_id);
    try std.testing.expectEqual(key.value, scratch.raster_reqs.items[0].atlas_key);
    try std.testing.expectEqualDeep(selection.cell_metrics, scratch.raster_reqs.items[0].cell_metrics);
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
    const faces = [_]face_selection.FaceRecord{
        .{ .id = .{ .value = 7 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    var renderable = testRenderableCell(0);
    renderable.cell_span = 3;
    const text = testCellText('a', ascii[0..]);
    const selection = testFaceSelection(&faces);
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    const lookup = lookupGlyph(driver, text, selection, faces[0]);
    const resolved = deriveResolvedGlyphKey(renderable, selection, faces[0], lookup);
    const expected_key = sprite_key.hashGlyphLocal(faces[0].id, lookup.glyph_id, renderable.cell_span, selection.cell_metrics);

    try std.testing.expectEqual(@as(u8, 3), resolved.span);
    try std.testing.expectEqual(expected_key.value, resolved.key.value);

    appendResolvedGlyph(driver, renderable, text, .{ .cols = 1, .rows = 1 }, selection, &lane_report, faces[0]);

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
    const faces = [_]face_selection.FaceRecord{
        .{ .id = .{ .value = 7 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const renderable = testRenderableCell(0);
    const text = testCellText('a', ascii[0..]);
    const selection = testFaceSelection(&faces);
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, renderable, text, .{ .cols = 1, .rows = 1 }, selection, &lane_report);

    const lookup = driver.glyph_lookup.lookupGlyph(faces[0].id, text.first_cp, selection.cell_metrics);
    const span = @max(renderable.cell_span, 1);
    const key = sprite_key.hashGlyphLocal(faces[0].id, lookup.glyph_id, span, selection.cell_metrics);

    try std.testing.expectEqual(@as(usize, 1), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(usize, 1), scratch.sprite_draws.items.len);
    try std.testing.expect(atlas.markRendered(key));

    try renderableAppend(driver, renderable, text, .{ .cols = 1, .rows = 1 }, selection, &lane_report);

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
    const faces = [_]face_selection.FaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, testRenderableCell(0), testCellText('a', ascii[0..]), .{ .cols = 1, .rows = 1 }, testFaceSelection(&faces), &lane_report);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);

    try renderableAppend(driver, testRenderableCell(1), testCellText(0, zero[0..]), .{ .cols = 1, .rows = 1 }, testFaceSelection(&faces), &lane_report);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);

    try renderableAppend(driver, testRenderableCell(2), testCellText('\t', tab[0..]), .{ .cols = 1, .rows = 1 }, testFaceSelection(&faces), &lane_report);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);

    try renderableAppend(driver, testRenderableCell(3), testCellText(0x2603, snowman[0..]), .{ .cols = 1, .rows = 1 }, testFaceSelection(&faces), &lane_report);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);
}
