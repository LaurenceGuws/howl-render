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

test "render surface layout ABI returns render-owned cell facts and grid" {
    var text: c.HowlRenderTextHandle = null;
    const config = testTextConfig();
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_init(&text, &config));
    defer c.howl_render_text_deinit(text);

    var response = std.mem.zeroes(c.HowlRenderLayoutResponse);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_term_surface_layout(text, .{ .width = 81, .height = 49 }, &response));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, response.status);
    try std.testing.expect(response.cell_layout.cell_px.width > 0);
    try std.testing.expect(response.cell_layout.cell_px.height > 0);
    try std.testing.expect(response.cell_layout.baseline_px < response.cell_layout.cell_px.height);
    try std.testing.expect(response.cell_layout.underline_height_px > 0);
    try std.testing.expect(response.cell_layout.strikethrough_height_px > 0);
    try std.testing.expectEqual(response.cell_layout.cell_px.height + 1, response.cell_layout.sprite_slot_height_px);
    try std.testing.expectEqual(response.grid.cols * response.cell_layout.cell_px.width, response.grid_px.width);
    try std.testing.expectEqual(response.grid.rows * response.cell_layout.cell_px.height, response.grid_px.height);
}

test "render surface point cell ABI returns inside flag and clamped cell" {
    var text: c.HowlRenderTextHandle = null;
    const config = testTextConfig();
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_init(&text, &config));
    defer c.howl_render_text_deinit(text);

    var layout_response = std.mem.zeroes(c.HowlRenderLayoutResponse);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_term_surface_layout(text, .{ .width = 81, .height = 49 }, &layout_response));

    var inside = std.mem.zeroes(c.HowlRenderTermSurfacePointCell);
    const cell_width = layout_response.cell_layout.cell_px.width;
    const cell_height = layout_response.cell_layout.cell_px.height;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_term_surface_point_cell(text, .{ .width = 81, .height = 49 }, .{ .x_px = cell_width, .y_px = cell_height }, &inside));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, inside.status);
    try std.testing.expectEqual(@as(u8, 1), inside.inside);
    try std.testing.expectEqual(@as(u16, 1), inside.col);
    try std.testing.expectEqual(@as(u16, 1), inside.row);

    var leftover = std.mem.zeroes(c.HowlRenderTermSurfacePointCell);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_term_surface_point_cell(text, .{ .width = 81, .height = 49 }, .{ .x_px = layout_response.render_px.width, .y_px = layout_response.render_px.height }, &leftover));
    try std.testing.expectEqual(@as(u8, 0), leftover.inside);
    try std.testing.expectEqual(layout_response.grid.cols - 1, leftover.col);
    try std.testing.expectEqual(layout_response.grid.rows - 1, leftover.row);
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
    const config = testTextConfig();
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_init(&text, &config));
    defer c.howl_render_text_deinit(text);

    var layout_response = std.mem.zeroes(c.HowlRenderLayoutResponse);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_term_surface_layout(text, .{ .width = 64, .height = 32 }, &layout_response));
    try std.testing.expect(layout_response.grid.cols >= 2);

    var upload = std.mem.zeroes(c.HowlRenderTextPreparedUpload);
    var prepare = std.mem.zeroes(c.HowlRenderTextPrepare);
    prepare = .{
        .render_state = render_state,
        .render_px = .{ .width = layout_response.cell_layout.cell_px.width * 2, .height = layout_response.cell_layout.cell_px.height },
        .layout_epoch = 1,
        .now_ns = 0,
        .activity_seq = 0,
        .focused = 1,
        .reserved0 = [_]u8{0} ** 7,
    };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_prepare(text, &prepare, &upload));
    const surface_ptr = upload.term_surface_prepared orelse return error.TestUnexpectedResult;
    const surface = surface_ptr.*;
    try std.testing.expectEqual(@as(u64, 1), upload.snapshot_seq);
    try std.testing.expect(surface.commands.count > 1);

    var has_foreground = false;
    var has_cursor = false;
    var fill_count: u32 = 0;
    for (surface.commands.ptr[0..surface.commands.count]) |command| {
        if (command.kind == c.HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_DRAW_GLYPH_RUN or command.kind == c.HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_DRAW_SPRITE) has_foreground = true;
        if (command.kind == c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT and command.rect.width_px > 0 and command.rect.height_px > 0) {
            has_cursor = true;
            fill_count += 1;
        }
    }
    try std.testing.expect(has_foreground);
    try std.testing.expect(has_cursor);

    var hidden_upload = std.mem.zeroes(c.HowlRenderTextPreparedUpload);
    var hidden_prepare = prepare;
    hidden_prepare.focused = 0;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_prepare(text, &hidden_prepare, &hidden_upload));
    const hidden_surface = (hidden_upload.term_surface_prepared orelse return error.TestUnexpectedResult).*;
    var hidden_has_foreground = false;
    var hidden_fill_count: u32 = 0;
    for (hidden_surface.commands.ptr[0..hidden_surface.commands.count]) |command| {
        if (command.kind == c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_GLYPH_RUN or command.kind == c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE) hidden_has_foreground = true;
        if (command.kind == c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT and command.rect.width_px > 0 and command.rect.height_px > 0) hidden_fill_count += 1;
    }
    try std.testing.expect(hidden_has_foreground);
    try std.testing.expect(hidden_fill_count < fill_count);
}

