const std = @import("std");
const tokens = @import("../tokens.zig");
const vt_surface = @import("surface.zig");

pub fn validateDirtyVtSurface(rows: u16, cols: u16, dirty_rows: []const u8, dirty_cols_start: []const u16, dirty_cols_end: []const u16) !void {
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

pub fn cursorPresentationChanged(prior: vt_surface.VtSurface, current: vt_surface.VtSurface) bool {
    if (prior.cursor.visible != current.cursor.visible) return true;
    if (prior.cursor.row != current.cursor.row or prior.cursor.col != current.cursor.col) return true;
    if (prior.cursor.shape != current.cursor.shape) return true;
    if (prior.cursor.blink != current.cursor.blink) return true;
    if (prior.cursor.position_changed_by_client_at_ms != current.cursor.position_changed_by_client_at_ms) return true;
    if (prior.cursor.cell_cols != current.cursor.cell_cols) return true;
    if (prior.cursor.cell_rows != current.cursor.cell_rows) return true;
    if (!sameColor(prior.cursor_color, current.cursor_color)) return true;
    if (!sameColor(prior.cursor_text_color, current.cursor_text_color)) return true;
    if (prior.cursor_opacity != current.cursor_opacity) return true;
    if (prior.text_blink_opacity != current.text_blink_opacity) return true;
    if (prior.cursor_focused != current.cursor_focused) return true;
    if (prior.effective_shape != current.effective_shape) return true;
    if (prior.extra_cursor_count != current.extra_cursor_count) return true;
    if (!sameExtraCursors(prior.extra_cursors[0..prior.extra_cursor_count], current.extra_cursors[0..current.extra_cursor_count])) return true;
    if (prior.cursor_trail_count != current.cursor_trail_count) return true;
    if (!std.mem.eql(u8, std.mem.sliceAsBytes(prior.cursor_trail_rects[0..prior.cursor_trail_count]), std.mem.sliceAsBytes(current.cursor_trail_rects[0..current.cursor_trail_count]))) return true;
    return false;
}

pub fn colorPresentationChanged(prior: vt_surface.VtSurface, current: vt_surface.VtSurface) bool {
    return !std.mem.eql(u8, std.mem.asBytes(&prior.colors), std.mem.asBytes(&current.colors));
}

pub fn setVtSurfaceCursorBlinkVisible(source: *vt_surface.VtSurface, visible: bool) bool {
    if (source.cursor.blink == 0) return false;
    const opacity: u8 = if (visible) 255 else 0;
    if (source.cursor_opacity == opacity) return false;
    source.cursor_opacity = opacity;
    source.text_blink_opacity = opacity;
    source.cursor_phase_visible = visible;
    return true;
}

pub fn sameSnapshotToken(a: tokens.SnapshotToken, b: tokens.SnapshotToken) bool {
    return a.snapshot_seq == b.snapshot_seq and a.dirty_epoch == b.dirty_epoch and a.geometry_epoch == b.geometry_epoch and a.damage_base_seq == b.damage_base_seq and a.damage_kind == b.damage_kind;
}

pub fn sameVtSurface(a: vt_surface.VtSurface, b: vt_surface.VtSurface) bool {
    return a.cols == b.cols and
        a.rows == b.rows and
        a.history_count == b.history_count and
        a.scroll_row == b.scroll_row and
        a.snapshot_seq == b.snapshot_seq and
        a.is_alternate_screen == b.is_alternate_screen and
        sameSelection(a.selection, b.selection) and
        a.cursor.row == b.cursor.row and
        a.cursor.col == b.cursor.col and
        a.cursor.visible == b.cursor.visible and
        a.cursor.shape == b.cursor.shape and
        a.cursor.blink == b.cursor.blink and
        a.cursor.position_changed_by_client_at_ms == b.cursor.position_changed_by_client_at_ms and
        a.cursor.cell_cols == b.cursor.cell_cols and
        a.cursor.cell_rows == b.cursor.cell_rows and
        sameColor(a.cursor_color, b.cursor_color) and
        sameColor(a.cursor_text_color, b.cursor_text_color) and
        a.cursor_opacity == b.cursor_opacity and
        a.text_blink_opacity == b.text_blink_opacity and
        a.cursor_focused == b.cursor_focused and
        a.effective_shape == b.effective_shape and
        a.extra_cursor_count == b.extra_cursor_count and
        sameExtraCursors(a.extra_cursors[0..a.extra_cursor_count], b.extra_cursors[0..b.extra_cursor_count]) and
        a.cursor_trail_count == b.cursor_trail_count and
        sameCursorTrailRects(a.cursor_trail_rects[0..a.cursor_trail_count], b.cursor_trail_rects[0..b.cursor_trail_count]) and
        sameColors(a.colors, b.colors) and
        sameCells(a.cells, b.cells) and
        std.mem.eql(u8, a.dirty_rows, b.dirty_rows) and
        std.mem.eql(u16, a.dirty_cols_start, b.dirty_cols_start) and
        std.mem.eql(u16, a.dirty_cols_end, b.dirty_cols_end);
}

fn sameSelection(a: anytype, b: anytype) bool {
    return a.active == b.active and a.selecting == b.selecting and a.start.row == b.start.row and a.start.col == b.start.col and a.end.row == b.end.row and a.end.col == b.end.col;
}

fn sameColors(a: anytype, b: anytype) bool {
    if (a.foreground.r != b.foreground.r or a.foreground.g != b.foreground.g or a.foreground.b != b.foreground.b) return false;
    if (a.background.r != b.background.r or a.background.g != b.background.g or a.background.b != b.background.b) return false;
    if (a.cursor.r != b.cursor.r or a.cursor.g != b.cursor.g or a.cursor.b != b.cursor.b) return false;
    for (a.palette, b.palette) |left, right| {
        if (left.r != right.r or left.g != right.g or left.b != right.b) return false;
    }
    return true;
}

fn sameExtraCursors(a: anytype, b: anytype) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.row != right.row or left.col != right.col or left.rows != right.rows or left.cols != right.cols) return false;
        if (left.shape != right.shape or left.mode != right.mode) return false;
        if (left.shape_follows_main != right.shape_follows_main or left.color_follows_main != right.color_follows_main) return false;
        if (!sameColor(left.cursor_color, right.cursor_color) or !sameColor(left.text_color, right.text_color)) return false;
    }
    return true;
}

