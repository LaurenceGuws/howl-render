const std = @import("std");

const c = @import("../../ffi.zig").c;
const ffi_prepared_surface = @import("../../ffi/prepared_surface.zig");
const prepared_buffer = @import("../../prepared/buffer.zig");
const prepared_owner = @import("../../prepared/owner.zig");
const prepared_surface = @import("../../prepared/surface.zig");
const render_surface_emitter = @import("../../prepared/render_surface_emitter.zig");
const render_surface_realizer = @import("../../render/render_surface_realizer.zig");
const contract = @import("../../text/contract.zig");
const text = @import("../../text/text.zig");
const text_session = @import("../../session/text.zig");

test "render surface prepared proof target imports owner oracle" {
    _ = prepared_buffer.compose;
    _ = text_session.TextSession;
    _ = render_surface_emitter.Emitter;
}

test "render surface surface emitter realizes prepared fill surface equal to full rgba oracle" {
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
    const prepared = preparedSurface(.{
        .clear_draws = &clear,
        .background_draws = &background,
        .decoration_draws = &decoration,
        .cursor_draws = &cursor,
        .width_px = 2,
        .height_px = 1,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter coalesces adjacent prepared fill commands" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const color = rgba(10, 20, 30, 255);
    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, color),
        backgroundDraw(1, 0, 2, 1, color),
        backgroundDraw(3, 0, 1, 1, color),
    };
    const prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 4,
        .height_px = 1,
    });

    const Emitter = render_surface_emitter.Emitter(.{});
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 1), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[0].kind);
    try std.testing.expectEqual(@as(i32, 0), surface.commands.ptr[0].rect.x_px);
    try std.testing.expectEqual(@as(i32, 0), surface.commands.ptr[0].rect.y_px);
    try std.testing.expectEqual(@as(u16, 4), surface.commands.ptr[0].rect.width_px);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[0].rect.height_px);
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter does not coalesce distinct prepared fills" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255)),
        backgroundDraw(1, 0, 1, 1, rgba(4, 5, 6, 255)),
        backgroundDraw(3, 0, 1, 1, rgba(4, 5, 6, 255)),
        backgroundDraw(4, 1, 1, 1, rgba(4, 5, 6, 255)),
    };
    const decoration = [_]contract.TextDecorationDraw{
        decorationDraw(0, 0, 1, 1, rgba(4, 5, 6, 255)),
    };
    const prepared = preparedSurface(.{
        .background_draws = &background,
        .decoration_draws = &decoration,
        .width_px = 5,
        .height_px = 2,
    });

    const Emitter = render_surface_emitter.Emitter(.{});
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 5), surface.commands.count);
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter realizes prepared alpha sprite surface equal to full rgba oracle" {
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
    const prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 2,
        .height_px = 1,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter batches prepared alpha sprite glyph commands" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{255};
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(111, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
        spriteDraw(111, 1, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        111,
        1,
        1,
        .alpha,
        &sprite_bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 2,
        .height_px = 1,
    });

    const Emitter = render_surface_emitter.Emitter(.{ .commands_max = 1, .glyph_refs_max = 2 });
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 1), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, surface.commands.ptr[0].kind);
    try std.testing.expectEqual(@as(u32, 2), surface.commands.ptr[0].glyphs.count);
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter emits over command bound alpha draws with batched glyph runs" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const draws_len: usize = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    const sprite_draws = try allocator.alloc(contract.TextSpriteDraw, draws_len);
    defer allocator.free(sprite_draws);
    for (sprite_draws, 0..) |*draw, index| {
        draw.* = spriteDraw(112, @intCast(index), 0, 1, 1, rgba(255, 255, 255, 255));
    }
    var sprite_bytes = [_]u8{255};
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        112,
        1,
        1,
        .alpha,
        &sprite_bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 1,
        .height_px = 1,
    });

    const glyphs_max: u32 = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    const Emitter = render_surface_emitter.Emitter(.{});
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    const commands_expected = std.math.divCeil(
        u32,
        glyphs_max,
        c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
    ) catch unreachable;
    try std.testing.expectEqual(commands_expected, surface.commands.count);
    try std.testing.expect(surface.commands.count < c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, surface.commands.ptr[0].kind);
    try std.testing.expectEqual(
        @as(u32, c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX),
        surface.commands.ptr[0].glyphs.count,
    );
    try std.testing.expectEqual(@as(u32, 1), surface.uploads.count);
}

