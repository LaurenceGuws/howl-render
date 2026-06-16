const std = @import("std");
const source_abi = @import("abi.zig");
const source_publication = @import("publication.zig");
const color = @import("theme.zig");

pub const max_extra_cursors = 256;
pub const max_cursor_trail_rects = 16;

pub const ColorKind = enum(u8) {
    default = 0,
    indexed = 1,
    rgb = 2,
};

pub const CursorColor = struct {
    kind: ColorKind,
    value: u32,
};

pub const Rgb8 = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const CellExtent = struct {
    row: u16,
    col: u16,
    rows: u16,
    cols: u16,
};

pub const CursorShape = enum(u8) {
    none = 0,
    block = 1,
    beam = 2,
    underline = 3,
    hollow = 4,
};

pub const ExtraCursorMode = enum(u8) {
    point = 0,
    rectangle = 1,
};

pub const ExtraCursorPresentation = struct {
    extent: CellExtent,
    shape: CursorShape,
    mode: ExtraCursorMode,
    shape_follows_main: bool,
    color_follows_main: bool,
    cursor_color: CursorColor,
    text_color: CursorColor,
};

pub const CursorTrailRect = struct {
    extent: CellExtent,
    opacity: u8,
    color: Rgb8,
    pixel_rect: bool = false,
    x_px: i32 = 0,
    y_px: i32 = 0,
    width_px: u16 = 0,
    height_px: u16 = 0,
};

pub const CursorTrailSource = struct {
    rects: [max_cursor_trail_rects]CursorTrailRect,
    count: u16,
};

pub const CursorPresentation = struct {
    focused: bool,
    visible: bool,
    blink: bool,
    shape: CursorShape,
    beam_thickness: f32 = 1.5,
    underline_thickness: f32 = 2.0,
    cursor_opacity: u8,
    text_blink_opacity: u8,
    cursor_color: CursorColor,
    cursor_text_color: CursorColor,
    cursor_trail_color: CursorColor = .{ .kind = .default, .value = 0 },
    default_foreground: Rgb8,
    default_background: Rgb8,
    primary_extent: CellExtent,
    extra_cursors: [max_extra_cursors]ExtraCursorPresentation,
    extra_cursor_count: u16,
    trail: CursorTrailSource,
};

pub fn mapPublicationCursor(source: source_publication.PublicationSource, theme: color.SurfaceTheme) CursorPresentation {
    std.debug.assert(source.cursor.row < source.rows);
    std.debug.assert(source.cursor.col < source.cols);
    const extra_cursors = mapPublicationExtraCursors(source.extra_cursors[0..source.extra_cursor_count]);
    return .{
        .focused = source.cursor.focused,
        .visible = source.cursor.visible,
        .blink = source.cursor.blink,
        .shape = mapCursorShape(source.cursor.effective_shape),
        .beam_thickness = theme.cursor_beam_thickness,
        .underline_thickness = theme.cursor_underline_thickness,
        .cursor_opacity = source.cursor.cursor_opacity,
        .text_blink_opacity = source.cursor.text_blink_opacity,
        .cursor_color = if (source.cursor.cursor_color.kind == 0) mapCursorColor(theme.cursor_default_color) else mapCursorColor(source.cursor.cursor_color),
        .cursor_text_color = if (source.cursor.cursor_text_color.kind == 0) mapCursorColor(theme.cursor_text_color) else mapCursorColor(source.cursor.cursor_text_color),
        .cursor_trail_color = mapCursorColor(theme.cursor_trail_color),
        .default_foreground = mapRgb8(theme.default_fg),
        .default_background = mapRgb8(theme.default_bg),
        .primary_extent = .{
            .row = source.cursor.row,
            .col = source.cursor.col,
            .rows = source.cursor.cell_rows,
            .cols = source.cursor.cell_cols,
        },
        .extra_cursors = extra_cursors,
        .extra_cursor_count = source.extra_cursor_count,
        .trail = mapCursorTrailSource(source.cursor_trail_rects[0..source.cursor_trail_count]),
    };
}

