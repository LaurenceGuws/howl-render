const std = @import("std");
const contract = @import("contract.zig");
const scene_damage = @import("scene_damage.zig");
const scene_rects = @import("scene_rects.zig");
const atlas_cache = @import("raster/atlas.zig");
const rasterizer = @import("raster/rasterizer.zig");
const sprite_key = @import("raster/key.zig");

pub const TextScene = contract.TextScene;
pub const TextSpriteDraw = contract.TextSpriteDraw;

pub const CursorFillRect = struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: contract.Rgba8,
    first_cell: u32,
    cell_span: u8,
};

pub const CursorTextRecolorSpan = struct {
    first_cell: u32,
    cell_span: u8,
    color: contract.Rgba8,
};

pub const CursorTrailRect = struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    opacity: u8,
    color: contract.Rgba8,
    first_cell: u32,
    cell_span: u8,
};

pub fn empty() TextScene {
    return .{ .clear_draws = &.{}, .background_draws = &.{}, .sprite_draws = &.{}, .decoration_draws = &.{}, .cursor_draws = &.{}, .missing = &.{} };
}

const kitty_dim_opacity_numerator: u16 = 2;
const kitty_dim_opacity_denominator: u16 = 5;

pub const BuildOptions = struct {
    cursor: ?contract.CursorPresentation = null,
    damage: scene_damage.DamageInput = .{},
};

pub const OwnedTextScene = struct {
    allocator: std.mem.Allocator,
    scene: contract.TextScene,
    cursor_presentation: ?contract.CursorPresentation = null,
    cursor_fill_rects: []const CursorFillRect = &.{},
    cursor_text_recolor_spans: []const CursorTextRecolorSpan = &.{},
    cursor_trail_rects: []const CursorTrailRect = &.{},
    owned: bool = true,

    pub fn deinit(self: *OwnedTextScene) void {
        if (self.owned) {
            self.allocator.free(self.scene.clear_draws);
            self.allocator.free(self.scene.background_draws);
            self.allocator.free(self.scene.sprite_draws);
            self.allocator.free(self.scene.decoration_draws);
            self.allocator.free(self.scene.cursor_draws);
            self.allocator.free(self.scene.raster_requests);
            self.allocator.free(self.scene.missing);
            self.allocator.free(self.cursor_fill_rects);
            self.allocator.free(self.cursor_text_recolor_spans);
            self.allocator.free(self.cursor_trail_rects);
        }
        self.* = undefined;
    }
};

pub const BorrowedTextScene = struct {
    allocator: std.mem.Allocator,
    scene: contract.TextScene,
    cursor_presentation: ?contract.CursorPresentation = null,
    cursor_fill_rects: []const CursorFillRect = &.{},
    cursor_text_recolor_spans: []const CursorTextRecolorSpan = &.{},
    cursor_trail_rects: []const CursorTrailRect = &.{},

    pub fn deinit(self: *BorrowedTextScene) void {
        self.allocator.free(self.scene.raster_requests);
        self.allocator.free(self.scene.missing);
        self.* = undefined;
    }
};

pub const RetainedScratch = struct {
    sprite_draws: std.ArrayList(contract.TextSpriteDraw) = .empty,
    background_draws: std.ArrayList(contract.TextBackgroundDraw) = .empty,
    clear_draws: std.ArrayList(contract.TextClearDraw) = .empty,
    decoration_draws: std.ArrayList(contract.TextDecorationDraw) = .empty,
    cursor_draws: std.ArrayList(contract.TextCursorDraw) = .empty,
    cursor_fill_rects: std.ArrayList(CursorFillRect) = .empty,
    cursor_text_recolor_spans: std.ArrayList(CursorTextRecolorSpan) = .empty,
    cursor_trail_rects: std.ArrayList(CursorTrailRect) = .empty,

    pub fn deinit(self: *RetainedScratch, allocator: std.mem.Allocator) void {
        self.cursor_trail_rects.deinit(allocator);
        self.cursor_text_recolor_spans.deinit(allocator);
        self.cursor_fill_rects.deinit(allocator);
        self.cursor_draws.deinit(allocator);
        self.decoration_draws.deinit(allocator);
        self.clear_draws.deinit(allocator);
        self.background_draws.deinit(allocator);
        self.sprite_draws.deinit(allocator);
        self.* = undefined;
    }

    fn reset(self: *RetainedScratch, allocator: std.mem.Allocator, capacities: DrawCapacities) !void {
        try self.sprite_draws.ensureTotalCapacity(allocator, capacities.sprite_draws);
        try self.background_draws.ensureTotalCapacity(allocator, capacities.background_draws);
        try self.clear_draws.ensureTotalCapacity(allocator, capacities.clear_draws);
        try self.decoration_draws.ensureTotalCapacity(allocator, capacities.decoration_draws);
        try self.cursor_draws.ensureTotalCapacity(allocator, capacities.cursor_draws);
        try self.cursor_fill_rects.ensureTotalCapacity(allocator, capacities.cursor_fill_rects);
        try self.cursor_text_recolor_spans.ensureTotalCapacity(allocator, capacities.cursor_text_recolor_spans);
        try self.cursor_trail_rects.ensureTotalCapacity(allocator, capacities.cursor_trail_rects);
        self.sprite_draws.clearRetainingCapacity();
        self.background_draws.clearRetainingCapacity();
        self.clear_draws.clearRetainingCapacity();
        self.decoration_draws.clearRetainingCapacity();
        self.cursor_draws.clearRetainingCapacity();
        self.cursor_fill_rects.clearRetainingCapacity();
        self.cursor_text_recolor_spans.clearRetainingCapacity();
        self.cursor_trail_rects.clearRetainingCapacity();
    }
};

pub fn buildSceneWithOptions(
    allocator: std.mem.Allocator,
    cells: []const contract.RenderableCell,
    groups: []const contract.GlyphGroup,
    missing: []const contract.MissingGlyph,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    options: BuildOptions,
) !OwnedTextScene {
    var cache = try atlas_cache.OwnedAtlasCache.init(allocator, @intCast(groups.len + cells.len));
    defer cache.deinit();
    return buildSceneWithAtlasCacheOptions(allocator, cells, groups, missing, cell_metrics, grid_metrics, &cache, options);
}

pub fn buildSceneWithAtlasCacheOptions(
    allocator: std.mem.Allocator,
    cells: []const contract.RenderableCell,
    groups: []const contract.GlyphGroup,
    missing: []const contract.MissingGlyph,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    cache: *atlas_cache.OwnedAtlasCache,
    options: BuildOptions,
) !OwnedTextScene {
    const damage = scene_damage.normalizeDamage(options.damage, grid_metrics.rows);
    var assembly = SceneAssembly{ .allocator = allocator };
    assembly.cursor_presentation = options.cursor;
    errdefer assembly.deinit();
    try appendSceneAssemblyPopulation(&assembly, cache, cells, groups, missing, cell_metrics, grid_metrics, damage, options.cursor);
    return assembly.toOwnedScene(damage);
}