test "render surface surface emitter preserves command overflow after batched glyph runs" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const draws_len: usize = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX + 1;
    const sprite_draws = try allocator.alloc(contract.TextSpriteDraw, draws_len);
    defer allocator.free(sprite_draws);
    for (sprite_draws, 0..) |*draw, index| {
        draw.* = spriteDraw(113, @intCast(index), 0, 1, 1, rgba(255, 255, 255, 255));
    }
    var sprite_bytes = [_]u8{255};
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        113,
        1,
        1,
        .alpha,
        &sprite_bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 1,
        .height_px = 1,
    });

    const Emitter = render_surface_emitter.Emitter(.{ .commands_max = 1, .glyph_refs_max = draws_len });
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    try std.testing.expectError(
        error.CommandBoundOverflow,
        emitter.emitPrepared(&resources, &session, &prepared),
    );
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().commands.count);
    try std.testing.expectEqual(@as(u32, 0), resources.atlas_count);
}

test "render surface surface emitter emits more than old alpha atlas entry cap" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const Emitter = render_surface_emitter.Emitter(.{});
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    var index: u32 = 0;
    while (index <= render_surface_emitter.persistent_sprite_resources_max) : (index += 1) {
        var sprite_bytes = [_]u8{@intCast((index % 251) + 1)};
        var sprite_draws = [_]contract.TextSpriteDraw{
            spriteDraw(10_000 + index, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
        };
        var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
            allocator,
            10_000 + index,
            1,
            1,
            .alpha,
            &sprite_bytes,
            .{},
        )};
        const prepared = preparedSurface(.{
            .sprite_draws = &sprite_draws,
            .raster_outputs = &raster_outputs,
            .width_px = 1,
            .height_px = 1,
        });

        const surface = try emitter.emitPrepared(&resources, &session, &prepared);
        try std.testing.expectEqual(@as(u32, 1), surface.uploads.count);
        try std.testing.expectEqual(@as(u32, 1), surface.commands.count);
        try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, surface.commands.ptr[0].kind);
    }
    try std.testing.expectEqual(render_surface_emitter.persistent_sprite_resources_max + 1, resources.atlas_count);
}

test "render surface surface emitter realizes prepared color sprite surface equal to full rgba oracle" {
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
    const prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 1,
        .height_px = 1,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter realizes sprite visual bounds like oracle" {
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
    const prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 3,
        .height_px = 2,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter persists prepared sprite resource across surfaces" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{ 255, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(31, 0, 0, 2, 1, rgba(255, 0, 0, 128)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        31,
        2,
        1,
        .alpha,
        &sprite_bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 2,
        .height_px = 1,
    });

    const Emitter = render_surface_emitter.Emitter(.{});
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    const surface1 = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(@as(u32, 1), surface1.creates.count);
    try std.testing.expectEqual(@as(u32, 1), surface1.uploads.count);
    try std.testing.expectEqual(@as(u32, 1), surface1.commands.count);
    try std.testing.expectEqual(@as(u32, 0), surface1.retires.count);
    const resource = surface1.commands.ptr[0].glyphs.ptr[0].atlas_resource;
    try std.testing.expect(resource.value != 0);
    try std.testing.expectEqual(@as(u32, 1), resource.generation);

    const retained = try allocator.create(render_surface_realizer.ResourceStore);
    defer allocator.destroy(retained);
    retained.count = 0;
    retained.bytes_count = 0;
    const oracle = try prepared_buffer.compose(allocator, null, &session, &prepared);
    defer allocator.free(oracle);
    const realized1 = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized1);
    try render_surface_realizer.realizeRetained(surface1, realized1, null, retained);
    try std.testing.expectEqualSlices(u8, oracle, realized1);

    const surface2 = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(@as(u32, 0), surface2.creates.count);
    try std.testing.expectEqual(@as(u32, 0), surface2.uploads.count);
    try std.testing.expectEqual(@as(u32, 1), surface2.commands.count);
    try std.testing.expectEqual(@as(u32, 0), surface2.retires.count);
    try std.testing.expectEqual(resource.value, surface2.commands.ptr[0].glyphs.ptr[0].atlas_resource.value);
    try std.testing.expectEqual(resource.generation, surface2.commands.ptr[0].glyphs.ptr[0].atlas_resource.generation);
    const realized2 = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized2);
    try render_surface_realizer.realizeRetained(surface2, realized2, null, retained);
    try std.testing.expectEqualSlices(u8, oracle, realized2);
}