test "tab bar surface ABI emits glyph frame facts" {
    var text: c.HowlRenderTextHandle = null;
    const config = testTextConfig();
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_init(&text, &config));
    defer c.howl_render_text_deinit(text);

    const cells = [_]c.HowlRenderCellText{
        cellText('A', .{ .r = 240, .g = 240, .b = 240, .a = 255 }, .{ .r = 8, .g = 9, .b = 10, .a = 255 }, 0),
        cellText('B', .{ .r = 200, .g = 210, .b = 220, .a = 255 }, .{ .r = 8, .g = 9, .b = 10, .a = 255 }, c.HOWL_RENDER_FONT_STYLE_BOLD),
    };
    var upload = std.mem.zeroes(c.HowlRenderTabBarSurfacePreparedUpload);
    const prepare = c.HowlRenderTabBarSurfacePrepare{
        .render_px = .{ .width = 16, .height = 16 },
        .grid_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 2, .rows = 1 },
        .layout_epoch = 1,
        .cells = .{ .ptr = cells[0..].ptr, .count = cells.len, .count_max = cells.len },
    };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_tab_bar_surface_prepare(text, &prepare, &upload));
    const surface = (upload.tab_bar_surface_prepared orelse return error.TestUnexpectedResult).*;
    try std.testing.expectEqual(@as(u32, 0), upload.tab_bar_surface_status);
    try std.testing.expectEqual(@as(@TypeOf(surface.prepared_version), c.HOWL_RENDER_TAB_BAR_SURFACE_PREPARED_VERSION), surface.prepared_version);
    try std.testing.expectEqual(@as(u64, 1), upload.snapshot_seq);
    try std.testing.expectEqual(@as(u16, 2), surface.grid.cols);
    try std.testing.expectEqual(@as(u16, 1), surface.grid.rows);

    var has_foreground = false;
    for (surface.commands.ptr[0..surface.commands.count]) |command| {
        if (command.kind == c.HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_DRAW_GLYPH_RUN or command.kind == c.HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_DRAW_SPRITE) has_foreground = true;
    }
    try std.testing.expect(has_foreground);

    var repeated_upload = std.mem.zeroes(c.HowlRenderTabBarSurfacePreparedUpload);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_tab_bar_surface_prepare(text, &prepare, &repeated_upload));
    try std.testing.expectEqual(@as(u64, 2), repeated_upload.snapshot_seq);
}

test "tab bar surface ABI rejects invalid spans" {
    var text: c.HowlRenderTextHandle = null;
    const config = testTextConfig();
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_init(&text, &config));
    defer c.howl_render_text_deinit(text);

    const cells = [_]c.HowlRenderCellText{cellText('A', .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, 0)};
    var upload = std.mem.zeroes(c.HowlRenderTabBarSurfacePreparedUpload);
    var prepare = c.HowlRenderTabBarSurfacePrepare{
        .render_px = .{ .width = 16, .height = 16 },
        .grid_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 2, .rows = 1 },
        .layout_epoch = 1,
        .cells = .{ .ptr = cells[0..].ptr, .count = cells.len, .count_max = cells.len },
    };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, c.howl_render_tab_bar_surface_prepare(text, &prepare, &upload));
    prepare.cells = .{ .ptr = null, .count = 2, .count_max = 2 };
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, c.howl_render_tab_bar_surface_prepare(text, &prepare, &upload));
}

