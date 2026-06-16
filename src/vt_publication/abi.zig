const std = @import("std");
const c = @import("howl_render_c");

pub const SourceRgb = c.HowlVtRgb8;
pub const SourceColor = c.HowlVtColor;
pub const SourceColors = c.HowlVtRenderColorState;
pub const SourceCellFlags = c.HowlVtSurfaceCellFlags;
pub const SourceCellAttrs = c.HowlVtSurfaceCellAttrs;
pub const SourceCell = c.HowlVtSurfaceCell;
pub const SourceSelectionPoint = c.HowlVtSelectionPos;
pub const SourceSelection = c.HowlVtSelection;

pub const max_extra_cursors = 256;
pub const max_cursor_trail_rects = 16;

pub const SourceCursorShape = enum(u8) {
    block = 0,
    underline = 1,
    beam = 2,
    none = 3,
    hollow_block = 4,
};

pub const SourceExtraCursorShape = enum(u8) {
    none = 0,
    block = 1,
    beam = 2,
    underline = 3,
    hollow = 4,
};

pub const SourceExtraCursorMode = enum(u8) {
    point = 0,
    rectangle = 1,
};

pub const SourceCursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
    shape: SourceCursorShape = .block,
    blink: bool = false,
    position_changed_by_client_at_ms: u64 = 0,
    cell_cols: u16 = 1,
    cell_rows: u16 = 1,
    cursor_color: SourceColor = .{ .kind = 0, .value = 0 },
    cursor_text_color: SourceColor = .{ .kind = 0, .value = 0 },
    cursor_opacity: u8 = 255,
    text_blink_opacity: u8 = 255,
    focused: bool = true,
    effective_shape: SourceCursorShape = .block,
};

pub const SourceExtraCursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    rows: u16 = 0,
    cols: u16 = 0,
    shape: SourceExtraCursorShape = .none,
    mode: SourceExtraCursorMode = .point,
    shape_follows_main: bool = false,
    color_follows_main: bool = false,
    cursor_color: SourceColor = .{ .kind = 0, .value = 0 },
    text_color: SourceColor = .{ .kind = 0, .value = 0 },
};

pub const SourceCursorTrailRect = struct {
    row: u16 = 0,
    col: u16 = 0,
    rows: u16 = 0,
    cols: u16 = 0,
    opacity: u8 = 0,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    color: SourceRgb = .{ .r = 0, .g = 0, .b = 0 },
    pixel_rect: bool = false,
    x_px: i32 = 0,
    y_px: i32 = 0,
    width_px: u16 = 0,
    height_px: u16 = 0,
};

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
    if (!sourceColorValid(surface.cursor_color)) return error.InvalidSurfaceSource;
    if (!sourceColorValid(surface.cursor_text_color)) return error.InvalidSurfaceSource;
    if (surface.cursor.cell_cols == 0) return error.InvalidSurfaceSource;
    if (surface.cursor.cell_rows == 0) return error.InvalidSurfaceSource;
    if (surface.extra_cursor_count > max_extra_cursors) return error.InvalidSurfaceSource;

    for (surface.extra_cursors[0..surface.extra_cursor_count]) |cursor| {
        if (cursor.shape > @intFromEnum(SourceExtraCursorShape.hollow)) return error.InvalidSurfaceSource;
        if (cursor.mode > @intFromEnum(SourceExtraCursorMode.rectangle)) return error.InvalidSurfaceSource;
        if (!sourceColorValid(cursor.cursor_color)) return error.InvalidSurfaceSource;
        if (!sourceColorValid(cursor.text_color)) return error.InvalidSurfaceSource;
    }

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

test "source abi rejects widened vt cursor and extra cursor enum violations" {
    var cells = [_]SourceCell{ std.mem.zeroes(SourceCell), std.mem.zeroes(SourceCell) };
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{0};
    const dirty_cols_end = [_]u16{1};
    var result = @import("publication.zig").validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);

    result.source.cursor.cell_cols = 0;
    try std.testing.expectError(error.InvalidSurfaceSource, validatePublicationSurfaceResult(result));

    result = @import("publication.zig").validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);
    result.source.cursor_color.kind = 3;
    try std.testing.expectError(error.InvalidSurfaceSource, validatePublicationSurfaceResult(result));

    result = @import("publication.zig").validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);
    result.source.extra_cursor_count = max_extra_cursors + 1;
    try std.testing.expectError(error.InvalidSurfaceSource, validatePublicationSurfaceResult(result));

    result = @import("publication.zig").validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);
    result.source.cursor.shape = 3;
    try validatePublicationSurfaceResult(result);

    result = @import("publication.zig").validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);
    result.source.cursor.shape = 4;
    try std.testing.expectError(error.InvalidSurfaceSource, validatePublicationSurfaceResult(result));

    result = @import("publication.zig").validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);
    result.source.extra_cursor_count = 1;
    result.source.extra_cursors[0].shape = 5;
    try std.testing.expectError(error.InvalidSurfaceSource, validatePublicationSurfaceResult(result));
}