pub fn buildBorrowedSceneWithAtlasCacheOptions(
    allocator: std.mem.Allocator,
    scratch: *RetainedScratch,
    cells: []const contract.RenderableCell,
    groups: []const contract.GlyphGroup,
    missing: []const contract.MissingGlyph,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    cache: *atlas_cache.OwnedAtlasCache,
    options: BuildOptions,
) !BorrowedTextScene {
    const damage = scene_damage.normalizeDamage(options.damage, grid_metrics.rows);
    const capacities = drawCapacities(cells, groups, cell_metrics, grid_metrics, damage, options.cursor);
    try scratch.reset(allocator, capacities);

    var assembly = SceneAssembly{ .allocator = allocator };
    assembly.cursor_presentation = options.cursor;
    assembly.adoptRetainedScratch(scratch);
    errdefer assembly.deinit();
    try appendSceneAssemblyPopulation(&assembly, cache, cells, groups, missing, cell_metrics, grid_metrics, damage, options.cursor);
    return assembly.toBorrowedScene(damage);
}

fn appendSceneAssemblyPopulation(
    assembly: *SceneAssembly,
    cache: *atlas_cache.OwnedAtlasCache,
    cells: []const contract.RenderableCell,
    groups: []const contract.GlyphGroup,
    missing: []const contract.MissingGlyph,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: scene_damage.NormalizedDamage,
    cursor: ?contract.CursorPresentation,
) !void {
    try assembly.missing.appendSlice(assembly.allocator, missing);

    try appendGroupSpriteDraws(assembly, cache, cells, groups, cell_metrics, grid_metrics, damage);
    try scene_rects.appendCursorPrimitives(
        assembly.allocator,
        &assembly.cursor_draws,
        &assembly.cursor_fill_rects,
        &assembly.cursor_text_recolor_spans,
        &assembly.cursor_trail_rects,
        cells,
        grid_metrics,
        cursor,
        damage,
        cell_metrics,
    );
    try scene_rects.appendClearDraws(assembly.allocator, &assembly.clear_draws, cells, cell_metrics, grid_metrics, damage);
    try scene_rects.appendBackgroundDraws(assembly.allocator, &assembly.background_draws, cells, cell_metrics, grid_metrics, damage);
    try scene_rects.appendRectDecorationDraws(underlineDrawColor, spriteDrawColor, assembly.allocator, &assembly.decoration_draws, cells, cell_metrics, grid_metrics, damage);
    try appendCurlyUnderlineSprites(assembly, cache, cells, cell_metrics, grid_metrics, damage);
}

const DrawCapacities = struct {
    sprite_draws: usize,
    background_draws: usize,
    clear_draws: usize,
    decoration_draws: usize,
    cursor_draws: usize,
    cursor_fill_rects: usize,
    cursor_text_recolor_spans: usize,
    cursor_trail_rects: usize,
};

