const std = @import("std");
const c = @import("howl_render_c");
const test_font_options = @import("test_font_options");

test {
    std.testing.refAllDecls(@import("libhowl_render.zig"));
}

test "render c enum values remain stable" {
    try std.testing.expectEqual(@as(c_int, 0), c.HOWL_RENDER_CALL_OK);
    try std.testing.expectEqual(@as(c_int, -1), c.HOWL_RENDER_CALL_MISSING_HANDLE);
    try std.testing.expectEqual(@as(c_int, -2), c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
    try std.testing.expectEqual(@as(c_int, -3), c.HOWL_RENDER_CALL_FAILED);
    try std.testing.expectEqual(@as(c_int, 0), c.HOWL_RENDER_DAMAGE_NONE);
    try std.testing.expectEqual(@as(c_int, 1), c.HOWL_RENDER_DAMAGE_PARTIAL);
    try std.testing.expectEqual(@as(c_int, 3), c.HOWL_RENDER_DAMAGE_FULL);
}

test "render text ABI emits foreground commands from VT render state" {
    const terminal = c.howl_vt_terminal_init(1, 2, 16) orelse return error.TestUnexpectedResult;
    defer c.howl_vt_terminal_deinit(terminal);
    const bytes = [_]u8{'A'};
    const feed = c.howl_vt_terminal_feed(terminal, &bytes, bytes.len);
    try std.testing.expectEqual(c.HOWL_VT_CALL_OK, feed.status);

    var render_state: c.HowlVtRenderStateHandle = null;
    try std.testing.expectEqual(c.HOWL_VT_CALL_OK, c.howl_vt_render_state_init(&render_state));
    defer c.howl_vt_render_state_deinit(render_state);
    try std.testing.expectEqual(c.HOWL_VT_CALL_OK, c.howl_vt_render_state_update(render_state, terminal));

    var text: c.HowlRenderTextHandle = null;
    const config = c.HowlRenderTextConfig{
        .font_size_px = 16,
        .fallback_font_path_count = 0,
        .reserved0 = 0,
        .primary_font_path = test_font_options.primary_path.ptr,
        .fallback_font_paths = null,
    };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_init(&text, &config));
    defer c.howl_render_text_deinit(text);

    var upload = std.mem.zeroes(c.HowlRenderTextPreparedUpload);
    var prepare = std.mem.zeroes(c.HowlRenderTextPrepare);
    prepare = .{
        .render_state = render_state,
        .render_px = .{ .width = 16, .height = 16 },
        .grid_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 2, .rows = 1 },
        .layout_epoch = 1,
        .focused = 1,
        .cursor_opacity = 255,
        .text_blink_opacity = 255,
        .effective_shape = c.HOWL_VT_CURSOR_SHAPE_BLOCK,
        .cursor_trail_count = 0,
        .reserved0 = 0,
        .cursor_color = .{ .kind = 0, .value = 0 },
        .cursor_text_color = .{ .kind = 0, .value = 0 },
        .cursor_trail_color = .{ .kind = 0, .value = 0 },
        .cursor_beam_thickness = 1.5,
        .cursor_underline_thickness = 2.0,
        .cursor_trail_rects = [_]c.HowlRenderCursorTrailRect{std.mem.zeroes(c.HowlRenderCursorTrailRect)} ** c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX,
    };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_prepare(text, &prepare, &upload));
    const surface_ptr = upload.surface_frame orelse return error.TestUnexpectedResult;
    const surface = surface_ptr.*;
    try std.testing.expectEqual(@as(u64, 1), upload.snapshot_seq);
    try std.testing.expect(surface.commands.count > 1);

    var has_foreground = false;
    var has_cursor = false;
    var fill_count: u32 = 0;
    for (surface.commands.ptr[0..surface.commands.count]) |command| {
        if (command.kind == c.HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_GLYPH_RUN or command.kind == c.HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_SPRITE) has_foreground = true;
        if (command.kind == c.HOWL_RENDER_SURFACE_FRAME_COMMAND_FILL_RECT and command.rect.width_px > 0 and command.rect.height_px > 0) {
            has_cursor = true;
            fill_count += 1;
        }
    }
    try std.testing.expect(has_foreground);
    try std.testing.expect(has_cursor);

    var hidden_upload = std.mem.zeroes(c.HowlRenderTextPreparedUpload);
    var hidden_prepare = prepare;
    hidden_prepare.cursor_opacity = 0;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_prepare(text, &hidden_prepare, &hidden_upload));
    const hidden_surface = (hidden_upload.surface_frame orelse return error.TestUnexpectedResult).*;
    var hidden_has_foreground = false;
    var hidden_fill_count: u32 = 0;
    for (hidden_surface.commands.ptr[0..hidden_surface.commands.count]) |command| {
        if (command.kind == c.HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_GLYPH_RUN or command.kind == c.HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_SPRITE) hidden_has_foreground = true;
        if (command.kind == c.HOWL_RENDER_SURFACE_FRAME_COMMAND_FILL_RECT and command.rect.width_px > 0 and command.rect.height_px > 0) hidden_fill_count += 1;
    }
    try std.testing.expect(hidden_has_foreground);
    try std.testing.expect(hidden_fill_count < fill_count);

    var trail_upload = std.mem.zeroes(c.HowlRenderTextPreparedUpload);
    var trail_prepare = hidden_prepare;
    trail_prepare.cursor_trail_count = 1;
    trail_prepare.cursor_trail_color = .{ .kind = 2, .value = 0x102030 };
    trail_prepare.cursor_trail_rects[0] = .{
        .row = 0,
        .col = 0,
        .rows = 1,
        .cols = 1,
        .opacity = 128,
        .pixel_rect = 1,
        .reserved0 = 0,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .x_px = 3,
        .y_px = 4,
        .width_px = 5,
        .height_px = 6,
    };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_prepare(text, &trail_prepare, &trail_upload));
    const trail_surface = (trail_upload.surface_frame orelse return error.TestUnexpectedResult).*;
    var saw_trail = false;
    for (trail_surface.commands.ptr[0..trail_surface.commands.count]) |command| {
        if (command.kind != c.HOWL_RENDER_SURFACE_FRAME_COMMAND_FILL_RECT) continue;
        if (command.rect.x_px != 3) continue;
        if (command.rect.y_px != 4) continue;
        if (command.rect.width_px != 5) continue;
        if (command.rect.height_px != 6) continue;
        saw_trail = true;
    }
    try std.testing.expect(saw_trail);
}

