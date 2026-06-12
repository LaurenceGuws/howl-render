const std = @import("std");
const c = @import("../abi.zig").c;
const tokens = @import("../geometry/tokens.zig");
const source_cell = @import("cell.zig");
const source_damage = @import("damage.zig");
const source_slot = @import("slot.zig");

pub const SourceRgb = c.HowlVtRgb8;
pub const SourceColor = c.HowlVtColor;
pub const SourceColors = c.HowlVtRenderColorState;
pub const SourceCellFlags = c.HowlVtSurfaceCellFlags;
pub const SourceCellAttrs = c.HowlVtSurfaceCellAttrs;
pub const SourceCell = c.HowlVtSurfaceCell;
pub const SourceSelectionPoint = c.HowlVtSelectionPos;
pub const SourceSelection = c.HowlVtSelection;
pub const SourceCursor = source_cell.CursorInfo;

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
    cells: []SourceCell,
    cursor: SourceCursor,
    colors: SourceColors,
    selection: SourceSelection,
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
        const cells = try allocator.dupe(SourceCell, self.cells);
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

pub fn validatePublicationSourceBoundary(source: PublicationSource) !void {
    if (source.cols == 0) return error.InvalidSurfaceSource;
    if (source.rows == 0) return error.InvalidSurfaceSource;
    const cell_count = source_slot.slotCellCountChecked(source.cols, source.rows) catch return error.InvalidSurfaceSource;
    if (source.cells.len != cell_count) return error.InvalidSurfaceSource;
    try source_damage.validateDirtySource(
        source.rows,
        source.cols,
        source.dirty_rows,
        source.dirty_cols_start,
        source.dirty_cols_end,
    );
}

pub fn validatePublicationSurfaceResult(result: anytype) !void {
    if (result.status != c.HOWL_VT_CALL_OK) return error.InvalidSurfaceSource;
    if (result.snapshot_seq == 0) return error.InvalidSurfaceSource;
    if (result.dirty_generation == 0) return error.InvalidSurfaceSource;
    if (result.scrollback_offset > result.history_count) return error.InvalidSurfaceSource;
    const surface = result.source;
    if (surface.cols == 0 or surface.rows == 0) return error.InvalidSurfaceSource;
    const cell_count = source_slot.slotCellCountChecked(surface.cols, surface.rows) catch return error.InvalidSurfaceSource;
    if (surface.surface_cells.ptr == null or surface.surface_cells.len != cell_count) return error.InvalidSurfaceSource;
    if (surface.dirty_rows.ptr == null or surface.dirty_cols_start.ptr == null or surface.dirty_cols_end.ptr == null) return error.InvalidSurfaceSource;
    if (surface.cursor.shape > 3) return error.InvalidSurfaceSource;
    try source_damage.validateDirtySource(
        surface.rows,
        surface.cols,
        surface.dirty_rows.ptr[0..surface.dirty_rows.len],
        surface.dirty_cols_start.ptr[0..surface.dirty_cols_start.len],
        surface.dirty_cols_end.ptr[0..surface.dirty_cols_end.len],
    );
    for (surface.surface_cells.ptr[0..surface.surface_cells.len]) |cell| try validateSourceCellAny(cell);
}

