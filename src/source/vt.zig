const std = @import("std");
const tokens = @import("../surface/tokens.zig");
const source_cell = @import("cell.zig");
const source_damage = @import("damage.zig");
const source_slot = @import("slot.zig");

pub const SourceRgb = extern struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const SourceColor = extern struct {
    kind: u8,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
    value: u32,
};

pub const SourceColors = extern struct {
    foreground: SourceRgb,
    background: SourceRgb,
    cursor: SourceRgb,
    palette: [256]SourceRgb,
};

pub const SourceCellFlags = extern struct {
    continuation: u8,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
};

pub const SourceCellAttrs = extern struct {
    bold: u8,
    dim: u8,
    italic: u8,
    underline: u8,
    underline_color_set: u8,
    blink: u8,
    inverse: u8,
    invisible: u8,
    strikethrough: u8,
    selected: u8,
};

pub const SourceCell = extern struct {
    codepoint: u32,
    combining_len: u8 = 0,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
    combining: [3]u32 = [_]u32{0} ** 3,
    flags: SourceCellFlags,
    fg_color: SourceColor,
    bg_color: SourceColor,
    underline_color: SourceColor,
    underline_style: u8,
    reserved3: u8 = 0,
    reserved4: u8 = 0,
    reserved5: u8 = 0,
    attrs: SourceCellAttrs,
    link_id: u32,
};

pub const SourceSelectionPoint = extern struct {
    row: i32,
    col: u16,
    reserved0: u16 = 0,
};

pub const SourceSelection = extern struct {
    active: u8,
    selecting: u8,
    reserved0: u16 = 0,
    start: SourceSelectionPoint,
    end: SourceSelectionPoint,
};

pub const SourceCursor = extern struct {
    row: u16,
    col: u16,
    visible: u8,
    shape: u8,
    blink: u8,
    reserved0: u8 = 0,
};

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
    cursor: source_cell.CursorInfo,
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

pub const ReservedSourceMeta = struct {
    history_count: u64,
    scroll_row: u64,
    snapshot_seq: u64,
    is_alternate_screen: bool,
    cursor: source_cell.CursorInfo,
    colors: SourceColors,
    selection: SourceSelection,
};

pub const VtSurfacePublishResult = struct {
    published: bool,
    queued: bool,
    damage_kind: tokens.DamageKind,
    snapshot_seq: u64,
    geometry_epoch: u64,
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

pub fn validateReservedSourceMeta(meta: ReservedSourceMeta) !void {
    if (meta.snapshot_seq == 0) return error.InvalidSurfaceSource;
}

pub fn sourceColorValid(color: SourceColor) bool {
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
        .cursor = std.mem.zeroes(source_cell.CursorInfo),
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
        .cursor = std.mem.zeroes(source_cell.CursorInfo),
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

test "source vt rejects reserved source meta without snapshot" {
    try std.testing.expectError(error.InvalidSurfaceSource, validateReservedSourceMeta(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 0,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(source_cell.CursorInfo),
        .colors = std.mem.zeroes(SourceColors),
        .selection = std.mem.zeroes(SourceSelection),
    }));
}
