const std = @import("std");
const tokens = @import("../tokens.zig");
const source_publication = @import("publication.zig");

pub fn validateDirtySource(rows: u16, cols: u16, dirty_rows: []const u8, dirty_cols_start: []const u16, dirty_cols_end: []const u16) !void {
    if (dirty_rows.len != rows) return error.InvalidSurfaceSource;
    if (dirty_cols_start.len != rows) return error.InvalidSurfaceSource;
    if (dirty_cols_end.len != rows) return error.InvalidSurfaceSource;

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        std.debug.assert(row < dirty_rows.len);
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

pub fn canonicalizeDirtyMetadata(rows: u16, dirty_rows: []const u8, dirty_cols_start: []u16, dirty_cols_end: []u16) void {
    std.debug.assert(dirty_rows.len == rows);
    std.debug.assert(dirty_cols_start.len == rows);
    std.debug.assert(dirty_cols_end.len == rows);

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        std.debug.assert(row < dirty_rows.len);
        if (dirty_rows[row] != 0) {
            std.debug.assert(dirty_cols_start[row] == rows or dirty_cols_start[row] <= dirty_cols_end[row]);
            continue;
        }
        dirty_cols_start[row] = 0;
        dirty_cols_end[row] = 0;
    }
}

pub fn cursorPresentationChanged(prior: source_publication.PublicationSource, current: source_publication.PublicationSource) bool {
    if (prior.cursor.visible != current.cursor.visible) return true;
    if (prior.cursor.row != current.cursor.row or prior.cursor.col != current.cursor.col) return true;
    if (prior.cursor.shape != current.cursor.shape) return true;
    if (prior.cursor.blink != current.cursor.blink) return true;
    if ((prior.cursor.blink or current.cursor.blink) and prior.cursor_phase_visible != current.cursor_phase_visible) return true;
    return false;
}

pub fn colorPresentationChanged(prior: source_publication.PublicationSource, current: source_publication.PublicationSource) bool {
    return !std.mem.eql(u8, std.mem.asBytes(&prior.colors), std.mem.asBytes(&current.colors));
}

pub fn setSourceCursorBlinkVisible(source: *source_publication.PublicationSource, visible: bool) bool {
    if (!source.cursor.blink or source.cursor_phase_visible == visible) return false;
    source.cursor_phase_visible = visible;
    return true;
}

pub fn sameSnapshotToken(a: tokens.SnapshotToken, b: tokens.SnapshotToken) bool {
    return a.snapshot_seq == b.snapshot_seq and a.dirty_epoch == b.dirty_epoch and a.geometry_epoch == b.geometry_epoch and a.damage_base_seq == b.damage_base_seq and a.damage_kind == b.damage_kind;
}

pub fn samePublicationSource(a: source_publication.PublicationSource, b: source_publication.PublicationSource) bool {
    return a.cols == b.cols and
        a.rows == b.rows and
        a.history_count == b.history_count and
        a.scroll_row == b.scroll_row and
        a.snapshot_seq == b.snapshot_seq and
        a.is_alternate_screen == b.is_alternate_screen and
        std.mem.eql(u8, std.mem.asBytes(&a.selection), std.mem.asBytes(&b.selection)) and
        a.cursor_phase_visible == b.cursor_phase_visible and
        a.cursor.row == b.cursor.row and
        a.cursor.col == b.cursor.col and
        a.cursor.visible == b.cursor.visible and
        a.cursor.shape == b.cursor.shape and
        a.cursor.blink == b.cursor.blink and
        std.mem.eql(u8, std.mem.asBytes(&a.colors), std.mem.asBytes(&b.colors)) and
        std.mem.eql(u8, std.mem.sliceAsBytes(a.cells), std.mem.sliceAsBytes(b.cells)) and
        std.mem.eql(u8, a.dirty_rows, b.dirty_rows) and
        std.mem.eql(u16, a.dirty_cols_start, b.dirty_cols_start) and
        std.mem.eql(u16, a.dirty_cols_end, b.dirty_cols_end);
}

