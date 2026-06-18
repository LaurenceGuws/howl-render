const std = @import("std");
const render = @import("../libhowl_render.zig");
const scene = @import("../scene.zig");
const scene_damage = @import("damage.zig");
const scene_rects = @import("rects.zig");

pub const Damage = struct {
    full: bool,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,

    pub fn init(damage: scene_damage.DamageInput, rows: u16) Damage {
        const normalized = scene_damage.normalizeDamage(damage, rows);
        return .{
            .full = normalized.full,
            .dirty_rows = normalized.dirty_rows,
            .dirty_cols_start = normalized.dirty_cols_start,
            .dirty_cols_end = normalized.dirty_cols_end,
        };
    }
};

pub fn borrowScene(allocator: std.mem.Allocator, damage: Damage, direct: anytype) scene.OwnedTextScene {
    return .{ .allocator = allocator, .scene = .{
        .full_redraw = damage.full,
        .clear_draws = direct.clear_draws.items,
        .background_draws = direct.background_draws.items,
        .sprite_draws = direct.sprite_draws.items,
        .decoration_draws = direct.decoration_draws.items,
        .cursor_draws = direct.cursor_draws.items,
        .raster_requests = &.{},
        .missing = direct.missing.items,
    }, .owned = false };
}

pub fn appendBackground(
    out: *std.ArrayListUnmanaged(render.TextBackgroundDraw),
    merge_live: *bool,
    merge_end_cell: *u32,
    cell: render.RenderableCell,
    cell_metrics: render.CellMetrics,
    grid_metrics: render.GridMetrics,
    damage: Damage,
) void {
    scene_rects.appendBackgroundDrawCellUnmanaged(out, merge_live, merge_end_cell, cell, cell_metrics, grid_metrics, toSceneDamage(damage));
}

pub fn appendClears(
    out: *std.ArrayListUnmanaged(render.TextClearDraw),
    clear_row_colors: []const render.Rgba8,
    clear_row_matches: []const bool,
    cell_metrics: render.CellMetrics,
    grid_metrics: render.GridMetrics,
    damage: Damage,
) void {
    scene_rects.appendClearRowDrawsUnmanaged(out, clear_row_colors, clear_row_matches, cell_metrics, grid_metrics, toSceneDamage(damage));
}

pub fn appendCursor(out: *std.ArrayListUnmanaged(render.TextCursorDraw), cursor: ?render.CursorPresentation, cell_metrics: render.CellMetrics, damage: Damage) void {
    scene_rects.appendCursorDrawsUnmanaged(out, cursor, toSceneDamage(damage), cell_metrics);
}

pub fn noteClearColor(clear_row_colors: []render.Rgba8, clear_row_matches: []bool, cell: render.RenderableCell, grid_metrics: render.GridMetrics, damage: Damage) void {
    scene_rects.noteClearColorCell(clear_row_colors, clear_row_matches, cell, grid_metrics, toSceneDamage(damage));
}

pub fn appendDecorations(
    out: *std.ArrayListUnmanaged(render.TextDecorationDraw),
    cell: render.RenderableCell,
    layout: scene_rects.RectDecorationLayout,
    damage: Damage,
) void {
    scene_rects.appendRectDecorationCellDrawsWithLayoutUnmanaged(scene.underlineDrawColor, scene.spriteDrawColor, out, cell, layout, toSceneDamage(damage));
}

pub fn appendRenderableRects(
    background_draws: *std.ArrayListUnmanaged(render.TextBackgroundDraw),
    background_merge_live: *bool,
    background_merge_end_cell: *u32,
    clear_row_colors: []render.Rgba8,
    clear_row_matches: []bool,
    decoration_draws: *std.ArrayListUnmanaged(render.TextDecorationDraw),
    cell: render.RenderableCell,
    cell_metrics: render.CellMetrics,
    grid_metrics: render.GridMetrics,
    decoration_layout: scene_rects.RectDecorationLayout,
    damage: Damage,
) void {
    appendBackground(background_draws, background_merge_live, background_merge_end_cell, cell, cell_metrics, grid_metrics, damage);
    noteClearColor(clear_row_colors, clear_row_matches, cell, grid_metrics, damage);
    appendDecorations(decoration_draws, cell, decoration_layout, damage);
}

fn toSceneDamage(damage: Damage) scene_damage.NormalizedDamage {
    return .{
        .full = damage.full,
        .dirty_rows = damage.dirty_rows,
        .dirty_cols_start = damage.dirty_cols_start,
        .dirty_cols_end = damage.dirty_cols_end,
    };
}
