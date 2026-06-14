const std = @import("std");
const contract = @import("contract.zig");
const scene_damage = @import("scene_damage.zig");

const CursorDrawCount = u3;

const BackgroundLead = enum(u2) {
    skip,
    transparent,
    span,
};

const BackgroundNext = enum(u3) {
    merge,
    stop_continuation,
    stop_damage,
    stop_color,
    stop_row,
    stop_gap,
};

const ClearColorCell = enum(u2) {
    skip,
    match,
};

const DecorationLead = enum(u2) {
    skip,
    draw,
};

const DecorationAppend = enum(u2) {
    append,
    merge,
};

const CursorLead = enum(u2) {
    skip,
    draw,
};

const SteppedUnderlineCadence = struct {
    kind: contract.DecorationKind,
    segment_px: u16,
    step_px: u16,
};

pub const RectDecorationLayout = struct {
    grid_metrics: contract.GridMetrics,
    geometry: contract.DecorationGeometry,
    cols: u32,
    cell_w_px: u16,
    cell_h_px: u16,

    pub fn init(cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics) RectDecorationLayout {
        return .{
            .grid_metrics = grid_metrics,
            .geometry = decorationGeometryForCellMetrics(cell_metrics),
            .cols = @max(@as(u32, grid_metrics.cols), 1),
            .cell_w_px = cell_metrics.cell_w_px,
            .cell_h_px = cell_metrics.cell_h_px,
        };
    }
};

pub fn rectDecorationLayout(cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics) RectDecorationLayout {
    return .init(cell_metrics, grid_metrics);
}

pub fn countClearDraws(grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) usize {
    if (damage.full) return 0;
    const rows = @min(grid_metrics.rows, scene_damage.damageRowCount(damage));
    var count: usize = 0;
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        if (scene_damage.dirtyRowSpan(damage, grid_metrics, row) == null) continue;
        count += 1;
    }
    return count;
}

pub fn countCursorDraws(cursor: anytype, damage: scene_damage.NormalizedDamage) usize {
    const cursor_value = cursor orelse return 0;
    if (classifyCursorLead(damage, cursor_value) != .draw) return 0;
    return cursorDrawCount(cursor_value.shape);
}

pub fn cursorDrawCount(shape: anytype) usize {
    return @intCast(cursorDrawCountExact(shape));
}

pub fn countRectDecorationDraws(cells: []const contract.RenderableCell, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) usize {
    const deco = decorationGeometryForCellMetrics(cell_metrics);
    var count: usize = 0;
    for (cells) |cell| {
        if (classifyDecorationLead(damage, grid_metrics, cell) != .draw) continue;
        const width_px: u16 = @intCast(@as(u32, @max(cell.cell_span, 1)) * @as(u32, cell_metrics.cell_w_px));
        if (cell.underline and cell.underline_style != .curly) count += countUnderlineDecorationDraws(width_px, deco.underline_h_px, cell.underline_style);
        if (cell.strikethrough) count += 1;
    }
    return count;
}