test "render surface surface emitter allocates distinct monotonic sprite resources" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var first_bytes = [_]u8{255};
    var first_draws = [_]contract.TextSpriteDraw{
        spriteDraw(41, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var first_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        41,
        1,
        1,
        .alpha,
        &first_bytes,
        .{},
    )};
    var second_bytes = [_]u8{128};
    var second_draws = [_]contract.TextSpriteDraw{
        spriteDraw(42, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var second_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        42,
        1,
        1,
        .alpha,
        &second_bytes,
        .{},
    )};
    const first = preparedSurface(.{
        .sprite_draws = &first_draws,
        .raster_outputs = &first_outputs,
        .width_px = 1,
        .height_px = 1,
    });
    const second = preparedSurface(.{
        .sprite_draws = &second_draws,
        .raster_outputs = &second_outputs,
        .width_px = 1,
        .height_px = 1,
    });

    const Emitter = render_surface_emitter.Emitter(.{});
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    const surface1 = try emitter.emitPrepared(&resources, &session, &first);
    const first_resource = surface1.commands.ptr[0].glyphs.ptr[0].atlas_resource;
    const surface2 = try emitter.emitPrepared(&resources, &session, &second);
    const second_resource = surface2.commands.ptr[0].glyphs.ptr[0].atlas_resource;
    try std.testing.expectEqual(@as(u64, 1), first_resource.value);
    try std.testing.expectEqual(first_resource.value, second_resource.value);
    try std.testing.expectEqual(@as(u32, 1), second_resource.generation);
}

test "render surface surface emitter allocates distinct resource for changed sprite bytes" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var first_bytes = [_]u8{255};
    var first_draws = [_]contract.TextSpriteDraw{
        spriteDraw(43, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var first_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        43,
        1,
        1,
        .alpha,
        &first_bytes,
        .{},
    )};
    var second_bytes = [_]u8{128};
    var second_draws = [_]contract.TextSpriteDraw{
        spriteDraw(43, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var second_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        43,
        1,
        1,
        .alpha,
        &second_bytes,
        .{},
    )};
    const first = preparedSurface(.{
        .sprite_draws = &first_draws,
        .raster_outputs = &first_outputs,
        .width_px = 1,
        .height_px = 1,
    });
    const second = preparedSurface(.{
        .sprite_draws = &second_draws,
        .raster_outputs = &second_outputs,
        .width_px = 1,
        .height_px = 1,
    });

    const Emitter = render_surface_emitter.Emitter(.{});
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    const surface1 = try emitter.emitPrepared(&resources, &session, &first);
    const first_resource = surface1.commands.ptr[0].glyphs.ptr[0].atlas_resource;
    const surface2 = try emitter.emitPrepared(&resources, &session, &second);
    const second_resource = surface2.commands.ptr[0].glyphs.ptr[0].atlas_resource;
    try std.testing.expectEqual(@as(u64, 1), first_resource.value);
    try std.testing.expectEqual(first_resource.value, second_resource.value);
    try std.testing.expectEqual(@as(u32, 1), first_resource.generation);
    try std.testing.expectEqual(@as(u32, 1), second_resource.generation);
    try std.testing.expectEqual(@as(u32, 0), surface1.retires.count);
    try std.testing.expectEqual(@as(u32, 0), surface2.retires.count);
}

test "render surface surface emitter allocates distinct resource for changed sprite dimensions" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var first_bytes = [_]u8{255};
    var first_draws = [_]contract.TextSpriteDraw{
        spriteDraw(44, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var first_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        44,
        1,
        1,
        .alpha,
        &first_bytes,
        .{},
    )};
    var second_bytes = [_]u8{ 255, 128 };
    var second_draws = [_]contract.TextSpriteDraw{
        spriteDraw(44, 0, 0, 2, 1, rgba(255, 255, 255, 255)),
    };
    var second_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        44,
        2,
        1,
        .alpha,
        &second_bytes,
        .{},
    )};
    const first = preparedSurface(.{
        .sprite_draws = &first_draws,
        .raster_outputs = &first_outputs,
        .width_px = 2,
        .height_px = 1,
    });
    const second = preparedSurface(.{
        .sprite_draws = &second_draws,
        .raster_outputs = &second_outputs,
        .width_px = 2,
        .height_px = 1,
    });

    const Emitter = render_surface_emitter.Emitter(.{});
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    const surface1 = try emitter.emitPrepared(&resources, &session, &first);
    const first_resource = surface1.commands.ptr[0].glyphs.ptr[0].atlas_resource;
    const surface2 = try emitter.emitPrepared(&resources, &session, &second);
    const second_resource = surface2.commands.ptr[0].glyphs.ptr[0].atlas_resource;
    try std.testing.expectEqual(@as(u64, 1), first_resource.value);
    try std.testing.expectEqual(first_resource.value, second_resource.value);
    try std.testing.expectEqual(@as(u32, 1), first_resource.generation);
    try std.testing.expectEqual(@as(u32, 1), second_resource.generation);
    try std.testing.expectEqual(@as(u32, 0), surface1.retires.count);
    try std.testing.expectEqual(@as(u32, 0), surface2.retires.count);
}

