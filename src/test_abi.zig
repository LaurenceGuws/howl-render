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
        if (command.kind == c.HOWL_RENDER_SURFACE_FRAME_COMMAND_FILL_RECT and command.rect.x_px == 3 and command.rect.y_px == 4 and command.rect.width_px == 5 and command.rect.height_px == 6) saw_trail = true;
    }
    try std.testing.expect(saw_trail);
}