pub fn appendBackgroundDraws(allocator: std.mem.Allocator, out: *std.ArrayList(contract.TextBackgroundDraw), cells: []const contract.RenderableCell, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) !void {
    const cell_len = count32(cells);
    var idx: u32 = 0;
    while (idx < cell_len) {
        const cell = cells[@intCast(idx)];
        const lead = classifyBackgroundLead(damage, grid_metrics, cell);
        if (lead == .skip or lead == .transparent) {
            idx += 1;
            continue;
        }
        const fill_color = cell.bg;
        const cols = @max(@as(u32, grid_metrics.cols), 1);
        const row: u16 = @intCast(cell.first_cell / cols);
        const span_first_cell = cell.first_cell;
        var span_cell_count: u32 = @max(cell.cell_span, 1);
        var next_idx = idx + 1;
        var span_end_cell = span_first_cell + span_cell_count;
        while (next_idx < cell_len) : (next_idx += 1) {
            const next = cells[@intCast(next_idx)];
            if (classifyBackgroundNext(damage, grid_metrics, row, fill_color, span_end_cell, next) != .merge) break;
            const next_span = @max(next.cell_span, 1);
            span_cell_count += next_span;
            span_end_cell += next_span;
        }

        const col: u16 = @intCast(cell.first_cell % cols);
        const base_x = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
        const base_y = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
        try out.append(allocator, .{
            .x_px = base_x,
            .y_px = base_y,
            .width_px = @intCast(span_cell_count * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .color = fill_color,
            .first_cell = span_first_cell,
            .cell_span = @intCast(@min(span_cell_count, @as(u32, std.math.maxInt(u8)))),
        });
        idx = next_idx;
    }
}

pub fn appendBackgroundDrawsUnmanaged(out: *std.ArrayListUnmanaged(contract.TextBackgroundDraw), cells: []const contract.RenderableCell, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) void {
    const cell_len = count32(cells);
    var idx: u32 = 0;
    while (idx < cell_len) {
        const cell = cells[@intCast(idx)];
        const lead = classifyBackgroundLead(damage, grid_metrics, cell);
        if (lead == .skip or lead == .transparent) {
            idx += 1;
            continue;
        }
        const fill_color = cell.bg;
        const cols = @max(@as(u32, grid_metrics.cols), 1);
        const row: u16 = @intCast(cell.first_cell / cols);
        const span_first_cell = cell.first_cell;
        var span_cell_count: u32 = @max(cell.cell_span, 1);
        var next_idx = idx + 1;
        var span_end_cell = span_first_cell + span_cell_count;
        while (next_idx < cell_len) : (next_idx += 1) {
            const next = cells[@intCast(next_idx)];
            if (classifyBackgroundNext(damage, grid_metrics, row, fill_color, span_end_cell, next) != .merge) break;
            const next_span = @max(next.cell_span, 1);
            span_cell_count += next_span;
            span_end_cell += next_span;
        }

        const col: u16 = @intCast(cell.first_cell % cols);
        const base_x = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
        const base_y = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
        out.appendAssumeCapacity(.{
            .x_px = base_x,
            .y_px = base_y,
            .width_px = @intCast(span_cell_count * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .color = fill_color,
            .first_cell = span_first_cell,
            .cell_span = @intCast(@min(span_cell_count, @as(u32, std.math.maxInt(u8)))),
        });
        idx = next_idx;
    }
}

pub fn appendBackgroundDrawCellUnmanaged(out: *std.ArrayListUnmanaged(contract.TextBackgroundDraw), merge_live: *bool, merge_end_cell: *u32, cell: contract.RenderableCell, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) void {
    const lead = classifyBackgroundLead(damage, grid_metrics, cell);
    if (lead == .skip) {
        merge_live.* = false;
        return;
    }
    if (lead == .transparent) {
        merge_live.* = false;
        return;
    }

    const span = @max(cell.cell_span, 1);
    if (merge_live.* and out.items.len != 0) {
        const last = &out.items[out.items.len - 1];
        const cols = @max(@as(u32, grid_metrics.cols), 1);
        const last_row: u16 = @intCast(last.first_cell / cols);
        const cell_row: u16 = @intCast(cell.first_cell / cols);
        if (sameRgba8(last.color, cell.bg) and last_row == cell_row and cell.first_cell == merge_end_cell.*) {
            last.width_px = @intCast(@as(u32, last.width_px) + @as(u32, span) * @as(u32, cell_metrics.cell_w_px));
            const merged_span = @as(u32, last.cell_span) + @as(u32, span);
            last.cell_span = @intCast(@min(merged_span, @as(u32, std.math.maxInt(u8))));
            merge_end_cell.* += span;
            return;
        }
    }

    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const col: u16 = @intCast(cell.first_cell % cols);
    const row: u16 = @intCast(cell.first_cell / cols);
    out.appendAssumeCapacity(.{
        .x_px = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px)),
        .y_px = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px)),
        .width_px = @intCast(@as(u32, span) * @as(u32, cell_metrics.cell_w_px)),
        .height_px = cell_metrics.cell_h_px,
        .color = cell.bg,
        .first_cell = cell.first_cell,
        .cell_span = cell.cell_span,
    });
    merge_live.* = true;
    merge_end_cell.* = cell.first_cell + span;
}