pub fn mapStateCursor(state: anytype, theme: color.SurfaceTheme) CursorPresentation {
    std.debug.assert(state.cursor.row < state.grid.rows);
    std.debug.assert(state.cursor.col < state.grid.cols);
    const blink = if (@hasField(@TypeOf(state.cursor), "blink")) state.cursor.blink else false;
    return .{
        .focused = true,
        .visible = state.cursor.visible,
        .blink = blink,
        .shape = mapLegacyStateCursorShape(state.cursor.shape),
        .beam_thickness = theme.cursor_beam_thickness,
        .underline_thickness = theme.cursor_underline_thickness,
        .cursor_opacity = if (state.cursor.visible) 255 else 0,
        .text_blink_opacity = 255,
        .cursor_color = mapCursorColor(theme.cursor_default_color),
        .cursor_text_color = mapCursorColor(theme.cursor_text_color),
        .cursor_trail_color = mapCursorColor(theme.cursor_trail_color),
        .default_foreground = mapRgb8(theme.default_fg),
        .default_background = mapRgb8(theme.default_bg),
        .primary_extent = .{ .row = state.cursor.row, .col = state.cursor.col, .rows = 1, .cols = 1 },
        .extra_cursors = [_]ExtraCursorPresentation{undefined} ** max_extra_cursors,
        .extra_cursor_count = 0,
        .trail = .{ .rects = [_]CursorTrailRect{undefined} ** max_cursor_trail_rects, .count = 0 },
    };
}

fn mapCursorShape(shape: source_abi.SourceCursorShape) CursorShape {
    return switch (shape) {
        .block => .block,
        .underline => .underline,
        .beam => .beam,
        .hollow_block => .hollow,
        .none => .none,
    };
}

fn mapLegacyStateCursorShape(shape: anytype) CursorShape {
    const name = @tagName(shape);
    if (std.mem.eql(u8, name, "underline")) return .underline;
    if (std.mem.eql(u8, name, "beam")) return .beam;
    if (std.mem.eql(u8, name, "bar")) return .beam;
    if (std.mem.eql(u8, name, "hollow_block")) return .hollow;
    return .block;
}

fn mapCursorColor(color_value: source_abi.SourceColor) CursorColor {
    return .{ .kind = @enumFromInt(color_value.kind), .value = color_value.value };
}

fn mapRgb8(value: anytype) Rgb8 {
    return .{ .r = value.r, .g = value.g, .b = value.b };
}

fn rgbToValue(value: anytype) u32 {
    return (@as(u32, value.r) << 16) | (@as(u32, value.g) << 8) | value.b;
}

fn mapPublicationExtraCursors(source: []const source_abi.SourceExtraCursor) [max_extra_cursors]ExtraCursorPresentation {
    var extra_cursors = [_]ExtraCursorPresentation{undefined} ** max_extra_cursors;
    for (0..extra_cursors.len) |index| {
        extra_cursors[index] = .{
            .extent = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 },
            .shape = .none,
            .mode = .point,
            .shape_follows_main = false,
            .color_follows_main = false,
            .cursor_color = .{ .kind = .default, .value = 0 },
            .text_color = .{ .kind = .default, .value = 0 },
        };
    }
    for (source, 0..) |cursor_value, index| {
        extra_cursors[index] = .{
            .extent = .{
                .row = cursor_value.row,
                .col = cursor_value.col,
                .rows = cursor_value.rows,
                .cols = cursor_value.cols,
            },
            .shape = @enumFromInt(@intFromEnum(cursor_value.shape)),
            .mode = @enumFromInt(@intFromEnum(cursor_value.mode)),
            .shape_follows_main = cursor_value.shape_follows_main,
            .color_follows_main = cursor_value.color_follows_main,
            .cursor_color = mapCursorColor(cursor_value.cursor_color),
            .text_color = mapCursorColor(cursor_value.text_color),
        };
    }
    return extra_cursors;
}

fn mapCursorTrailSource(source: []const source_abi.SourceCursorTrailRect) CursorTrailSource {
    var rects = [_]CursorTrailRect{undefined} ** max_cursor_trail_rects;
    for (0..rects.len) |index| {
        rects[index] = .{
            .extent = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 },
            .opacity = 0,
            .color = .{ .r = 0, .g = 0, .b = 0 },
            .pixel_rect = false,
            .x_px = 0,
            .y_px = 0,
            .width_px = 0,
            .height_px = 0,
        };
    }
    for (source, 0..) |rect_value, index| {
        rects[index] = .{
            .extent = .{
                .row = rect_value.row,
                .col = rect_value.col,
                .rows = rect_value.rows,
                .cols = rect_value.cols,
            },
            .opacity = rect_value.opacity,
            .color = mapRgb8(rect_value.color),
            .pixel_rect = rect_value.pixel_rect,
            .x_px = rect_value.x_px,
            .y_px = rect_value.y_px,
            .width_px = rect_value.width_px,
            .height_px = rect_value.height_px,
        };
    }
    return .{ .rects = rects, .count = @intCast(source.len) };
}

