const std = @import("std");
const c = @import("howl_render_c");

pub const VtSurfaceSnapshot = struct {
    cols: u16,
    rows: u16,
    history_count: u64,
    scroll_row: u64,
    snapshot_seq: u64,
    dirty_epoch: u64,
    is_alternate_screen: bool,
    dirty_rows: []const u8,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
};

pub const VtSurface = struct {
    cols: u16,
    rows: u16,
    history_count: u64,
    scroll_row: u64,
    snapshot_seq: u64,
    dirty_epoch: u64,
    is_alternate_screen: bool,
    cells: []c.HowlVtSurfaceCell,
    cursor: c.HowlVtCursor,
    cursor_color: c.HowlVtColor = .{ .kind = 0, .value = 0 },
    cursor_text_color: c.HowlVtColor = .{ .kind = 0, .value = 0 },
    cursor_opacity: u8 = 255,
    text_blink_opacity: u8 = 255,
    cursor_focused: bool = true,
    effective_shape: u8 = c.HOWL_VT_CURSOR_SHAPE_BLOCK,
    extra_cursor_count: u16 = 0,
    extra_cursors: [c.HOWL_VT_MAX_EXTRA_CURSORS]c.HowlVtExtraCursor = [_]c.HowlVtExtraCursor{.{}} ** c.HOWL_VT_MAX_EXTRA_CURSORS,
    cursor_trail_count: u16 = 0,
    cursor_trail_rects: [c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX]c.HowlRenderHostCursorTrailRect = [_]c.HowlRenderHostCursorTrailRect{.{}} ** c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX,
    colors: c.HowlVtRenderColorState,
    selection: c.HowlVtSelection,
    // Compatibility field for later-slice consumers still reading blink visibility directly.
    cursor_phase_visible: bool,
    dirty_rows: []u8 = &.{},
    dirty_cols_start: []u16 = &.{},
    dirty_cols_end: []u16 = &.{},
    retained_storage: bool = false,

    pub fn deinit(self: *VtSurface, allocator: std.mem.Allocator) void {
        if (!self.retained_storage) {
            allocator.free(self.cells);
            if (self.dirty_rows.len > 0) allocator.free(self.dirty_rows);
            if (self.dirty_cols_start.len > 0) allocator.free(self.dirty_cols_start);
            if (self.dirty_cols_end.len > 0) allocator.free(self.dirty_cols_end);
        }
        self.* = undefined;
    }

    pub fn clone(self: *const VtSurface, allocator: std.mem.Allocator) !VtSurface {
        const cells = try allocator.dupe(c.HowlVtSurfaceCell, self.cells);
        errdefer allocator.free(cells);
        const dirty_rows = try allocator.dupe(u8, self.dirty_rows);
        errdefer allocator.free(dirty_rows);
        const dirty_cols_start = try allocator.dupe(u16, self.dirty_cols_start);
        errdefer allocator.free(dirty_cols_start);
        const dirty_cols_end = try allocator.dupe(u16, self.dirty_cols_end);
        errdefer allocator.free(dirty_cols_end);
        return .{
            .cols = self.cols,
            .rows = self.rows,
            .history_count = self.history_count,
            .scroll_row = self.scroll_row,
            .snapshot_seq = self.snapshot_seq,
            .dirty_epoch = self.dirty_epoch,
            .is_alternate_screen = self.is_alternate_screen,
            .cells = cells,
            .cursor = self.cursor,
            .cursor_color = self.cursor_color,
            .cursor_text_color = self.cursor_text_color,
            .cursor_opacity = self.cursor_opacity,
            .text_blink_opacity = self.text_blink_opacity,
            .cursor_focused = self.cursor_focused,
            .effective_shape = self.effective_shape,
            .extra_cursor_count = self.extra_cursor_count,
            .extra_cursors = self.extra_cursors,
            .cursor_trail_count = self.cursor_trail_count,
            .cursor_trail_rects = self.cursor_trail_rects,
            .colors = self.colors,
            .selection = self.selection,
            .cursor_phase_visible = self.cursor_phase_visible,
            .dirty_rows = dirty_rows,
            .dirty_cols_start = dirty_cols_start,
            .dirty_cols_end = dirty_cols_end,
            .retained_storage = false,
        };
    }

    pub fn snapshot(self: *const VtSurface) VtSurfaceSnapshot {
        return .{
            .cols = self.cols,
            .rows = self.rows,
            .history_count = self.history_count,
            .scroll_row = self.scroll_row,
            .snapshot_seq = self.snapshot_seq,
            .dirty_epoch = self.dirty_epoch,
            .is_alternate_screen = self.is_alternate_screen,
            .dirty_rows = self.dirty_rows,
            .dirty_cols_start = self.dirty_cols_start,
            .dirty_cols_end = self.dirty_cols_end,
        };
    }
};