pub fn appendClearDraws(allocator: std.mem.Allocator, out: *std.ArrayList(contract.TextClearDraw), cells: []const contract.RenderableCell, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) !void {
    if (damage.full) return;
    const rows = @min(grid_metrics.rows, scene_damage.damageRowCount(damage));
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const dirty = scene_damage.dirtyRowSpan(damage, grid_metrics, row) orelse continue;
        const first_cell = dirty.firstCell(grid_metrics);
        const cell_span = dirty.cellSpan();
        const span_cells = @as(u32, @max(cell_span, 1));
        try out.append(allocator, .{
            .x_px = @as(i32, @intCast(dirty.start_col)) * @as(i32, @intCast(cell_metrics.cell_w_px)),
            .y_px = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px)),
            .width_px = @intCast(span_cells * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .color = clearColorForSpan(cells, grid_metrics, dirty),
            .first_cell = first_cell,
            .cell_span = cell_span,
        });
    }
}

pub fn appendClearDrawsUnmanaged(out: *std.ArrayListUnmanaged(contract.TextClearDraw), cells: []const contract.RenderableCell, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) void {
    if (damage.full) return;
    const rows = @min(grid_metrics.rows, scene_damage.damageRowCount(damage));
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const dirty = scene_damage.dirtyRowSpan(damage, grid_metrics, row) orelse continue;
        const first_cell = dirty.firstCell(grid_metrics);
        const cell_span = dirty.cellSpan();
        const span_cells = @as(u32, @max(cell_span, 1));
        out.appendAssumeCapacity(.{
            .x_px = @as(i32, @intCast(dirty.start_col)) * @as(i32, @intCast(cell_metrics.cell_w_px)),
            .y_px = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px)),
            .width_px = @intCast(span_cells * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .color = clearColorForSpan(cells, grid_metrics, dirty),
            .first_cell = first_cell,
            .cell_span = cell_span,
        });
    }
}

pub fn noteClearColorCell(clear_row_colors: []contract.Rgba8, clear_row_matches: []bool, cell: contract.RenderableCell, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) void {
    if (damage.full) return;
    if (cell.continuation) return;
    if (cell.bg.a != 0) return;

    const rows = @min(grid_metrics.rows, scene_damage.damageRowCount(damage));
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        if (clear_row_matches[row]) continue;
        const dirty = scene_damage.dirtyRowSpan(damage, grid_metrics, row) orelse continue;
        if (!scene_damage.dirtySpanOverlapsCellSpan(grid_metrics, dirty, cell)) continue;
        clear_row_colors[row] = .{ .r = cell.bg.r, .g = cell.bg.g, .b = cell.bg.b, .a = 255 };
        clear_row_matches[row] = true;
    }
}

pub fn appendClearRowDrawsUnmanaged(out: *std.ArrayListUnmanaged(contract.TextClearDraw), clear_row_colors: []const contract.Rgba8, clear_row_matches: []const bool, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) void {
    if (damage.full) return;
    const rows = @min(grid_metrics.rows, scene_damage.damageRowCount(damage));
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const dirty = scene_damage.dirtyRowSpan(damage, grid_metrics, row) orelse continue;
        const first_cell = dirty.firstCell(grid_metrics);
        const cell_span = dirty.cellSpan();
        const span_cells = @as(u32, @max(cell_span, 1));
        out.appendAssumeCapacity(.{
            .x_px = @as(i32, @intCast(dirty.start_col)) * @as(i32, @intCast(cell_metrics.cell_w_px)),
            .y_px = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px)),
            .width_px = @intCast(span_cells * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .color = if (clear_row_matches[row]) clear_row_colors[row] else .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .first_cell = first_cell,
            .cell_span = cell_span,
        });
    }
}

