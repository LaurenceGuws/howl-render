const std = @import("std");
const surface_types = @import("../surface/types.zig");
const source_vt = @import("vt.zig");
const source_damage = @import("damage.zig");

pub const PublicationSlot = struct {
    cells: []source_vt.SourceCell,
    dirty_rows: []u8,
    dirty_cols_start: []u16,
    dirty_cols_end: []u16,
};

pub const RetainedSlot = struct {
    cells: []source_vt.SourceCell = &.{},
    dirty_rows: []u8 = &.{},
    dirty_cols_start: []u16 = &.{},
    dirty_cols_end: []u16 = &.{},
    cols_capacity: u16 = 0,
    rows_capacity: u16 = 0,

    pub fn deinit(self: *RetainedSlot, allocator: std.mem.Allocator) void {
        if (self.cells.len > 0) allocator.free(self.cells);
        if (self.dirty_rows.len > 0) allocator.free(self.dirty_rows);
        if (self.dirty_cols_start.len > 0) allocator.free(self.dirty_cols_start);
        if (self.dirty_cols_end.len > 0) allocator.free(self.dirty_cols_end);
        self.* = .{};
    }

    pub fn ensureCapacity(
        self: *RetainedSlot,
        allocator: std.mem.Allocator,
        cols: u16,
        rows: u16,
    ) !void {
        std.debug.assert(cols > 0);
        std.debug.assert(rows > 0);
        if (self.cols_capacity >= cols and self.rows_capacity >= rows) return;

        const cell_count = slotCellCount(cols, rows);
        const cells = try allocator.alloc(source_vt.SourceCell, cell_count);
        errdefer allocator.free(cells);
        const dirty_rows = try allocator.alloc(u8, rows);
        errdefer allocator.free(dirty_rows);
        const dirty_cols_start = try allocator.alloc(u16, rows);
        errdefer allocator.free(dirty_cols_start);
        const dirty_cols_end = try allocator.alloc(u16, rows);
        errdefer allocator.free(dirty_cols_end);

        self.deinit(allocator);
        self.cells = cells;
        self.dirty_rows = dirty_rows;
        self.dirty_cols_start = dirty_cols_start;
        self.dirty_cols_end = dirty_cols_end;
        self.cols_capacity = cols;
        self.rows_capacity = rows;
    }

    pub fn canHold(self: *const RetainedSlot, cols: u16, rows: u16) bool {
        return self.cols_capacity >= cols and self.rows_capacity >= rows;
    }

    pub fn publicationSlot(self: *const RetainedSlot, cols: u16, rows: u16) PublicationSlot {
        std.debug.assert(self.canHold(cols, rows));
        return .{
            .cells = self.cells[0..slotCellCount(cols, rows)],
            .dirty_rows = self.dirty_rows[0..rows],
            .dirty_cols_start = self.dirty_cols_start[0..rows],
            .dirty_cols_end = self.dirty_cols_end[0..rows],
        };
    }
};