fn sameCursorTrailRects(a: anytype, b: anytype) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.row != right.row or left.col != right.col or left.rows != right.rows or left.cols != right.cols) return false;
        if (left.opacity != right.opacity) return false;
        if (left.color.r != right.color.r or left.color.g != right.color.g or left.color.b != right.color.b) return false;
    }
    return true;
}

fn sameCells(a: anytype, b: anytype) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.codepoint != right.codepoint or left.combining_len != right.combining_len) return false;
        if (!std.mem.eql(u32, left.combining[0..left.combining_len], right.combining[0..right.combining_len])) return false;
        if (left.flags.continuation != right.flags.continuation) return false;
        if (!sameColor(left.fg_color, right.fg_color) or !sameColor(left.bg_color, right.bg_color) or !sameColor(left.underline_color, right.underline_color)) return false;
        if (left.underline_style != right.underline_style or left.link_id != right.link_id) return false;
        if (!sameAttrs(left.attrs, right.attrs)) return false;
    }
    return true;
}

fn sameColor(a: anytype, b: anytype) bool {
    return a.kind == b.kind and a.value == b.value;
}

fn sameAttrs(a: anytype, b: anytype) bool {
    return a.bold == b.bold and a.dim == b.dim and a.italic == b.italic and a.underline == b.underline and a.underline_color_set == b.underline_color_set and a.blink == b.blink and a.inverse == b.inverse and a.invisible == b.invisible and a.strikethrough == b.strikethrough and a.selected == b.selected;
}