const SceneAssembly = struct {
    allocator: std.mem.Allocator,
    retained_scratch: ?*RetainedScratch = null,
    cursor_presentation: ?contract.CursorPresentation = null,
    sprite_draws: std.ArrayList(contract.TextSpriteDraw) = .empty,
    background_draws: std.ArrayList(contract.TextBackgroundDraw) = .empty,
    clear_draws: std.ArrayList(contract.TextClearDraw) = .empty,
    decoration_draws: std.ArrayList(contract.TextDecorationDraw) = .empty,
    cursor_draws: std.ArrayList(contract.TextCursorDraw) = .empty,
    cursor_fill_rects: std.ArrayList(CursorFillRect) = .empty,
    cursor_text_recolor_spans: std.ArrayList(CursorTextRecolorSpan) = .empty,
    cursor_trail_rects: std.ArrayList(CursorTrailRect) = .empty,
    raster_requests: std.ArrayList(contract.SpriteRasterRequest) = .empty,
    missing: std.ArrayList(contract.MissingGlyph) = .empty,

    fn adoptRetainedScratch(self: *SceneAssembly, scratch: *RetainedScratch) void {
        self.retained_scratch = scratch;
        self.sprite_draws = scratch.sprite_draws;
        self.background_draws = scratch.background_draws;
        self.clear_draws = scratch.clear_draws;
        self.decoration_draws = scratch.decoration_draws;
        self.cursor_draws = scratch.cursor_draws;
        self.cursor_fill_rects = scratch.cursor_fill_rects;
        self.cursor_text_recolor_spans = scratch.cursor_text_recolor_spans;
        self.cursor_trail_rects = scratch.cursor_trail_rects;
    }

    fn releaseRetainedScratch(self: *SceneAssembly) void {
        const scratch = self.retained_scratch orelse return;
        scratch.sprite_draws = self.sprite_draws;
        scratch.background_draws = self.background_draws;
        scratch.clear_draws = self.clear_draws;
        scratch.decoration_draws = self.decoration_draws;
        scratch.cursor_draws = self.cursor_draws;
        scratch.cursor_fill_rects = self.cursor_fill_rects;
        scratch.cursor_text_recolor_spans = self.cursor_text_recolor_spans;
        scratch.cursor_trail_rects = self.cursor_trail_rects;
    }

    fn deinit(self: *SceneAssembly) void {
        if (self.retained_scratch == null) {
            self.sprite_draws.deinit(self.allocator);
            self.background_draws.deinit(self.allocator);
            self.clear_draws.deinit(self.allocator);
            self.decoration_draws.deinit(self.allocator);
            self.cursor_draws.deinit(self.allocator);
            self.cursor_fill_rects.deinit(self.allocator);
            self.cursor_text_recolor_spans.deinit(self.allocator);
            self.cursor_trail_rects.deinit(self.allocator);
        } else {
            self.releaseRetainedScratch();
        }
        self.raster_requests.deinit(self.allocator);
        self.missing.deinit(self.allocator);
        self.* = undefined;
    }

    fn toOwnedScene(self: *SceneAssembly, damage: scene_damage.NormalizedDamage) !OwnedTextScene {
        defer if (self.retained_scratch != null) self.releaseRetainedScratch();
        return .{
            .allocator = self.allocator,
            .scene = .{
                .full_redraw = damage.full,
                .clear_draws = try self.clear_draws.toOwnedSlice(self.allocator),
                .background_draws = try self.background_draws.toOwnedSlice(self.allocator),
                .sprite_draws = try self.sprite_draws.toOwnedSlice(self.allocator),
                .decoration_draws = try self.decoration_draws.toOwnedSlice(self.allocator),
                .cursor_draws = try self.cursor_draws.toOwnedSlice(self.allocator),
                .raster_requests = try self.raster_requests.toOwnedSlice(self.allocator),
                .missing = try self.missing.toOwnedSlice(self.allocator),
            },
            .cursor_presentation = self.cursor_presentation,
            .cursor_fill_rects = try self.cursor_fill_rects.toOwnedSlice(self.allocator),
            .cursor_text_recolor_spans = try self.cursor_text_recolor_spans.toOwnedSlice(self.allocator),
            .cursor_trail_rects = try self.cursor_trail_rects.toOwnedSlice(self.allocator),
        };
    }

    fn toBorrowedScene(self: *SceneAssembly, damage: scene_damage.NormalizedDamage) !BorrowedTextScene {
        std.debug.assert(self.retained_scratch != null);
        defer self.releaseRetainedScratch();
        const raster_requests = try self.raster_requests.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(raster_requests);
        const missing = try self.missing.toOwnedSlice(self.allocator);
        return .{
            .allocator = self.allocator,
            .scene = .{
                .full_redraw = damage.full,
                .clear_draws = self.clear_draws.items,
                .background_draws = self.background_draws.items,
                .sprite_draws = self.sprite_draws.items,
                .decoration_draws = self.decoration_draws.items,
                .cursor_draws = self.cursor_draws.items,
                .raster_requests = raster_requests,
                .missing = missing,
            },
            .cursor_presentation = self.cursor_presentation,
            .cursor_fill_rects = self.cursor_fill_rects.items,
            .cursor_text_recolor_spans = self.cursor_text_recolor_spans.items,
            .cursor_trail_rects = self.cursor_trail_rects.items,
        };
    }

    fn appendRasterizedSpriteDraw(self: *SceneAssembly, cache: *atlas_cache.OwnedAtlasCache, req: contract.SpriteRasterRequest, draw: SpriteDrawInput) !void {
        std.debug.assert(draw.width_px > 0);
        std.debug.assert(draw.height_px > 0);
        const residency = cache.reserveRequest(req);
        try rasterizer.appendPendingRequest(self.allocator, &self.raster_requests, residency.pending, req);
        try self.sprite_draws.append(self.allocator, .{
            .sprite = residency.position,
            .x_px = draw.x_px,
            .y_px = draw.y_px,
            .width_px = draw.width_px,
            .height_px = draw.height_px,
            .placement = draw.placement,
            .color = draw.color,
            .first_cell = draw.first_cell,
            .cell_span = draw.cell_span,
        });
    }

    fn appendUndercurl(
        self: *SceneAssembly,
        cache: *atlas_cache.OwnedAtlasCache,
        cell: contract.RenderableCell,
        x: i32,
        row_y: i32,
        width: u16,
        deco: contract.DecorationGeometry,
        cell_metrics: contract.CellMetrics,
        color: contract.Rgba8,
    ) !void {
        const cell_h = @max(cell_metrics.cell_h_px, 1);
        const underline_position: u16 = @intCast(std.math.clamp(deco.underline_y_px, 0, @as(i32, @intCast(cell_h - 1))));
        const underline_thickness = deco.underline_h_px;
        const half_thickness = underline_thickness / 2;
        const half_remainder = underline_thickness % 2;
        const position_base = @min(underline_position, saturatingSub(cell_h, half_thickness + half_remainder));
        const bounded_thickness = @max(@as(u16, 1), @min(underline_thickness, saturatingSub(cell_h, position_base + 1)));
        const max_height = cell_h - saturatingSub(position_base, bounded_thickness / 2);
        const amplitude: u16 = @max(@as(u16, 1), max_height / 4);
        const stroke: u16 = if (bounded_thickness < 3) 0 else bounded_thickness - 2;
        var y_px: u16 = @intCast(@min(@as(u32, position_base) + @as(u32, amplitude) * 2, @as(u32, cell_h - 1)));
        if (y_px + amplitude > cell_h - 1) y_px = saturatingSub(cell_h - 1, amplitude);
        const period: u16 = @max(saturatingSub(cell_metrics.cell_w_px, 1), 1);
        const decoration = contract.DecorationSpriteRaster{ .stroke_px = stroke, .amplitude_px = amplitude, .period_px = period, .y_px = y_px };
        const key = sprite_key.hashUndercurl(width, cell_h, stroke, amplitude, period, y_px);
        const req = rasterizer.requestForUndercurl(key, width, cell_h, decoration);
        try self.appendRasterizedSpriteDraw(cache, req, .{
            .x_px = x,
            .y_px = row_y,
            .width_px = width,
            .height_px = cell_h,
            .color = color,
            .first_cell = cell.first_cell,
            .cell_span = cell.cell_span,
        });
    }
};

fn drawCapacities(
    cells: []const contract.RenderableCell,
    groups: []const contract.GlyphGroup,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: scene_damage.NormalizedDamage,
    cursor: ?contract.CursorPresentation,
) DrawCapacities {
    return .{
        .sprite_draws = countGroupSpriteDraws(groups, grid_metrics, damage) + countCurlyUnderlineSprites(cells, grid_metrics, damage),
        .background_draws = cells.len,
        .clear_draws = scene_rects.countClearDraws(grid_metrics, damage),
        .decoration_draws = scene_rects.countRectDecorationDraws(cells, cell_metrics, grid_metrics, damage),
        .cursor_draws = scene_rects.countCursorDraws(cursor, damage),
        .cursor_fill_rects = scene_rects.countCursorFillRects(cursor, damage),
        .cursor_text_recolor_spans = scene_rects.countCursorTextRecolorSpans(cursor, damage),
        .cursor_trail_rects = scene_rects.countCursorTrailRects(cursor, damage),
    };
}

fn emptyExtraCursorPresentation() contract.ExtraCursorPresentation {
    return .{
        .extent = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 },
        .shape = .none,
        .mode = .point,
        .shape_follows_main = false,
        .color_follows_main = false,
        .cursor_color = .{ .kind = .default, .value = 0 },
        .text_color = .{ .kind = .default, .value = 0 },
    };
}

fn emptyCursorTrailRect() contract.CursorTrailRect {
    return .{ .extent = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 }, .opacity = 0, .color = .{ .r = 0, .g = 0, .b = 0 } };
}

fn testCursorPresentation(shape: contract.CursorShape, col: u16, row: u16, rgb: contract.Rgba8) contract.CursorPresentation {
    return .{
        .focused = true,
        .visible = true,
        .blink = false,
        .shape = shape,
        .cursor_opacity = 255,
        .text_blink_opacity = 255,
        .cursor_color = .{ .kind = .rgb, .value = (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b },
        .cursor_text_color = .{ .kind = .default, .value = 0 },
        .default_foreground = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b },
        .default_background = .{ .r = 0, .g = 0, .b = 0 },
        .primary_extent = .{ .row = row, .col = col, .rows = 1, .cols = 1 },
        .extra_cursors = [_]contract.ExtraCursorPresentation{emptyExtraCursorPresentation()} ** contract.max_extra_cursors,
        .extra_cursor_count = 0,
        .trail = .{ .rects = [_]contract.CursorTrailRect{emptyCursorTrailRect()} ** contract.max_cursor_trail_rects, .count = 0 },
    };
}

