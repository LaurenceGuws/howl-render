const std = @import("std");
const source_publication = @import("../vt_publication/publication.zig");
const scene = @import("../text/scene.zig");
const color = @import("color.zig");

pub fn mapCursorShape(shape: source_publication.SourceCursorShape) scene.CursorShape {
    return switch (shape) {
        .block => .block,
        .underline => .underline,
        .beam => .beam,
        .hollow_block => .hollow_block,
    };
}

pub fn mapTextSceneCursorShape(shape: anytype) scene.CursorShape {
    const name = @tagName(shape);
    if (std.mem.eql(u8, name, "underline")) return .underline;
    if (std.mem.eql(u8, name, "beam")) return .beam;
    if (std.mem.eql(u8, name, "hollow_block")) return .hollow_block;
    return .block;
}

pub fn mapPublicationCursor(source: source_publication.PublicationSource, theme: color.SurfaceTheme) ?scene.CursorInput {
    const cursor_visible = source.cursor.visible and (!source.cursor.blink or source.cursor_phase_visible);
    if (!cursor_visible) return null;
    std.debug.assert(source.cursor.row < source.rows);
    std.debug.assert(source.cursor.col < source.cols);
    return .{
        .cell_col = source.cursor.col,
        .cell_row = source.cursor.row,
        .shape = mapTextSceneCursorShape(source.cursor.shape),
        .color = theme.cursor_color,
        .blink = source.cursor.blink,
    };
}

pub fn mapStateCursor(state: anytype, theme: color.SurfaceTheme) ?scene.CursorInput {
    if (!state.cursor.visible) return null;
    std.debug.assert(state.cursor.row < state.grid.rows);
    std.debug.assert(state.cursor.col < state.grid.cols);
    return .{
        .cell_col = state.cursor.col,
        .cell_row = state.cursor.row,
        .shape = mapTextSceneCursorShape(state.cursor.shape),
        .color = theme.cursor_color,
        .blink = state.cursor.blink,
    };
}

test "renderable content cursor maps blink visible and hidden publication cursor" {
    const theme = color.default_theme;
    var cells = [_]source_publication.SourceCell{std.mem.zeroes(source_publication.SourceCell)};
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};
    const visible = mapPublicationCursor(.{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .beam, .blink = true },
        .colors = std.mem.zeroes(source_publication.SourceColors),
        .selection = std.mem.zeroes(source_publication.SourceSelection),
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, theme);
    try std.testing.expect(visible != null);
    try std.testing.expectEqual(scene.CursorShape.beam, visible.?.shape);

    const hidden = mapPublicationCursor(.{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .beam, .blink = true },
        .colors = std.mem.zeroes(source_publication.SourceColors),
        .selection = std.mem.zeroes(source_publication.SourceSelection),
        .cursor_phase_visible = false,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, theme);
    try std.testing.expectEqual(@as(?scene.CursorInput, null), hidden);
}