pub fn appendCursorDraws(allocator: std.mem.Allocator, out: *std.ArrayList(contract.TextCursorDraw), cursor: anytype, damage: scene_damage.NormalizedDamage, cell_metrics: contract.CellMetrics) !void {
    const cursor_value = cursor orelse return;
    if (classifyCursorLead(damage, cursor_value) != .draw) return;
    const count_before = out.items.len;
    var draws: [4]contract.TextCursorDraw = undefined;
    try out.appendSlice(allocator, cursorDrawRects(draws[0..], cursor_value, cell_metrics));
    assertCursorDrawCount(out.items.len - count_before, cursor_value.shape);
}

pub fn appendCursorDrawsUnmanaged(out: *std.ArrayListUnmanaged(contract.TextCursorDraw), cursor: anytype, damage: scene_damage.NormalizedDamage, cell_metrics: contract.CellMetrics) void {
    const cursor_value = cursor orelse return;
    if (classifyCursorLead(damage, cursor_value) != .draw) return;
    const count_before = out.items.len;
    var draws: [4]contract.TextCursorDraw = undefined;
    out.appendSliceAssumeCapacity(cursorDrawRects(draws[0..], cursor_value, cell_metrics));
    assertCursorDrawCount(out.items.len - count_before, cursor_value.shape);
}

pub fn cursorDraws(allocator: std.mem.Allocator, cursor: anytype, cell_metrics: contract.CellMetrics) ![]contract.TextCursorDraw {
    const count = cursorDrawCountExact(cursor.shape);
    const draws = try allocator.alloc(contract.TextCursorDraw, @intCast(count));
    errdefer allocator.free(draws);
    _ = cursorDrawRects(draws, cursor, cell_metrics);
    return draws;
}

pub fn decorationGeometryForCellMetrics(cell_metrics: contract.CellMetrics) contract.DecorationGeometry {
    return decorationGeometry(cell_metrics, defaultFontMetrics(cell_metrics));
}

pub fn appendRectDecorationDraws(comptime underline_color_fn: fn (contract.RenderableCell) contract.Rgba8, comptime text_color_fn: fn (contract.RenderableCell) contract.Rgba8, allocator: std.mem.Allocator, out: *std.ArrayList(contract.TextDecorationDraw), cells: []const contract.RenderableCell, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) !void {
    const deco = decorationGeometryForCellMetrics(cell_metrics);
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    for (cells) |cell| {
        if (classifyDecorationLead(damage, grid_metrics, cell) != .draw) continue;
        const col = cell.first_cell % cols;
        const row = cell.first_cell / cols;
        const base_x = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
        const base_y = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
        const width_px: u16 = @intCast(@as(u32, @max(cell.cell_span, 1)) * @as(u32, cell_metrics.cell_w_px));
        if (cell.underline and cell.underline_style != .curly) try appendUnderlineDraws(allocator, out, cell, base_x, base_y, width_px, deco, underline_color_fn(cell));
        if (cell.strikethrough) try appendDecoration(out, allocator, .{ .kind = .strikethrough, .x_px = base_x, .y_px = base_y + deco.strikethrough_y_px, .width_px = width_px, .height_px = deco.strikethrough_h_px, .color = text_color_fn(cell), .first_cell = cell.first_cell, .cell_span = cell.cell_span });
    }
}

pub fn appendRectDecorationDrawsUnmanaged(comptime underline_color_fn: fn (contract.RenderableCell) contract.Rgba8, comptime text_color_fn: fn (contract.RenderableCell) contract.Rgba8, out: *std.ArrayListUnmanaged(contract.TextDecorationDraw), cells: []const contract.RenderableCell, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) void {
    const deco = decorationGeometryForCellMetrics(cell_metrics);
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    for (cells) |cell| {
        if (classifyDecorationLead(damage, grid_metrics, cell) != .draw) continue;
        const col = cell.first_cell % cols;
        const row = cell.first_cell / cols;
        const base_x = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
        const base_y = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
        const width_px: u16 = @intCast(@as(u32, @max(cell.cell_span, 1)) * @as(u32, cell_metrics.cell_w_px));
        if (cell.underline and cell.underline_style != .curly) appendUnderlineDrawsUnmanaged(out, cell, base_x, base_y, width_px, deco, underline_color_fn(cell));
        if (cell.strikethrough) appendDecorationUnmanaged(out, .{ .kind = .strikethrough, .x_px = base_x, .y_px = base_y + deco.strikethrough_y_px, .width_px = width_px, .height_px = deco.strikethrough_h_px, .color = text_color_fn(cell), .first_cell = cell.first_cell, .cell_span = cell.cell_span });
    }
}

