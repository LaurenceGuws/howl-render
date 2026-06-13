const std = @import("std");
const contract = @import("contract.zig");
const scene = @import("scene.zig");
const scene_damage = @import("scene_damage.zig");
const scene_rects = @import("scene_rects.zig");

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

pub fn appendBackgrounds(
    out: *std.ArrayListUnmanaged(contract.TextBackgroundDraw),
    cells: []const contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: Damage,
) void {
    scene_rects.appendBackgroundDrawsUnmanaged(out, cells, cell_metrics, grid_metrics, toSceneDamage(damage));
}

pub fn appendClears(
    out: *std.ArrayListUnmanaged(contract.TextClearDraw),
    cells: []const contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: Damage,
) void {
    scene_rects.appendClearDrawsUnmanaged(out, cells, cell_metrics, grid_metrics, toSceneDamage(damage));
}

pub fn appendCursor(out: *std.ArrayListUnmanaged(contract.TextCursorDraw), cursor: ?scene.CursorInput, cell_metrics: contract.CellMetrics, damage: Damage) void {
    scene_rects.appendCursorDrawsUnmanaged(out, cursor, toSceneDamage(damage), cell_metrics);
}

pub fn appendDecorations(
    out: *std.ArrayListUnmanaged(contract.TextDecorationDraw),
    cells: []const contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: Damage,
) void {
    scene_rects.appendRectDecorationDrawsUnmanaged(scene.underlineDrawColor, scene.spriteDrawColor, out, cells, cell_metrics, grid_metrics, toSceneDamage(damage));
}

fn toSceneDamage(damage: Damage) scene_damage.NormalizedDamage {
    return .{
        .full = damage.full,
        .dirty_rows = damage.dirty_rows,
        .dirty_cols_start = damage.dirty_cols_start,
        .dirty_cols_end = damage.dirty_cols_end,
    };
}
