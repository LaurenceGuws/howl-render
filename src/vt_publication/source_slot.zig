const std = @import("std");
const source_damage = @import("damage.zig");
const source_abi = @import("abi.zig");
const source_publication = @import("publication.zig");

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
    staged_slot: RetainedSlot = .{},
    active_slot: RetainedSlot = .{},
    reserved: ?source_publication.PublicationSource = null,

    pub fn init(allocator: std.mem.Allocator) SourceSlot {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SourceSlot) void {
        if (self.reserved) |*source| source.deinit(self.allocator);
        self.reserved = null;
        self.active_slot.deinit(self.allocator);
        self.staged_slot.deinit(self.allocator);
    }

    pub fn syncReservedSlotCapacity(self: *SourceSlot, cols: u16, rows: u16) !void {
        std.debug.assert(cols > 0);
        std.debug.assert(rows > 0);
        try self.staged_slot.ensureCapacity(self.allocator, cols, rows);
        try self.active_slot.ensureCapacity(self.allocator, cols, rows);
        self.refreshStagedSlotView();
    }

    pub fn copyPublishedSource(self: *SourceSlot, source_result: anytype, dirty_epoch: u64, cursor_phase_visible: bool) !source_publication.PublicationSource {
        const surface = source_result.source;
        try source_abi.validatePublicationSurfaceResult(source_result);
        const cell_count = try slotCellCountChecked(surface.cols, surface.rows);
        std.debug.assert(surface.surface_cells.len == cell_count);
        std.debug.assert(surface.dirty_rows.len == surface.rows);
        std.debug.assert(surface.dirty_cols_start.len == surface.rows);
        std.debug.assert(surface.dirty_cols_end.len == surface.rows);

        try self.staged_slot.ensureCapacity(self.allocator, surface.cols, surface.rows);
        const slot = self.staged_slot.vtSurfaceSlot(surface.cols, surface.rows);
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
            .cursor = vtCursorIn(surface.cursor, surface.cursor_color, surface.cursor_text_color),
            .extra_cursor_count = surface.extra_cursor_count,
            .extra_cursors = extraCursorsIn(surface.extra_cursors, surface.extra_cursor_count),
            .cursor_trail_count = 0,
            .cursor_trail_rects = [_]source_abi.SourceCursorTrailRect{.{}} ** source_abi.max_cursor_trail_rects,
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
        if (!self.staged_slot.canHold(cols, rows)) return error.VtSurfaceSlotOutOfRange;

        self.reserved = self.retainedSource(&self.staged_slot, cols, rows);
        return self.staged_slot.vtSurfaceSlot(cols, rows);
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

    pub fn promoteStagedSource(self: *SourceSlot, source: *source_publication.PublicationSource) !void {
        std.debug.assert(source.retained_storage);
        std.debug.assert(source.cells.ptr == self.staged_slot.cells.ptr);
        std.debug.assert(source.dirty_rows.ptr == self.staged_slot.dirty_rows.ptr);
        std.debug.assert(source.dirty_cols_start.ptr == self.staged_slot.dirty_cols_start.ptr);
        std.debug.assert(source.dirty_cols_end.ptr == self.staged_slot.dirty_cols_end.ptr);

        try self.active_slot.ensureCapacity(self.allocator, source.cols, source.rows);
        const cell_count = try slotCellCountChecked(source.cols, source.rows);
        const slot = self.active_slot.vtSurfaceSlot(source.cols, source.rows);
        std.debug.assert(slot.cells.len == cell_count);
        @memcpy(slot.cells, source.cells);
        @memcpy(slot.dirty_rows, source.dirty_rows);
        @memcpy(slot.dirty_cols_start, source.dirty_cols_start);
        @memcpy(slot.dirty_cols_end, source.dirty_cols_end);

        const history_count = source.history_count;
        const scroll_row = source.scroll_row;
        const snapshot_seq = source.snapshot_seq;
        const dirty_epoch = source.dirty_epoch;
        const is_alternate_screen = source.is_alternate_screen;
        const cursor = source.cursor;
        const extra_cursor_count = source.extra_cursor_count;
        const extra_cursors = source.extra_cursors;
        const cursor_trail_count = source.cursor_trail_count;
        const cursor_trail_rects = source.cursor_trail_rects;
        const colors = source.colors;
        const selection = source.selection;
        const cursor_phase_visible = source.cursor_phase_visible;

        source.* = self.retainedSource(&self.active_slot, source.cols, source.rows);
        source.history_count = history_count;
        source.scroll_row = scroll_row;
        source.snapshot_seq = snapshot_seq;
        source.dirty_epoch = dirty_epoch;
        source.is_alternate_screen = is_alternate_screen;
        source.cursor = cursor;
        source.extra_cursor_count = extra_cursor_count;
        source.extra_cursors = extra_cursors;
        source.cursor_trail_count = cursor_trail_count;
        source.cursor_trail_rects = cursor_trail_rects;
        source.colors = colors;
        source.selection = selection;
        source.cursor_phase_visible = cursor_phase_visible;

        std.debug.assert(source.snapshot_seq != 0);
        std.debug.assert(source.dirty_epoch != 0);
        try source_abi.validateSourceCells(source.cells);
        try source_damage.validateDirtySource(source.rows, source.cols, source.dirty_rows, source.dirty_cols_start, source.dirty_cols_end);
    }

    pub fn sourcePending(self: *const SourceSlot) bool {
        return self.reserved != null;
    }

    fn retainedSource(_: *const SourceSlot, slot_owner: *const RetainedSlot, cols: u16, rows: u16) source_publication.PublicationSource {
        const slot = slot_owner.vtSurfaceSlot(cols, rows);
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
            .extra_cursor_count = 0,
            .extra_cursors = [_]source_abi.SourceExtraCursor{.{}} ** source_abi.max_extra_cursors,
            .cursor_trail_count = 0,
            .cursor_trail_rects = [_]source_abi.SourceCursorTrailRect{.{}} ** source_abi.max_cursor_trail_rects,
            .colors = std.mem.zeroes(source_abi.SourceColors),
            .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
            .cursor_phase_visible = true,
            .dirty_rows = slot.dirty_rows,
            .dirty_cols_start = slot.dirty_cols_start,
            .dirty_cols_end = slot.dirty_cols_end,
            .retained_storage = true,
        };
    }

    fn refreshStagedSlotView(self: *SourceSlot) void {
        if (self.reserved) |*source| {
            if (source.retained_storage) self.refreshSourceForSlot(source, &self.staged_slot);
        }
    }

    pub fn refreshActiveSource(self: *SourceSlot, source: *source_publication.PublicationSource) void {
        self.refreshSourceForSlot(source, &self.active_slot);
    }

    fn refreshSourceForSlot(self: *SourceSlot, source: *source_publication.PublicationSource, slot_owner: *const RetainedSlot) void {
        const scroll_row = source.scroll_row;
        const history_count = source.history_count;
        const snapshot_seq = source.snapshot_seq;
        const dirty_epoch = source.dirty_epoch;
        const is_alternate_screen = source.is_alternate_screen;
        const cursor = source.cursor;
        const extra_cursor_count = source.extra_cursor_count;
        const extra_cursors = source.extra_cursors;
        const cursor_trail_count = source.cursor_trail_count;
        const cursor_trail_rects = source.cursor_trail_rects;
        const colors = source.colors;
        const selection = source.selection;
        const cursor_phase_visible = source.cursor_phase_visible;
        source.* = self.retainedSource(slot_owner, source.cols, source.rows);
        source.history_count = history_count;
        source.scroll_row = scroll_row;
        source.snapshot_seq = snapshot_seq;
        source.dirty_epoch = dirty_epoch;
        source.is_alternate_screen = is_alternate_screen;
        source.cursor = cursor;
        source.extra_cursor_count = extra_cursor_count;
        source.extra_cursors = extra_cursors;
        source.cursor_trail_count = cursor_trail_count;
        source.cursor_trail_rects = cursor_trail_rects;
        source.colors = colors;
        source.selection = selection;
        source.cursor_phase_visible = cursor_phase_visible;
    }
};