fn countGroupSpriteDraws(groups: []const contract.GlyphGroup, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) usize {
    var count: usize = 0;
    for (groups) |group| {
        if (classifyGroupLead(damage, grid_metrics, group) != .draw) continue;
        count += 1;
    }
    return count;
}

fn countCurlyUnderlineSprites(cells: []const contract.RenderableCell, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) usize {
    var count: usize = 0;
    for (cells) |cell| {
        if (cell.continuation) continue;
        if (!scene_damage.includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) continue;
        if (!cell.underline) continue;
        if (cell.underline_style != .curly) continue;
        count += 1;
    }
    return count;
}

fn classifyIconSpan(group: contract.GlyphGroup, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, next_group_cell: ?u32) IconSpan {
    if (group.kind != .icon) return .keep_kind;
    if (cell_metrics.cell_w_px == 0) return .keep_zero_width;
    const desired = desiredIconCells(group, cell_metrics.cell_w_px);
    if (desired <= group.cell_span) return .keep_current_span;

    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const row_end = ((group.first_cell / cols) + 1) * cols;
    const next = next_group_cell orelse row_end;
    const available_end = @min(row_end, next);
    if (available_end <= group.first_cell) return .keep_no_space;
    return .expand;
}

const SpriteDrawInput = struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    placement: contract.GlyphPlacement = .{},
    color: contract.Rgba8,
    first_cell: u32,
    cell_span: u8,
};

const GroupLead = enum(u2) {
    skip,
    draw,
};

const IconSpan = enum(u3) {
    keep_kind,
    keep_zero_width,
    keep_current_span,
    keep_no_space,
    expand,
};

fn classifyGroupLead(damage: scene_damage.NormalizedDamage, grid_metrics: contract.GridMetrics, group: contract.GlyphGroup) GroupLead {
    if (!scene_damage.includeSpan(damage, grid_metrics, group.first_cell, group.cell_span)) return .skip;
    return .draw;
}

fn appendGroupSpriteDraws(
    assembly: *SceneAssembly,
    cache: *atlas_cache.OwnedAtlasCache,
    cells: []const contract.RenderableCell,
    groups: []const contract.GlyphGroup,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: scene_damage.NormalizedDamage,
) !void {
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const cell_w = @as(i32, @intCast(cell_metrics.cell_w_px));
    const cell_h = @as(i32, @intCast(cell_metrics.cell_h_px));
    for (groups, 0..) |group, group_idx| {
        if (classifyGroupLead(damage, grid_metrics, group) != .draw) continue;
        const next_group_cell = if (group_idx + 1 < groups.len) groups[group_idx + 1].first_cell else null;
        const scene_group = iconGroupWithAvailableSpace(group, cell_metrics, grid_metrics, next_group_cell);
        const first_cell = scene_group.first_cell;
        const width_cells = @max(scene_group.cell_span, 1);
        const req = rasterizer.requestForGroup(scene_group, cell_metrics);
        const col = first_cell % cols;
        const row = first_cell / cols;
        try assembly.appendRasterizedSpriteDraw(cache, req, .{
            .x_px = @as(i32, @intCast(col)) * cell_w,
            .y_px = @as(i32, @intCast(row)) * cell_h,
            .width_px = @intCast(@as(u32, width_cells) * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .placement = group.placement,
            .color = spriteColorForGroup(cells, group.first_cell),
            .first_cell = group.first_cell,
            .cell_span = scene_group.cell_span,
        });
    }
}

fn appendCurlyUnderlineSprites(assembly: *SceneAssembly, cache: *atlas_cache.OwnedAtlasCache, cells: []const contract.RenderableCell, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) !void {
    const deco = scene_rects.decorationGeometryForCellMetrics(cell_metrics);
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    for (cells) |cell| {
        if (cell.continuation) continue;
        if (!cell.underline) continue;
        if (cell.underline_style != .curly) continue;
        if (!scene_damage.includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) continue;
        const col = cell.first_cell % cols;
        const row = cell.first_cell / cols;
        const base_x = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
        const base_y = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
        const width_px: u16 = @intCast(@as(u32, @max(cell.cell_span, 1)) * @as(u32, cell_metrics.cell_w_px));
        try assembly.appendUndercurl(cache, cell, base_x, base_y, width_px, deco, cell_metrics, underlineDrawColor(cell));
    }
}

fn saturatingSub(a: u16, b: u16) u16 {
    return if (a > b) a - b else 0;
}

pub fn spriteDrawColor(cell: contract.RenderableCell) contract.Rgba8 {
    return textStyleColor(cell.fg, cell.dim, cell.invisible);
}

pub fn underlineDrawColor(cell: contract.RenderableCell) contract.Rgba8 {
    const base = if (cell.underline_color.a == 0) cell.fg else cell.underline_color;
    return textStyleColor(base, cell.dim, cell.invisible);
}

fn spriteColorForGroup(cells: []const contract.RenderableCell, first_cell: u32) contract.Rgba8 {
    if (findCellByFirstCell(cells, first_cell)) |cell| return spriteDrawColor(cell);
    return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
}

fn textStyleColor(color: contract.Rgba8, dim: bool, invisible: bool) contract.Rgba8 {
    if (invisible) return .{ .r = color.r, .g = color.g, .b = color.b, .a = 0 };
    if (!dim) return color;
    return .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = @intCast((@as(u16, color.a) * kitty_dim_opacity_numerator) / kitty_dim_opacity_denominator),
    };
}

fn findCellByFirstCell(cells: []const contract.RenderableCell, first_cell: u32) ?contract.RenderableCell {
    var lo: u32 = 0;
    var hi = count32(cells);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cell = cells[@intCast(mid)];
        if (cell.first_cell < first_cell) {
            lo = mid + 1;
        } else if (cell.first_cell > first_cell) {
            hi = mid;
        } else {
            return cell;
        }
    }
    return null;
}

fn iconGroupWithAvailableSpace(group: contract.GlyphGroup, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, next_group_cell: ?u32) contract.GlyphGroup {
    if (classifyIconSpan(group, cell_metrics, grid_metrics, next_group_cell) != .expand) return group;

    const desired = desiredIconCells(group, cell_metrics.cell_w_px);
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const row_end = ((group.first_cell / cols) + 1) * cols;
    const next = next_group_cell orelse row_end;
    const available_end = @min(row_end, next);
    const available_cells: u8 = @intCast(@min(available_end - group.first_cell, std.math.maxInt(u8)));
    const cell_span = @min(desired, available_cells);
    if (cell_span <= group.cell_span) return group;

    var out = group;
    out.cell_span = cell_span;
    out.placement.advance_px = @max(out.placement.advance_px, @as(f32, @floatFromInt(@as(u32, cell_span) * @as(u32, cell_metrics.cell_w_px))));
    if (out.glyphs.len > 0) out.sprite_key = sprite_key.hashGlyphSequence(out.glyphs[0].face_id, out.glyphs, cell_span, cell_metrics);
    return out;
}