pub fn appendRectDecorationCellDrawsUnmanaged(comptime underline_color_fn: fn (contract.RenderableCell) contract.Rgba8, comptime text_color_fn: fn (contract.RenderableCell) contract.Rgba8, out: *std.ArrayListUnmanaged(contract.TextDecorationDraw), cell: contract.RenderableCell, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, damage: scene_damage.NormalizedDamage) void {
    const layout = rectDecorationLayout(cell_metrics, grid_metrics);
    appendRectDecorationCellDrawsWithLayoutUnmanaged(underline_color_fn, text_color_fn, out, cell, layout, damage);
}

pub fn appendRectDecorationCellDrawsWithLayoutUnmanaged(comptime underline_color_fn: fn (contract.RenderableCell) contract.Rgba8, comptime text_color_fn: fn (contract.RenderableCell) contract.Rgba8, out: *std.ArrayListUnmanaged(contract.TextDecorationDraw), cell: contract.RenderableCell, layout: RectDecorationLayout, damage: scene_damage.NormalizedDamage) void {
    if (classifyDecorationLead(damage, layout.grid_metrics, cell) != .draw) return;
    const col = cell.first_cell % layout.cols;
    const row = cell.first_cell / layout.cols;
    const base_x = @as(i32, @intCast(col)) * @as(i32, @intCast(layout.cell_w_px));
    const base_y = @as(i32, @intCast(row)) * @as(i32, @intCast(layout.cell_h_px));
    const width_px: u16 = @intCast(@as(u32, @max(cell.cell_span, 1)) * @as(u32, layout.cell_w_px));
    if (cell.underline and cell.underline_style != .curly) appendUnderlineDrawsUnmanaged(out, cell, base_x, base_y, width_px, layout.geometry, underline_color_fn(cell));
    if (cell.strikethrough) appendDecorationUnmanaged(out, .{ .kind = .strikethrough, .x_px = base_x, .y_px = base_y + layout.geometry.strikethrough_y_px, .width_px = width_px, .height_px = layout.geometry.strikethrough_h_px, .color = text_color_fn(cell), .first_cell = cell.first_cell, .cell_span = cell.cell_span });
}

fn classifyCursorLead(damage: scene_damage.NormalizedDamage, cursor: anytype) CursorLead {
    if (!damage.full and !scene_damage.rowDirty(damage, cursor.cell_row)) return .skip;
    return .draw;
}

fn classifyBackgroundLead(damage: scene_damage.NormalizedDamage, grid_metrics: contract.GridMetrics, cell: contract.RenderableCell) BackgroundLead {
    if (cell.continuation) return .skip;
    if (!scene_damage.includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) return .skip;
    if (cell.bg.a == 0) return .transparent;
    return .span;
}

fn classifyBackgroundNext(damage: scene_damage.NormalizedDamage, grid_metrics: contract.GridMetrics, row: u16, fill_color: contract.Rgba8, span_end_cell: u32, cell: contract.RenderableCell) BackgroundNext {
    if (cell.continuation) return .stop_continuation;
    if (!scene_damage.includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) return .stop_damage;
    if (!sameRgba8(cell.bg, fill_color)) return .stop_color;
    if (cell.first_cell / @max(@as(u32, grid_metrics.cols), 1) != row) return .stop_row;
    if (cell.first_cell != span_end_cell) return .stop_gap;
    return .merge;
}

