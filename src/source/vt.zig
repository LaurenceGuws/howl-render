const std = @import("std");
const tokens = @import("../surface/tokens.zig");
const vt_publication = @import("../surface/publication_source.zig");
const source_cell = @import("cell.zig");
const source_damage = @import("damage.zig");
const source_slot = @import("slot.zig");

pub const SourceRgb = vt_publication.SourceRgb;
pub const SourceColor = vt_publication.SourceColor;
pub const SourceColors = vt_publication.SourceColors;
pub const SourceCellFlags = vt_publication.SourceCellFlags;
pub const SourceCellAttrs = vt_publication.SourceCellAttrs;
pub const SourceCell = vt_publication.SourceCell;
pub const SourceSelectionPoint = vt_publication.SourceSelectionPoint;
pub const SourceSelection = vt_publication.SourceSelection;

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

pub const VtPublishResult = struct {
    published: bool,
    queued: bool,
    damage_kind: tokens.DamageKind,
    snapshot_seq: u64,
    geometry_epoch: u64,
};

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