fn vtCursorIn(value: anytype, cursor_color: anytype, cursor_text_color: anytype) source_abi.SourceCursor {
    const shape = switch (value.shape) {
        1 => source_abi.SourceCursorShape.underline,
        2 => .beam,
        3 => .none,
        else => .block,
    };
    return .{
        .row = value.row,
        .col = value.col,
        .visible = value.visible != 0,
        .shape = shape,
        .blink = value.blink != 0,
        .position_changed_by_client_at_ms = value.position_changed_by_client_at_ms,
        .cell_cols = value.cell_cols,
        .cell_rows = value.cell_rows,
        .cursor_color = cursor_color,
        .cursor_text_color = cursor_text_color,
        .cursor_opacity = 255,
        .text_blink_opacity = 255,
        .focused = true,
        .effective_shape = shape,
    };
}

fn extraCursorsIn(value: anytype, count: u16) [source_abi.max_extra_cursors]source_abi.SourceExtraCursor {
    var out = [_]source_abi.SourceExtraCursor{.{}} ** source_abi.max_extra_cursors;
    for (out[0..count], value[0..count]) |*target, source| {
        target.* = .{
            .row = source.row,
            .col = source.col,
            .rows = source.rows,
            .cols = source.cols,
            .shape = @enumFromInt(source.shape),
            .mode = @enumFromInt(source.mode),
            .shape_follows_main = source.shape_follows_main != 0,
            .color_follows_main = source.color_follows_main != 0,
            .cursor_color = source.cursor_color,
            .text_color = source.text_color,
        };
    }
    return out;
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
    try std.testing.expectEqual(slot_owner.staged_slot.cells.ptr, slot.cells.ptr);
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
    const retained_cells = slot_owner.staged_slot.cells.ptr;
    const retained_dirty_rows = slot_owner.staged_slot.dirty_rows.ptr;

    source.deinit(std.testing.allocator);

    try std.testing.expectEqual(retained_cells, slot_owner.staged_slot.cells.ptr);
    try std.testing.expectEqual(retained_dirty_rows, slot_owner.staged_slot.dirty_rows.ptr);
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
    try std.testing.expectEqual(@as(u16, 0), source.extra_cursor_count);
    try std.testing.expectEqual(@as(u16, 0), source.cursor_trail_count);
    try std.testing.expectEqual(@as(usize, 2), source.cells.len);
    try std.testing.expectEqual(@as(u32, 'A'), source.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'B'), source.cells[1].codepoint);
    try std.testing.expectEqualSlices(u8, dirty_rows[0..], source.dirty_rows);
    try std.testing.expectEqualSlices(u16, dirty_cols_start[0..], source.dirty_cols_start);
    try std.testing.expectEqualSlices(u16, dirty_cols_end[0..], source.dirty_cols_end);
}