pub fn validateVtSurfaceBoundary(source: VtSurface) !void {
    if (source.cols == 0) return error.InvalidSurfaceSource;
    if (source.rows == 0) return error.InvalidSurfaceSource;
    const cell_count = cellCountChecked(source.cols, source.rows) catch return error.InvalidSurfaceSource;
    if (source.cells.len != cell_count) return error.InvalidSurfaceSource;
    if (source.cursor.cell_cols == 0) return error.InvalidSurfaceSource;
    if (source.cursor.cell_rows == 0) return error.InvalidSurfaceSource;
    if (!vtSurfaceColorValid(source.cursor_color)) return error.InvalidSurfaceSource;
    if (!vtSurfaceColorValid(source.cursor_text_color)) return error.InvalidSurfaceSource;
    try validateVtSurfaceCells(source.cells);
    if (source.extra_cursor_count > c.HOWL_VT_MAX_EXTRA_CURSORS) return error.InvalidSurfaceSource;
    if (source.cursor_trail_count > c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX) return error.InvalidSurfaceSource;
    for (source.extra_cursors[0..source.extra_cursor_count]) |cursor| {
        if (cursor.rows == 0) return error.InvalidSurfaceSource;
        if (cursor.cols == 0) return error.InvalidSurfaceSource;
        if (!vtSurfaceColorValid(cursor.cursor_color)) return error.InvalidSurfaceSource;
        if (!vtSurfaceColorValid(cursor.text_color)) return error.InvalidSurfaceSource;
    }
    for (source.cursor_trail_rects[0..source.cursor_trail_count]) |rect| {
        if (rect.rows == 0) return error.InvalidSurfaceSource;
        if (rect.cols == 0) return error.InvalidSurfaceSource;
    }
    try validateDirtyVtSurface(
        source.rows,
        source.cols,
        source.dirty_rows,
        source.dirty_cols_start,
        source.dirty_cols_end,
    );
}

pub fn validateVtSurfaceCell(cell: c.HowlVtSurfaceCell) !void {
    if (cell.codepoint > std.math.maxInt(u21)) return error.InvalidSurfaceSource;
    if (cell.combining_len > cell.combining.len) return error.InvalidSurfaceSource;
    for (cell.combining[0..cell.combining_len]) |codepoint| {
        if (codepoint > std.math.maxInt(u21)) return error.InvalidSurfaceSource;
    }
    if (!vtSurfaceColorValid(cell.fg_color)) return error.InvalidSurfaceSource;
    if (!vtSurfaceColorValid(cell.bg_color)) return error.InvalidSurfaceSource;
    if (!vtSurfaceColorValid(cell.underline_color)) return error.InvalidSurfaceSource;
    if (!underlineStyleValid(cell.underline_style)) return error.InvalidSurfaceSource;
}

pub fn validateVtSurfaceCells(cells: []const c.HowlVtSurfaceCell) !void {
    for (cells) |cell| try validateVtSurfaceCell(cell);
}

