const std = @import("std");
const render = @import("draw_primitives.zig");
const text_damage = @import("damage.zig");

const CursorDrawCount = u3;
const block_contrast_threshold: f32 = 2.5;

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
    kind: render.DecorationKind,
    segment_px: u16,
    step_px: u16,
};

pub const RectDecorationLayout = struct {
    grid_metrics: render.CellGridMetrics,
    geometry: render.DecorationGeometry,
    cols: u32,
    cell_w_px: u16,
    cell_h_px: u16,

    pub fn init(cell_metrics: render.CellMetrics, grid_metrics: render.CellGridMetrics) RectDecorationLayout {
        return .{
            .grid_metrics = grid_metrics,
            .geometry = decorationGeometryForCellMetrics(cell_metrics),
            .cols = @max(@as(u32, grid_metrics.cols), 1),
            .cell_w_px = cell_metrics.cell_w_px,
            .cell_h_px = cell_metrics.cell_h_px,
        };
    }
};

pub fn rectDecorationLayout(cell_metrics: render.CellMetrics, grid_metrics: render.CellGridMetrics) RectDecorationLayout {
    return .init(cell_metrics, grid_metrics);
}

pub fn countClearDraws(grid_metrics: render.CellGridMetrics, damage: text_damage.NormalizedDamage) usize {
    if (damage.full) return 0;
    const rows = @min(grid_metrics.rows, text_damage.damageRowCount(damage));
    var count: usize = 0;
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        if (text_damage.dirtyRowSpan(damage, grid_metrics, row) == null) continue;
        count += 1;
    }
    return count;
}

pub fn countCursorDraws(cursor: anytype, damage: text_damage.NormalizedDamage) usize {
    const cursor_value = cursor orelse return 0;
    if (!cursor_value.visible) return 0;
    if (classifyCursorLead(damage, cursor_value) != .draw) return 0;
    return cursorDrawCount(cursor_value.shape);
}

pub fn countCursorFillRects(cursor: anytype, damage: text_damage.NormalizedDamage) usize {
    const cursor_value = cursor orelse return 0;
    if (!cursor_value.visible) return 0;
    if (classifyCursorLead(damage, cursor_value) != .draw) return 0;
    return switch (cursor_value.shape) {
        .none => 0,
        .hollow => 4,
        .block, .beam, .underline => 1,
    };
}

pub fn countCursorTextRecolorSpans(cursor: anytype, damage: text_damage.NormalizedDamage) usize {
    const cursor_value = cursor orelse return 0;
    if (!cursor_value.visible) return 0;
    if (classifyCursorLead(damage, cursor_value) != .draw) return 0;
    return if (cursor_value.shape == .block) 1 else 0;
}

pub fn countCursorTrailRects(cursor: anytype, damage: text_damage.NormalizedDamage) usize {
    _ = damage;
    const cursor_value = cursor orelse return 0;
    return cursor_value.trail.count;
}

pub fn cursorDrawCount(shape: anytype) usize {
    return @intCast(cursorDrawCountExact(shape));
}