pub const SourceSlot = struct {
    allocator: std.mem.Allocator,
    retained_slot: RetainedSlot = .{},
    reserved: ?source_vt.PublicationSource = null,

    pub fn init(allocator: std.mem.Allocator) SourceSlot {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SourceSlot) void {
        if (self.reserved) |*source| source.deinit(self.allocator);
        self.reserved = null;
        self.retained_slot.deinit(self.allocator);
    }

    pub fn syncReservedSlotCapacity(self: *SourceSlot, cols: u16, rows: u16) !void {
        std.debug.assert(cols > 0);
        std.debug.assert(rows > 0);
        try self.retained_slot.ensureCapacity(self.allocator, cols, rows);
        self.refreshRetainedSlotViews();
    }

    pub fn reserveSourceSlot(self: *SourceSlot, cols: u16, rows: u16) !PublicationSlot {
        std.debug.assert(cols > 0);
        std.debug.assert(rows > 0);
        if (self.reserved != null) return error.PublishSlotBusy;
        if (!self.retained_slot.canHold(cols, rows)) return error.PublishSlotOutOfRange;

        self.reserved = self.retainedSource(cols, rows);
        return self.retained_slot.publicationSlot(cols, rows);
    }

    pub fn cancelReservedSource(self: *SourceSlot) void {
        self.reserved = null;
    }

    pub fn commitReservedSource(
        self: *SourceSlot,
        meta: source_vt.ReservedSourceMeta,
        dirty_epoch: u64,
    ) !source_vt.PublicationSource {
        var source = self.reserved orelse return error.MissingPublishSlot;
        self.reserved = null;
        source.scroll_row = meta.scroll_row;
        source.history_count = meta.history_count;
        source.snapshot_seq = meta.snapshot_seq;
        source.dirty_epoch = dirty_epoch;
        source.is_alternate_screen = meta.is_alternate_screen;
        source.cursor = meta.cursor;
        source.colors = meta.colors;
        source.selection = meta.selection;
        try source_damage.validateDirtySource(
            source.rows,
            source.cols,
            source.dirty_rows,
            source.dirty_cols_start,
            source.dirty_cols_end,
        );
        source_damage.canonicalizeDirtyMetadata(
            source.rows,
            source.dirty_rows,
            source.dirty_cols_start,
            source.dirty_cols_end,
        );
        return source;
    }

    pub fn reservedSource(self: *SourceSlot) ?*source_vt.PublicationSource {
        if (self.reserved) |*source| return source;
        return null;
    }

    pub fn sourcePending(self: *const SourceSlot) bool {
        return self.reserved != null;
    }

    fn retainedSource(self: *const SourceSlot, cols: u16, rows: u16) source_vt.PublicationSource {
        const slot = self.retained_slot.publicationSlot(cols, rows);
        return .{
            .cols = cols,
            .rows = rows,
            .history_count = 0,
            .scroll_row = 0,
            .snapshot_seq = 0,
            .dirty_epoch = 0,
            .is_alternate_screen = false,
            .cells = slot.cells,
            .cursor = std.mem.zeroes(surface_types.CursorInfo),
            .colors = std.mem.zeroes(source_vt.SourceColors),
            .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
            .cursor_phase_visible = true,
            .dirty_rows = slot.dirty_rows,
            .dirty_cols_start = slot.dirty_cols_start,
            .dirty_cols_end = slot.dirty_cols_end,
            .retained_storage = true,
        };
    }

    fn refreshRetainedSlotViews(self: *SourceSlot) void {
        if (self.reserved) |*source| {
            if (source.retained_storage) self.refreshRetainedSource(source);
        }
    }

    pub fn refreshRetainedSource(self: *SourceSlot, source: *source_vt.PublicationSource) void {
        const scroll_row = source.scroll_row;
        const history_count = source.history_count;
        const snapshot_seq = source.snapshot_seq;
        const dirty_epoch = source.dirty_epoch;
        const is_alternate_screen = source.is_alternate_screen;
        const cursor = source.cursor;
        const colors = source.colors;
        const selected = source.selection;
        const cursor_phase_visible = source.cursor_phase_visible;
        source.* = self.retainedSource(source.cols, source.rows);
        source.history_count = history_count;
        source.scroll_row = scroll_row;
        source.snapshot_seq = snapshot_seq;
        source.dirty_epoch = dirty_epoch;
        source.is_alternate_screen = is_alternate_screen;
        source.cursor = cursor;
        source.colors = colors;
        source.selection = selected;
        source.cursor_phase_visible = cursor_phase_visible;
    }
};

pub fn slotCellCount(cols: u16, rows: u16) usize {
    return @as(usize, cols) * @as(usize, rows);
}

pub fn slotCellCountChecked(cols: u16, rows: u16) !usize {
    return std.math.mul(usize, cols, rows);
}

test "source slot reuses retained publish slot storage across reservations" {
    var slot_owner = SourceSlot.init(std.testing.allocator);
    defer slot_owner.deinit();
    try slot_owner.syncReservedSlotCapacity(1, 1);

    const first = try slot_owner.reserveSourceSlot(1, 1);
    const first_cells = first.cells.ptr;
    const first_dirty_rows = first.dirty_rows.ptr;
    const first_dirty_cols_start = first.dirty_cols_start.ptr;
    const first_dirty_cols_end = first.dirty_cols_end.ptr;
    slot_owner.cancelReservedSource();

    const second = try slot_owner.reserveSourceSlot(1, 1);
    try std.testing.expectEqual(first_cells, second.cells.ptr);
    try std.testing.expectEqual(first_dirty_rows, second.dirty_rows.ptr);
    try std.testing.expectEqual(first_dirty_cols_start, second.dirty_cols_start.ptr);
    try std.testing.expectEqual(first_dirty_cols_end, second.dirty_cols_end.ptr);
}

test "source slot commit returns source without prepare or submit state" {
    var slot_owner = SourceSlot.init(std.testing.allocator);
    defer slot_owner.deinit();
    try slot_owner.syncReservedSlotCapacity(1, 1);

    const slot = try slot_owner.reserveSourceSlot(1, 1);
    slot.cells[0] = std.mem.zeroes(source_vt.SourceCell);
    slot.cells[0].codepoint = 'A';
    slot.dirty_rows[0] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 0;

    var source = try slot_owner.commitReservedSource(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(surface_types.CursorInfo),
        .colors = std.mem.zeroes(source_vt.SourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
    }, 7);

    try std.testing.expectEqual(@as(u64, 7), source.dirty_epoch);
    source.deinit(std.testing.allocator);
}
