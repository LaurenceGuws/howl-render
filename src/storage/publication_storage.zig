const std = @import("std");
const source_damage = @import("../damage/publication_damage.zig");
const source_abi = @import("../vt_publication/abi.zig");
const source_publication = @import("../vt_publication/publication.zig");

pub const VtSurfaceSlot = struct {
    cells: []source_abi.SourceCell,
    dirty_rows: []u8,
    dirty_cols_start: []u16,
    dirty_cols_end: []u16,
};

pub const RetainedSlot = struct {
    cells: []source_abi.SourceCell = &.{},
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

    pub fn ensureCapacity(self: *RetainedSlot, allocator: std.mem.Allocator, cols: u16, rows: u16) !void {
        std.debug.assert(cols > 0);
        std.debug.assert(rows > 0);
        if (self.cols_capacity >= cols and self.rows_capacity >= rows) return;

        const cell_count = try slotCellCountChecked(cols, rows);
        const cells = try allocator.alloc(source_abi.SourceCell, cell_count);
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

    pub fn vtSurfaceSlot(self: *const RetainedSlot, cols: u16, rows: u16) VtSurfaceSlot {
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
    reserved: ?source_publication.PublicationSource = null,

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

    pub fn copyPublishedSource(self: *SourceSlot, source_result: anytype, dirty_epoch: u64, cursor_phase_visible: bool) !source_publication.PublicationSource {
        const surface = source_result.source;
        try source_abi.validatePublicationSurfaceResult(source_result);
        const cell_count = try slotCellCountChecked(surface.cols, surface.rows);
        std.debug.assert(surface.surface_cells.len == cell_count);
        std.debug.assert(surface.dirty_rows.len == surface.rows);
        std.debug.assert(surface.dirty_cols_start.len == surface.rows);
        std.debug.assert(surface.dirty_cols_end.len == surface.rows);

        try self.retained_slot.ensureCapacity(self.allocator, surface.cols, surface.rows);
        const slot = self.retained_slot.vtSurfaceSlot(surface.cols, surface.rows);
        std.debug.assert(slot.cells.len == cell_count);
        @memcpy(slot.cells, surface.surface_cells.ptr[0..surface.surface_cells.len]);
        @memcpy(slot.dirty_rows, surface.dirty_rows.ptr[0..surface.dirty_rows.len]);
        @memcpy(slot.dirty_cols_start, surface.dirty_cols_start.ptr[0..surface.dirty_cols_start.len]);
        @memcpy(slot.dirty_cols_end, surface.dirty_cols_end.ptr[0..surface.dirty_cols_end.len]);

        const retained = source_publication.PublicationSource{
            .cols = surface.cols,
            .rows = surface.rows,
            .history_count = source_result.history_count,
            .scroll_row = surface.scroll_row,
            .snapshot_seq = source_result.snapshot_seq,
            .dirty_epoch = dirty_epoch,
            .is_alternate_screen = surface.is_alternate_screen != 0,
            .cells = slot.cells,
            .cursor = vtCursorIn(surface.cursor),
            .colors = surface.colors,
            .selection = surface.selection,
            .cursor_phase_visible = cursor_phase_visible,
            .dirty_rows = slot.dirty_rows,
            .dirty_cols_start = slot.dirty_cols_start,
            .dirty_cols_end = slot.dirty_cols_end,
            .retained_storage = true,
        };
        try source_abi.validateSourceCells(retained.cells);
        try source_damage.validateDirtySource(retained.rows, retained.cols, retained.dirty_rows, retained.dirty_cols_start, retained.dirty_cols_end);
        source_damage.canonicalizeDirtyMetadata(retained.rows, retained.dirty_rows, retained.dirty_cols_start, retained.dirty_cols_end);
        return retained;
    }

    pub fn reserveSourceSlot(self: *SourceSlot, cols: u16, rows: u16) !VtSurfaceSlot {
        std.debug.assert(cols > 0);
        std.debug.assert(rows > 0);
        if (self.reserved != null) return error.VtSurfaceSlotBusy;
        if (!self.retained_slot.canHold(cols, rows)) return error.VtSurfaceSlotOutOfRange;

        self.reserved = self.retainedSource(cols, rows);
        return self.retained_slot.vtSurfaceSlot(cols, rows);
    }

    pub fn cancelReservedSource(self: *SourceSlot) void {
        self.reserved = null;
    }

    pub fn commitReservedSource(self: *SourceSlot, meta: anytype, dirty_epoch: u64) !source_publication.PublicationSource {
        if (meta.snapshot_seq == 0) return error.InvalidSurfaceSource;
        const source = if (self.reserved) |*value| value else return error.MissingVtSurfaceSlot;
        source.scroll_row = meta.scroll_row;
        source.history_count = meta.history_count;
        source.snapshot_seq = meta.snapshot_seq;
        source.dirty_epoch = dirty_epoch;
        source.is_alternate_screen = meta.is_alternate_screen;
        source.cursor = meta.cursor;
        source.colors = meta.colors;
        source.selection = meta.selection;
        try source_abi.validateSourceCells(source.cells);
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
        const committed = source.*;
        self.reserved = null;
        return committed;
    }

    pub fn reservedSource(self: *SourceSlot) ?*source_publication.PublicationSource {
        if (self.reserved) |*source| return source;
        return null;
    }

    pub fn sourcePending(self: *const SourceSlot) bool {
        return self.reserved != null;
    }

    fn retainedSource(self: *const SourceSlot, cols: u16, rows: u16) source_publication.PublicationSource {
        const slot = self.retained_slot.vtSurfaceSlot(cols, rows);
        return .{
            .cols = cols,
            .rows = rows,
            .history_count = 0,
            .scroll_row = 0,
            .snapshot_seq = 0,
            .dirty_epoch = 0,
            .is_alternate_screen = false,
            .cells = slot.cells,
            .cursor = std.mem.zeroes(source_abi.SourceCursor),
            .colors = std.mem.zeroes(source_abi.SourceColors),
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

    pub fn refreshRetainedSource(self: *SourceSlot, source: *source_publication.PublicationSource) void {
        const scroll_row = source.scroll_row;
        const history_count = source.history_count;
        const snapshot_seq = source.snapshot_seq;
        const dirty_epoch = source.dirty_epoch;
        const is_alternate_screen = source.is_alternate_screen;
        const cursor = source.cursor;
        const colors = source.colors;
        const selection = source.selection;
        const cursor_phase_visible = source.cursor_phase_visible;
        source.* = self.retainedSource(source.cols, source.rows);
        source.history_count = history_count;
        source.scroll_row = scroll_row;
        source.snapshot_seq = snapshot_seq;
        source.dirty_epoch = dirty_epoch;
        source.is_alternate_screen = is_alternate_screen;
        source.cursor = cursor;
        source.colors = colors;
        source.selection = selection;
        source.cursor_phase_visible = cursor_phase_visible;
    }
};

fn vtCursorIn(value: anytype) source_abi.SourceCursor {
    const shape = switch (value.shape) {
        1 => source_abi.SourceCursorShape.underline,
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

pub fn slotCellCount(cols: u16, rows: u16) usize {
    return @as(usize, cols) * @as(usize, rows);
}

pub fn slotCellCountChecked(cols: u16, rows: u16) !usize {
    return std.math.mul(usize, cols, rows);
}

test "source slot reuses retained vt surface slot storage across reservations" {
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

test "source slot exposes retained source cell storage for publication" {
    var slot_owner = SourceSlot.init(std.testing.allocator);
    defer slot_owner.deinit();
    try slot_owner.syncReservedSlotCapacity(2, 1);

    const slot = try slot_owner.reserveSourceSlot(2, 1);
    try std.testing.expectEqual(slot_owner.retained_slot.cells.ptr, slot.cells.ptr);
    try std.testing.expectEqual(@as(usize, 2), slot.cells.len);
    slot_owner.cancelReservedSource();
}

test "source slot commit rejects invalid source cell without ffi scratch" {
    var slot_owner = SourceSlot.init(std.testing.allocator);
    defer slot_owner.deinit();
    try slot_owner.syncReservedSlotCapacity(1, 1);

    const slot = try slot_owner.reserveSourceSlot(1, 1);
    slot.cells[0] = std.mem.zeroes(source_abi.SourceCell);
    slot.cells[0].codepoint = @as(u32, std.math.maxInt(u21)) + 1;
    slot.dirty_rows[0] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 0;

    try std.testing.expectError(error.InvalidSurfaceSource, slot_owner.commitReservedSource(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(source_abi.SourceCursor),
        .colors = std.mem.zeroes(source_abi.SourceColors),
        .selection = std.mem.zeroes(source_abi.SourceSelection),
    }, 1));
    try std.testing.expect(slot_owner.reserved != null);
    slot_owner.cancelReservedSource();
    try std.testing.expect(slot_owner.reserved == null);
}

test "source slot commit returns source without prepare or submit state" {
    var slot_owner = SourceSlot.init(std.testing.allocator);
    defer slot_owner.deinit();
    try slot_owner.syncReservedSlotCapacity(1, 1);

    const slot = try slot_owner.reserveSourceSlot(1, 1);
    slot.cells[0] = std.mem.zeroes(source_abi.SourceCell);
    slot.cells[0].codepoint = 'A';
    slot.dirty_rows[0] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 0;

    var source = try slot_owner.commitReservedSource(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(source_abi.SourceCursor),
        .colors = std.mem.zeroes(source_abi.SourceColors),
        .selection = std.mem.zeroes(source_abi.SourceSelection),
    }, 7);

    try std.testing.expectEqual(@as(u64, 7), source.dirty_epoch);
    source.deinit(std.testing.allocator);
}

test "source slot retained source deinit does not free retained storage" {
    var slot_owner = SourceSlot.init(std.testing.allocator);
    defer slot_owner.deinit();
    try slot_owner.syncReservedSlotCapacity(1, 1);

    const slot = try slot_owner.reserveSourceSlot(1, 1);
    slot.cells[0] = std.mem.zeroes(source_abi.SourceCell);
    slot.cells[0].codepoint = 'A';
    slot.dirty_rows[0] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 0;

    var source = try slot_owner.commitReservedSource(.{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = false,
        .cursor = std.mem.zeroes(source_abi.SourceCursor),
        .colors = std.mem.zeroes(source_abi.SourceColors),
        .selection = std.mem.zeroes(source_abi.SourceSelection),
    }, 1);
    const retained_cells = slot_owner.retained_slot.cells.ptr;
    const retained_dirty_rows = slot_owner.retained_slot.dirty_rows.ptr;

    source.deinit(std.testing.allocator);

    try std.testing.expectEqual(retained_cells, slot_owner.retained_slot.cells.ptr);
    try std.testing.expectEqual(retained_dirty_rows, slot_owner.retained_slot.dirty_rows.ptr);
    const next = try slot_owner.reserveSourceSlot(1, 1);
    try std.testing.expectEqual(retained_cells, next.cells.ptr);
    slot_owner.cancelReservedSource();
}

test "source slot copy in preserves snapshot and dirty metadata" {
    var slot_owner = SourceSlot.init(std.testing.allocator);
    defer slot_owner.deinit();

    var cells = [_]source_abi.SourceCell{ std.mem.zeroes(source_abi.SourceCell), std.mem.zeroes(source_abi.SourceCell) };
    cells[0].codepoint = 'A';
    cells[1].codepoint = 'B';
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{0};
    const dirty_cols_end = [_]u16{1};
    const result = @import("../vt_publication/publication.zig").validSurfaceResult(cells[0..], dirty_rows[0..], dirty_cols_start[0..], dirty_cols_end[0..]);

    var source = try slot_owner.copyPublishedSource(result, 99, false);
    defer source.deinit(std.testing.allocator);

    try std.testing.expect(source.retained_storage);
    try std.testing.expectEqual(@as(u64, 11), source.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 99), source.dirty_epoch);
    try std.testing.expectEqual(@as(u64, 7), source.history_count);
    try std.testing.expectEqual(@as(u64, 5), source.scroll_row);
    try std.testing.expect(source.is_alternate_screen);
    try std.testing.expect(!source.cursor_phase_visible);
    try std.testing.expectEqual(@as(usize, 2), source.cells.len);
    try std.testing.expectEqual(@as(u32, 'A'), source.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'B'), source.cells[1].codepoint);
    try std.testing.expectEqualSlices(u8, dirty_rows[0..], source.dirty_rows);
    try std.testing.expectEqualSlices(u16, dirty_cols_start[0..], source.dirty_cols_start);
    try std.testing.expectEqualSlices(u16, dirty_cols_end[0..], source.dirty_cols_end);
}

test "source slot refresh preserves snapshot and dirty metadata" {
    var slot_owner = SourceSlot.init(std.testing.allocator);
    defer slot_owner.deinit();
    try slot_owner.syncReservedSlotCapacity(2, 1);

    const slot = try slot_owner.reserveSourceSlot(2, 1);
    slot.cells[0] = std.mem.zeroes(source_abi.SourceCell);
    slot.cells[1] = std.mem.zeroes(source_abi.SourceCell);
    slot.cells[0].codepoint = 'A';
    slot.cells[1].codepoint = 'B';
    slot.dirty_rows[0] = 1;
    slot.dirty_cols_start[0] = 0;
    slot.dirty_cols_end[0] = 1;

    const source = try slot_owner.commitReservedSource(.{
        .history_count = 4,
        .scroll_row = 3,
        .snapshot_seq = 8,
        .is_alternate_screen = true,
        .cursor = source_abi.SourceCursor{ .row = 0, .col = 1, .visible = true, .shape = .beam, .blink = true },
        .colors = std.mem.zeroes(source_abi.SourceColors),
        .selection = std.mem.zeroes(source_abi.SourceSelection),
    }, 9);

    try slot_owner.syncReservedSlotCapacity(3, 2);

    try std.testing.expect(source.retained_storage);
    try std.testing.expectEqual(@as(u64, 4), source.history_count);
    try std.testing.expectEqual(@as(u64, 3), source.scroll_row);
    try std.testing.expectEqual(@as(u64, 8), source.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 9), source.dirty_epoch);
    try std.testing.expect(source.is_alternate_screen);
    try std.testing.expectEqual(@as(usize, 1), source.dirty_rows.len);
}