test "render surface surface emitter failure preserves accepted persistent resource state" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var bytes = [_]u8{ 255, 255 };
    var draws = [_]contract.TextSpriteDraw{
        spriteDraw(51, 0, 0, 2, 1, rgba(255, 255, 255, 255)),
    };
    var outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        51,
        2,
        1,
        .alpha,
        &bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &draws,
        .raster_outputs = &outputs,
        .width_px = 2,
        .height_px = 1,
    });

    var emitter = render_surface_emitter.Emitter(.{
        .commands_max = 1,
        .glyph_refs_max = 1,
        .upload_bytes_max = 1,
    }).init();
    var resources = render_surface_emitter.SpriteResourceStore.init();
    try std.testing.expectError(
        error.UploadBytesOverflow,
        emitter.emitPrepared(&resources, &session, &prepared),
    );
    try std.testing.expectEqual(@as(u32, 0), resources.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().creates.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().commands.count);
}

test "render surface surface emitter resource id exhaustion preserves accepted state" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var bytes = [_]u8{ 255, 255, 255, 255 };
    var draws = [_]contract.TextSpriteDraw{
        spriteDraw(61, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        61,
        1,
        1,
        .color,
        &bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &draws,
        .raster_outputs = &outputs,
        .width_px = 1,
        .height_px = 1,
    });

    const Emitter = render_surface_emitter.Emitter(.{});
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    resources.value_next = 0;
    try std.testing.expectError(
        error.ResourceBoundOverflow,
        emitter.emitPrepared(&resources, &session, &prepared),
    );
    try std.testing.expectEqual(@as(u32, 0), resources.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().creates.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().commands.count);
}

test "render surface surface emitter emits transient sprite beyond persistent budget" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var bytes = [_]u8{ 255, 255, 255, 255 };
    var draws = [_]contract.TextSpriteDraw{
        spriteDraw(62, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        62,
        1,
        1,
        .color,
        &bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &draws,
        .raster_outputs = &outputs,
        .width_px = 1,
        .height_px = 1,
    });

    const Emitter = render_surface_emitter.Emitter(.{});
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    resources.fillForTest(render_surface_emitter.persistent_sprite_resources_max);
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(render_surface_emitter.persistent_sprite_resources_max, resources.count);
    try std.testing.expectEqual(@as(u32, 1), surface.creates.count);
    try std.testing.expectEqual(@as(u32, 1), surface.uploads.count);
    try std.testing.expectEqual(@as(u32, 1), surface.commands.count);
    try std.testing.expectEqual(@as(u32, 1), surface.retires.count);
    try std.testing.expectEqual(surface.commands.ptr[0].resource.value, surface.retires.ptr[0].resource.value);
    try std.testing.expectEqual(@as(u64, 1), surface.retires.ptr[0].retire_seq);
}