fn desiredIconCells(group: contract.GlyphGroup, cell_w: u16) u8 {
    const max_cells: u8 = 5;
    const advance = @max(group.placement.advance_px, @as(f32, @floatFromInt(cell_w)));
    const raw = @as(u32, @intFromFloat(std.math.ceil(advance / @as(f32, @floatFromInt(cell_w)))));
    return @intCast(std.math.clamp(raw, @as(u32, @max(group.cell_span, 1)), @as(u32, max_cells)));
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

fn count16(items: anytype) u16 {
    std.debug.assert(items.len <= std.math.maxInt(u16));
    return @intCast(items.len);
}

test "scene builds ordered sprite draws from groups" {
    const cell = contract.RenderableCell{
        .text_id = .{ .value = 0 },
        .first_cell = 3,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 9, .g = 8, .b = 7, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const group = contract.GlyphGroup{
        .first_cell = 0,
        .cell_span = 2,
        .glyphs = &.{},
        .sprite_key = .{ .value = 99 },
        .kind = .normal,
    };
    var owned = try buildSceneWithOptions(std.testing.allocator, &.{cell}, &.{group}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 10 }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.raster_requests));
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.background_draws));
    try std.testing.expectEqual(@as(u32, 0), count32(owned.scene.decoration_draws));
    try std.testing.expectEqual(@as(u16, 16), owned.scene.sprite_draws[0].width_px);
    try std.testing.expectEqual(@as(u64, 99), owned.scene.sprite_draws[0].sprite.key.value);
}

test "scene emits background draws from non-continuation cells" {
    const cells = [_]contract.RenderableCell{
        .{
            .text_id = .{ .value = 0 },
            .first_cell = 0,
            .cell_span = 2,
            .style = .regular,
            .presentation = .any,
            .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .bg = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        },
        .{
            .text_id = .{ .value = 1 },
            .first_cell = 1,
            .cell_span = 1,
            .style = .regular,
            .presentation = .any,
            .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .bg = .{ .r = 4, .g = 5, .b = 6, .a = 255 },
            .continuation = true,
        },
    };
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 2 }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.background_draws));
    try std.testing.expectEqual(@as(u16, 16), owned.scene.background_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 1), owned.scene.background_draws[0].color.r);
}

test "scene merges adjacent same-color background cells on one row" {
    const bg = contract.Rgba8{ .r = 1, .g = 2, .b = 3, .a = 255 };
    const cells = [_]contract.RenderableCell{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .style = .regular, .presentation = .any, .fg = bg, .bg = bg },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .style = .regular, .presentation = .any, .fg = bg, .bg = bg },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .style = .regular, .presentation = .any, .fg = bg, .bg = bg },
    };
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 3, .rows = 1 }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.background_draws));
    try std.testing.expectEqual(@as(u16, 24), owned.scene.background_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 3), owned.scene.background_draws[0].cell_span);
}

test "scene keeps distinct background spans across color changes" {
    const bg_a = contract.Rgba8{ .r = 1, .g = 2, .b = 3, .a = 255 };
    const bg_b = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    const cells = [_]contract.RenderableCell{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .style = .regular, .presentation = .any, .fg = bg_a, .bg = bg_a },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .style = .regular, .presentation = .any, .fg = bg_a, .bg = bg_a },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .style = .regular, .presentation = .any, .fg = bg_b, .bg = bg_b },
        .{ .text_id = .{ .value = 3 }, .first_cell = 3, .cell_span = 1, .style = .regular, .presentation = .any, .fg = bg_a, .bg = bg_a },
    };
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 4, .rows = 1 }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(u32, 3), count32(owned.scene.background_draws));
    try std.testing.expectEqual(@as(u16, 16), owned.scene.background_draws[0].width_px);
    try std.testing.expectEqual(@as(i32, 16), owned.scene.background_draws[1].x_px);
    try std.testing.expectEqual(@as(i32, 24), owned.scene.background_draws[2].x_px);
}

test "scene emits explicit clears for transparent default backgrounds on partial damage" {
    const transparent_bg = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const fg = contract.Rgba8{ .r = 200, .g = 200, .b = 200, .a = 255 };
    const cells = [_]contract.RenderableCell{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .style = .regular, .presentation = .any, .fg = fg, .bg = transparent_bg },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .style = .regular, .presentation = .any, .fg = fg, .bg = transparent_bg },
    };
    const dirty_rows = [_]bool{true};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{1};
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 2, .rows = 1 }, .{
        .damage = .{
            .full = false,
            .dirty_rows = &dirty_rows,
            .dirty_cols_start = &dirty_starts,
            .dirty_cols_end = &dirty_ends,
        },
    });
    defer owned.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.clear_draws));
    try std.testing.expectEqual(@as(u16, 16), owned.scene.clear_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 255), owned.scene.clear_draws[0].color.a);
    try std.testing.expectEqual(@as(u32, 0), count32(owned.scene.background_draws));
}

test "scene cursor draws emit shared cursor geometry" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    const cell_metrics = contract.CellMetrics{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 };
    const underline_cursor = testCursorPresentation(.underline, 2, 1, color);
    const underline = try scene_rects.cursorDraws(std.testing.allocator, underline_cursor, cell_metrics);
    defer std.testing.allocator.free(underline);
    try std.testing.expectEqual(@as(u32, @intCast(scene_rects.cursorDrawCount(.underline))), count32(underline));
    try std.testing.expectEqual(@as(i32, 16), underline[0].x_px);
    try std.testing.expectEqual(@as(u16, 8), underline[0].width_px);
    try std.testing.expectEqual(color.r, underline[0].color.r);

    const hollow_cursor = testCursorPresentation(.hollow, 0, 0, color);
    const hollow = try scene_rects.cursorDraws(std.testing.allocator, hollow_cursor, cell_metrics);
    defer std.testing.allocator.free(hollow);
    try std.testing.expectEqual(@as(u32, @intCast(scene_rects.cursorDrawCount(.hollow))), count32(hollow));
}

test "scene build options include cursor draws" {
    const color = contract.Rgba8{ .r = 7, .g = 8, .b = 9, .a = 255 };
    var owned = try buildSceneWithOptions(std.testing.allocator, &.{}, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 4 }, .{
        .cursor = testCursorPresentation(.beam, 3, 2, color),
    });
    defer owned.deinit();
    try std.testing.expectEqual(@as(u32, @intCast(scene_rects.cursorDrawCount(.beam))), count32(owned.scene.cursor_draws));
    try std.testing.expectEqual(@as(i32, 24), owned.scene.cursor_draws[0].x_px);
    try std.testing.expectEqual(@as(i32, 32), owned.scene.cursor_draws[0].y_px);
    try std.testing.expectEqual(color.g, owned.scene.cursor_draws[0].color.g);
}

