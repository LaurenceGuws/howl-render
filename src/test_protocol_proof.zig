const std = @import("std");

const prepared_buffer = @import("prepared/buffer.zig");
const prepared_surface = @import("prepared/surface.zig");
const protocol_emit = @import("protocol_v0/emit.zig");
const protocol_realize = @import("protocol_v0/realize.zig");
const contract = @import("text/contract.zig");
const text = @import("text/text.zig");
const text_session = @import("session/text.zig");

test "protocol v0 prepared proof target imports owner oracle" {
    _ = prepared_buffer.compose;
    _ = text_session.TextSession;
    _ = protocol_emit.Emitter;
}

test "protocol v0 emitter realizes prepared fill frame equal to full rgba oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const clear = [_]contract.TextClearDraw{clearDraw(0, 0, 2, 1, rgba(0, 0, 0, 255))};
    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(255, 0, 0, 255)),
    };
    const decoration = [_]contract.TextDecorationDraw{
        decorationDraw(1, 0, 1, 1, rgba(0, 255, 0, 255)),
    };
    const cursor = [_]contract.TextCursorDraw{
        cursorDraw(0, 0, 2, 1, rgba(0, 0, 255, 128)),
    };
    var prepared = preparedSurface(.{
        .clear_draws = &clear,
        .background_draws = &background,
        .decoration_draws = &decoration,
        .cursor_draws = &cursor,
        .width_px = 2,
        .height_px = 1,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "protocol v0 emitter realizes prepared alpha sprite frame equal to full rgba oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{ 255, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(11, 0, 0, 2, 1, rgba(255, 0, 0, 128)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        11,
        2,
        1,
        .alpha,
        &sprite_bytes,
        .{},
    )};
    var prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 2,
        .height_px = 1,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "protocol v0 emitter realizes prepared color sprite frame equal to full rgba oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{ 0, 255, 0, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(12, 0, 0, 1, 1, rgba(255, 0, 0, 255)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        12,
        1,
        1,
        .color,
        &sprite_bytes,
        .{},
    )};
    var prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 1,
        .height_px = 1,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "protocol v0 emitter realizes prepared sprite visual bounds equal to full rgba oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{
        0, 200, 0,
        0, 100, 0,
    };
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(13, 0, 0, 3, 2, rgba(0, 0, 255, 255)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        13,
        3,
        2,
        .alpha,
        &sprite_bytes,
        .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 2 },
    )};
    var prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 3,
        .height_px = 2,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "protocol v0 emitter rejects missing prepared sprite without mutating accepted frame" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(255, 0, 0, 255)),
    };
    var accepted_prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 1,
        .height_px = 1,
    });
    var missing_sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(99, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var missing_prepared = preparedSurface(.{
        .sprite_draws = &missing_sprite_draws,
        .width_px = 1,
        .height_px = 1,
    });

    var emitter = protocol_emit.Emitter(.{}).init();
    const accepted_frame = try emitter.emitPrepared(&session, &accepted_prepared);
    try std.testing.expectError(
        error.MissingPreparedSprite,
        emitter.emitPrepared(&session, &missing_prepared),
    );
    try std.testing.expectEqual(accepted_frame, emitter.frame());

    const oracle = try prepared_buffer.compose(allocator, null, &session, &accepted_prepared);
    defer allocator.free(oracle);
    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try protocol_realize.realize(emitter.frame(), realized, null);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "protocol v0 emitter realizes partial prepared frame equal to full rgba oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var base = [_]u8{
        1, 2, 3, 255,
        4, 5, 6, 255,
    };
    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(9, 8, 7, 255)),
    };
    var prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 2,
        .height_px = 1,
        .full_redraw = false,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, &base);
}

fn expectPreparedEmissionEqualsCompose(
    allocator: std.mem.Allocator,
    session: *text_session.TextSession,
    prepared: *const prepared_surface.PreparedSurface,
    base_pixels: ?[]const u8,
) !void {
    const oracle = try prepared_buffer.compose(allocator, base_pixels, session, prepared);
    defer allocator.free(oracle);
    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    var emitter = protocol_emit.Emitter(.{}).init();
    const frame = try emitter.emitPrepared(session, prepared);
    try protocol_realize.realize(frame, realized, base_pixels);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

const PreparedOptions = struct {
    clear_draws: []const contract.TextClearDraw = &.{},
    background_draws: []const contract.TextBackgroundDraw = &.{},
    sprite_draws: []const contract.TextSpriteDraw = &.{},
    decoration_draws: []const contract.TextDecorationDraw = &.{},
    cursor_draws: []const contract.TextCursorDraw = &.{},
    raster_outputs: []text.Rasterizer.RasterSpriteOutput = &.{},
    width_px: u16,
    height_px: u16,
    full_redraw: bool = true,
};

fn preparedSurface(options: PreparedOptions) prepared_surface.PreparedSurface {
    return .{
        .allocator = std.testing.allocator,
        .request = .{
            .token = .{
                .snapshot_seq = 1,
                .dirty_epoch = 1,
                .geometry_epoch = 1,
                .damage_base_seq = if (options.full_redraw) 0 else 1,
                .damage_kind = if (options.full_redraw) .full else .partial,
            },
        },
        .geometry_epoch = 1,
        .render_px = .{ .width = options.width_px, .height = options.height_px },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = options.width_px, .rows = options.height_px },
        .text_frame = .{
            .scene = .{
                .allocator = std.testing.allocator,
                .owned = false,
                .scene = .{
                    .clear_draws = options.clear_draws,
                    .background_draws = options.background_draws,
                    .sprite_draws = options.sprite_draws,
                    .decoration_draws = options.decoration_draws,
                    .cursor_draws = options.cursor_draws,
                    .raster_requests = &.{},
                    .missing = &.{},
                    .full_redraw = options.full_redraw,
                },
            },
            .raster_plan = .{
                .allocator = std.testing.allocator,
                .outputs = options.raster_outputs,
                .owned = false,
            },
        },
    };
}

fn rasterOutput(
    allocator: std.mem.Allocator,
    key: u64,
    width_px: u16,
    height_px: u16,
    color_mode: contract.SpriteColorMode,
    pixels: []u8,
    visual_bounds: text.Rasterizer.SpriteBounds,
) text.Rasterizer.RasterSpriteOutput {
    return .{
        .allocator = allocator,
        .key = .{ .value = key },
        .width_px = width_px,
        .height_px = height_px,
        .color_mode = color_mode,
        .visual_bounds = visual_bounds,
        .pixels = pixels,
    };
}

fn clearDraw(
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: contract.Rgba8,
) contract.TextClearDraw {
    return .{
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .color = color,
        .first_cell = 0,
        .cell_span = 1,
    };
}

fn backgroundDraw(
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: contract.Rgba8,
) contract.TextBackgroundDraw {
    return .{
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .color = color,
        .first_cell = 0,
        .cell_span = 1,
    };
}

fn decorationDraw(
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: contract.Rgba8,
) contract.TextDecorationDraw {
    return .{
        .kind = .underline,
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .color = color,
        .first_cell = 0,
        .cell_span = 1,
    };
}

fn cursorDraw(
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: contract.Rgba8,
) contract.TextCursorDraw {
    return .{ .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color };
}

fn spriteDraw(
    key: u64,
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: contract.Rgba8,
) contract.TextSpriteDraw {
    return .{
        .sprite = .{ .slot = 0, .key = .{ .value = key } },
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .color = color,
        .first_cell = 0,
        .cell_span = 1,
    };
}

fn rgba(r: u8, g: u8, b: u8, a: u8) contract.Rgba8 {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