pub fn ownedSourceFromSurfaceResult(allocator: std.mem.Allocator, result: anytype, cursor_phase_visible: bool) !PublicationSource {
    try validatePublicationSurfaceResult(result);
    const surface = result.source;
    const cells = try allocator.alloc(SourceCell, surface.surface_cells.len);
    errdefer allocator.free(cells);
    for (surface.surface_cells.ptr[0..surface.surface_cells.len], cells) |src, *dst| dst.* = .{
        .codepoint = src.codepoint,
        .combining = src.combining,
        .combining_len = src.combining_len,
        .flags = .{ .continuation = src.flags.continuation },
        .fg_color = sourceColorFrom(src.fg_color),
        .bg_color = sourceColorFrom(src.bg_color),
        .underline_color = sourceColorFrom(src.underline_color),
        .underline_style = src.underline_style,
        .attrs = sourceAttrsFrom(src.attrs),
        .link_id = src.link_id,
    };
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
        .cursor = .{ .row = surface.cursor.row, .col = surface.cursor.col, .visible = surface.cursor.visible != 0, .shape = @enumFromInt(surface.cursor.shape), .blink = surface.cursor.blink != 0 },
        .colors = sourceColorsFrom(surface.colors),
        .selection = sourceSelectionFrom(surface.selection),
        .cursor_phase_visible = cursor_phase_visible,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

fn sourceColorFrom(value: anytype) SourceColor {
    return .{ .kind = value.kind, .value = value.value };
}

fn sourceRgbFrom(value: anytype) SourceRgb {
    return .{ .r = value.r, .g = value.g, .b = value.b };
}

fn sourceAttrsFrom(value: anytype) SourceCellAttrs {
    return .{ .bold = value.bold, .dim = value.dim, .italic = value.italic, .underline = value.underline, .underline_color_set = value.underline_color_set, .blink = value.blink, .inverse = value.inverse, .invisible = value.invisible, .strikethrough = value.strikethrough, .selected = value.selected };
}

fn sourceColorsFrom(value: anytype) SourceColors {
    var colors = SourceColors{
        .foreground = sourceRgbFrom(value.foreground),
        .background = sourceRgbFrom(value.background),
        .cursor = sourceRgbFrom(value.cursor),
        .palette = undefined,
    };
    for (&colors.palette, value.palette) |*dst, src| dst.* = sourceRgbFrom(src);
    return colors;
}

fn sourceSelectionPointFrom(value: anytype) SourceSelectionPoint {
    return .{ .row = value.row, .col = value.col, .reserved0 = value.reserved0 };
}

fn sourceSelectionFrom(value: anytype) SourceSelection {
    return .{ .active = value.active, .selecting = value.selecting, .reserved0 = value.reserved0, .start = sourceSelectionPointFrom(value.start), .end = sourceSelectionPointFrom(value.end) };
}

pub fn testSourceFromSnapshot(allocator: std.mem.Allocator, snapshot: VtSnapshot) !PublicationSource {
    const cell_count: u32 = @as(u32, snapshot.cols) * @as(u32, snapshot.rows);
    const cells = try allocator.alloc(SourceCell, @intCast(cell_count));
    @memset(cells, std.mem.zeroes(SourceCell));
    const dirty_rows = try allocator.alloc(u8, snapshot.rows);
    errdefer allocator.free(dirty_rows);
    @memset(dirty_rows, 0);
    for (snapshot.dirty_rows, 0..) |src, i| {
        if (i >= dirty_rows.len) break;
        dirty_rows[i] = src;
    }
    const dirty_cols_start = try allocator.alloc(u16, snapshot.rows);
    errdefer allocator.free(dirty_cols_start);
    @memset(dirty_cols_start, 0);
    for (snapshot.dirty_cols_start, 0..) |src, i| {
        if (i >= dirty_cols_start.len) break;
        dirty_cols_start[i] = src;
    }
    const dirty_cols_end = try allocator.alloc(u16, snapshot.rows);
    errdefer allocator.free(dirty_cols_end);
    @memset(dirty_cols_end, 0);
    for (snapshot.dirty_cols_end, 0..) |src, i| {
        if (i >= dirty_cols_end.len) break;
        dirty_cols_end[i] = src;
    }
    return .{
        .cols = snapshot.cols,
        .rows = snapshot.rows,
        .history_count = snapshot.history_count,
        .scroll_row = snapshot.scroll_row,
        .snapshot_seq = snapshot.snapshot_seq,
        .dirty_epoch = snapshot.dirty_epoch,
        .is_alternate_screen = snapshot.is_alternate_screen,
        .cells = cells,
        .cursor = std.mem.zeroes(SourceCursor),
        .colors = std.mem.zeroes(SourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

pub fn ownedTestSource(allocator: std.mem.Allocator, snapshot_seq: u64, codepoint: u21) !PublicationSource {
    const cells = try allocator.alloc(SourceCell, 1);
    cells[0] = std.mem.zeroes(SourceCell);
    cells[0].codepoint = codepoint;
    const dirty_rows = try allocator.alloc(u8, 1);
    dirty_rows[0] = 1;
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
        .cursor = std.mem.zeroes(SourceCursor),
        .colors = std.mem.zeroes(SourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

fn validTestCell() SourceCell {
    var cell = std.mem.zeroes(SourceCell);
    cell.codepoint = 'A';
    return cell;
}

test "source vt rejects source cell codepoint above u21" {
    var cell = validTestCell();
    cell.codepoint = @as(u32, std.math.maxInt(u21)) + 1;
    try std.testing.expectError(error.InvalidSurfaceSource, validateSourceCell(cell));
}

test "source vt rejects combining length beyond storage" {
    var cell = validTestCell();
    cell.combining_len = 4;
    try std.testing.expectError(error.InvalidSurfaceSource, validateSourceCell(cell));
}

test "source vt rejects active combining codepoint above u21" {
    var cell = validTestCell();
    cell.combining_len = 1;
    cell.combining[0] = @as(u32, std.math.maxInt(u21)) + 1;
    try std.testing.expectError(error.InvalidSurfaceSource, validateSourceCell(cell));
}

test "source vt rejects invalid color kind" {
    var cell = validTestCell();
    cell.fg_color = .{ .kind = 3, .value = 0 };
    try std.testing.expectError(error.InvalidSurfaceSource, validateSourceCell(cell));
}

test "source vt rejects indexed color outside u8" {
    var cell = validTestCell();
    cell.bg_color = .{ .kind = 1, .value = @as(u32, std.math.maxInt(u8)) + 1 };
    try std.testing.expectError(error.InvalidSurfaceSource, validateSourceCell(cell));
}

test "source vt rejects rgb color outside u24" {
    var cell = validTestCell();
    cell.underline_color = .{ .kind = 2, .value = @as(u32, std.math.maxInt(u24)) + 1 };
    try std.testing.expectError(error.InvalidSurfaceSource, validateSourceCell(cell));
}

test "source vt rejects underline style above shipped range" {
    var cell = validTestCell();
    cell.underline_style = 5;
    try std.testing.expectError(error.InvalidSurfaceSource, validateSourceCell(cell));
}