test "scene stores cursor presentation owner" {
    var presentation = testCursorPresentation(.beam, 3, 2, .{ .r = 4, .g = 5, .b = 6, .a = 255 });
    presentation.blink = true;
    presentation.cursor_opacity = 200;
    presentation.text_blink_opacity = 150;
    presentation.cursor_color = .{ .kind = .rgb, .value = 0x010203 };
    presentation.cursor_text_color = .{ .kind = .indexed, .value = 7 };
    presentation.default_background = .{ .r = 7, .g = 8, .b = 9 };
    var owned = try buildSceneWithOptions(std.testing.allocator, &.{}, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 4 }, .{
        .cursor = presentation,
    });
    defer owned.deinit();
    try std.testing.expect(owned.cursor_presentation != null);
    try std.testing.expectEqual(@as(u16, 3), owned.cursor_presentation.?.primary_extent.col);
    try std.testing.expectEqual(@as(u8, 200), owned.cursor_presentation.?.cursor_opacity);
}

test "scene cursor primitive metadata uses grid width for non-zero-row multicell beam" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    var cursor = testCursorPresentation(.beam, 2, 1, color);
    cursor.primary_extent.cols = 3;
    cursor.primary_extent.rows = 2;
    var owned = try buildSceneWithOptions(std.testing.allocator, &.{}, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 10, .rows = 4 }, .{ .cursor = cursor });
    defer owned.deinit();
    try std.testing.expectEqual(@as(u32, 12), owned.cursor_fill_rects[0].first_cell);
    try std.testing.expectEqual(@as(u8, 6), owned.cursor_fill_rects[0].cell_span);
}

test "scene cursor primitive metadata uses full covered extent for hollow edges" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    var cursor = testCursorPresentation(.hollow, 4, 2, color);
    cursor.primary_extent.cols = 2;
    cursor.primary_extent.rows = 3;
    var owned = try buildSceneWithOptions(std.testing.allocator, &.{}, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 12, .rows = 5 }, .{ .cursor = cursor });
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 4), owned.cursor_fill_rects.len);
    for (owned.cursor_fill_rects) |rect| {
        try std.testing.expectEqual(@as(u32, 28), rect.first_cell);
        try std.testing.expectEqual(@as(u8, 6), rect.cell_span);
    }
}

test "scene cursor trail primitive metadata uses grid width and full extent" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    var cursor = testCursorPresentation(.beam, 0, 0, color);
    cursor.visible = false;
    cursor.trail.count = 1;
    cursor.trail.rects[0] = .{ .extent = .{ .row = 3, .col = 5, .rows = 2, .cols = 4 }, .opacity = 12, .color = .{ .r = 1, .g = 2, .b = 3 } };
    var owned = try buildSceneWithOptions(std.testing.allocator, &.{}, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 20, .rows = 6 }, .{ .cursor = cursor });
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), owned.cursor_trail_rects.len);
    try std.testing.expectEqual(@as(u32, 65), owned.cursor_trail_rects[0].first_cell);
    try std.testing.expectEqual(@as(u8, 8), owned.cursor_trail_rects[0].cell_span);
}

test "hidden cursor emits trail primitives only" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    var cursor = testCursorPresentation(.block, 1, 1, color);
    cursor.visible = false;
    cursor.trail.count = 1;
    cursor.trail.rects[0] = .{ .extent = .{ .row = 2, .col = 3, .rows = 1, .cols = 2 }, .opacity = 12, .color = .{ .r = 1, .g = 2, .b = 3 } };
    var owned = try buildSceneWithOptions(std.testing.allocator, &.{}, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 10, .rows = 4 }, .{ .cursor = cursor });
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 0), owned.scene.cursor_draws.len);
    try std.testing.expectEqual(@as(usize, 0), owned.cursor_fill_rects.len);
    try std.testing.expectEqual(@as(usize, 0), owned.cursor_text_recolor_spans.len);
    try std.testing.expectEqual(@as(usize, 1), owned.cursor_trail_rects.len);
}

test "scene damage filters clean rows" {
    const color = contract.Rgba8{ .r = 1, .g = 2, .b = 3, .a = 255 };
    const cells = [_]contract.RenderableCell{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = color },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = color },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = color },
        .{ .text_id = .{ .value = 3 }, .first_cell = 3, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = color },
    };
    const groups = [_]contract.GlyphGroup{
        .{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 1 }, .kind = .normal },
        .{ .first_cell = 3, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 2 }, .kind = .normal },
    };
    const dirty_rows = [_]bool{ false, true };
    const dirty_starts = [_]u16{ 0, 0 };
    const dirty_ends = [_]u16{ 0, 1 };
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &groups, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 2, .rows = 2 }, .{
        .damage = .{
            .full = false,
            .dirty_rows = &dirty_rows,
            .dirty_cols_start = &dirty_starts,
            .dirty_cols_end = &dirty_ends,
        },
    });
    defer owned.deinit();
    try std.testing.expect(!owned.scene.full_redraw);
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.clear_draws));
    try std.testing.expectEqual(@as(u16, 16), owned.scene.clear_draws[0].width_px);
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.background_draws));
    try std.testing.expectEqual(@as(u16, 16), owned.scene.background_draws[0].width_px);
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 3), owned.scene.sprite_draws[0].first_cell);
}

test "scene emits shared-geometry decoration draws from cells" {
    const cells = [_]contract.RenderableCell{.{
        .text_id = .{ .value = 0 },
        .first_cell = 1,
        .cell_span = 2,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .underline_color = .{ .r = 9, .g = 8, .b = 7, .a = 255 },
        .underline = true,
        .strikethrough = true,
    }};
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 13 }, .{ .cols = 4, .rows = 1 }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(u32, 2), count32(owned.scene.decoration_draws));
    try std.testing.expectEqual(contract.DecorationKind.underline, owned.scene.decoration_draws[0].kind);
    try std.testing.expectEqual(@as(i32, 8), owned.scene.decoration_draws[0].x_px);
    try std.testing.expectEqual(@as(u16, 16), owned.scene.decoration_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 9), owned.scene.decoration_draws[0].color.r);
    try std.testing.expectEqual(contract.DecorationKind.strikethrough, owned.scene.decoration_draws[1].kind);
}

test "scene merges contiguous straight underline spans" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    const cells = [_]contract.RenderableCell{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .underline = true },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .underline = true },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .underline = true },
    };
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 13 }, .{ .cols = 3, .rows = 1 }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.decoration_draws));
    try std.testing.expectEqual(@as(u16, 24), owned.scene.decoration_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 3), owned.scene.decoration_draws[0].cell_span);
}