test "render surface surface emitter reports exact transient retire bound" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var first_bytes = [_]u8{ 255, 255, 255, 255 };
    var second_bytes = [_]u8{ 128, 128, 128, 255 };
    var draws = [_]contract.TextSpriteDraw{
        spriteDraw(63, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
        spriteDraw(64, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var outputs = [_]text.Rasterizer.RasterSpriteOutput{
        rasterOutput(allocator, 63, 1, 1, .color, &first_bytes, .{}),
        rasterOutput(allocator, 64, 1, 1, .color, &second_bytes, .{}),
    };
    const prepared = preparedSurface(.{
        .sprite_draws = &draws,
        .raster_outputs = &outputs,
        .width_px = 1,
        .height_px = 1,
    });

    var emitter = render_surface_emitter.Emitter(.{
        .commands_max = 2,
        .glyph_refs_max = 2,
        .retires_max = 1,
    }).init();
    var resources = render_surface_emitter.SpriteResourceStore.init();
    resources.fillForTest(render_surface_emitter.persistent_sprite_resources_max);
    try std.testing.expectError(
        error.RetireBoundOverflow,
        emitter.emitPrepared(&resources, &session, &prepared),
    );
    try std.testing.expectEqual(render_surface_emitter.persistent_sprite_resources_max, resources.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().commands.count);
}

test "render surface surface emitter rejects missing prepared sprite without mutating accepted surface" {
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

    const Emitter = render_surface_emitter.Emitter(.{});
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    const accepted_surface = try emitter.emitPrepared(&resources, &session, &accepted_prepared);
    try std.testing.expectError(
        error.MissingPreparedSprite,
        emitter.emitPrepared(&resources, &session, &missing_prepared),
    );
    try std.testing.expectEqual(accepted_surface, emitter.surface());

    const oracle = try prepared_buffer.compose(allocator, null, &session, &accepted_prepared);
    defer allocator.free(oracle);
    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try render_surface_realizer.realize(emitter.surface(), realized, null);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "render surface surface emitter realizes partial prepared surface equal to full rgba oracle" {
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
    const prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 2,
        .height_px = 1,
        .full_redraw = false,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, &base);
}

test "render surface prepared owner surface equals explicit rgba oracle" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(
        allocator,
        .{ .surface_px = .{ .width = 2, .height = 1 } },
    ) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    var sprite_bytes = [_]u8{ 255, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(21, 0, 0, 2, 1, rgba(255, 0, 0, 128)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        21,
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

    const oracle = try prepared_buffer.compose(allocator, null, &session_owner.session, &prepared);
    defer allocator.free(oracle);
    const owner = try prepared_owner.Owner.create(session_owner, &prepared);
    const surface = owner.renderSurfaceForTest();
    try std.testing.expectEqual(@as(u32, 1), surface.uploads.count);
    try std.testing.expect(surface.uploads.ptr[0].bytes_ptr != null);
    const upload_bytes_ptr = surface.uploads.ptr[0].bytes_ptr;

    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try render_surface_realizer.realize(surface, realized, null);
    try std.testing.expectEqual(
        upload_bytes_ptr,
        owner.renderSurfaceForTest().uploads.ptr[0].bytes_ptr,
    );
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "render surface prepared ffi borrowed surface realizes explicit rgba oracle" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(
        allocator,
        .{ .surface_px = .{ .width = 2, .height = 1 } },
    ) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 2, 1, rgba(1, 2, 3, 255)),
    };
    var prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 2,
        .height_px = 1,
    });
    const oracle = try prepared_buffer.compose(allocator, null, &session_owner.session, &prepared);
    defer allocator.free(oracle);
    const owner = try prepared_owner.Owner.create(session_owner, &prepared);

    var surface: ?*const c.HowlRenderSurface = null;
    try std.testing.expectEqual(
        c.HOWL_RENDER_CALL_OK,
        ffi_prepared_surface.renderSurface(@ptrCast(owner), &surface),
    );
    const value = surface orelse return error.MissingSurface;

    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try render_surface_realizer.realize(value, realized, null);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "render surface prepared owner partial surface equals explicit base rgba oracle" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(
        allocator,
        .{ .surface_px = .{ .width = 2, .height = 1 } },
    ) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const base = [_]u8{
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

    const oracle = try prepared_buffer.compose(allocator, &base, &session_owner.session, &prepared);
    defer allocator.free(oracle);
    const owner = try prepared_owner.Owner.create(session_owner, &prepared);
    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try render_surface_realizer.realize(
        owner.renderSurfaceForTest(),
        realized,
        &base,
    );
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "render surface prepared owner releases render_surface payload with handle" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(
        allocator,
        .{ .surface_px = .{ .width = 1, .height = 1 } },
    ) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255)),
    };
    var prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 1,
        .height_px = 1,
    });

    const owner = try prepared_owner.Owner.create(session_owner, &prepared);
    try std.testing.expectEqual(@as(u32, 1), owner.renderSurfaceForTest().commands.count);

    owner.release();

    try std.testing.expect(owner.renderSurfaceStorageEmptyForTest());
}

