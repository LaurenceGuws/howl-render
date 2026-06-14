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

pub fn appendBackground(
    out: *std.ArrayListUnmanaged(contract.TextBackgroundDraw),
    merge_live: *bool,
    merge_end_cell: *u32,
    cell: contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: Damage,
) void {
    scene_rects.appendBackgroundDrawCellUnmanaged(out, merge_live, merge_end_cell, cell, cell_metrics, grid_metrics, toSceneDamage(damage));
}

pub fn appendClears(
    out: *std.ArrayListUnmanaged(contract.TextClearDraw),
    clear_row_colors: []const contract.Rgba8,
    clear_row_matches: []const bool,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: Damage,
) void {
    scene_rects.appendClearRowDrawsUnmanaged(out, clear_row_colors, clear_row_matches, cell_metrics, grid_metrics, toSceneDamage(damage));
}

pub fn appendCursor(out: *std.ArrayListUnmanaged(contract.TextCursorDraw), cursor: ?scene.CursorInput, cell_metrics: contract.CellMetrics, damage: Damage) void {
    scene_rects.appendCursorDrawsUnmanaged(out, cursor, toSceneDamage(damage), cell_metrics);
}

pub fn noteClearColor(clear_row_colors: []contract.Rgba8, clear_row_matches: []bool, cell: contract.RenderableCell, grid_metrics: contract.GridMetrics, damage: Damage) void {
    scene_rects.noteClearColorCell(clear_row_colors, clear_row_matches, cell, grid_metrics, toSceneDamage(damage));
}

pub fn appendDecorations(
    out: *std.ArrayListUnmanaged(contract.TextDecorationDraw),
    cell: contract.RenderableCell,
    layout: scene_rects.RectDecorationLayout,
    damage: Damage,
) void {
    scene_rects.appendRectDecorationCellDrawsWithLayoutUnmanaged(scene.underlineDrawColor, scene.spriteDrawColor, out, cell, layout, toSceneDamage(damage));
}

pub fn appendRenderableRects(
    background_draws: *std.ArrayListUnmanaged(contract.TextBackgroundDraw),
    background_merge_live: *bool,
    background_merge_end_cell: *u32,
    clear_row_colors: []contract.Rgba8,
    clear_row_matches: []bool,
    decoration_draws: *std.ArrayListUnmanaged(contract.TextDecorationDraw),
    inline_background_ns: *u64,
    inline_clear_note_ns: *u64,
    inline_decoration_ns: *u64,
    cell: contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    decoration_layout: scene_rects.RectDecorationLayout,
    damage: Damage,
) void {
    const inline_background_start_ns = timeNowNs();
    appendBackground(background_draws, background_merge_live, background_merge_end_cell, cell, cell_metrics, grid_metrics, damage);
    inline_background_ns.* += elapsedSinceNs(inline_background_start_ns);

    const inline_clear_note_start_ns = timeNowNs();
    noteClearColor(clear_row_colors, clear_row_matches, cell, grid_metrics, damage);
    inline_clear_note_ns.* += elapsedSinceNs(inline_clear_note_start_ns);

    const inline_decoration_start_ns = timeNowNs();
    appendDecorations(decoration_draws, cell, decoration_layout, damage);
    inline_decoration_ns.* += elapsedSinceNs(inline_decoration_start_ns);
}

fn toSceneDamage(damage: Damage) scene_damage.NormalizedDamage {
    return .{
        .full = damage.full,
        .dirty_rows = damage.dirty_rows,
        .dirty_cols_start = damage.dirty_cols_start,
        .dirty_cols_end = damage.dirty_cols_end,
    };
}

fn timeNowNs() u64 {
    var timespec: std.c.timespec = undefined;
    switch (std.c.errno(std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &timespec))) {
        .SUCCESS => {},
        else => unreachable,
    }
    const seconds_ns = @as(u64, @intCast(timespec.sec)) * std.time.ns_per_s;
    return seconds_ns + @as(u64, @intCast(timespec.nsec));
}

fn elapsedSinceNs(start_ns: u64) u64 {
    const end_ns = timeNowNs();
    std.debug.assert(end_ns >= start_ns);
    return end_ns - start_ns;
}