test "scene double underline count and geometry stay aligned" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    const cell_metrics = contract.CellMetrics{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 13 };
    const deco = scene_rects.decorationGeometryForCellMetrics(cell_metrics);
    const cells = [_]contract.RenderableCell{.{
        .text_id = .{ .value = 0 },
        .first_cell = 0,
        .cell_span = 2,
        .style = .regular,
        .presentation = .any,
        .fg = color,
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .underline = true,
        .underline_style = .double,
    }};
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &.{}, &.{}, cell_metrics, .{ .cols = 2, .rows = 1 }, .{});
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), scene_rects.countUnderlineDecorationDraws(cell_metrics.cell_w_px * 2, deco.underline_h_px, .double));
    try std.testing.expectEqual(@as(u32, 2), count32(owned.scene.decoration_draws));
    try std.testing.expectEqual(contract.DecorationKind.underline, owned.scene.decoration_draws[0].kind);
    try std.testing.expectEqual(contract.DecorationKind.underline, owned.scene.decoration_draws[1].kind);
    try std.testing.expectEqual(@as(i32, 12), owned.scene.decoration_draws[0].y_px);
    try std.testing.expectEqual(@as(i32, 14), owned.scene.decoration_draws[1].y_px);
    try std.testing.expectEqual(@as(u16, 16), owned.scene.decoration_draws[0].width_px);
    try std.testing.expectEqual(@as(u16, 16), owned.scene.decoration_draws[1].width_px);
}

test "scene emits undercurl sprite for curly underline" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    const cells = [_]contract.RenderableCell{.{
        .text_id = .{ .value = 0 },
        .first_cell = 0,
        .cell_span = 4,
        .style = .regular,
        .presentation = .any,
        .fg = color,
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .underline = true,
        .underline_style = .curly,
    }};
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 13 }, .{ .cols = 4, .rows = 1 }, .{});
    defer owned.deinit();

    try std.testing.expectEqual(@as(u32, 0), count32(owned.scene.decoration_draws));
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.sprite_draws));
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.raster_requests));
    try std.testing.expectEqual(contract.SpriteRasterKind.undercurl, owned.scene.raster_requests[0].kind);
    try std.testing.expectEqual(@as(u16, 32), owned.scene.sprite_draws[0].width_px);
    try std.testing.expect(owned.scene.raster_requests[0].decoration.amplitude_px >= 1);
}

test "scene dotted underline geometry stays aligned with counted capacity" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    const cell_metrics = contract.CellMetrics{ .cell_w_px = 9, .cell_h_px = 16, .baseline_px = 13 };
    const deco = scene_rects.decorationGeometryForCellMetrics(cell_metrics);
    const cells = [_]contract.RenderableCell{.{
        .text_id = .{ .value = 0 },
        .first_cell = 0,
        .cell_span = 2,
        .style = .regular,
        .presentation = .any,
        .fg = color,
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .underline = true,
        .underline_style = .dotted,
    }};
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &.{}, &.{}, cell_metrics, .{ .cols = 2, .rows = 1 }, .{});
    defer owned.deinit();

    const width_px: u16 = cell_metrics.cell_w_px * 2;
    try std.testing.expectEqual(scene_rects.countUnderlineDecorationDraws(width_px, deco.underline_h_px, .dotted), owned.scene.decoration_draws.len);
    try std.testing.expectEqual(@as(u32, 9), count32(owned.scene.decoration_draws));
    for (owned.scene.decoration_draws, 0..) |draw, index| {
        try std.testing.expectEqual(contract.DecorationKind.underline_dotted, draw.kind);
        try std.testing.expectEqual(@as(i32, @intCast(index * 2)), draw.x_px);
        try std.testing.expectEqual(deco.underline_y_px, draw.y_px);
        try std.testing.expectEqual(deco.underline_h_px, draw.height_px);
        try std.testing.expectEqual(@as(u16, 1), draw.width_px);
    }
}

test "scene dashed underline geometry stays aligned with counted capacity" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    const cell_metrics = contract.CellMetrics{ .cell_w_px = 17, .cell_h_px = 16, .baseline_px = 13 };
    const deco = scene_rects.decorationGeometryForCellMetrics(cell_metrics);
    const cells = [_]contract.RenderableCell{.{
        .text_id = .{ .value = 0 },
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = color,
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .underline = true,
        .underline_style = .dashed,
    }};
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &.{}, &.{}, cell_metrics, .{ .cols = 1, .rows = 1 }, .{});
    defer owned.deinit();

    try std.testing.expectEqual(scene_rects.countUnderlineDecorationDraws(cell_metrics.cell_w_px, deco.underline_h_px, .dashed), owned.scene.decoration_draws.len);
    try std.testing.expectEqual(@as(u32, 3), count32(owned.scene.decoration_draws));
    try std.testing.expectEqual(contract.DecorationKind.underline_dashed, owned.scene.decoration_draws[0].kind);
    try std.testing.expectEqual(@as(i32, 0), owned.scene.decoration_draws[0].x_px);
    try std.testing.expectEqual(@as(u16, 5), owned.scene.decoration_draws[0].width_px);
    try std.testing.expectEqual(@as(i32, 7), owned.scene.decoration_draws[1].x_px);
    try std.testing.expectEqual(@as(u16, 5), owned.scene.decoration_draws[1].width_px);
    try std.testing.expectEqual(@as(i32, 14), owned.scene.decoration_draws[2].x_px);
    try std.testing.expectEqual(@as(u16, 3), owned.scene.decoration_draws[2].width_px);
    for (owned.scene.decoration_draws) |draw| {
        try std.testing.expectEqual(contract.DecorationKind.underline_dashed, draw.kind);
        try std.testing.expectEqual(deco.underline_y_px, draw.y_px);
        try std.testing.expectEqual(deco.underline_h_px, draw.height_px);
    }
}

test "scene merges contiguous strikethrough spans" {
    const color = contract.Rgba8{ .r = 1, .g = 2, .b = 3, .a = 255 };
    const cells = [_]contract.RenderableCell{
        .{
            .text_id = .{ .value = 0 },
            .first_cell = 0,
            .cell_span = 1,
            .style = .regular,
            .presentation = .any,
            .fg = color,
            .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .strikethrough = true,
        },
        .{
            .text_id = .{ .value = 1 },
            .first_cell = 1,
            .cell_span = 1,
            .style = .regular,
            .presentation = .any,
            .fg = color,
            .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .strikethrough = true,
        },
    };
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 13 }, .{ .cols = 2, .rows = 1 }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.decoration_draws));
    try std.testing.expectEqual(contract.DecorationKind.strikethrough, owned.scene.decoration_draws[0].kind);
    try std.testing.expectEqual(@as(u16, 16), owned.scene.decoration_draws[0].width_px);
}

test "scene carries group placement offsets into sprite draw" {
    const group = contract.GlyphGroup{
        .first_cell = 1,
        .cell_span = 1,
        .glyphs = &.{},
        .placement = .{ .x_offset_px = -1, .y_offset_px = 2, .advance_px = 8 },
        .sprite_key = .{ .value = 77 },
        .kind = .normal,
    };
    var owned = try buildSceneWithOptions(std.testing.allocator, &.{}, &.{group}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 10 }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(i32, 8), owned.scene.sprite_draws[0].x_px);
    try std.testing.expectEqual(@as(i32, 0), owned.scene.sprite_draws[0].y_px);
    try std.testing.expectEqual(@as(f32, 8), owned.scene.sprite_draws[0].placement.advance_px);
}