pub fn vtSurfaceColorValid(color: anytype) bool {
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

pub fn validateVtSurfaceResult(result: anytype) !void {
    if (result.status != c.HOWL_VT_CALL_OK) return error.InvalidSurfaceSource;
    if (result.snapshot_seq == 0) return error.InvalidSurfaceSource;
    if (result.dirty_generation == 0) return error.InvalidSurfaceSource;
    if (result.scrollback_offset > result.history_count) return error.InvalidSurfaceSource;

    const surface = result.source;
    if (surface.cols == 0) return error.InvalidSurfaceSource;
    if (surface.rows == 0) return error.InvalidSurfaceSource;

    const cell_count = cellCountChecked(surface.cols, surface.rows) catch return error.InvalidSurfaceSource;
    if (surface.surface_cells.ptr == null or surface.surface_cells.len != cell_count) return error.InvalidSurfaceSource;
    if (surface.dirty_rows.ptr == null or surface.dirty_rows.len != surface.rows) return error.InvalidSurfaceSource;
    if (surface.dirty_cols_start.ptr == null or surface.dirty_cols_start.len != surface.rows) return error.InvalidSurfaceSource;
    if (surface.dirty_cols_end.ptr == null or surface.dirty_cols_end.len != surface.rows) return error.InvalidSurfaceSource;
    if (surface.cursor.shape > 3) return error.InvalidSurfaceSource;
    if (!vtSurfaceColorValid(surface.cursor_color)) return error.InvalidSurfaceSource;
    if (!vtSurfaceColorValid(surface.cursor_text_color)) return error.InvalidSurfaceSource;
    if (surface.cursor.cell_cols == 0) return error.InvalidSurfaceSource;
    if (surface.cursor.cell_rows == 0) return error.InvalidSurfaceSource;
    if (surface.extra_cursor_count > c.HOWL_VT_MAX_EXTRA_CURSORS) return error.InvalidSurfaceSource;

    for (surface.extra_cursors[0..surface.extra_cursor_count]) |cursor| {
        if (cursor.shape > 4) return error.InvalidSurfaceSource;
        if (cursor.mode > 1) return error.InvalidSurfaceSource;
        if (!vtSurfaceColorValid(cursor.cursor_color)) return error.InvalidSurfaceSource;
        if (!vtSurfaceColorValid(cursor.text_color)) return error.InvalidSurfaceSource;
    }

    const dirty_rows = surface.dirty_rows.ptr[0..surface.dirty_rows.len];
    const dirty_cols_start = surface.dirty_cols_start.ptr[0..surface.dirty_cols_start.len];
    const dirty_cols_end = surface.dirty_cols_end.ptr[0..surface.dirty_cols_end.len];
    validateDirtyVtSurface(surface.rows, surface.cols, dirty_rows, dirty_cols_start, dirty_cols_end) catch return error.InvalidSurfaceSource;
    for (surface.surface_cells.ptr[0..surface.surface_cells.len]) |cell| try validateVtSurfaceCell(cell);
}

pub fn vtSurfaceFromResult(allocator: std.mem.Allocator, result: anytype, cursor_phase_visible: bool) !VtSurface {
    try validateVtSurfaceResult(result);

    const surface = result.source;
    const cell_count = try cellCountChecked(surface.cols, surface.rows);
    std.debug.assert(surface.surface_cells.len == cell_count);
    std.debug.assert(surface.dirty_rows.len == surface.rows);
    std.debug.assert(surface.dirty_cols_start.len == surface.rows);
    std.debug.assert(surface.dirty_cols_end.len == surface.rows);

    const cells = try allocator.alloc(c.HowlVtSurfaceCell, cell_count);
    errdefer allocator.free(cells);
    @memcpy(cells, surface.surface_cells.ptr[0..surface.surface_cells.len]);
    std.debug.assert(cells.len == cell_count);

    const dirty_rows = try allocator.dupe(u8, surface.dirty_rows.ptr[0..surface.dirty_rows.len]);
    errdefer allocator.free(dirty_rows);
    const dirty_cols_start = try allocator.dupe(u16, surface.dirty_cols_start.ptr[0..surface.dirty_cols_start.len]);
    errdefer allocator.free(dirty_cols_start);
    const dirty_cols_end = try allocator.dupe(u16, surface.dirty_cols_end.ptr[0..surface.dirty_cols_end.len]);
    errdefer allocator.free(dirty_cols_end);

    return .{
        .cols = surface.cols,
        .rows = surface.rows,
        .history_count = result.history_count,
        .scroll_row = surface.scroll_row,
        .snapshot_seq = result.snapshot_seq,
        .dirty_epoch = result.dirty_generation,
        .is_alternate_screen = surface.is_alternate_screen != 0,
        .cells = cells,
        .cursor = surface.cursor,
        .cursor_color = surface.cursor_color,
        .cursor_text_color = surface.cursor_text_color,
        .effective_shape = surface.cursor.shape,
        .extra_cursor_count = surface.extra_cursor_count,
        .extra_cursors = extraCursorsIn(surface.extra_cursors, surface.extra_cursor_count),
        .cursor_trail_count = 0,
        .cursor_trail_rects = [_]c.HowlRenderHostCursorTrailRect{.{}} ** c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX,
        .colors = surface.colors,
        .selection = surface.selection,
        .cursor_phase_visible = cursor_phase_visible,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

pub fn testVtSurfaceFromSnapshot(allocator: std.mem.Allocator, snapshot: VtSurfaceSnapshot) !VtSurface {
    std.debug.assert(snapshot.cols > 0);
    std.debug.assert(snapshot.rows > 0);
    std.debug.assert(snapshot.dirty_rows.len == snapshot.rows);
    std.debug.assert(snapshot.dirty_cols_start.len == snapshot.rows);
    std.debug.assert(snapshot.dirty_cols_end.len == snapshot.rows);

    const cell_count = try cellCountChecked(snapshot.cols, snapshot.rows);
    const cells = try allocator.alloc(c.HowlVtSurfaceCell, cell_count);
    errdefer allocator.free(cells);
    @memset(cells, std.mem.zeroes(c.HowlVtSurfaceCell));
    const dirty_rows = try allocator.dupe(u8, snapshot.dirty_rows);
    errdefer allocator.free(dirty_rows);
    const dirty_cols_start = try allocator.dupe(u16, snapshot.dirty_cols_start);
    errdefer allocator.free(dirty_cols_start);
    const dirty_cols_end = try allocator.dupe(u16, snapshot.dirty_cols_end);
    errdefer allocator.free(dirty_cols_end);
    return .{
        .cols = snapshot.cols,
        .rows = snapshot.rows,
        .history_count = snapshot.history_count,
        .scroll_row = snapshot.scroll_row,
        .snapshot_seq = snapshot.snapshot_seq,
        .dirty_epoch = snapshot.dirty_epoch,
        .is_alternate_screen = snapshot.is_alternate_screen,
        .cells = cells,
        .cursor = std.mem.zeroes(c.HowlVtCursor),
        .cursor_color = .{ .kind = 0, .value = 0 },
        .cursor_text_color = .{ .kind = 0, .value = 0 },
        .effective_shape = c.HOWL_VT_CURSOR_SHAPE_BLOCK,
        .extra_cursor_count = 0,
        .extra_cursors = [_]c.HowlVtExtraCursor{.{}} ** c.HOWL_VT_MAX_EXTRA_CURSORS,
        .cursor_trail_count = 0,
        .cursor_trail_rects = [_]c.HowlRenderHostCursorTrailRect{.{}} ** c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX,
        .colors = std.mem.zeroes(c.HowlVtRenderColorState),
        .selection = std.mem.zeroes(c.HowlVtSelection),
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

pub fn ownedTestVtSurface(allocator: std.mem.Allocator, snapshot_seq: u64, codepoint: u21) !VtSurface {
    const cells = try allocator.alloc(c.HowlVtSurfaceCell, 1);
    errdefer allocator.free(cells);
    cells[0] = std.mem.zeroes(c.HowlVtSurfaceCell);
    cells[0].codepoint = codepoint;
    const dirty_rows = try allocator.dupe(u8, &[_]u8{1});
    errdefer allocator.free(dirty_rows);
    const dirty_cols_start = try allocator.dupe(u16, &[_]u16{0});
    errdefer allocator.free(dirty_cols_start);
    const dirty_cols_end = try allocator.dupe(u16, &[_]u16{0});
    errdefer allocator.free(dirty_cols_end);
    return .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = snapshot_seq,
        .dirty_epoch = snapshot_seq,
        .is_alternate_screen = false,
        .cells = cells,
        .cursor = std.mem.zeroes(c.HowlVtCursor),
        .cursor_color = .{ .kind = 0, .value = 0 },
        .cursor_text_color = .{ .kind = 0, .value = 0 },
        .effective_shape = c.HOWL_VT_CURSOR_SHAPE_BLOCK,
        .extra_cursor_count = 0,
        .extra_cursors = [_]c.HowlVtExtraCursor{.{}} ** c.HOWL_VT_MAX_EXTRA_CURSORS,
        .cursor_trail_count = 0,
        .cursor_trail_rects = [_]c.HowlRenderHostCursorTrailRect{.{}} ** c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX,
        .colors = std.mem.zeroes(c.HowlVtRenderColorState),
        .selection = std.mem.zeroes(c.HowlVtSelection),
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

fn cellCountChecked(cols: u16, rows: u16) !usize {
    return std.math.mul(usize, cols, rows);
}

fn validateDirtyVtSurface(rows: u16, cols: u16, dirty_rows: []const u8, dirty_cols_start: []const u16, dirty_cols_end: []const u16) !void {
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

fn validTestCell() c.HowlVtSurfaceCell {
    var cell = std.mem.zeroes(c.HowlVtSurfaceCell);
    cell.codepoint = 'A';
    return cell;
}

fn extraCursorsIn(value: [c.HOWL_VT_MAX_EXTRA_CURSORS]c.HowlVtExtraCursor, count: u16) [c.HOWL_VT_MAX_EXTRA_CURSORS]c.HowlVtExtraCursor {
    var out = [_]c.HowlVtExtraCursor{.{}} ** c.HOWL_VT_MAX_EXTRA_CURSORS;
    for (out[0..count], value[0..count]) |*target, source| target.* = source;
    return out;
}

pub fn validSurfaceResult(cells: []const c.HowlVtSurfaceCell, dirty_rows: []const u8, dirty_cols_start: []const u16, dirty_cols_end: []const u16) c.HowlVtSurfaceResult {
    return .{
        .status = c.HOWL_VT_CALL_OK,
        .history_count = 7,
        .scrollback_offset = 3,
        .snapshot_seq = 11,
        .dirty_generation = 13,
        .source = .{
            .surface_cells = .{ .ptr = cells.ptr, .len = cells.len },
            .cols = 2,
            .rows = 1,
            .scroll_row = 5,
            .is_alternate_screen = 1,
            .reserved0 = 0,
            .reserved1 = 0,
            .dirty_rows = .{ .ptr = dirty_rows.ptr, .len = dirty_rows.len },
            .dirty_cols_start = .{ .ptr = dirty_cols_start.ptr, .len = dirty_cols_start.len },
            .dirty_cols_end = .{ .ptr = dirty_cols_end.ptr, .len = dirty_cols_end.len },
            .cursor = .{ .row = 0, .col = 1, .visible = 1, .shape = 2, .blink = 1, .reserved0 = 0, .position_changed_by_client_at_ms = 17, .cell_cols = 1, .cell_rows = 1 },
            .cursor_color = .{ .kind = 2, .value = 0x010203 },
            .cursor_text_color = .{ .kind = 1, .value = 7 },
            .extra_cursor_count = 0,
            .extra_cursors = [_]c.HowlVtExtraCursor{.{}} ** c.HOWL_VT_MAX_EXTRA_CURSORS,
            .colors = std.mem.zeroes(c.HowlVtRenderColorState),
            .selection = .{ .active = 1, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 1 } },
        },
    };
}

test "vt surface rejects source cell codepoint above u21" {
    var cell = validTestCell();
    cell.codepoint = @as(u32, std.math.maxInt(u21)) + 1;
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceCell(cell));
}

test "vt surface rejects combining length beyond storage" {
    var cell = validTestCell();
    cell.combining_len = 4;
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceCell(cell));
}

test "vt surface rejects active combining codepoint above u21" {
    var cell = validTestCell();
    cell.combining_len = 1;
    cell.combining[0] = @as(u32, std.math.maxInt(u21)) + 1;
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceCell(cell));
}

test "vt surface rejects invalid color kind" {
    var cell = validTestCell();
    cell.fg_color = .{ .kind = 3, .value = 0 };
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceCell(cell));
}

test "vt surface rejects indexed color outside u8" {
    var cell = validTestCell();
    cell.bg_color = .{ .kind = 1, .value = @as(u32, std.math.maxInt(u8)) + 1 };
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceCell(cell));
}

test "vt surface rejects rgb color outside u24" {
    var cell = validTestCell();
    cell.underline_color = .{ .kind = 2, .value = @as(u32, std.math.maxInt(u24)) + 1 };
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceCell(cell));
}

