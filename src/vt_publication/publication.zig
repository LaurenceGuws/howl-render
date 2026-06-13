const std = @import("std");
const abi = @import("abi.zig");
const c = @import("howl_render_c");

pub const source_abi = abi;
pub const SourceRgb = abi.SourceRgb;
pub const SourceColor = abi.SourceColor;
pub const SourceColors = abi.SourceColors;
pub const SourceCellFlags = abi.SourceCellFlags;
pub const SourceCellAttrs = abi.SourceCellAttrs;
pub const SourceCell = abi.SourceCell;
pub const SourceSelectionPoint = abi.SourceSelectionPoint;
pub const SourceSelection = abi.SourceSelection;
pub const SourceCursor = abi.SourceCursor;

pub const VtSnapshot = struct {
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

pub const PublicationSource = struct {
    cols: u16,
    rows: u16,
    history_count: u64,
    scroll_row: u64,
    snapshot_seq: u64,
    dirty_epoch: u64,
    is_alternate_screen: bool,
    cells: []abi.SourceCell,
    cursor: abi.SourceCursor,
    colors: abi.SourceColors,
    selection: abi.SourceSelection,
    cursor_phase_visible: bool,
    dirty_rows: []u8 = &.{},
    dirty_cols_start: []u16 = &.{},
    dirty_cols_end: []u16 = &.{},
    retained_storage: bool = false,

    pub fn deinit(self: *PublicationSource, allocator: std.mem.Allocator) void {
        if (!self.retained_storage) {
            allocator.free(self.cells);
            if (self.dirty_rows.len > 0) allocator.free(self.dirty_rows);
            if (self.dirty_cols_start.len > 0) allocator.free(self.dirty_cols_start);
            if (self.dirty_cols_end.len > 0) allocator.free(self.dirty_cols_end);
        }
        self.* = undefined;
    }

    pub fn clone(self: *const PublicationSource, allocator: std.mem.Allocator) !PublicationSource {
        const cells = try allocator.dupe(abi.SourceCell, self.cells);
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
            .colors = self.colors,
            .selection = self.selection,
            .cursor_phase_visible = self.cursor_phase_visible,
            .dirty_rows = dirty_rows,
            .dirty_cols_start = dirty_cols_start,
            .dirty_cols_end = dirty_cols_end,
            .retained_storage = false,
        };
    }

    pub fn snapshot(self: *const PublicationSource) VtSnapshot {
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

pub fn validatePublicationSourceBoundary(source: PublicationSource) !void {
    if (source.cols == 0) return error.InvalidSurfaceSource;
    if (source.rows == 0) return error.InvalidSurfaceSource;
    const cell_count = cellCountChecked(source.cols, source.rows) catch return error.InvalidSurfaceSource;
    if (source.cells.len != cell_count) return error.InvalidSurfaceSource;
    try abi.validateSourceCells(source.cells);
    try validateDirtySource(
        source.rows,
        source.cols,
        source.dirty_rows,
        source.dirty_cols_start,
        source.dirty_cols_end,
    );
}

pub fn ownedSourceFromSurfaceResult(allocator: std.mem.Allocator, result: anytype, cursor_phase_visible: bool) !PublicationSource {
    try abi.validatePublicationSurfaceResult(result);

    const surface = result.source;
    const cell_count = try cellCountChecked(surface.cols, surface.rows);
    std.debug.assert(surface.surface_cells.len == cell_count);
    std.debug.assert(surface.dirty_rows.len == surface.rows);
    std.debug.assert(surface.dirty_cols_start.len == surface.rows);
    std.debug.assert(surface.dirty_cols_end.len == surface.rows);

    const cells = try allocator.alloc(abi.SourceCell, cell_count);
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
        .cursor = vtCursorIn(surface.cursor),
        .colors = surface.colors,
        .selection = surface.selection,
        .cursor_phase_visible = cursor_phase_visible,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

pub fn testSourceFromSnapshot(allocator: std.mem.Allocator, snapshot: VtSnapshot) !PublicationSource {
    std.debug.assert(snapshot.cols > 0);
    std.debug.assert(snapshot.rows > 0);
    std.debug.assert(snapshot.dirty_rows.len == snapshot.rows);
    std.debug.assert(snapshot.dirty_cols_start.len == snapshot.rows);
    std.debug.assert(snapshot.dirty_cols_end.len == snapshot.rows);

    const cell_count = try cellCountChecked(snapshot.cols, snapshot.rows);
    const cells = try allocator.alloc(abi.SourceCell, cell_count);
    errdefer allocator.free(cells);
    @memset(cells, std.mem.zeroes(abi.SourceCell));
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
        .cursor = std.mem.zeroes(abi.SourceCursor),
        .colors = std.mem.zeroes(abi.SourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

pub fn ownedTestSource(allocator: std.mem.Allocator, snapshot_seq: u64, codepoint: u21) !PublicationSource {
    const cells = try allocator.alloc(abi.SourceCell, 1);
    errdefer allocator.free(cells);
    cells[0] = std.mem.zeroes(abi.SourceCell);
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
        .cursor = std.mem.zeroes(abi.SourceCursor),
        .colors = std.mem.zeroes(abi.SourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

fn cellCountChecked(cols: u16, rows: u16) !usize {
    return std.math.mul(usize, cols, rows);
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

fn vtCursorIn(value: c.HowlVtCursor) abi.SourceCursor {
    const shape = switch (value.shape) {
        1 => @import("../tv_surface/cell.zig").CursorShape.underline,
        2 => .beam,
        3 => .hollow_block,
        else => .block,
    };
    return .{
        .row = value.row,
        .col = value.col,
        .visible = value.visible != 0,
        .shape = shape,
        .blink = value.blink != 0,
    };
}

fn validTestCell() abi.SourceCell {
    var cell = std.mem.zeroes(abi.SourceCell);
    cell.codepoint = 'A';
    return cell;
}

pub fn validSurfaceResult(cells: []const abi.SourceCell, dirty_rows: []const u8, dirty_cols_start: []const u16, dirty_cols_end: []const u16) c.HowlVtSurfaceResult {
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
            .cursor = .{ .row = 0, .col = 1, .visible = 1, .shape = 2, .blink = 1 },
            .colors = std.mem.zeroes(c.HowlVtRenderColorState),
            .selection = .{ .active = 1, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 1 } },
        },
    };
}

test "source vt rejects source cell codepoint above u21" {
    var cell = validTestCell();
    cell.codepoint = @as(u32, std.math.maxInt(u21)) + 1;
    try std.testing.expectError(error.InvalidSurfaceSource, abi.validateSourceCell(cell));
}

test "source vt rejects combining length beyond storage" {
    var cell = validTestCell();
    cell.combining_len = 4;
    try std.testing.expectError(error.InvalidSurfaceSource, abi.validateSourceCell(cell));
}

test "source vt rejects active combining codepoint above u21" {
    var cell = validTestCell();
    cell.combining_len = 1;
    cell.combining[0] = @as(u32, std.math.maxInt(u21)) + 1;
    try std.testing.expectError(error.InvalidSurfaceSource, abi.validateSourceCell(cell));
}

test "source vt rejects invalid color kind" {
    var cell = validTestCell();
    cell.fg_color = .{ .kind = 3, .value = 0 };
    try std.testing.expectError(error.InvalidSurfaceSource, abi.validateSourceCell(cell));
}

test "source vt rejects indexed color outside u8" {
    var cell = validTestCell();
    cell.bg_color = .{ .kind = 1, .value = @as(u32, std.math.maxInt(u8)) + 1 };
    try std.testing.expectError(error.InvalidSurfaceSource, abi.validateSourceCell(cell));
}

test "source vt rejects rgb color outside u24" {
    var cell = validTestCell();
    cell.underline_color = .{ .kind = 2, .value = @as(u32, std.math.maxInt(u24)) + 1 };
    try std.testing.expectError(error.InvalidSurfaceSource, abi.validateSourceCell(cell));
}

test "source vt rejects underline style above shipped range" {
    var cell = validTestCell();
    cell.underline_style = 5;
    try std.testing.expectError(error.InvalidSurfaceSource, abi.validateSourceCell(cell));
}

test "source publication boundary rejects dirty span length mismatch" {
    var cells = [_]abi.SourceCell{validTestCell()};
    var dirty_cols_start = [_]u16{0};
    var dirty_cols_end = [_]u16{0};
    const source = PublicationSource{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = std.mem.zeroes(abi.SourceCursor),
        .colors = std.mem.zeroes(abi.SourceColors),
        .selection = std.mem.zeroes(abi.SourceSelection),
        .cursor_phase_visible = true,
        .dirty_rows = &[_]u8{},
        .dirty_cols_start = dirty_cols_start[0..],
        .dirty_cols_end = dirty_cols_end[0..],
    };
    try std.testing.expectError(error.InvalidSurfaceSource, validatePublicationSourceBoundary(source));
}

test "source publication copy in preserves snapshot and dirty metadata" {
    const cells = [_]abi.SourceCell{ validTestCell(), validTestCell() };
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{0};
    const dirty_cols_end = [_]u16{1};
    const result = validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);

    var source = try ownedSourceFromSurfaceResult(std.testing.allocator, result, false);
    defer source.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 2), source.cols);
    try std.testing.expectEqual(@as(u16, 1), source.rows);
    try std.testing.expectEqual(@as(u64, 7), source.history_count);
    try std.testing.expectEqual(@as(u64, 5), source.scroll_row);
    try std.testing.expectEqual(@as(u64, 11), source.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 13), source.dirty_epoch);
    try std.testing.expect(source.is_alternate_screen);
    try std.testing.expect(!source.cursor_phase_visible);
    try std.testing.expectEqualSlices(u8, dirty_rows[0..], source.dirty_rows);
    try std.testing.expectEqualSlices(u16, dirty_cols_start[0..], source.dirty_cols_start);
    try std.testing.expectEqualSlices(u16, dirty_cols_end[0..], source.dirty_cols_end);
    try std.testing.expectEqual(@as(u32, 'A'), source.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'A'), source.cells[1].codepoint);
}