test "scene extends wide icon groups into available blank cells" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    const cells = [_]contract.RenderableCell{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
    };
    const glyph = contract.GlyphInstance{ .face_id = .{ .value = 1 }, .glyph_id = 7, .cluster_index = 0, .x_advance_px = 16 };
    const icon = contract.GlyphGroup{
        .first_cell = 0,
        .cell_span = 1,
        .glyphs = &.{glyph},
        .placement = .{ .advance_px = 16 },
        .sprite_key = .{ .value = 7 },
        .kind = .icon,
    };
    const next = contract.GlyphGroup{ .first_cell = 2, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 9 }, .kind = .normal };
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &.{ icon, next }, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 3, .rows = 1 }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(u16, 16), owned.scene.sprite_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 2), owned.scene.sprite_draws[0].cell_span);
    try std.testing.expectEqual(@as(u16, 16), owned.scene.raster_requests[0].width_px);
}

test "scene positions sprite draws by grid columns" {
    const group = contract.GlyphGroup{
        .first_cell = 7,
        .cell_span = 1,
        .glyphs = &.{},
        .sprite_key = .{ .value = 1 },
        .kind = .normal,
    };
    var owned = try buildSceneWithOptions(std.testing.allocator, &.{}, &.{group}, &.{}, .{ .cell_w_px = 9, .cell_h_px = 17, .baseline_px = 13 }, .{ .cols = 5, .rows = 2 }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(i32, 18), owned.scene.sprite_draws[0].x_px);
    try std.testing.expectEqual(@as(i32, 17), owned.scene.sprite_draws[0].y_px);
}

test "scene reuses atlas slots for repeated sprite keys" {
    const groups = [_]contract.GlyphGroup{
        .{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 7 }, .kind = .normal },
        .{ .first_cell = 1, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 7 }, .kind = .normal },
    };
    var cache = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 8);
    defer cache.deinit();
    var owned = try buildSceneWithAtlasCacheOptions(std.testing.allocator, &.{}, &groups, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 8 }, &cache, .{});
    defer owned.deinit();
    try std.testing.expectEqual(owned.scene.sprite_draws[0].sprite.slot, owned.scene.sprite_draws[1].sprite.slot);
    try std.testing.expectEqual(@as(u32, 1), count32(owned.scene.raster_requests));
    try std.testing.expectEqual(@as(u32, 1), cache.len);
}

test "scene does not request raster for cache hit" {
    const group = contract.GlyphGroup{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 21 }, .kind = .normal };
    var cache = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 8);
    defer cache.deinit();
    _ = cache.reserve(group.sprite_key, false);
    try std.testing.expect(cache.markRendered(group.sprite_key));
    var owned = try buildSceneWithAtlasCacheOptions(std.testing.allocator, &.{}, &.{group}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 8 }, &cache, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(u32, 0), count32(owned.scene.raster_requests));
}

test "borrowed scene reuses retained draw list storage" {
    const fg = contract.Rgba8{ .r = 1, .g = 2, .b = 3, .a = 255 };
    const bg = contract.Rgba8{ .r = 4, .g = 5, .b = 6, .a = 255 };
    const cells = [_]contract.RenderableCell{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .style = .regular, .presentation = .any, .fg = fg, .bg = bg, .underline = true, .underline_style = .straight },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .style = .regular, .presentation = .any, .fg = fg, .bg = bg },
    };
    const groups = [_]contract.GlyphGroup{
        .{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .placement = .{}, .sprite_key = .{ .value = 7 }, .kind = .normal },
    };
    var cache = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 8);
    defer cache.deinit();
    var scratch = RetainedScratch{};
    defer scratch.deinit(std.testing.allocator);

    var first = try buildBorrowedSceneWithAtlasCacheOptions(
        std.testing.allocator,
        &scratch,
        &cells,
        &groups,
        &.{},
        .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
        .{ .cols = 2, .rows = 1 },
        &cache,
        .{ .cursor = testCursorPresentation(.beam, 0, 0, fg) },
    );
    defer first.deinit();

    const sprite_ptr = first.scene.sprite_draws.ptr;
    const background_ptr = first.scene.background_draws.ptr;
    const decoration_ptr = first.scene.decoration_draws.ptr;
    const cursor_ptr = first.scene.cursor_draws.ptr;

    var second = try buildBorrowedSceneWithAtlasCacheOptions(
        std.testing.allocator,
        &scratch,
        &cells,
        &groups,
        &.{},
        .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
        .{ .cols = 2, .rows = 1 },
        &cache,
        .{ .cursor = testCursorPresentation(.beam, 0, 0, fg) },
    );
    defer second.deinit();

    try std.testing.expectEqual(sprite_ptr, second.scene.sprite_draws.ptr);
    try std.testing.expectEqual(background_ptr, second.scene.background_draws.ptr);
    try std.testing.expectEqual(decoration_ptr, second.scene.decoration_draws.ptr);
    try std.testing.expectEqual(cursor_ptr, second.scene.cursor_draws.ptr);
}

test "text scene applies kitty dim opacity at render-time for sprite draws" {
    const dim_fg = contract.Rgba8{ .r = 100, .g = 150, .b = 200, .a = 255 };
    const transparent_bg = contract.Rgba8{ .r = 0x44, .g = 0x55, .b = 0x66, .a = 0 };
    const groups = [_]contract.GlyphGroup{
        .{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 1 }, .kind = .normal },
    };
    const cells = [_]contract.RenderableCell{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .style = .regular, .presentation = .any, .dim = true, .fg = dim_fg, .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .style = .regular, .presentation = .any, .invisible = true, .fg = .{ .r = 7, .g = 8, .b = 9, .a = 255 }, .bg = transparent_bg },
    };

    var owned = try buildSceneWithOptions(
        std.testing.allocator,
        &cells,
        &groups,
        &.{},
        .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
        .{ .cols = 2, .rows = 1 },
        .{ .damage = .{ .full = false, .dirty_rows = &[_]bool{true}, .dirty_cols_start = &[_]u16{0}, .dirty_cols_end = &[_]u16{1} } },
    );
    defer owned.deinit();

    try std.testing.expectEqual(@as(u8, dim_fg.r), owned.scene.sprite_draws[0].color.r);
    try std.testing.expectEqual(@as(u8, dim_fg.g), owned.scene.sprite_draws[0].color.g);
    try std.testing.expectEqual(@as(u8, dim_fg.b), owned.scene.sprite_draws[0].color.b);
    try std.testing.expectEqual(@as(u8, 102), owned.scene.sprite_draws[0].color.a);
    try std.testing.expectEqual(transparent_bg.r, owned.scene.clear_draws[0].color.r);
    try std.testing.expectEqual(transparent_bg.g, owned.scene.clear_draws[0].color.g);
    try std.testing.expectEqual(transparent_bg.b, owned.scene.clear_draws[0].color.b);
    try std.testing.expectEqual(@as(u8, 255), owned.scene.clear_draws[0].color.a);
}