test "renderable content cursor presentation maps widened publication truth" {
    const theme = color.default_theme;
    var cells = [_]source_abi.SourceCell{std.mem.zeroes(source_abi.SourceCell)};
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
        .cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .beam, .blink = true, .position_changed_by_client_at_ms = 7, .cell_cols = 2, .cell_rows = 3, .cursor_color = .{ .kind = 2, .value = 0x010203 }, .cursor_text_color = .{ .kind = 1, .value = 9 }, .cursor_opacity = 120, .text_blink_opacity = 45, .focused = false, .effective_shape = .beam },
        .extra_cursor_count = 1,
        .extra_cursors = [_]source_abi.SourceExtraCursor{.{
            .row = 2,
            .col = 3,
            .rows = 4,
            .cols = 5,
            .shape = .underline,
            .mode = .rectangle,
            .shape_follows_main = true,
            .color_follows_main = false,
            .cursor_color = .{ .kind = 1, .value = 4 },
            .text_color = .{ .kind = 2, .value = 0x040506 },
        }} ++ [_]source_abi.SourceExtraCursor{.{
            .row = 0,
            .col = 0,
            .rows = 0,
            .cols = 0,
            .shape = .none,
            .mode = .point,
            .shape_follows_main = false,
            .color_follows_main = false,
            .cursor_color = .{ .kind = 0, .value = 0 },
            .text_color = .{ .kind = 0, .value = 0 },
        }} ** (max_extra_cursors - 1),
        .cursor_trail_count = 1,
        .cursor_trail_rects = [_]source_abi.SourceCursorTrailRect{.{
            .row = 6,
            .col = 7,
            .rows = 8,
            .cols = 9,
            .opacity = 10,
            .reserved0 = 0,
            .reserved1 = 0,
            .color = .{ .r = 11, .g = 12, .b = 13 },
        }} ++ [_]source_abi.SourceCursorTrailRect{.{
            .row = 0,
            .col = 0,
            .rows = 0,
            .cols = 0,
            .opacity = 0,
            .reserved0 = 0,
            .reserved1 = 0,
            .color = .{ .r = 0, .g = 0, .b = 0 },
        }} ** (max_cursor_trail_rects - 1),
        .colors = std.mem.zeroes(source_abi.SourceColors),
        .selection = std.mem.zeroes(source_abi.SourceSelection),
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, theme);
    try std.testing.expect(!visible.focused);
    try std.testing.expect(visible.visible);
    try std.testing.expect(visible.blink);
    try std.testing.expectEqual(CursorShape.beam, visible.shape);
    try std.testing.expectEqual(@as(f32, 1.5), visible.beam_thickness);
    try std.testing.expectEqual(@as(f32, 2.0), visible.underline_thickness);
    try std.testing.expectEqual(@as(u8, 120), visible.cursor_opacity);
    try std.testing.expectEqual(@as(u8, 45), visible.text_blink_opacity);
    try std.testing.expectEqual(@as(u32, 0x010203), visible.cursor_color.value);
    try std.testing.expectEqual(@as(u32, 9), visible.cursor_text_color.value);
    try std.testing.expectEqual(@as(u16, 2), visible.primary_extent.cols);
    try std.testing.expectEqual(@as(u16, 3), visible.primary_extent.rows);
    try std.testing.expectEqual(@as(u16, 1), visible.extra_cursor_count);
    try std.testing.expectEqual(CursorShape.underline, visible.extra_cursors[0].shape);
    try std.testing.expectEqual(ExtraCursorMode.rectangle, visible.extra_cursors[0].mode);
    try std.testing.expect(visible.extra_cursors[0].shape_follows_main);
    try std.testing.expectEqual(@as(u16, 1), visible.trail.count);
    try std.testing.expectEqual(@as(u8, 10), visible.trail.rects[0].opacity);
}

test "renderable content cursor presentation keeps explicit no-shape" {
    const theme = color.default_theme;
    var cells = [_]source_abi.SourceCell{std.mem.zeroes(source_abi.SourceCell)};
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
        .cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .none, .blink = true, .position_changed_by_client_at_ms = 0, .cell_cols = 1, .cell_rows = 1, .cursor_color = .{ .kind = 0, .value = 0 }, .cursor_text_color = .{ .kind = 0, .value = 0 }, .cursor_opacity = 255, .text_blink_opacity = 255, .focused = true, .effective_shape = .none },
        .extra_cursor_count = 0,
        .extra_cursors = [_]source_abi.SourceExtraCursor{.{}} ** max_extra_cursors,
        .cursor_trail_count = 0,
        .cursor_trail_rects = [_]source_abi.SourceCursorTrailRect{.{}} ** max_cursor_trail_rects,
        .colors = std.mem.zeroes(source_abi.SourceColors),
        .selection = std.mem.zeroes(source_abi.SourceSelection),
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, theme);

    try std.testing.expectEqual(CursorShape.none, visible.shape);
    try std.testing.expect(visible.visible);
}