test "vt surface rejects underline style above shipped range" {
    var cell = validTestCell();
    cell.underline_style = 5;
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceCell(cell));
}

test "vt surface boundary rejects dirty span length mismatch" {
    var cells = [_]c.HowlVtSurfaceCell{validTestCell()};
    var dirty_cols_start = [_]u16{0};
    var dirty_cols_end = [_]u16{0};
    const source = VtSurface{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = std.mem.zeroes(c.HowlVtCursor),
        .colors = std.mem.zeroes(c.HowlVtRenderColorState),
        .selection = std.mem.zeroes(c.HowlVtSelection),
        .cursor_phase_visible = true,
        .dirty_rows = &[_]u8{},
        .dirty_cols_start = dirty_cols_start[0..],
        .dirty_cols_end = dirty_cols_end[0..],
    };
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceBoundary(source));
}

test "vt surface copy in preserves snapshot and dirty metadata" {
    const cells = [_]c.HowlVtSurfaceCell{ validTestCell(), validTestCell() };
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{0};
    const dirty_cols_end = [_]u16{1};
    const result = validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);

    var source = try vtSurfaceFromResult(std.testing.allocator, result, false);
    defer source.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 2), source.cols);
    try std.testing.expectEqual(@as(u16, 1), source.rows);
    try std.testing.expectEqual(@as(u64, 7), source.history_count);
    try std.testing.expectEqual(@as(u64, 5), source.scroll_row);
    try std.testing.expectEqual(@as(u64, 11), source.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 13), source.dirty_epoch);
    try std.testing.expect(source.is_alternate_screen);
    try std.testing.expect(!source.cursor_phase_visible);
    try std.testing.expectEqual(@as(u64, 17), source.cursor.position_changed_by_client_at_ms);
    try std.testing.expectEqual(@as(u32, 0x010203), source.cursor_color.value);
    try std.testing.expectEqual(@as(u32, 7), source.cursor_text_color.value);
    try std.testing.expectEqual(@as(u16, 0), source.extra_cursor_count);
    try std.testing.expectEqual(@as(u16, 0), source.cursor_trail_count);
    try std.testing.expectEqualSlices(u8, dirty_rows[0..], source.dirty_rows);
    try std.testing.expectEqualSlices(u16, dirty_cols_start[0..], source.dirty_cols_start);
    try std.testing.expectEqualSlices(u16, dirty_cols_end[0..], source.dirty_cols_end);
    try std.testing.expectEqual(@as(u32, 'A'), source.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'A'), source.cells[1].codepoint);
}