fn clearColorForSpan(cells: []const contract.RenderableCell, grid_metrics: contract.GridMetrics, dirty: scene_damage.DirtyRowSpan) contract.Rgba8 {
    for (cells) |cell| {
        if (classifyClearColorCell(grid_metrics, dirty, cell) != .match) continue;
        const clear = contract.Rgba8{ .r = cell.bg.r, .g = cell.bg.g, .b = cell.bg.b, .a = 255 };
        std.debug.assert(clear.r == cell.bg.r and clear.g == cell.bg.g and clear.b == cell.bg.b and clear.a == 255);
        return clear;
    }
    return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
}

fn classifyClearColorCell(grid_metrics: contract.GridMetrics, dirty_span: scene_damage.DirtyRowSpan, cell: contract.RenderableCell) ClearColorCell {
    if (cell.continuation) return .skip;
    if (cell.bg.a != 0) return .skip;
    if (!scene_damage.dirtySpanOverlapsCellSpan(grid_metrics, dirty_span, cell)) return .skip;
    return .match;
}

fn classifyDecorationLead(damage: scene_damage.NormalizedDamage, grid_metrics: contract.GridMetrics, cell: contract.RenderableCell) DecorationLead {
    if (cell.continuation) return .skip;
    if (!cell.underline and !cell.strikethrough) return .skip;
    if (!scene_damage.includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) return .skip;
    return .draw;
}

pub fn countUnderlineDecorationDraws(width_px: u16, height_px: u16, style: contract.UnderlineStyle) usize {
    const cadence = underlineSteppedCadence(width_px, height_px, style);
    if (cadence) |value| return countSteppedDecorationDraws(width_px, value.step_px);
    return switch (style) {
        .straight => 1,
        .double => 2,
        .curly => 0,
        .dotted, .dashed => unreachable,
    };
}

fn countSteppedDecorationDraws(width_px: u16, step_px: u16) usize {
    std.debug.assert(step_px > 0);
    if (width_px == 0) return 0;
    const width = @as(usize, width_px);
    const step = @as(usize, step_px);
    return (width + step - 1) / step;
}

fn appendDecoration(out: *std.ArrayList(contract.TextDecorationDraw), allocator: std.mem.Allocator, draw: contract.TextDecorationDraw) !void {
    if (out.items.len > 0) {
        const last = &out.items[out.items.len - 1];
        if (classifyDecorationAppend(last.*, draw) == .merge) {
            const merged_cell_span = @as(u32, last.cell_span) + @as(u32, draw.cell_span);
            last.width_px +%= draw.width_px;
            last.cell_span = @intCast(@min(merged_cell_span, @as(u32, std.math.maxInt(u8))));
            return;
        }
    }
    try out.append(allocator, draw);
}

fn appendDecorationUnmanaged(out: *std.ArrayListUnmanaged(contract.TextDecorationDraw), draw: contract.TextDecorationDraw) void {
    if (out.items.len > 0) {
        const last = &out.items[out.items.len - 1];
        if (classifyDecorationAppend(last.*, draw) == .merge) {
            const merged_cell_span = @as(u32, last.cell_span) + @as(u32, draw.cell_span);
            last.width_px +%= draw.width_px;
            last.cell_span = @intCast(@min(merged_cell_span, @as(u32, std.math.maxInt(u8))));
            return;
        }
    }
    out.appendAssumeCapacity(draw);
}

fn classifyDecorationAppend(last: contract.TextDecorationDraw, draw: contract.TextDecorationDraw) DecorationAppend {
    const last_end_x = last.x_px + @as(i32, @intCast(last.width_px));
    if (last.kind != draw.kind) return .append;
    if (last.y_px != draw.y_px) return .append;
    if (last.height_px != draw.height_px) return .append;
    if (!sameRgba8(last.color, draw.color)) return .append;
    if (last_end_x != draw.x_px) return .append;
    return .merge;
}