pub fn classifyDirty(snapshot: vt_surface.VtSurfaceSnapshot) tokens.DamageKind {
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

fn allRowsCoverFullWidth(snapshot: vt_surface.VtSurfaceSnapshot) bool {
    if (snapshot.rows == 0) return false;
    var row: u16 = 0;
    while (row < snapshot.rows) : (row += 1) {
        if (snapshot.dirty_rows[row] == 0) return false;
        if (snapshot.dirty_cols_start[row] != 0) return false;
        if (snapshot.dirty_cols_end[row] != snapshot.cols -| 1) return false;
    }
    return true;
}

fn testSnapshot(rows: u16, cols: u16, scroll_row: u64, snapshot_seq: u64, dirty_rows: []const u8, dirty_cols_start: []const u16, dirty_cols_end: []const u16) vt_surface.VtSurfaceSnapshot {
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

test "vt surface damage canonicalizes clean dirty metadata before equality dedupe" {
    var first = try vt_surface.testVtSurfaceFromSnapshot(std.testing.allocator, testSnapshot(2, 3, 0, 7, &[_]u8{ 1, 0 }, &[_]u16{ 0, 2 }, &[_]u16{ 1, 1 }));
    defer first.deinit(std.testing.allocator);
    var second = try vt_surface.testVtSurfaceFromSnapshot(std.testing.allocator, testSnapshot(2, 3, 0, 7, &[_]u8{ 1, 0 }, &[_]u16{ 0, 1 }, &[_]u16{ 1, 2 }));
    defer second.deinit(std.testing.allocator);

    canonicalizeDirtyMetadata(first.rows, first.dirty_rows, first.dirty_cols_start, first.dirty_cols_end);
    canonicalizeDirtyMetadata(second.rows, second.dirty_rows, second.dirty_cols_start, second.dirty_cols_end);

    try std.testing.expect(sameVtSurface(first, second));
}

test "vt surface damage preserves dirty row spans and sentinels while canonicalizing" {
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

test "vt surface damage boundary rejects invalid dirty metadata before canonicalization" {
    var source = try vt_surface.testVtSurfaceFromSnapshot(std.testing.allocator, testSnapshot(1, 3, 0, 17, &[_]u8{1}, &[_]u16{3}, &[_]u16{1}));
    defer source.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidSurfaceSource, vt_surface.validateVtSurfaceBoundary(source));
}

test "vt surface damage classifies full damage when rows and cols are fully covered" {
    const damage_kind = classifyDirty(testSnapshot(2, 3, 0, 1, &[_]u8{ 1, 1 }, &[_]u16{ 0, 0 }, &[_]u16{ 2, 2 }));
    try std.testing.expectEqual(tokens.DamageKind.full, damage_kind);
}

test "vt surface damage keeps partial classification for partial row coverage" {
    const damage_kind = classifyDirty(testSnapshot(2, 3, 0, 1, &[_]u8{ 1, 1 }, &[_]u16{ 0, 1 }, &[_]u16{ 2, 2 }));
    try std.testing.expectEqual(tokens.DamageKind.partial, damage_kind);
}

test "vt surface damage treats widened cursor truth as cursor damage not terminal content" {
    var prior = try vt_surface.ownedTestVtSurface(std.testing.allocator, 1, 'a');
    defer prior.deinit(std.testing.allocator);
    var current = try vt_surface.ownedTestVtSurface(std.testing.allocator, 1, 'a');
    defer current.deinit(std.testing.allocator);

    current.cursor.position_changed_by_client_at_ms = 9;
    try std.testing.expect(cursorPresentationChanged(prior, current));
    try std.testing.expect(!colorPresentationChanged(prior, current));
}

test "vt surface damage detects widened empty aggregate changes as cursor damage" {
    var prior = try vt_surface.ownedTestVtSurface(std.testing.allocator, 1, 'a');
    defer prior.deinit(std.testing.allocator);
    var current = try vt_surface.ownedTestVtSurface(std.testing.allocator, 1, 'a');
    defer current.deinit(std.testing.allocator);

    current.cursor_color = .{ .kind = 2, .value = 0x010203 };
    try std.testing.expect(cursorPresentationChanged(prior, current));

    current.cursor_color = .{ .kind = 0, .value = 0 };
    current.extra_cursor_count = 1;
    current.extra_cursors[0].rows = 1;
    current.extra_cursors[0].cols = 1;
    try std.testing.expect(cursorPresentationChanged(prior, current));

    current.extra_cursor_count = 0;
    current.cursor_trail_count = 1;
    current.cursor_trail_rects[0].rows = 1;
    current.cursor_trail_rects[0].cols = 1;
    try std.testing.expect(cursorPresentationChanged(prior, current));
}
