const std = @import("std");
const render = @import("../text/draw_primitives.zig");
const draw_list = @import("../text/draw_list.zig");
const text_damage = @import("../text/damage.zig");
const rect_primitives = @import("../text/rect_primitives.zig");

pub const Damage = struct {
    full: bool,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,

    pub fn init(damage: text_damage.DamageInput, rows: u16) Damage {
        const normalized = text_damage.normalizeDamage(damage, rows);
        return .{
            .full = normalized.full,
            .dirty_rows = normalized.dirty_rows,
            .dirty_cols_start = normalized.dirty_cols_start,
            .dirty_cols_end = normalized.dirty_cols_end,
        };
    }
};

pub fn borrowDrawList(allocator: std.mem.Allocator, damage: Damage, direct: anytype) draw_list.OwnedTextDrawList {
    return .{ .allocator = allocator, .draw_list = .{
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
    grid_metrics: render.CellGridMetrics,
    damage: Damage,
) void {
    rect_primitives.appendBackgroundDrawCellUnmanaged(out, merge_live, merge_end_cell, cell, cell_metrics, grid_metrics, toDrawListDamage(damage));
}

pub fn appendClears(
    out: *std.ArrayListUnmanaged(render.TextClearDraw),
    clear_row_colors: []const render.Rgba8,
    clear_row_matches: []const bool,
    cell_metrics: render.CellMetrics,
    grid_metrics: render.CellGridMetrics,
    damage: Damage,
) void {
    rect_primitives.appendClearRowDrawsUnmanaged(out, clear_row_colors, clear_row_matches, cell_metrics, grid_metrics, toDrawListDamage(damage));
}

pub fn appendCursor(out: *std.ArrayListUnmanaged(render.TextCursorDraw), cursor: ?render.CursorPresentation, cell_metrics: render.CellMetrics, damage: Damage) void {
    rect_primitives.appendCursorDrawsUnmanaged(out, cursor, toDrawListDamage(damage), cell_metrics);
}

pub fn noteClearColor(clear_row_colors: []render.Rgba8, clear_row_matches: []bool, cell: render.RenderableCell, grid_metrics: render.CellGridMetrics, damage: Damage) void {
    rect_primitives.noteClearColorCell(clear_row_colors, clear_row_matches, cell, grid_metrics, toDrawListDamage(damage));
}

pub fn appendDecorations(
    out: *std.ArrayListUnmanaged(render.TextDecorationDraw),
    cell: render.RenderableCell,
    layout: rect_primitives.RectDecorationLayout,
    damage: Damage,
) void {
    rect_primitives.appendRectDecorationCellDrawsWithLayoutUnmanaged(draw_list.underlineDrawColor, draw_list.spriteDrawColor, out, cell, layout, toDrawListDamage(damage));
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
    grid_metrics: render.CellGridMetrics,
    decoration_layout: rect_primitives.RectDecorationLayout,
    damage: Damage,
) void {
    appendBackground(background_draws, background_merge_live, background_merge_end_cell, cell, cell_metrics, grid_metrics, damage);
    noteClearColor(clear_row_colors, clear_row_matches, cell, grid_metrics, damage);
    appendDecorations(decoration_draws, cell, decoration_layout, damage);
}

fn toDrawListDamage(damage: Damage) text_damage.NormalizedDamage {
    return .{
        .full = damage.full,
        .dirty_rows = damage.dirty_rows,
        .dirty_cols_start = damage.dirty_cols_start,
        .dirty_cols_end = damage.dirty_cols_end,
    };
}