pub fn classifyDirty(snapshot: source_publication.VtSnapshot) tokens.DamageKind {
    std.debug.assert(snapshot.dirty_rows.len == snapshot.rows);
    std.debug.assert(snapshot.dirty_cols_start.len == snapshot.rows);
    std.debug.assert(snapshot.dirty_cols_end.len == snapshot.rows);
    var any_dirty = false;
    var all_rows_dirty = snapshot.rows != 0;
    var row: u16 = 0;
    while (row < snapshot.rows) : (row += 1) {
        if (snapshot.dirty_rows[row] == 0) {
            all_rows_dirty = false;
            continue;
        }
        any_dirty = true;
        if (snapshot.dirty_cols_start[row] != 0) all_rows_dirty = false;
        if (snapshot.dirty_cols_end[row] != snapshot.cols -| 1) all_rows_dirty = false;
    }
    if (!any_dirty) return .none;
    if (all_rows_dirty) return .full;
    std.debug.assert(snapshot.rows == 0 or snapshot.cols == 0 or !allRowsCoverFullWidth(snapshot));
    return .partial;
}

fn allRowsCoverFullWidth(snapshot: source_publication.VtSnapshot) bool {
    if (snapshot.rows == 0) return false;
    var row: u16 = 0;
    while (row < snapshot.rows) : (row += 1) {
        if (snapshot.dirty_rows[row] == 0) return false;
        if (snapshot.dirty_cols_start[row] != 0) return false;
        if (snapshot.dirty_cols_end[row] != snapshot.cols -| 1) return false;
    }
    return true;
}

fn testSnapshot(rows: u16, cols: u16, scroll_row: u64, snapshot_seq: u64, dirty_rows: []const u8, dirty_cols_start: []const u16, dirty_cols_end: []const u16) source_publication.VtSnapshot {
    return .{
        .cols = cols,
        .rows = rows,
        .history_count = scroll_row,
        .scroll_row = scroll_row,
        .snapshot_seq = snapshot_seq,
        .dirty_epoch = snapshot_seq,
        .is_alternate_screen = false,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

test "publication damage canonicalizes clean dirty metadata before equality dedupe" {
    var first = try source_publication.testSourceFromSnapshot(std.testing.allocator, testSnapshot(2, 3, 0, 7, &[_]u8{ 1, 0 }, &[_]u16{ 0, 2 }, &[_]u16{ 1, 1 }));
    defer first.deinit(std.testing.allocator);
    var second = try source_publication.testSourceFromSnapshot(std.testing.allocator, testSnapshot(2, 3, 0, 7, &[_]u8{ 1, 0 }, &[_]u16{ 0, 1 }, &[_]u16{ 1, 2 }));
    defer second.deinit(std.testing.allocator);

    canonicalizeDirtyMetadata(first.rows, first.dirty_rows, first.dirty_cols_start, first.dirty_cols_end);
    canonicalizeDirtyMetadata(second.rows, second.dirty_rows, second.dirty_cols_start, second.dirty_cols_end);

    try std.testing.expect(samePublicationSource(first, second));
}

test "publication damage preserves dirty row spans and sentinels while canonicalizing" {
    const dirty_rows = [_]u8{ 1, 1, 0 };
    var dirty_cols_start = [_]u16{ 1, 3, 2 };
    var dirty_cols_end = [_]u16{ 2, 3, 1 };

    canonicalizeDirtyMetadata(3, &dirty_rows, &dirty_cols_start, &dirty_cols_end);

    try std.testing.expectEqual(@as(u16, 1), dirty_cols_start[0]);
    try std.testing.expectEqual(@as(u16, 2), dirty_cols_end[0]);
    try std.testing.expectEqual(@as(u16, 3), dirty_cols_start[1]);
    try std.testing.expectEqual(@as(u16, 3), dirty_cols_end[1]);
    try std.testing.expectEqual(@as(u16, 0), dirty_cols_start[2]);
    try std.testing.expectEqual(@as(u16, 0), dirty_cols_end[2]);
}

test "publication damage boundary rejects invalid dirty metadata before canonicalization" {
    var source = try source_publication.testSourceFromSnapshot(std.testing.allocator, testSnapshot(1, 3, 0, 17, &[_]u8{1}, &[_]u16{3}, &[_]u16{1}));
    defer source.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidSurfaceSource, source_publication.validatePublicationSourceBoundary(source));
}

test "publication damage classifies full damage when rows and cols are fully covered" {
    const damage_kind = classifyDirty(testSnapshot(2, 3, 0, 1, &[_]u8{ 1, 1 }, &[_]u16{ 0, 0 }, &[_]u16{ 2, 2 }));
    try std.testing.expectEqual(tokens.DamageKind.full, damage_kind);
}

test "publication damage keeps partial classification for partial row coverage" {
    const damage_kind = classifyDirty(testSnapshot(2, 3, 0, 1, &[_]u8{ 1, 1 }, &[_]u16{ 0, 1 }, &[_]u16{ 2, 2 }));
    try std.testing.expectEqual(tokens.DamageKind.partial, damage_kind);
}