fn appendUnderlineDraws(allocator: std.mem.Allocator, out: *std.ArrayList(contract.TextDecorationDraw), cell: contract.RenderableCell, x: i32, row_y: i32, width: u16, deco: contract.DecorationGeometry, color: contract.Rgba8) !void {
    const y = row_y + deco.underline_y_px;
    const height = deco.underline_h_px;
    if (underlineSteppedCadence(width, height, cell.underline_style)) |cadence| {
        var off: u16 = 0;
        while (off < width) : (off += cadence.step_px) {
            try appendDecoration(out, allocator, .{ .kind = cadence.kind, .x_px = x + @as(i32, @intCast(off)), .y_px = y, .width_px = @min(cadence.segment_px, width - off), .height_px = height, .color = color, .first_cell = cell.first_cell, .cell_span = cell.cell_span });
        }
        return;
    }
    switch (cell.underline_style) {
        .straight => try appendDecoration(out, allocator, .{ .kind = .underline, .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = cell.first_cell, .cell_span = cell.cell_span }),
        .double => {
            const gap: i32 = @max(@as(i32, @intCast(height)), 1);
            try appendDecoration(out, allocator, .{ .kind = .underline, .x_px = x, .y_px = @max(y - gap - @as(i32, @intCast(height)), 0), .width_px = width, .height_px = height, .color = color, .first_cell = cell.first_cell, .cell_span = cell.cell_span });
            try appendDecoration(out, allocator, .{ .kind = .underline, .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = cell.first_cell, .cell_span = cell.cell_span });
        },
        .dotted, .dashed => unreachable,
        .curly => unreachable,
    }
}

fn appendUnderlineDrawsUnmanaged(out: *std.ArrayListUnmanaged(contract.TextDecorationDraw), cell: contract.RenderableCell, x: i32, row_y: i32, width: u16, deco: contract.DecorationGeometry, color: contract.Rgba8) void {
    const y = row_y + deco.underline_y_px;
    const height = deco.underline_h_px;
    if (underlineSteppedCadence(width, height, cell.underline_style)) |cadence| {
        var off: u16 = 0;
        while (off < width) : (off += cadence.step_px) {
            appendDecorationUnmanaged(out, .{ .kind = cadence.kind, .x_px = x + @as(i32, @intCast(off)), .y_px = y, .width_px = @min(cadence.segment_px, width - off), .height_px = height, .color = color, .first_cell = cell.first_cell, .cell_span = cell.cell_span });
        }
        return;
    }
    switch (cell.underline_style) {
        .straight => appendDecorationUnmanaged(out, .{ .kind = .underline, .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = cell.first_cell, .cell_span = cell.cell_span }),
        .double => {
            const gap: i32 = @max(@as(i32, @intCast(height)), 1);
            appendDecorationUnmanaged(out, .{ .kind = .underline, .x_px = x, .y_px = @max(y - gap - @as(i32, @intCast(height)), 0), .width_px = width, .height_px = height, .color = color, .first_cell = cell.first_cell, .cell_span = cell.cell_span });
            appendDecorationUnmanaged(out, .{ .kind = .underline, .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = cell.first_cell, .cell_span = cell.cell_span });
        },
        .dotted, .dashed => unreachable,
        .curly => unreachable,
    }
}

fn underlineSteppedCadence(width_px: u16, height_px: u16, style: contract.UnderlineStyle) ?SteppedUnderlineCadence {
    return switch (style) {
        .dotted => .{ .kind = .underline_dotted, .segment_px = @max(height_px, 1), .step_px = @max(@max(height_px, 1) * 2, 2) },
        .dashed => .{ .kind = .underline_dashed, .segment_px = @max(width_px / 3, @as(u16, 2)), .step_px = @max(@max(width_px / 3, @as(u16, 2)) + 2, 3) },
        .straight, .double, .curly => null,
    };
}

