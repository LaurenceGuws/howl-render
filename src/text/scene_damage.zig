const std = @import("std");
const contract = @import("contract.zig");

pub const DamageInput = struct {
    full: bool = true,
    dirty_rows: []const bool = &.{},
    dirty_cols_start: []const u16 = &.{},
    dirty_cols_end: []const u16 = &.{},
};

pub const NormalizedDamage = struct {
    full: bool,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
};

pub const DirtyRowSpan = struct {
    row: u16,
    start_col: u16,
    end_col: u16,

    pub fn firstCell(self: DirtyRowSpan, grid_metrics: contract.GridMetrics) u32 {
        return @as(u32, self.row) * @as(u32, @max(grid_metrics.cols, 1)) + @as(u32, self.start_col);
    }

    pub fn cellSpan(self: DirtyRowSpan) u8 {
        const span_u32 = @as(u32, self.end_col - self.start_col) + 1;
        return @intCast(@min(span_u32, @as(u32, std.math.maxInt(u8))));
    }
};

const CellSpan = struct {
    row: u16,
    start_col: u16,
    end_col: u16,

    fn init(grid_metrics: contract.GridMetrics, first_cell: u32, cell_span: u8) CellSpan {
        const cols = @max(@as(u32, grid_metrics.cols), 1);
        const start_col_u32 = first_cell % cols;
        const span_u32 = @as(u32, @max(cell_span, 1));
        return .{
            .row = @intCast(first_cell / cols),
            .start_col = @intCast(start_col_u32),
            .end_col = @intCast(start_col_u32 + span_u32 - 1),
        };
    }

    pub fn overlaps(self: CellSpan, other: CellSpan) bool {
        if (self.row != other.row) return false;
        return !(self.end_col < other.start_col or self.start_col > other.end_col);
    }
};

pub fn normalizeDamage(damage: DamageInput, rows: u16) NormalizedDamage {
    const row_len = rows;
    if (!damage.full) assertDamageRowLengths(damage, rows);
    const valid = !damage.full and
        count16(damage.dirty_rows) == row_len and
        count16(damage.dirty_cols_start) == row_len and
        count16(damage.dirty_cols_end) == row_len;
    return .{
        .full = !valid,
        .dirty_rows = if (valid) damage.dirty_rows else &.{},
        .dirty_cols_start = if (valid) damage.dirty_cols_start else &.{},
        .dirty_cols_end = if (valid) damage.dirty_cols_end else &.{},
    };
}

pub fn assertDamageRowLengths(damage: DamageInput, rows: u16) void {
    std.debug.assert(damage.dirty_rows.len == rows);
    std.debug.assert(damage.dirty_cols_start.len == rows);
    std.debug.assert(damage.dirty_cols_end.len == rows);
}

pub fn damageRowCount(damage: NormalizedDamage) u16 {
    std.debug.assert(damage.dirty_rows.len == damage.dirty_cols_start.len);
    std.debug.assert(damage.dirty_rows.len == damage.dirty_cols_end.len);
    std.debug.assert(damage.dirty_rows.len <= std.math.maxInt(u16));
    return @intCast(damage.dirty_rows.len);
}

pub fn rowDirty(damage: NormalizedDamage, row: u16) bool {
    if (damage.full) return true;
    return row < count16(damage.dirty_rows) and damage.dirty_rows[@intCast(row)];
}

pub fn dirtyRowSpan(damage: NormalizedDamage, grid_metrics: contract.GridMetrics, row: u16) ?DirtyRowSpan {
    if (damage.full) return null;
    if (!rowDirty(damage, row)) return null;

    const cols = @max(grid_metrics.cols, 1);
    const last_col: u16 = cols - 1;
    const start_col = @min(damage.dirty_cols_start[@intCast(row)], last_col);
    const end_col = @min(damage.dirty_cols_end[@intCast(row)], last_col);
    if (end_col < start_col) return null;

    return .{
        .row = row,
        .start_col = start_col,
        .end_col = end_col,
    };
}

pub fn includeSpan(damage: NormalizedDamage, grid_metrics: contract.GridMetrics, first_cell: u32, cell_span: u8) bool {
    if (damage.full) return true;
    const cell = CellSpan.init(grid_metrics, first_cell, cell_span);
    const dirty = dirtyRowSpan(damage, grid_metrics, cell.row) orelse return false;
    return !(cell.end_col < dirty.start_col or cell.start_col > dirty.end_col);
}

pub fn cleanRowSkip(damage: NormalizedDamage, grid_metrics: contract.GridMetrics, idx: u32, cells_len: u32) ?u32 {
    if (damage.full) return null;
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const row = idx / cols;
    if (row >= count32(damage.dirty_rows)) return cells_len;
    if (damage.dirty_rows[@intCast(row)]) return null;
    return @min((row + 1) * cols, cells_len);
}

pub fn dirtySpanOverlapsCellSpan(grid_metrics: contract.GridMetrics, dirty: DirtyRowSpan, cell: contract.RenderableCell) bool {
    const dirty_span = CellSpan{ .row = dirty.row, .start_col = dirty.start_col, .end_col = dirty.end_col };
    return CellSpan.init(grid_metrics, cell.first_cell, cell.cell_span).overlaps(dirty_span);
}

fn count16(items: anytype) u16 {
    std.debug.assert(items.len <= std.math.maxInt(u16));
    return @intCast(items.len);
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}