test "source slot promote preserves widened empty cursor aggregates and primary cursor truth" {
    var slot_owner = SourceSlot.init(std.testing.allocator);
    defer slot_owner.deinit();

    var cells = [_]source_abi.SourceCell{ testCell('A'), testCell('B') };
    const result = source_publication.validSurfaceResult(cells[0..], &[_]u8{1}, &[_]u16{0}, &[_]u16{1});
    var source = try slot_owner.copyPublishedSource(result, 22, false);
    defer source.deinit(std.testing.allocator);

    try slot_owner.promoteStagedSource(&source);

    try std.testing.expectEqual(@as(u64, 17), source.cursor.position_changed_by_client_at_ms);
    try std.testing.expectEqual(@as(u16, 0), source.extra_cursor_count);
    try std.testing.expectEqual(@as(u16, 0), source.cursor_trail_count);
    try std.testing.expectEqual(@as(u32, 0x010203), source.cursor.cursor_color.value);
    try std.testing.expectEqual(@as(u32, 7), source.cursor.cursor_text_color.value);
}

test "source slot copy ignores inactive extra cursor tail when count is zero" {
    var slot_owner = SourceSlot.init(std.testing.allocator);
    defer slot_owner.deinit();

    var cells = [_]source_abi.SourceCell{ testCell('A'), testCell('B') };
    var result = source_publication.validSurfaceResult(cells[0..], &[_]u8{1}, &[_]u16{0}, &[_]u16{1});
    result.source.extra_cursors[0].shape = 255;
    result.source.extra_cursors[0].mode = 255;
    result.source.extra_cursor_count = 0;

    var source = try slot_owner.copyPublishedSource(result, 22, false);
    defer source.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 0), source.extra_cursor_count);
    try std.testing.expectEqual(std.mem.zeroes(source_abi.SourceExtraCursor), source.extra_cursors[0]);
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

    var source = try slot_owner.commitReservedSource(.{
        .history_count = 4,
        .scroll_row = 3,
        .snapshot_seq = 8,
        .is_alternate_screen = true,
        .cursor = source_abi.SourceCursor{ .row = 0, .col = 1, .visible = true, .shape = .beam, .blink = true },
        .colors = std.mem.zeroes(source_abi.SourceColors),
        .selection = std.mem.zeroes(source_abi.SourceSelection),
    }, 9);

    try slot_owner.promoteStagedSource(&source);

    const old_staged_cells = slot_owner.staged_slot.cells.ptr;
    const old_active_cells = slot_owner.active_slot.cells.ptr;
    const old_active_dirty_rows = slot_owner.active_slot.dirty_rows.ptr;

    try slot_owner.syncReservedSlotCapacity(3, 2);
    slot_owner.refreshActiveSource(&source);

    try std.testing.expect(source.retained_storage);
    try std.testing.expect(old_staged_cells != slot_owner.staged_slot.cells.ptr);
    try std.testing.expect(old_active_cells != slot_owner.active_slot.cells.ptr);
    try std.testing.expect(old_active_dirty_rows != slot_owner.active_slot.dirty_rows.ptr);
    try std.testing.expectEqual(@as(u64, 4), source.history_count);
    try std.testing.expectEqual(@as(u64, 3), source.scroll_row);
    try std.testing.expectEqual(@as(u64, 8), source.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 9), source.dirty_epoch);
    try std.testing.expect(source.is_alternate_screen);
    try std.testing.expectEqual(@as(usize, 1), source.dirty_rows.len);
    try std.testing.expectEqual(slot_owner.active_slot.cells.ptr, source.cells.ptr);
    try std.testing.expectEqual(slot_owner.active_slot.dirty_rows.ptr, source.dirty_rows.ptr);

    const refreshed_slot = try slot_owner.reserveSourceSlot(3, 2);
    defer slot_owner.cancelReservedSource();
    try std.testing.expectEqual(slot_owner.staged_slot.cells.ptr, refreshed_slot.cells.ptr);
    try std.testing.expectEqual(slot_owner.staged_slot.dirty_rows.ptr, refreshed_slot.dirty_rows.ptr);
    const refreshed_source = slot_owner.reservedSource() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(slot_owner.staged_slot.cells.ptr, refreshed_source.cells.ptr);
    try std.testing.expectEqual(slot_owner.staged_slot.dirty_rows.ptr, refreshed_source.dirty_rows.ptr);
}