test "cell surface ABI emits glyph frame facts" {
    var text: c.HowlRenderTextHandle = null;
    const config = c.HowlRenderTextConfig{
        .font_size_px = 16,
        .fallback_font_path_count = 0,
        .reserved0 = 0,
        .primary_font_path = test_font_options.primary_path.ptr,
        .fallback_font_paths = null,
    };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_init(&text, &config));
    defer c.howl_render_text_deinit(text);

    const cells = [_]c.HowlRenderCellText{
        cellText('A', .{ .r = 240, .g = 240, .b = 240, .a = 255 }, .{ .r = 8, .g = 9, .b = 10, .a = 255 }, 0),
        cellText('B', .{ .r = 200, .g = 210, .b = 220, .a = 255 }, .{ .r = 8, .g = 9, .b = 10, .a = 255 }, c.HOWL_RENDER_FONT_STYLE_BOLD),
    };
    var upload = std.mem.zeroes(c.HowlRenderCellSurfacePreparedUpload);
    const prepare = c.HowlRenderCellSurfacePrepare{
        .render_px = .{ .width = 16, .height = 16 },
        .grid_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 2, .rows = 1 },
        .layout_epoch = 1,
        .cells = .{ .ptr = cells[0..].ptr, .count = cells.len, .count_max = cells.len },
    };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_cell_surface_prepare(text, &prepare, &upload));
    const surface = (upload.surface_frame orelse return error.TestUnexpectedResult).*;
    try std.testing.expectEqual(@as(u64, 1), upload.snapshot_seq);
    try std.testing.expectEqual(@as(u16, 2), surface.grid.cols);
    try std.testing.expectEqual(@as(u16, 1), surface.grid.rows);

    var has_foreground = false;
    for (surface.commands.ptr[0..surface.commands.count]) |command| {
        if (command.kind == c.HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_GLYPH_RUN or command.kind == c.HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_SPRITE) has_foreground = true;
    }
    try std.testing.expect(has_foreground);

    var repeated_upload = std.mem.zeroes(c.HowlRenderCellSurfacePreparedUpload);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_cell_surface_prepare(text, &prepare, &repeated_upload));
    try std.testing.expectEqual(@as(u64, 2), repeated_upload.snapshot_seq);
}

