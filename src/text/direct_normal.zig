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
    rejected_complex_cells_out: ?*u64,
) !?Product {
    var timings = Timings{};
    const damage = direct_scene.Damage.init(damage_input, grid_metrics.rows);
    const source_len = sourceLen(source);
    var rejected_complex_cells: u64 = 0;
    try driver.scratch.reset(driver.allocator, source_len, source_len, grid_metrics.rows);
    const scan_start_ns = monotonicNs();
    if (!try appendVisible(driver, source, damage, grid_metrics, session, policy, lane_report, &rejected_complex_cells)) {
        std.debug.assert(policy == .require_all_normal);
        std.debug.assert(rejected_complex_cells != 0);
        if (rejected_complex_cells_out) |out| out.* = rejected_complex_cells;
        assertNoPartialDrawState(driver.scratch);
        lane_report.assertValid();
        return null;
    }
    timings.scan_us = elapsedUs(scan_start_ns);
    std.debug.assert(rejected_complex_cells == 0);
    if (rejected_complex_cells_out) |out| out.* = 0;
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

const PublicationCandidate = union(enum) {
    candidate: Candidate,
    skip,
    unsupported,
};

const ascii_codepoints = initAsciiCodepoints();

const ScratchCheckpoint = struct {
    renderable_len: usize,
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
    grid_metrics: contract.GridMetrics,
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
        const candidate = sourceCandidate(source, idx, damage, grid_metrics) orelse continue;
        if (rejecting) {
            if (candidate.choice.renderableClass() != .normal) rejected_complex_cells.* += 1;
            continue;
        }
        switch (candidateDecision(policy, lane_report, candidate)) {
            .include => try appendRenderable(driver, candidate.item.renderable, candidate.item.text, grid_metrics, session, lane_report),
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

fn sourceCandidate(source: Source, idx: u32, damage: direct_scene.Damage, grid_metrics: contract.GridMetrics) ?Candidate {
    if (source == .publication) {
        const publication = source.publication;
        switch (publicationCandidate(publication.cells, publication.theme, idx, damage, grid_metrics)) {
            .candidate => |candidate| return candidate,
            .skip => return null,
            .unsupported => {},
        }
    }
    const item = sourceItem(source, idx) orelse return null;
    if (!cluster.includeDamage(grid_metrics, damageInput(damage), item.renderable)) return null;
    return .{ .item = item, .choice = lane.classifyRenderableCell(item.renderable, item.text) };
}

fn publicationCandidate(cells: []const source_vt.SourceCell, theme: publication_cell_map.FrameTheme, idx: u32, damage: direct_scene.Damage, grid_metrics: contract.GridMetrics) PublicationCandidate {
    std.debug.assert(idx < count32(cells));
    const cell = cells[@intCast(idx)];
    if (!publicationCellSupported(cells, idx, cell)) return .unsupported;

    const item = publicationRenderableText(theme, idx, cell);
    if (!cluster.includeDamage(grid_metrics, damageInput(damage), item.renderable)) return .skip;
    const choice = lane.LaneClass.normal();
    choice.assertValid();
    std.debug.assert(lane.classifyRenderableCell(item.renderable, item.text).renderableClass() == .normal);
    return .{ .candidate = .{ .item = item, .choice = choice } };
}

fn publicationCellSupported(cells: []const source_vt.SourceCell, idx: u32, cell: source_vt.SourceCell) bool {
    if (cell.codepoint < 0x21 or cell.codepoint >= 0x7f) return false;
    if (cell.combining_len != 0) return false;
    if (cell.flags.continuation != 0) return false;
    if (publicationCellSpan(cells, idx) != 1) return false;
    if (cell.link_id != 0) return false;
    if (!publicationColorSupported(cell.fg_color)) return false;
    if (!publicationColorSupported(cell.bg_color)) return false;
    if (cell.attrs.selected != 0) return false;
    if (cell.attrs.invisible != 0) return false;
    if (cell.attrs.strikethrough != 0) return false;
    if (cell.attrs.underline_color_set != 0) return false;
    if (cell.underline_style != 0) return false;
    return true;
}

fn publicationRenderableText(theme: publication_cell_map.FrameTheme, idx: u32, cell: source_vt.SourceCell) cluster.RenderableText {
    std.debug.assert(cell.codepoint >= 0x21 and cell.codepoint < 0x7f);
    std.debug.assert(cell.combining_len == 0);
    std.debug.assert(cell.flags.continuation == 0);
    std.debug.assert(publicationColorSupported(cell.fg_color));
    std.debug.assert(publicationColorSupported(cell.bg_color));
    std.debug.assert(cell.underline_style == 0);

    var fg = publicationColorRgba(cell.fg_color, true, theme);
    var bg = publicationColorRgba(cell.bg_color, false, theme);
    if (cell.attrs.inverse != 0) std.mem.swap(contract.Rgba8, &fg, &bg);

    const item = cluster.RenderableText{
        .renderable = .{
            .text_id = .{ .value = 0 },
            .first_cell = idx,
            .cell_span = 1,
            .style = publicationFontStyle(cell.attrs.bold != 0, cell.attrs.italic != 0),
            .presentation = .any,
            .dim = cell.attrs.dim != 0,
            .invisible = false,
            .semantic_fg = publicationSemanticColor(cell.fg_color),
            .semantic_bg = publicationSemanticColor(cell.bg_color),
            .fg = fg,
            .bg = bg,
            .underline_color_set = false,
            .semantic_underline_color = .{},
            .underline_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .underline_style = .straight,
            .underline = cell.attrs.underline != 0,
            .strikethrough = false,
            .continuation = false,
        },
        .text = .{ .id = .{ .value = 0 }, .first_cp = cell.codepoint, .codepoints = ascii_codepoints[@intCast(cell.codepoint)][0..1] },
    };
    std.debug.assert(item.text.codepoints.len == 1);
    std.debug.assert(item.text.codepoints[0] == item.text.first_cp);
    std.debug.assert(item.renderable.cell_span == 1);
    return item;
}

fn publicationColorSupported(color: source_vt.SourceColor) bool {
    return switch (color.kind) {
        0 => true,
        1 => color.value <= std.math.maxInt(u8),
        else => false,
    };
}

fn publicationColorRgba(color: source_vt.SourceColor, foreground: bool, theme: publication_cell_map.FrameTheme) contract.Rgba8 {
    std.debug.assert(publicationColorSupported(color));
    return switch (color.kind) {
        0 => if (foreground) theme.default_fg else theme.default_bg,
        1 => theme.palette[@intCast(color.value)],
        else => unreachable,
    };
}

fn publicationSemanticColor(color: source_vt.SourceColor) contract.SemanticColor {
    std.debug.assert(publicationColorSupported(color));
    return switch (color.kind) {
        0 => .{ .kind = .default },
        1 => .{ .kind = .indexed, .value = color.value },
        else => unreachable,
    };
}

fn publicationFontStyle(bold: bool, italic: bool) contract.FontStyle {
    if (bold and italic) return .bold_italic;
    if (bold) return .bold;
    if (italic) return .italic;
    return .regular;
}

fn publicationCellSpan(cells: []const source_vt.SourceCell, idx: u32) u8 {
    var span: u32 = 1;
    const total = count32(cells);
    while (idx + span < total and cells[@intCast(idx + span)].flags.continuation != 0) : (span += 1) {}
    return @intCast(@min(span, std.math.maxInt(u8)));
}

fn initAsciiCodepoints() [128][1]u32 {
    var table: [128][1]u32 = undefined;
    for (&table, 0..) |*entry, idx| entry[0] = @intCast(idx);
    return table;
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
    const sprite_draw_count = driver.scratch.sprite_draws.items.len;
    if (text.first_cp == 0 or text.first_cp == '\t') {
        std.debug.assert(driver.scratch.sprite_draws.items.len == sprite_draw_count);
        return;
    }

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
        .renderable_len = scratch.renderable.items.len,
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
    scratch.renderable.items.len = checkpoint.renderable_len;
    scratch.missing.items.len = checkpoint.missing_len;
    scratch.sprite_draws.items.len = checkpoint.sprite_draws_len;
    scratch.background_draws.items.len = checkpoint.background_draws_len;
    scratch.clear_draws.items.len = checkpoint.clear_draws_len;
    scratch.decoration_draws.items.len = checkpoint.decoration_draws_len;
    scratch.cursor_draws.items.len = checkpoint.cursor_draws_len;
    scratch.raster_reqs.items.len = checkpoint.raster_reqs_len;
}

fn scratchEmpty(scratch: *const Scratch) bool {
    std.debug.assert(scratch.renderable.items.len == 0);
    std.debug.assert(scratch.missing.items.len == 0);
    std.debug.assert(scratch.sprite_draws.items.len == 0);
    std.debug.assert(scratch.background_draws.items.len == 0);
    std.debug.assert(scratch.clear_draws.items.len == 0);
    std.debug.assert(scratch.decoration_draws.items.len == 0);
    std.debug.assert(scratch.cursor_draws.items.len == 0);
    std.debug.assert(scratch.raster_reqs.items.len == 0);
    return true;
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