test "source slot staged and active publications stay separate" {
    var slot_owner = SourceSlot.init(std.testing.allocator);
    defer slot_owner.deinit();

    var first_cells = [_]source_abi.SourceCell{ testCell('A'), testCell('B') };
    const first_result = source_publication.validSurfaceResult(first_cells[0..], &[_]u8{1}, &[_]u16{0}, &[_]u16{1});
    var active_source = try slot_owner.copyPublishedSource(first_result, 21, true);
    try slot_owner.promoteStagedSource(&active_source);

    var second_cells = [_]source_abi.SourceCell{ testCell('C'), testCell('D') };
    const second_result = source_publication.validSurfaceResult(second_cells[0..], &[_]u8{1}, &[_]u16{0}, &[_]u16{1});
    const staged_source = try slot_owner.copyPublishedSource(second_result, 22, false);

    try std.testing.expectEqual(@as(u32, 'A'), active_source.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'B'), active_source.cells[1].codepoint);
    try std.testing.expectEqual(@as(u32, 'C'), staged_source.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'D'), staged_source.cells[1].codepoint);
    try std.testing.expectEqual(slot_owner.active_slot.cells.ptr, active_source.cells.ptr);
    try std.testing.expectEqual(slot_owner.staged_slot.cells.ptr, staged_source.cells.ptr);
    try std.testing.expect(active_source.cells.ptr != staged_source.cells.ptr);
    try std.testing.expect(active_source.dirty_rows.ptr != staged_source.dirty_rows.ptr);
    try std.testing.expect(active_source.dirty_cols_start.ptr != staged_source.dirty_cols_start.ptr);
    try std.testing.expect(active_source.dirty_cols_end.ptr != staged_source.dirty_cols_end.ptr);
}

fn testCell(codepoint: u21) source_abi.SourceCell {
    var cell = std.mem.zeroes(source_abi.SourceCell);
    cell.codepoint = codepoint;
    return cell;
}