pub fn countRectDecorationDraws(cells: []const render.RenderableCell, cell_metrics: render.CellMetrics, grid_metrics: render.CellGridMetrics, damage: text_damage.NormalizedDamage) usize {
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

pub fn appendBackgroundDraws(allocator: std.mem.Allocator, out: *std.ArrayList(render.TextBackgroundDraw), cells: []const render.RenderableCell, cell_metrics: render.CellMetrics, grid_metrics: render.CellGridMetrics, damage: text_damage.NormalizedDamage) !void {
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

pub fn appendBackgroundDrawsUnmanaged(out: *std.ArrayListUnmanaged(render.TextBackgroundDraw), cells: []const render.RenderableCell, cell_metrics: render.CellMetrics, grid_metrics: render.CellGridMetrics, damage: text_damage.NormalizedDamage) void {
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

pub fn appendBackgroundDrawCellUnmanaged(out: *std.ArrayListUnmanaged(render.TextBackgroundDraw), merge_live: *bool, merge_end_cell: *u32, cell: render.RenderableCell, cell_metrics: render.CellMetrics, grid_metrics: render.CellGridMetrics, damage: text_damage.NormalizedDamage) void {
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

pub fn appendClearDraws(allocator: std.mem.Allocator, out: *std.ArrayList(render.TextClearDraw), cells: []const render.RenderableCell, cell_metrics: render.CellMetrics, grid_metrics: render.CellGridMetrics, damage: text_damage.NormalizedDamage) !void {
    if (damage.full) return;
    const rows = @min(grid_metrics.rows, text_damage.damageRowCount(damage));
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const dirty = text_damage.dirtyRowSpan(damage, grid_metrics, row) orelse continue;
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

pub fn appendClearDrawsUnmanaged(out: *std.ArrayListUnmanaged(render.TextClearDraw), cells: []const render.RenderableCell, cell_metrics: render.CellMetrics, grid_metrics: render.CellGridMetrics, damage: text_damage.NormalizedDamage) void {
    if (damage.full) return;
    const rows = @min(grid_metrics.rows, text_damage.damageRowCount(damage));
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const dirty = text_damage.dirtyRowSpan(damage, grid_metrics, row) orelse continue;
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

pub fn noteClearColorCell(clear_row_colors: []render.Rgba8, clear_row_matches: []bool, cell: render.RenderableCell, grid_metrics: render.CellGridMetrics, damage: text_damage.NormalizedDamage) void {
    if (damage.full) return;
    if (cell.continuation) return;
    if (cell.bg.a != 0) return;

    const rows = @min(grid_metrics.rows, text_damage.damageRowCount(damage));
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        if (clear_row_matches[row]) continue;
        const dirty = text_damage.dirtyRowSpan(damage, grid_metrics, row) orelse continue;
        if (!text_damage.dirtySpanOverlapsCellSpan(grid_metrics, dirty, cell)) continue;
        clear_row_colors[row] = .{ .r = cell.bg.r, .g = cell.bg.g, .b = cell.bg.b, .a = 255 };
        clear_row_matches[row] = true;
    }
}

pub fn appendClearRowDrawsUnmanaged(out: *std.ArrayListUnmanaged(render.TextClearDraw), clear_row_colors: []const render.Rgba8, clear_row_matches: []const bool, cell_metrics: render.CellMetrics, grid_metrics: render.CellGridMetrics, damage: text_damage.NormalizedDamage) void {
    if (damage.full) return;
    const rows = @min(grid_metrics.rows, text_damage.damageRowCount(damage));
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const dirty = text_damage.dirtyRowSpan(damage, grid_metrics, row) orelse continue;
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

pub fn appendCursorDraws(allocator: std.mem.Allocator, out: *std.ArrayList(render.TextCursorDraw), cursor: ?render.CursorPresentation, damage: text_damage.NormalizedDamage, cell_metrics: render.CellMetrics) !void {
    const cursor_value = cursor orelse return;
    if (!cursor_value.visible) return;
    if (classifyCursorLead(damage, cursor_value) != .draw) return;
    if (cursor_value.shape == .none) return;
    const count_before = out.items.len;
    var draws: [4]render.TextCursorDraw = undefined;
    try out.appendSlice(allocator, cursorDrawRects(draws[0..], cursor_value, cell_metrics));
    assertCursorDrawCount(out.items.len - count_before, cursor_value.shape);
}

pub fn appendCursorPrimitives(
    allocator: std.mem.Allocator,
    cursor_draws: *std.ArrayList(render.TextCursorDraw),
    cursor_fill_rects: *std.ArrayList(@import("draw_list.zig").CursorFillRect),
    cursor_text_recolor_spans: *std.ArrayList(@import("draw_list.zig").CursorTextRecolorSpan),
    cursor_trail_rects: *std.ArrayList(@import("draw_list.zig").CursorTrailRect),
    cells: []const render.RenderableCell,
    grid_metrics: render.CellGridMetrics,
    cursor: ?render.CursorPresentation,
    damage: text_damage.NormalizedDamage,
    cell_metrics: render.CellMetrics,
) !void {
    const cursor_value = cursor orelse return;
    try appendCursorTrailRects(allocator, cursor_trail_rects, grid_metrics, cursor_value, cell_metrics);
    if (!cursor_value.visible) return;
    if (classifyCursorLead(damage, cursor_value) != .draw) return;

    try appendCursorDraws(allocator, cursor_draws, cursor_value, damage, cell_metrics);
    try appendCursorFillRects(allocator, cursor_fill_rects, cells, grid_metrics, cursor_value, cell_metrics);
    try appendCursorTextRecolorSpans(allocator, cursor_text_recolor_spans, cells, grid_metrics, cursor_value);
}

fn appendCursorFillRects(allocator: std.mem.Allocator, out: *std.ArrayList(@import("draw_list.zig").CursorFillRect), cells: []const render.RenderableCell, grid_metrics: render.CellGridMetrics, cursor: anytype, cell_metrics: render.CellMetrics) !void {
    const first_cell: u32 = @as(u32, cursor.primary_extent.row) * @max(@as(u32, 1), @as(u32, grid_metrics.cols)) + @as(u32, cursor.primary_extent.col);
    const cell_span: u8 = @intCast(@min(@as(u32, cursor.primary_extent.cols) * @as(u32, cursor.primary_extent.rows), @as(u32, std.math.maxInt(u8))));
    const base_x: i32 = @as(i32, @intCast(cursor.primary_extent.col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
    const base_y: i32 = @as(i32, @intCast(cursor.primary_extent.row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
    const width_px: u16 = @intCast(@as(u32, cursor.primary_extent.cols) * @as(u32, cell_metrics.cell_w_px));
    const height_px: u16 = @intCast(@as(u32, cursor.primary_extent.rows) * @as(u32, cell_metrics.cell_h_px));
    const geom = cursorGeometry(cursor, cell_metrics);
    switch (cursor.shape) {
        .none => {},
        .block => {
            const fill_color = resolveCursorFillColor(cursor, cells, first_cell);
            try out.append(allocator, .{ .x_px = base_x, .y_px = base_y, .width_px = width_px, .height_px = height_px, .color = fill_color, .first_cell = first_cell, .cell_span = cell_span });
        },
        .beam => try out.append(allocator, .{ .x_px = base_x, .y_px = base_y, .width_px = geom.beam_w_px, .height_px = height_px, .color = cursorColor(cursor), .first_cell = first_cell, .cell_span = cell_span }),
        .underline => try out.append(allocator, .{ .x_px = base_x, .y_px = base_y + @as(i32, @intCast(height_px - geom.underline_h_px)), .width_px = width_px, .height_px = geom.underline_h_px, .color = cursorColor(cursor), .first_cell = first_cell, .cell_span = cell_span }),
        .hollow => {
            const stroke = geom.hollow_stroke_px;
            const fill_color = cursorColor(cursor);
            try out.append(allocator, .{ .x_px = base_x, .y_px = base_y, .width_px = width_px, .height_px = stroke, .color = fill_color, .first_cell = first_cell, .cell_span = cell_span });
            try out.append(allocator, .{ .x_px = base_x, .y_px = base_y + @as(i32, @intCast(height_px - stroke)), .width_px = width_px, .height_px = stroke, .color = fill_color, .first_cell = first_cell, .cell_span = cell_span });
            try out.append(allocator, .{ .x_px = base_x, .y_px = base_y, .width_px = stroke, .height_px = height_px, .color = fill_color, .first_cell = first_cell, .cell_span = cell_span });
            try out.append(allocator, .{ .x_px = base_x + @as(i32, @intCast(width_px - stroke)), .y_px = base_y, .width_px = stroke, .height_px = height_px, .color = fill_color, .first_cell = first_cell, .cell_span = cell_span });
        },
    }
}

fn appendCursorTextRecolorSpans(allocator: std.mem.Allocator, out: *std.ArrayList(@import("draw_list.zig").CursorTextRecolorSpan), cells: []const render.RenderableCell, grid_metrics: render.CellGridMetrics, cursor: anytype) !void {
    if (cursor.shape != .block) return;
    const first_cell: u32 = @as(u32, cursor.primary_extent.row) * @max(@as(u32, 1), @as(u32, grid_metrics.cols)) + @as(u32, cursor.primary_extent.col);
    const cell = findCellByFirstCell(cells, first_cell) orelse return;
    const colors = resolveBlockCursorColors(cursor, rgbFromRgba(cell.fg), rgbFromRgba(cell.bg));
    try out.append(allocator, .{
        .first_cell = first_cell,
        .cell_span = @intCast(@min(@as(u32, cursor.primary_extent.cols) * @as(u32, cursor.primary_extent.rows), @as(u32, std.math.maxInt(u8)))),
        .color = .{ .r = colors.cursor_fg.r, .g = colors.cursor_fg.g, .b = colors.cursor_fg.b, .a = cursor.cursor_opacity },
    });
}

fn appendCursorTrailRects(allocator: std.mem.Allocator, out: *std.ArrayList(@import("draw_list.zig").CursorTrailRect), grid_metrics: render.CellGridMetrics, cursor: anytype, cell_metrics: render.CellMetrics) !void {
    for (cursor.trail.rects[0..cursor.trail.count]) |rect| {
        try out.append(allocator, cursorTrailDrawRect(grid_metrics, cursor, rect, cell_metrics));
    }
}

pub fn appendCursorTrailRectsUnmanaged(out: *std.ArrayListUnmanaged(@import("draw_list.zig").CursorTrailRect), grid_metrics: render.CellGridMetrics, cursor: ?render.CursorPresentation, cell_metrics: render.CellMetrics) void {
    const cursor_value = cursor orelse return;
    for (cursor_value.trail.rects[0..cursor_value.trail.count]) |rect| out.appendAssumeCapacity(cursorTrailDrawRect(grid_metrics, cursor_value, rect, cell_metrics));
}

fn cursorTrailDrawRect(grid_metrics: render.CellGridMetrics, cursor: anytype, rect: anytype, cell_metrics: render.CellMetrics) @import("draw_list.zig").CursorTrailRect {
    const first_cell: u32 = if (rect.pixel_rect) pixelRectFirstCell(rect, grid_metrics, cell_metrics) else @as(u32, rect.extent.row) * @max(@as(u32, 1), @as(u32, grid_metrics.cols)) + @as(u32, rect.extent.col);
    const x_px: i32 = if (rect.pixel_rect) rect.x_px else @as(i32, @intCast(rect.extent.col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
    const y_px: i32 = if (rect.pixel_rect) rect.y_px else @as(i32, @intCast(rect.extent.row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
    const width_px: u16 = if (rect.pixel_rect) rect.width_px else @intCast(@as(u32, rect.extent.cols) * @as(u32, cell_metrics.cell_w_px));
    const height_px: u16 = if (rect.pixel_rect) rect.height_px else @intCast(@as(u32, rect.extent.rows) * @as(u32, cell_metrics.cell_h_px));
    const cell_span: u8 = if (rect.pixel_rect) 1 else @intCast(@min(@as(u32, rect.extent.cols) * @as(u32, rect.extent.rows), @as(u32, std.math.maxInt(u8))));
    const color_value = resolveCursorTrailColor(cursor, rect);
    return .{ .x_px = x_px, .y_px = y_px, .width_px = width_px, .height_px = height_px, .opacity = rect.opacity, .color = .{ .r = color_value.r, .g = color_value.g, .b = color_value.b, .a = rect.opacity }, .first_cell = first_cell, .cell_span = cell_span };
}

fn pixelRectFirstCell(rect: anytype, grid_metrics: render.CellGridMetrics, cell_metrics: render.CellMetrics) u32 {
    std.debug.assert(rect.pixel_rect);
    std.debug.assert(cell_metrics.cell_w_px != 0);
    std.debug.assert(cell_metrics.cell_h_px != 0);
    const col: u32 = @intCast(@max(@divTrunc(rect.x_px, @as(i32, @intCast(cell_metrics.cell_w_px))), 0));
    const row: u32 = @intCast(@max(@divTrunc(rect.y_px, @as(i32, @intCast(cell_metrics.cell_h_px))), 0));
    return @min(row, @as(u32, @max(grid_metrics.rows, 1)) - 1) * @max(@as(u32, grid_metrics.cols), 1) + @min(col, @as(u32, @max(grid_metrics.cols, 1)) - 1);
}

pub fn appendCursorDrawsUnmanaged(out: *std.ArrayListUnmanaged(render.TextCursorDraw), cursor: anytype, damage: text_damage.NormalizedDamage, cell_metrics: render.CellMetrics) void {
    const cursor_value = cursor orelse return;
    if (!cursor_value.visible) return;
    if (classifyCursorLead(damage, cursor_value) != .draw) return;
    if (cursor_value.shape == .none) return;
    const count_before = out.items.len;
    var draws: [4]render.TextCursorDraw = undefined;
    out.appendSliceAssumeCapacity(cursorDrawRects(draws[0..], cursor_value, cell_metrics));
    assertCursorDrawCount(out.items.len - count_before, cursor_value.shape);
}

pub fn cursorDraws(allocator: std.mem.Allocator, cursor: anytype, cell_metrics: render.CellMetrics) ![]render.TextCursorDraw {
    if (!cursor.visible) return allocator.alloc(render.TextCursorDraw, 0);
    const count = cursorDrawCountExact(cursor.shape);
    if (count == 0) return allocator.alloc(render.TextCursorDraw, 0);
    const draws = try allocator.alloc(render.TextCursorDraw, @intCast(count));
    errdefer allocator.free(draws);
    _ = cursorDrawRects(draws, cursor, cell_metrics);
    return draws;
}

pub fn decorationGeometryForCellMetrics(cell_metrics: render.CellMetrics) render.DecorationGeometry {
    return decorationGeometry(cell_metrics, defaultFontMetrics(cell_metrics));
}

pub fn appendRectDecorationDraws(comptime underline_color_fn: fn (render.RenderableCell) render.Rgba8, comptime text_color_fn: fn (render.RenderableCell) render.Rgba8, allocator: std.mem.Allocator, out: *std.ArrayList(render.TextDecorationDraw), cells: []const render.RenderableCell, cell_metrics: render.CellMetrics, grid_metrics: render.CellGridMetrics, damage: text_damage.NormalizedDamage) !void {
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

pub fn appendRectDecorationDrawsUnmanaged(comptime underline_color_fn: fn (render.RenderableCell) render.Rgba8, comptime text_color_fn: fn (render.RenderableCell) render.Rgba8, out: *std.ArrayListUnmanaged(render.TextDecorationDraw), cells: []const render.RenderableCell, cell_metrics: render.CellMetrics, grid_metrics: render.CellGridMetrics, damage: text_damage.NormalizedDamage) void {
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

pub fn appendRectDecorationCellDrawsUnmanaged(comptime underline_color_fn: fn (render.RenderableCell) render.Rgba8, comptime text_color_fn: fn (render.RenderableCell) render.Rgba8, out: *std.ArrayListUnmanaged(render.TextDecorationDraw), cell: render.RenderableCell, cell_metrics: render.CellMetrics, grid_metrics: render.CellGridMetrics, damage: text_damage.NormalizedDamage) void {
    const layout = rectDecorationLayout(cell_metrics, grid_metrics);
    appendRectDecorationCellDrawsWithLayoutUnmanaged(underline_color_fn, text_color_fn, out, cell, layout, damage);
}

pub fn appendRectDecorationCellDrawsWithLayoutUnmanaged(comptime underline_color_fn: fn (render.RenderableCell) render.Rgba8, comptime text_color_fn: fn (render.RenderableCell) render.Rgba8, out: *std.ArrayListUnmanaged(render.TextDecorationDraw), cell: render.RenderableCell, layout: RectDecorationLayout, damage: text_damage.NormalizedDamage) void {
    if (classifyDecorationLead(damage, layout.grid_metrics, cell) != .draw) return;
    const col = cell.first_cell % layout.cols;
    const row = cell.first_cell / layout.cols;
    const base_x = @as(i32, @intCast(col)) * @as(i32, @intCast(layout.cell_w_px));
    const base_y = @as(i32, @intCast(row)) * @as(i32, @intCast(layout.cell_h_px));
    const width_px: u16 = @intCast(@as(u32, @max(cell.cell_span, 1)) * @as(u32, layout.cell_w_px));
    if (cell.underline and cell.underline_style != .curly) appendUnderlineDrawsUnmanaged(out, cell, base_x, base_y, width_px, layout.geometry, underline_color_fn(cell));
    if (cell.strikethrough) appendDecorationUnmanaged(out, .{ .kind = .strikethrough, .x_px = base_x, .y_px = base_y + layout.geometry.strikethrough_y_px, .width_px = width_px, .height_px = layout.geometry.strikethrough_h_px, .color = text_color_fn(cell), .first_cell = cell.first_cell, .cell_span = cell.cell_span });
}

fn classifyCursorLead(damage: text_damage.NormalizedDamage, cursor: anytype) CursorLead {
    if (!damage.full and !text_damage.rowDirty(damage, cursor.primary_extent.row)) return .skip;
    return .draw;
}

fn classifyBackgroundLead(damage: text_damage.NormalizedDamage, grid_metrics: render.CellGridMetrics, cell: render.RenderableCell) BackgroundLead {
    if (cell.continuation) return .skip;
    if (!text_damage.includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) return .skip;
    if (cell.bg.a == 0) return .transparent;
    return .span;
}

fn classifyBackgroundNext(damage: text_damage.NormalizedDamage, grid_metrics: render.CellGridMetrics, row: u16, fill_color: render.Rgba8, span_end_cell: u32, cell: render.RenderableCell) BackgroundNext {
    if (cell.continuation) return .stop_continuation;
    if (!text_damage.includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) return .stop_damage;
    if (!sameRgba8(cell.bg, fill_color)) return .stop_color;
    if (cell.first_cell / @max(@as(u32, grid_metrics.cols), 1) != row) return .stop_row;
    if (cell.first_cell != span_end_cell) return .stop_gap;
    return .merge;
}

fn clearColorForSpan(cells: []const render.RenderableCell, grid_metrics: render.CellGridMetrics, dirty: text_damage.DirtyRowSpan) render.Rgba8 {
    for (cells) |cell| {
        if (classifyClearColorCell(grid_metrics, dirty, cell) != .match) continue;
        const clear = render.Rgba8{ .r = cell.bg.r, .g = cell.bg.g, .b = cell.bg.b, .a = 255 };
        std.debug.assert(clear.r == cell.bg.r and clear.g == cell.bg.g and clear.b == cell.bg.b and clear.a == 255);
        return clear;
    }
    return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
}

fn classifyClearColorCell(grid_metrics: render.CellGridMetrics, dirty_span: text_damage.DirtyRowSpan, cell: render.RenderableCell) ClearColorCell {
    if (cell.continuation) return .skip;
    if (cell.bg.a != 0) return .skip;
    if (!text_damage.dirtySpanOverlapsCellSpan(grid_metrics, dirty_span, cell)) return .skip;
    return .match;
}

fn classifyDecorationLead(damage: text_damage.NormalizedDamage, grid_metrics: render.CellGridMetrics, cell: render.RenderableCell) DecorationLead {
    if (cell.continuation) return .skip;
    if (!cell.underline and !cell.strikethrough) return .skip;
    if (!text_damage.includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) return .skip;
    return .draw;
}

pub fn countUnderlineDecorationDraws(width_px: u16, height_px: u16, style: render.UnderlineStyle) usize {
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

fn appendDecoration(out: *std.ArrayList(render.TextDecorationDraw), allocator: std.mem.Allocator, draw: render.TextDecorationDraw) !void {
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

fn appendDecorationUnmanaged(out: *std.ArrayListUnmanaged(render.TextDecorationDraw), draw: render.TextDecorationDraw) void {
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

fn classifyDecorationAppend(last: render.TextDecorationDraw, draw: render.TextDecorationDraw) DecorationAppend {
    const last_end_x = last.x_px + @as(i32, @intCast(last.width_px));
    if (last.kind != draw.kind) return .append;
    if (last.y_px != draw.y_px) return .append;
    if (last.height_px != draw.height_px) return .append;
    if (!sameRgba8(last.color, draw.color)) return .append;
    if (last_end_x != draw.x_px) return .append;
    return .merge;
}

fn appendUnderlineDraws(allocator: std.mem.Allocator, out: *std.ArrayList(render.TextDecorationDraw), cell: render.RenderableCell, x: i32, row_y: i32, width: u16, deco: render.DecorationGeometry, color: render.Rgba8) !void {
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

fn appendUnderlineDrawsUnmanaged(out: *std.ArrayListUnmanaged(render.TextDecorationDraw), cell: render.RenderableCell, x: i32, row_y: i32, width: u16, deco: render.DecorationGeometry, color: render.Rgba8) void {
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

fn underlineSteppedCadence(width_px: u16, height_px: u16, style: render.UnderlineStyle) ?SteppedUnderlineCadence {
    return switch (style) {
        .dotted => .{ .kind = .underline_dotted, .segment_px = @max(height_px, 1), .step_px = @max(@max(height_px, 1) * 2, 2) },
        .dashed => .{ .kind = .underline_dashed, .segment_px = @max(width_px / 3, @as(u16, 2)), .step_px = @max(@max(width_px / 3, @as(u16, 2)) + 2, 3) },
        .straight, .double, .curly => null,
    };
}

fn cursorDrawRects(out: []render.TextCursorDraw, cursor: anytype, cell_metrics: render.CellMetrics) []const render.TextCursorDraw {
    const count = cursorDrawCountExact(cursor.shape);
    std.debug.assert(out.len >= count);

    const base_x: i32 = @as(i32, @intCast(cursor.primary_extent.col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
    const base_y: i32 = @as(i32, @intCast(cursor.primary_extent.row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
    const geom = cursorGeometry(cursor, cell_metrics);
    const cursor_color = cursorColor(cursor);

    switch (cursor.shape) {
        .block => out[0] = .{ .x_px = base_x, .y_px = base_y, .width_px = cell_metrics.cell_w_px, .height_px = cell_metrics.cell_h_px, .color = cursor_color },
        .beam => out[0] = .{ .x_px = base_x, .y_px = base_y, .width_px = geom.beam_w_px, .height_px = cell_metrics.cell_h_px, .color = cursor_color },
        .underline => out[0] = .{ .x_px = base_x, .y_px = base_y + @as(i32, @intCast(cell_metrics.cell_h_px - geom.underline_h_px)), .width_px = cell_metrics.cell_w_px, .height_px = geom.underline_h_px, .color = cursor_color },
        .hollow => {
            const stroke = geom.hollow_stroke_px;
            out[0] = .{ .x_px = base_x, .y_px = base_y, .width_px = cell_metrics.cell_w_px, .height_px = stroke, .color = cursor_color };
            out[1] = .{ .x_px = base_x, .y_px = base_y + @as(i32, @intCast(cell_metrics.cell_h_px - stroke)), .width_px = cell_metrics.cell_w_px, .height_px = stroke, .color = cursor_color };
            out[2] = .{ .x_px = base_x, .y_px = base_y, .width_px = stroke, .height_px = cell_metrics.cell_h_px, .color = cursor_color };
            out[3] = .{ .x_px = base_x + @as(i32, @intCast(cell_metrics.cell_w_px - stroke)), .y_px = base_y, .width_px = stroke, .height_px = cell_metrics.cell_h_px, .color = cursor_color };
        },
        .none => unreachable,
    }

    return out[0..count];
}

fn cursorDrawCountExact(shape: anytype) CursorDrawCount {
    return switch (shape) {
        .none => 0,
        .hollow => 4,
        else => 1,
    };
}

pub fn resolveBlockCursorColors(presentation: anytype, cell_fg: render.Rgb8, cell_bg: render.Rgb8) struct { cursor_fg: render.Rgb8, cursor_bg: render.Rgb8 } {
    const cell_contrast = rgbContrast(cell_fg, cell_bg);
    const default_contrast = rgbContrast(presentation.default_foreground, presentation.default_background);
    var cursor_fg: render.Rgb8 = if (cell_contrast < block_contrast_threshold and default_contrast > cell_contrast) presentation.default_background else cell_bg;
    var cursor_bg: render.Rgb8 = if (cell_contrast < block_contrast_threshold and default_contrast > cell_contrast) presentation.default_foreground else cell_fg;

    switch (presentation.cursor_color.kind) {
        .default => {
            if (cell_bg.r == cell_fg.r and cell_bg.g == cell_fg.g and cell_bg.b == cell_fg.b) {
                cursor_fg = presentation.default_background;
                cursor_bg = presentation.default_foreground;
            } else {
                cursor_fg = cell_bg;
                cursor_bg = cell_fg;
            }
        },
        .indexed, .rgb => {
            cursor_bg = cursorColorRgb(presentation.cursor_color, presentation.default_foreground);
            cursor_fg = switch (presentation.cursor_text_color.kind) {
                .default => cell_bg,
                .indexed, .rgb => cursorColorRgb(presentation.cursor_text_color, presentation.default_foreground),
            };
        },
    }
    return .{ .cursor_fg = cursor_fg, .cursor_bg = cursor_bg };
}

fn cursorColor(cursor: anytype) render.Rgba8 {
    const rgb: @TypeOf(cursor.default_foreground) = switch (cursor.cursor_color.kind) {
        .rgb => .{
            .r = @as(u8, @intCast((cursor.cursor_color.value >> 16) & 0xff)),
            .g = @as(u8, @intCast((cursor.cursor_color.value >> 8) & 0xff)),
            .b = @as(u8, @intCast(cursor.cursor_color.value & 0xff)),
        },
        .default, .indexed => cursor.default_foreground,
    };
    return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = cursor.cursor_opacity };
}

fn cursorColorRgb(color_value: anytype, default_rgb: anytype) @TypeOf(default_rgb) {
    return switch (color_value.kind) {
        .rgb => .{
            .r = @as(u8, @intCast((color_value.value >> 16) & 0xff)),
            .g = @as(u8, @intCast((color_value.value >> 8) & 0xff)),
            .b = @as(u8, @intCast(color_value.value & 0xff)),
        },
        .default, .indexed => default_rgb,
    };
}

fn rgbFromRgba(value: render.Rgba8) render.Rgb8 {
    return .{ .r = value.r, .g = value.g, .b = value.b };
}

fn findCellByFirstCell(cells: []const render.RenderableCell, first_cell: u32) ?render.RenderableCell {
    for (cells) |cell| {
        if (cell.first_cell == first_cell) return cell;
    }
    return null;
}

fn rgbContrast(a: anytype, b: anytype) f32 {
    const a_luma = relativeLuminance(a);
    const b_luma = relativeLuminance(b);
    const high = @max(a_luma, b_luma);
    const low = @min(a_luma, b_luma);
    return (high + 0.05) / (low + 0.05);
}

fn relativeLuminance(rgb: anytype) f32 {
    return 0.2126 * channelLuminance(rgb.r) + 0.7152 * channelLuminance(rgb.g) + 0.0722 * channelLuminance(rgb.b);
}

fn channelLuminance(channel: u8) f32 {
    const scaled = @as(f32, @floatFromInt(channel)) / 255.0;
    return if (scaled <= 0.04045) scaled / 12.92 else std.math.pow(f32, (scaled + 0.055) / 1.055, 2.4);
}

fn assertCursorDrawCount(draw_count: usize, shape: anytype) void {
    std.debug.assert(draw_count == cursorDrawCountExact(shape));
}

fn defaultFontMetrics(cell_metrics: render.CellMetrics) render.FontMetrics {
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

fn decorationGeometry(cell_metrics: render.CellMetrics, font_metrics: render.FontMetrics) render.DecorationGeometry {
    return .{
        .underline_y_px = std.math.clamp(@as(i32, @intFromFloat(@round(font_metrics.underline_pos_px))), 0, @as(i32, @intCast(cell_metrics.cell_h_px - 1))),
        .underline_h_px = @max(@as(u16, @intFromFloat(@round(font_metrics.underline_thickness_px))), 1),
        .strikethrough_y_px = std.math.clamp(@as(i32, @intFromFloat(@round(font_metrics.strikethrough_pos_px))), 0, @as(i32, @intCast(cell_metrics.cell_h_px - 1))),
        .strikethrough_h_px = @max(@as(u16, @intFromFloat(@round(font_metrics.strikethrough_thickness_px))), 1),
    };
}

fn cursorGeometry(cursor: anytype, cell_metrics: render.CellMetrics) render.CursorGeometry {
    return .{
        .beam_w_px = configuredThicknessPx(cell_metrics.cell_w_px, cursor.beam_thickness),
        .underline_h_px = configuredThicknessPx(cell_metrics.cell_h_px, cursor.underline_thickness),
        .hollow_stroke_px = 2,
    };
}

fn configuredThicknessPx(cell_px: u16, thickness: f32) u16 {
    const scaled = @max((@as(f32, @floatFromInt(@max(cell_px, 1))) * thickness) / 16.0, 1.0);
    return @intFromFloat(@round(scaled));
}

fn resolveCursorFillColor(cursor: anytype, cells: []const render.RenderableCell, first_cell: u32) render.Rgba8 {
    const cell = findCellByFirstCell(cells, first_cell) orelse return cursorColor(cursor);
    const colors = resolveBlockCursorColors(cursor, rgbFromRgba(cell.fg), rgbFromRgba(cell.bg));
    return .{ .r = colors.cursor_bg.r, .g = colors.cursor_bg.g, .b = colors.cursor_bg.b, .a = cursor.cursor_opacity };
}

fn resolveCursorTrailColor(cursor: anytype, rect: anytype) render.Rgb8 {
    return switch (cursor.cursor_trail_color.kind) {
        .default => if (rect.color.r != 0 or rect.color.g != 0 or rect.color.b != 0)
            .{ .r = rect.color.r, .g = rect.color.g, .b = rect.color.b }
        else
            rgbFromRgba(cursorColor(cursor)),
        .rgb => cursorColorRgb(cursor.cursor_trail_color, cursor.default_foreground),
        .indexed => cursorColorRgb(cursor.cursor_trail_color, cursor.default_foreground),
    };
}

fn scaledDecorationThickness(cell_h_px: u16) u16 {
    return @intCast(@max(@divTrunc(@as(u32, @max(cell_h_px, 1)) + 15, 16), 1));
}

fn sameRgba8(a: render.Rgba8, b: render.Rgba8) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

fn testCursorPresentation() render.CursorPresentation {
    return .{
        .focused = true,
        .visible = true,
        .blink = false,
        .shape = .beam,
        .beam_thickness = 1.5,
        .underline_thickness = 2.0,
        .cursor_opacity = 255,
        .text_blink_opacity = 255,
        .cursor_color = .{ .kind = .rgb, .value = 0x102030 },
        .cursor_text_color = .{ .kind = .rgb, .value = 0x405060 },
        .cursor_trail_color = .{ .kind = .default, .value = 0 },
        .default_foreground = .{ .r = 0x10, .g = 0x20, .b = 0x30 },
        .default_background = .{ .r = 0x40, .g = 0x50, .b = 0x60 },
        .primary_extent = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 },
        .extra_cursors = [_]render.ExtraCursorPresentation{undefined} ** render.max_extra_cursors,
        .extra_cursor_count = 0,
        .trail = .{ .rects = [_]render.CursorTrailRect{.{ .extent = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 }, .opacity = 128, .color = .{ .r = 0, .g = 0, .b = 0 } }} ++ [_]render.CursorTrailRect{.{ .extent = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 }, .opacity = 0, .color = .{ .r = 0, .g = 0, .b = 0 } }} ** (render.max_cursor_trail_rects - 1), .count = 1 },
    };
}

test "configured beam and underline thickness affect cursor geometry" {
    const damage = text_damage.normalizeDamage(.{ .full = true }, 1);
    const cell_metrics = render.CellMetrics{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 };

    var beam = testCursorPresentation();
    beam.shape = .beam;
    beam.beam_thickness = 3.5;
    const beam_draws = try cursorDraws(std.testing.allocator, beam, cell_metrics);
    defer std.testing.allocator.free(beam_draws);
    try std.testing.expect(beam_draws[0].width_px > 1);

    var underline = testCursorPresentation();
    underline.shape = .underline;
    underline.underline_thickness = 4.0;
    var list = std.ArrayList(@import("draw_list.zig").CursorFillRect).empty;
    defer list.deinit(std.testing.allocator);
    try appendCursorFillRects(std.testing.allocator, &list, &.{}, .{ .cols = 1, .rows = 1 }, underline, cell_metrics);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expect(list.items[0].height_px > 1);
    _ = damage;
}

test "configured trail color overrides empty trail rect color" {
    var cursor = testCursorPresentation();
    cursor.cursor_trail_color = .{ .kind = .rgb, .value = 0x708090 };
    var list = std.ArrayList(@import("draw_list.zig").CursorTrailRect).empty;
    defer list.deinit(std.testing.allocator);
    try appendCursorTrailRects(std.testing.allocator, &list, .{ .cols = 1, .rows = 1 }, cursor, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(u8, 0x70), list.items[0].color.r);
}

test "cursor trail pixel rect bypasses cell extent scaling" {
    var cursor = testCursorPresentation();
    cursor.trail.rects[0].pixel_rect = true;
    cursor.trail.rects[0].x_px = 5;
    cursor.trail.rects[0].y_px = 7;
    cursor.trail.rects[0].width_px = 23;
    cursor.trail.rects[0].height_px = 29;

    var list = std.ArrayList(@import("draw_list.zig").CursorTrailRect).empty;
    defer list.deinit(std.testing.allocator);
    try appendCursorTrailRects(std.testing.allocator, &list, .{ .cols = 8, .rows = 4 }, cursor, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(i32, 5), list.items[0].x_px);
    try std.testing.expectEqual(@as(i32, 7), list.items[0].y_px);
    try std.testing.expectEqual(@as(u16, 23), list.items[0].width_px);
    try std.testing.expectEqual(@as(u16, 29), list.items[0].height_px);
}

test "visible no-shape produces no cursor draws fill or recolor" {
    const damage = text_damage.normalizeDamage(.{ .full = true }, 1);
    const cell_metrics = render.CellMetrics{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 };
    var cursor = testCursorPresentation();
    cursor.shape = .none;

    try std.testing.expectEqual(@as(usize, 0), countCursorDraws(@as(?@TypeOf(cursor), cursor), damage));
    try std.testing.expectEqual(@as(usize, 0), countCursorFillRects(@as(?@TypeOf(cursor), cursor), damage));
    try std.testing.expectEqual(@as(usize, 0), countCursorTextRecolorSpans(@as(?@TypeOf(cursor), cursor), damage));
    try std.testing.expectEqual(@as(usize, 1), countCursorTrailRects(@as(?@TypeOf(cursor), cursor), damage));

    const draws = try cursorDraws(std.testing.allocator, cursor, cell_metrics);
    defer std.testing.allocator.free(draws);
    try std.testing.expectEqual(@as(usize, 0), draws.len);

    var draw_list = std.ArrayList(render.TextCursorDraw).empty;
    defer draw_list.deinit(std.testing.allocator);
    var fill_list = std.ArrayList(@import("draw_list.zig").CursorFillRect).empty;
    defer fill_list.deinit(std.testing.allocator);
    var recolor_list = std.ArrayList(@import("draw_list.zig").CursorTextRecolorSpan).empty;
    defer recolor_list.deinit(std.testing.allocator);
    var trail_list = std.ArrayList(@import("draw_list.zig").CursorTrailRect).empty;
    defer trail_list.deinit(std.testing.allocator);
    try appendCursorPrimitives(std.testing.allocator, &draw_list, &fill_list, &recolor_list, &trail_list, &.{}, .{ .cols = 1, .rows = 1 }, cursor, damage, cell_metrics);
    try std.testing.expectEqual(@as(usize, 0), draw_list.items.len);
    try std.testing.expectEqual(@as(usize, 0), fill_list.items.len);
    try std.testing.expectEqual(@as(usize, 0), recolor_list.items.len);
    try std.testing.expectEqual(@as(usize, 1), trail_list.items.len);
}
