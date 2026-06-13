const std = @import("std");
const c = @import("howl_render_c");
const source_cell = @import("../tv_surface/cell.zig");

pub const SourceRgb = c.HowlVtRgb8;
pub const SourceColor = c.HowlVtColor;
pub const SourceColors = c.HowlVtRenderColorState;
pub const SourceCellFlags = c.HowlVtSurfaceCellFlags;
pub const SourceCellAttrs = c.HowlVtSurfaceCellAttrs;
pub const SourceCell = c.HowlVtSurfaceCell;
pub const SourceSelectionPoint = c.HowlVtSelectionPos;
pub const SourceSelection = c.HowlVtSelection;
pub const SourceCursor = source_cell.CursorInfo;

pub fn validateSourceCell(cell: SourceCell) !void {
    if (cell.codepoint > std.math.maxInt(u21)) return error.InvalidSurfaceSource;
    if (cell.combining_len > cell.combining.len) return error.InvalidSurfaceSource;
    for (cell.combining[0..cell.combining_len]) |codepoint| {
        if (codepoint > std.math.maxInt(u21)) return error.InvalidSurfaceSource;
    }
    if (!sourceColorValid(cell.fg_color)) return error.InvalidSurfaceSource;
    if (!sourceColorValid(cell.bg_color)) return error.InvalidSurfaceSource;
    if (!sourceColorValid(cell.underline_color)) return error.InvalidSurfaceSource;
    if (!underlineStyleValid(cell.underline_style)) return error.InvalidSurfaceSource;
}

pub fn validateSourceCells(cells: []const SourceCell) !void {
    for (cells) |cell| try validateSourceCell(cell);
}

pub fn sourceColorValid(color: anytype) bool {
    return switch (color.kind) {
        0 => true,
        1 => color.value <= std.math.maxInt(u8),
        2 => color.value <= std.math.maxInt(u24),
        else => false,
    };
}

pub fn underlineStyleValid(value: u8) bool {
    return value <= 4;
}

pub fn validatePublicationSurfaceResult(result: anytype) !void {
    if (result.status != c.HOWL_VT_CALL_OK) return error.InvalidSurfaceSource;
    if (result.snapshot_seq == 0) return error.InvalidSurfaceSource;
    if (result.dirty_generation == 0) return error.InvalidSurfaceSource;
    if (result.scrollback_offset > result.history_count) return error.InvalidSurfaceSource;

    const surface = result.source;
    if (surface.cols == 0) return error.InvalidSurfaceSource;
    if (surface.rows == 0) return error.InvalidSurfaceSource;

    const cell_count = surfaceCellCountChecked(surface.cols, surface.rows) catch return error.InvalidSurfaceSource;
    if (surface.surface_cells.ptr == null or surface.surface_cells.len != cell_count) return error.InvalidSurfaceSource;
    if (surface.dirty_rows.ptr == null or surface.dirty_rows.len != surface.rows) return error.InvalidSurfaceSource;
    if (surface.dirty_cols_start.ptr == null or surface.dirty_cols_start.len != surface.rows) return error.InvalidSurfaceSource;
    if (surface.dirty_cols_end.ptr == null or surface.dirty_cols_end.len != surface.rows) return error.InvalidSurfaceSource;
    if (surface.cursor.shape > 3) return error.InvalidSurfaceSource;

    const dirty_rows = surface.dirty_rows.ptr[0..surface.dirty_rows.len];
    const dirty_cols_start = surface.dirty_cols_start.ptr[0..surface.dirty_cols_start.len];
    const dirty_cols_end = surface.dirty_cols_end.ptr[0..surface.dirty_cols_end.len];
    validateDirtySource(surface.rows, surface.cols, dirty_rows, dirty_cols_start, dirty_cols_end) catch return error.InvalidSurfaceSource;
    for (surface.surface_cells.ptr[0..surface.surface_cells.len]) |cell| try validateSourceCellAny(cell);
}

fn surfaceCellCountChecked(cols: u16, rows: u16) !usize {
    return std.math.mul(usize, cols, rows);
}

fn validateSourceCellAny(cell: anytype) !void {
    if (cell.codepoint > std.math.maxInt(u21)) return error.InvalidSurfaceSource;
    if (cell.combining_len > cell.combining.len) return error.InvalidSurfaceSource;
    for (cell.combining[0..cell.combining_len]) |codepoint| {
        if (codepoint > std.math.maxInt(u21)) return error.InvalidSurfaceSource;
    }
    if (!sourceColorValid(cell.fg_color)) return error.InvalidSurfaceSource;
    if (!sourceColorValid(cell.bg_color)) return error.InvalidSurfaceSource;
    if (!sourceColorValid(cell.underline_color)) return error.InvalidSurfaceSource;
    if (!underlineStyleValid(cell.underline_style)) return error.InvalidSurfaceSource;
}

fn validateDirtySource(rows: u16, cols: u16, dirty_rows: []const u8, dirty_cols_start: []const u16, dirty_cols_end: []const u16) !void {
    if (dirty_rows.len != rows) return error.InvalidSurfaceSource;
    if (dirty_cols_start.len != rows) return error.InvalidSurfaceSource;
    if (dirty_cols_end.len != rows) return error.InvalidSurfaceSource;

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const dirty = dirty_rows[row];
        const start_col = dirty_cols_start[row];
        const end_col = dirty_cols_end[row];
        if (dirty == 0) continue;
        if (dirty != 1) return error.InvalidSurfaceSource;
        if (start_col == cols and end_col == 0) continue;
        if (start_col >= cols) return error.InvalidSurfaceSource;
        if (end_col >= cols) return error.InvalidSurfaceSource;
        if (end_col < start_col) return error.InvalidSurfaceSource;
    }
}