test "tab bar surface ABI rejects invalid cell facts" {
    var text: c.HowlRenderTextHandle = null;
    const config = testTextConfig();
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_init(&text, &config));
    defer c.howl_render_text_deinit(text);

    var upload = std.mem.zeroes(c.HowlRenderTabBarSurfacePreparedUpload);
    var cells = [_]c.HowlRenderCellText{cellText('A', white(), black(), 0)};
    var prepare = tabBarSurfacePrepare(cells[0..]);
    cells[0].combining_len = c.HOWL_RENDER_CELL_TEXT_COMBINING_MAX + 1;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, c.howl_render_tab_bar_surface_prepare(text, &prepare, &upload));
    cells[0] = cellText('A', white(), black(), 0);
    cells[0].combining_len = 1;
    cells[0].combining[0] = std.math.maxInt(u21) + 1;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, c.howl_render_tab_bar_surface_prepare(text, &prepare, &upload));
    cells[0] = cellText('A', white(), black(), 0);
    cells[0].flags = 0x80;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, c.howl_render_tab_bar_surface_prepare(text, &prepare, &upload));
}

test "tab bar surface ABI gives empty cells transparent blank semantics" {
    var text: c.HowlRenderTextHandle = null;
    const config = testTextConfig();
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_text_init(&text, &config));
    defer c.howl_render_text_deinit(text);

    var upload = std.mem.zeroes(c.HowlRenderTabBarSurfacePreparedUpload);
    const cells = [_]c.HowlRenderCellText{emptyCellText()};
    const prepare = tabBarSurfacePrepare(cells[0..]);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, c.howl_render_tab_bar_surface_prepare(text, &prepare, &upload));
    const surface = (upload.tab_bar_surface_prepared orelse return error.TestUnexpectedResult).*;
    for (surface.commands.ptr[0..surface.commands.count]) |command| {
        try std.testing.expect(command.kind != c.HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_DRAW_GLYPH_RUN);
        try std.testing.expect(command.kind != c.HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_DRAW_SPRITE);
    }

    var invalid_empty = [_]c.HowlRenderCellText{emptyCellText()};
    invalid_empty[0].codepoint = 'x';
    const invalid_prepare = tabBarSurfacePrepare(invalid_empty[0..]);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, c.howl_render_tab_bar_surface_prepare(text, &invalid_prepare, &upload));
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

fn testTextConfig() c.HowlRenderTextConfig {
    return .{
        .font_size_px = 16,
        .fallback_font_path_count = 0,
        .reserved0 = 0,
        .primary_font_path = test_font_options.primary_path.ptr,
        .fallback_font_paths = null,
        .cursor_blink_interval_s = 0,
        .cursor_blink_inactivity_s = 0,
        .cursor_trail_delay_s = 0,
        .cursor_trail_decay_fast_s = 0,
        .cursor_trail_decay_slow_s = 0,
        .cursor_trail_start_threshold = 0,
        .reserved1 = 0,
        .cursor_color = .{ .kind = 0, .value = 0 },
        .cursor_text_color = .{ .kind = 0, .value = 0 },
        .cursor_trail_color = .{ .kind = 0, .value = 0 },
        .cursor_beam_thickness = 1.5,
        .cursor_underline_thickness = 2.0,
        .cursor_unfocused_shape = c.HOWL_VT_CURSOR_SHAPE_NONE,
        .reserved2 = [_]u8{0} ** 7,
    };
}

fn emptyCellText() c.HowlRenderCellText {
    var cell = cellText(' ', white(), black(), 0);
    cell.flags = c.HOWL_RENDER_CELL_TEXT_EMPTY;
    return cell;
}

fn tabBarSurfacePrepare(cells: []const c.HowlRenderCellText) c.HowlRenderTabBarSurfacePrepare {
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