test "vt surface copy in preserves vt no-shape without reinterpretation" {
    const cells = [_]c.HowlVtSurfaceCell{ validTestCell(), validTestCell() };
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{0};
    const dirty_cols_end = [_]u16{1};
    var result = validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);
    result.source.cursor.shape = 3;

    var source = try vtSurfaceFromResult(std.testing.allocator, result, true);
    defer source.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, c.HOWL_VT_CURSOR_SHAPE_NONE), source.cursor.shape);
    try std.testing.expectEqual(@as(u8, c.HOWL_VT_CURSOR_SHAPE_NONE), source.effective_shape);
    try std.testing.expect(source.cursor_phase_visible);
}

test "vt surface boundary rejects widened invalid cursor aggregates" {
    var source = try testVtSurfaceFromSnapshot(std.testing.allocator, .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 17,
        .dirty_epoch = 17,
        .is_alternate_screen = false,
        .dirty_rows = &[_]u8{1},
        .dirty_cols_start = &[_]u16{0},
        .dirty_cols_end = &[_]u16{0},
    });
    defer source.deinit(std.testing.allocator);

    source.cursor.cell_cols = 0;
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceBoundary(source));

    source.cursor.cell_cols = 1;
    source.extra_cursor_count = c.HOWL_VT_MAX_EXTRA_CURSORS + 1;
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceBoundary(source));

    source.extra_cursor_count = 0;
    source.cursor_trail_count = c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX + 1;
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceBoundary(source));
}