fn cursorDrawRects(out: []contract.TextCursorDraw, cursor: anytype, cell_metrics: contract.CellMetrics) []const contract.TextCursorDraw {
    const count = cursorDrawCountExact(cursor.shape);
    std.debug.assert(out.len >= count);

    const base_x: i32 = @as(i32, @intCast(cursor.cell_col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
    const base_y: i32 = @as(i32, @intCast(cursor.cell_row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
    const geom = cursorGeometry(cell_metrics);

    switch (cursor.shape) {
        .block => out[0] = .{ .x_px = base_x, .y_px = base_y, .width_px = cell_metrics.cell_w_px, .height_px = cell_metrics.cell_h_px, .color = cursor.color },
        .beam => out[0] = .{ .x_px = base_x, .y_px = base_y, .width_px = geom.beam_w_px, .height_px = cell_metrics.cell_h_px, .color = cursor.color },
        .underline => out[0] = .{ .x_px = base_x, .y_px = base_y + @as(i32, @intCast(cell_metrics.cell_h_px - geom.underline_h_px)), .width_px = cell_metrics.cell_w_px, .height_px = geom.underline_h_px, .color = cursor.color },
        .hollow_block => {
            const stroke = geom.hollow_stroke_px;
            out[0] = .{ .x_px = base_x, .y_px = base_y, .width_px = cell_metrics.cell_w_px, .height_px = stroke, .color = cursor.color };
            out[1] = .{ .x_px = base_x, .y_px = base_y + @as(i32, @intCast(cell_metrics.cell_h_px - stroke)), .width_px = cell_metrics.cell_w_px, .height_px = stroke, .color = cursor.color };
            out[2] = .{ .x_px = base_x, .y_px = base_y, .width_px = stroke, .height_px = cell_metrics.cell_h_px, .color = cursor.color };
            out[3] = .{ .x_px = base_x + @as(i32, @intCast(cell_metrics.cell_w_px - stroke)), .y_px = base_y, .width_px = stroke, .height_px = cell_metrics.cell_h_px, .color = cursor.color };
        },
    }

    return out[0..count];
}

fn cursorDrawCountExact(shape: anytype) CursorDrawCount {
    return if (shape == .hollow_block) 4 else 1;
}

fn assertCursorDrawCount(draw_count: usize, shape: anytype) void {
    std.debug.assert(draw_count == cursorDrawCountExact(shape));
}

fn defaultFontMetrics(cell_metrics: contract.CellMetrics) contract.FontMetrics {
    const thickness: f32 = @floatFromInt(scaledDecorationThickness(cell_metrics.cell_h_px));
    const baseline: f32 = @floatFromInt(cell_metrics.baseline_px);
    return .{
        .ascent_px = baseline,
        .descent_px = @floatFromInt(@as(i32, cell_metrics.cell_h_px) - @as(i32, cell_metrics.baseline_px)),
        .line_gap_px = 0,
        .underline_pos_px = baseline + thickness,
        .underline_thickness_px = thickness,
        .strikethrough_pos_px = baseline / 2.0,
        .strikethrough_thickness_px = thickness,
    };
}

fn decorationGeometry(cell_metrics: contract.CellMetrics, font_metrics: contract.FontMetrics) contract.DecorationGeometry {
    return .{
        .underline_y_px = std.math.clamp(@as(i32, @intFromFloat(@round(font_metrics.underline_pos_px))), 0, @as(i32, @intCast(cell_metrics.cell_h_px - 1))),
        .underline_h_px = @max(@as(u16, @intFromFloat(@round(font_metrics.underline_thickness_px))), 1),
        .strikethrough_y_px = std.math.clamp(@as(i32, @intFromFloat(@round(font_metrics.strikethrough_pos_px))), 0, @as(i32, @intCast(cell_metrics.cell_h_px - 1))),
        .strikethrough_h_px = @max(@as(u16, @intFromFloat(@round(font_metrics.strikethrough_thickness_px))), 1),
    };
}

fn cursorGeometry(cell_metrics: contract.CellMetrics) contract.CursorGeometry {
    return .{
        .beam_w_px = @max(cell_metrics.cell_w_px / 8, 1),
        .underline_h_px = scaledDecorationThickness(cell_metrics.cell_h_px),
        .hollow_stroke_px = 2,
    };
}

fn scaledDecorationThickness(cell_h_px: u16) u16 {
    return @intCast(@max(@divTrunc(@as(u32, @max(cell_h_px, 1)) + 15, 16), 1));
}

fn sameRgba8(a: contract.Rgba8, b: contract.Rgba8) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}