test "cell surface ABI rejects invalid spans" {
    var text: c.HowlRenderTextHandle = null;
    const config = c.HowlRenderTextConfig{
        .font_size_px = 16,
        .fallback_font_path_count = 0,
        .reserved0 = 0,
        .primary_font_path = test_font_options.primary_path.ptr,
        .fallback_font_paths = null,
    };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_init(&text, &config));
    defer c.howl_render_text_deinit(text);

    const cells = [_]c.HowlRenderCellText{cellText('A', .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, 0)};
    var upload = std.mem.zeroes(c.HowlRenderCellSurfacePreparedUpload);
    var prepare = c.HowlRenderCellSurfacePrepare{
        .render_px = .{ .width = 16, .height = 16 },
        .grid_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 2, .rows = 1 },
        .layout_epoch = 1,
        .cells = .{ .ptr = cells[0..].ptr, .count = cells.len, .count_max = cells.len },
    };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, c.howl_render_cell_surface_prepare(text, &prepare, &upload));
    prepare.cells = .{ .ptr = null, .count = 2, .count_max = 2 };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, c.howl_render_cell_surface_prepare(text, &prepare, &upload));
}

test "cell surface ABI rejects invalid cell facts" {
    var text: c.HowlRenderTextHandle = null;
    const config = c.HowlRenderTextConfig{
        .font_size_px = 16,
        .fallback_font_path_count = 0,
        .reserved0 = 0,
        .primary_font_path = test_font_options.primary_path.ptr,
        .fallback_font_paths = null,
    };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_init(&text, &config));
    defer c.howl_render_text_deinit(text);

    var upload = std.mem.zeroes(c.HowlRenderCellSurfacePreparedUpload);
    var cells = [_]c.HowlRenderCellText{cellText('A', white(), black(), 0)};
    var prepare = cellSurfacePrepare(cells[0..]);
    cells[0].combining_len = c.HOWL_RENDER_CELL_TEXT_COMBINING_MAX + 1;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, c.howl_render_cell_surface_prepare(text, &prepare, &upload));
    cells[0] = cellText('A', white(), black(), 0);
    cells[0].combining_len = 1;
    cells[0].combining[0] = std.math.maxInt(u21) + 1;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, c.howl_render_cell_surface_prepare(text, &prepare, &upload));
    cells[0] = cellText('A', white(), black(), 0);
    cells[0].flags = 0x80;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, c.howl_render_cell_surface_prepare(text, &prepare, &upload));
}

test "cell surface ABI gives empty cells transparent blank semantics" {
    var text: c.HowlRenderTextHandle = null;
    const config = c.HowlRenderTextConfig{
        .font_size_px = 16,
        .fallback_font_path_count = 0,
        .reserved0 = 0,
        .primary_font_path = test_font_options.primary_path.ptr,
        .fallback_font_paths = null,
    };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_init(&text, &config));
    defer c.howl_render_text_deinit(text);

    var upload = std.mem.zeroes(c.HowlRenderCellSurfacePreparedUpload);
    const cells = [_]c.HowlRenderCellText{emptyCellText()};
    const prepare = cellSurfacePrepare(cells[0..]);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_cell_surface_prepare(text, &prepare, &upload));
    const surface = (upload.surface_frame orelse return error.TestUnexpectedResult).*;
    for (surface.commands.ptr[0..surface.commands.count]) |command| {
        try std.testing.expect(command.kind != c.HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_GLYPH_RUN);
        try std.testing.expect(command.kind != c.HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_SPRITE);
    }

    var invalid_empty = [_]c.HowlRenderCellText{emptyCellText()};
    invalid_empty[0].codepoint = 'x';
    const invalid_prepare = cellSurfacePrepare(invalid_empty[0..]);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, c.howl_render_cell_surface_prepare(text, &invalid_prepare, &upload));
}

fn cellText(codepoint: u32, foreground: c.HowlRenderRgba8, background: c.HowlRenderRgba8, style: u8) c.HowlRenderCellText {
    return .{
        .codepoint = codepoint,
        .combining = .{ 0, 0, 0 },
        .combining_len = 0,
        .style = style,
        .presentation = c.HOWL_RENDER_TEXT_PRESENTATION_ANY,
        .flags = 0,
        .foreground = foreground,
        .background = background,
        .underline_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .underline_style = 0,
        .reserved0 = 0,
        .reserved1 = 0,
    };
}

fn emptyCellText() c.HowlRenderCellText {
    var cell = cellText(' ', white(), black(), 0);
    cell.flags = c.HOWL_RENDER_CELL_TEXT_EMPTY;
    return cell;
}

fn cellSurfacePrepare(cells: []const c.HowlRenderCellText) c.HowlRenderCellSurfacePrepare {
    return .{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = @intCast(cells.len), .rows = 1 },
        .layout_epoch = 1,
        .cells = .{ .ptr = cells.ptr, .count = @intCast(cells.len), .count_max = @intCast(cells.len) },
    };
}

fn white() c.HowlRenderRgba8 {
    return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
}

fn black() c.HowlRenderRgba8 {
    return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
}