test "render surface prepared owner reports missing surface when render_surface emission overflows" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(
        allocator,
        .{ .surface_px = .{ .width = 1, .height = 1 } },
    ) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const draws_len: usize = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    const background_draws = try allocator.alloc(contract.TextBackgroundDraw, draws_len);
    defer allocator.free(background_draws);
    for (background_draws) |*draw| {
        draw.* = backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255));
    }
    var prepared = preparedSurface(.{
        .background_draws = background_draws,
        .width_px = 1,
        .height_px = 1,
    });

    const owner = try prepared_owner.Owner.create(session_owner, &prepared);

    try std.testing.expect(owner.renderSurface() == null);
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_COMMAND_BOUND_OVERFLOW,
        owner.diagnostics().render_surface_emit_status,
    );
    try std.testing.expectEqual(@as(usize, 1), session_owner.prepared_handles.items.len);
}

test "render surface prepared owner overflow still consumes prepare surface once" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(
        allocator,
        .{ .surface_px = .{ .width = 1, .height = 1 } },
    ) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    var prepared = try ownedCommandOverflowPreparedSurface(allocator);
    const owner = try prepared_owner.Owner.create(session_owner, &prepared);

    try std.testing.expect(owner.renderSurface() == null);
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_COMMAND_BOUND_OVERFLOW,
        owner.diagnostics().render_surface_emit_status,
    );
    try std.testing.expectEqual(@as(u64, 0), prepared.request.token.snapshot_seq);
    try std.testing.expectEqual(@as(usize, 1), session_owner.prepared_handles.items.len);
}

test "render surface prepared owner allocation failure remains diagnostic only" {
    var probe_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var session_owner = text_session.TextSessionOwner.create(
            probe_allocator_state.allocator(),
            .{ .surface_px = .{ .width = 1, .height = 1 } },
        ) orelse return error.OutOfMemory;
        defer session_owner.destroy();
        const background = [_]contract.TextBackgroundDraw{
            backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255)),
        };
        var prepared = preparedSurface(.{
            .background_draws = &background,
            .width_px = 1,
            .height_px = 1,
        });
        const owner = try prepared_owner.Owner.create(session_owner, &prepared);
        owner.release();
    }

    var fail_index: usize = 0;
    while (fail_index < probe_allocator_state.alloc_index) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var session_owner = text_session.TextSessionOwner.create(
            failing_allocator_state.allocator(),
            .{ .surface_px = .{ .width = 1, .height = 1 } },
        ) orelse continue;
        defer session_owner.destroy();
        const background = [_]contract.TextBackgroundDraw{
            backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255)),
        };
        var prepared = preparedSurface(.{
            .background_draws = &background,
            .width_px = 1,
            .height_px = 1,
        });
        const owner = prepared_owner.Owner.create(session_owner, &prepared) catch continue;
        if (owner.diagnostics().render_surface_emit_status !=
            c.HOWL_RENDER_SURFACE_EMIT_ALLOCATION_FAILED) continue;
        try std.testing.expect(owner.renderSurface() == null);
        return;
    }
    return error.MissingAllocationFailureCase;
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
    const Emitter = render_surface_emitter.Emitter(.{});
    const emitter = try allocator.create(Emitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = render_surface_emitter.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, session, prepared);
    try render_surface_realizer.realize(surface, realized, base_pixels);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

fn ownedCommandOverflowPreparedSurface(
    allocator: std.mem.Allocator,
) !prepared_surface.PreparedSurface {
    const draws_len: usize = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    const background_draws = try allocator.alloc(contract.TextBackgroundDraw, draws_len);
    for (background_draws) |*draw| {
        draw.* = backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255));
    }
    return .{
        .allocator = allocator,
        .request = .{ .token = .{
            .snapshot_seq = 1,
            .dirty_epoch = 1,
            .geometry_epoch = 1,
            .damage_base_seq = 0,
            .damage_kind = .full,
        } },
        .geometry_epoch = 1,
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .text_frame = .{
            .scene = .{
                .allocator = allocator,
                .owned = true,
                .scene = .{
                    .clear_draws = &.{},
                    .background_draws = background_draws,
                    .sprite_draws = &.{},
                    .decoration_draws = &.{},
                    .cursor_draws = &.{},
                    .raster_requests = &.{},
                    .missing = &.{},
                    .full_redraw = true,
                },
            },
            .raster_plan = .{ .allocator = allocator, .outputs = &.{}, .owned = false },
        },
    };
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