test "vt surface ignores inactive extra cursor tail when count is zero" {
    const cells = [_]c.HowlVtSurfaceCell{ validTestCell(), validTestCell() };
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{0};
    const dirty_cols_end = [_]u16{1};
    var result = validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);

    result.source.extra_cursors[0].shape = 255;
    result.source.extra_cursors[0].mode = 255;
    result.source.extra_cursors[0].shape_follows_main = 255;
    result.source.extra_cursors[0].color_follows_main = 255;
    result.source.extra_cursors[0].cursor_color = .{ .kind = 3, .value = 0xffffffff };
    result.source.extra_cursors[0].text_color = .{ .kind = 3, .value = 0xffffffff };
    result.source.extra_cursor_count = 0;

    var source = try vtSurfaceFromResult(std.testing.allocator, result, false);
    defer source.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 0), source.extra_cursor_count);
    try std.testing.expectEqual(std.mem.zeroes(c.HowlVtExtraCursor), source.extra_cursors[0]);
}

test "vt surface result rejects widened cursor and extra cursor enum violations" {
    var cells = [_]c.HowlVtSurfaceCell{ std.mem.zeroes(c.HowlVtSurfaceCell), std.mem.zeroes(c.HowlVtSurfaceCell) };
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{0};
    const dirty_cols_end = [_]u16{1};
    var result = validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);

    result.source.cursor.cell_cols = 0;
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceResult(result));

    result = validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);
    result.source.cursor_color.kind = 3;
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceResult(result));

    result = validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);
    result.source.extra_cursor_count = c.HOWL_VT_MAX_EXTRA_CURSORS + 1;
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceResult(result));

    result = validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);
    result.source.cursor.shape = 3;
    try validateVtSurfaceResult(result);

    result = validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);
    result.source.cursor.shape = 4;
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceResult(result));

    result = validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);
    result.source.extra_cursor_count = 1;
    result.source.extra_cursors[0].shape = 5;
    try std.testing.expectError(error.InvalidSurfaceSource, validateVtSurfaceResult(result));
}
