const std = @import("std");

const c = @import("../abi.zig").c;
const contract = @import("../text/contract.zig");
const prepared_buffer = @import("buffer.zig");
const prepared_surface = @import("surface.zig");
const realize = @import("../geometry/render_surface_realizer.zig");
const render_surface_emitter = @import("render_surface_emitter.zig");
const sprite_resource_store = @import("sprite_resource_store.zig");
const rasterizer = @import("../text/raster/rasterizer.zig");
const text_session = @import("../session/text.zig");
const test_support = @import("../test_support.zig");

const GlyphRef = c.HowlRenderGlyphRef;
const Limits = render_surface_emitter.Limits;
const Emitter = render_surface_emitter.Emitter;
const Surface = render_surface_emitter.Surface;
const Error = render_surface_emitter.Error;
const Rect = c.HowlRenderSurfaceRect;
const ResourceId = c.HowlRenderResourceId;
const emitter_testing = render_surface_emitter.testing;

const ColorMode = enum {
    alpha,
    color,
};

const Fill = struct {
    rect: Rect,
    color_rgba: u32,
};

const Sprite = struct {
    rect: Rect,
    color_rgba: u32,
    bytes: []const u8,
    width_px: u16,
    height_px: u16,
    stride_bytes: u32,
    color_mode: ColorMode,
};

const Fixture = struct {
    render_px: c.HowlRenderPixelSize,
    cell_px: c.HowlRenderCellSize = .{ .width = 1, .height = 1 },
    grid: c.HowlRenderGridSize = .{ .cols = 1, .rows = 1 },
    token: c.HowlRenderSurfaceToken = .{
        .snapshot_seq = 0,
        .surface_seq = 0,
        .geometry_epoch = 0,
        .resource_epoch = 0,
    },
    clear_fills: []const Fill = &.{},
    background_fills: []const Fill = &.{},
    decoration_fills: []const Fill = &.{},
    sprites: []const Sprite = &.{},
    cursor_fills: []const Fill = &.{},
};

fn rect(x_px: i32, y_px: i32, width_px: u16, height_px: u16) c.HowlRenderSurfaceRect {
    return .{ .x_px = x_px, .y_px = y_px, .width_px = width_px, .height_px = height_px };
}

fn glyphRefForTest(glyph_id: u32) GlyphRef {
    return .{
        .atlas_resource = .{
            .value = 1,
            .generation = 1,
            .kind = c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA,
        },
        .atlas_rect = rect(0, 0, 1, 1),
        .x_px = @intCast(glyph_id),
        .y_px = 0,
        .glyph_id = glyph_id,
        .color_rgba = 0xffffffff,
    };
}

fn fillResourcesForTest(resources: *sprite_resource_store.SpriteResourceStore, count: u32) void {
    std.debug.assert(count <= c.HOWL_RENDER_SURFACE_RESOURCES_MAX);
    resources.count = count;
    resources.bytes_count = 0;
    resources.value_next = @as(u64, count) + 1;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const value = @as(u64, index) + 1;
        resources.entries[@intCast(index)] = .{
            .key = .{ .value = value },
            .bytes_hash = value,
            .bytes_offset = 0,
            .bytes_count = 0,
            .resource = .{
                .value = value,
                .generation = 1,
                .kind = c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
            },
            .width_px = 1,
            .height_px = 1,
            .format = c.HOWL_RENDER_UPLOAD_ALPHA8,
        };
    }
}

fn realizeFixture(comptime limits: Limits, fixture: Fixture, pixels: []u8) !void {
    var emitter = Emitter(limits).init();
    const surface = try emitTesting(limits, &emitter, &fixture);
    try realize.realize(surface, pixels, null);
}

fn emitTesting(comptime limits: Limits, emitter: *Emitter(limits), fixture: *const Fixture) Error!*const Surface {
    var next = emitter.*;
    resetTesting(limits, &next, fixture);
    try appendFullDamage(limits, &next, fixture.render_px);
    try appendTestingFillPass(limits, &next, fixture.clear_fills, c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT);
    try appendTestingFillPass(limits, &next, fixture.background_fills, c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
    try appendTestingFillPass(limits, &next, fixture.decoration_fills, c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
    try appendTestingSprites(limits, &next, fixture.sprites);
    try appendTestingFillPass(limits, &next, fixture.cursor_fills, c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
    emitter.* = next;
    emitter_testing.publishSurface(limits, emitter);
    return emitter.surface();
}

fn resetTesting(comptime limits: Limits, emitter: *Emitter(limits), fixture: *const Fixture) void {
    emitter.damage_count = 0;
    emitter.create_count = 0;
    emitter.upload_count = 0;
    emitter.command_count = 0;
    emitter.glyph_count = 0;
    emitter.retire_count = 0;
    emitter.upload_bytes_count = 0;
    emitter.surface_storage = emptySurface();
    emitter.surface_storage.token = fixture.token;
    emitter.surface_storage.render_px = fixture.render_px;
    emitter.surface_storage.cell_px = fixture.cell_px;
    emitter.surface_storage.grid = fixture.grid;
}

fn appendFullDamage(comptime limits: Limits, emitter: *Emitter(limits), render_px: c.HowlRenderPixelSize) Error!void {
    if (emitter.damage_count >= limits.damage_max) return error.DamageBoundOverflow;
    emitter.damage[emitter.damage_count] = .{
        .kind = c.HOWL_RENDER_SURFACE_DAMAGE_FULL,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = .{ .x_px = 0, .y_px = 0, .width_px = render_px.width, .height_px = render_px.height },
    };
    emitter.damage_count += 1;
}

fn appendTestingFillPass(comptime limits: Limits, emitter: *Emitter(limits), fills: []const Fill, kind: u8) Error!void {
    for (fills) |fill| try appendCommand(limits, emitter, .{
        .kind = kind,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = fill.rect,
        .color_rgba = fill.color_rgba,
        .resource = zeroResource(),
        .glyphs = emptyGlyphs(),
    });
}

fn appendTestingSprites(comptime limits: Limits, emitter: *Emitter(limits), sprites: []const Sprite) Error!void {
    for (sprites, 0..) |sprite, sprite_index| {
        const resource = spriteResource(sprite, @intCast(sprite_index + 1));
        try appendTestingCreate(limits, emitter, resource, sprite);
        try appendTestingUpload(limits, emitter, resource, sprite);
        try appendCommand(limits, emitter, .{
            .kind = c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = sprite.rect,
            .color_rgba = if (sprite.color_mode == .alpha) sprite.color_rgba else 0,
            .resource = resource,
            .glyphs = emptyGlyphs(),
        });
        try appendRetire(limits, emitter, resource, emitter.command_count);
    }
}

fn appendTestingCreate(comptime limits: Limits, emitter: *Emitter(limits), resource: ResourceId, sprite: Sprite) Error!void {
    if (emitter.create_count >= limits.creates_max) return error.CreateBoundOverflow;
    emitter.creates[emitter.create_count] = .{
        .resource = resource,
        .width_px = sprite.width_px,
        .height_px = sprite.height_px,
        .format = uploadFormat(sprite.color_mode),
        .create_seq = 0,
    };
    emitter.create_count += 1;
}

fn appendTestingUpload(comptime limits: Limits, emitter: *Emitter(limits), resource: ResourceId, sprite: Sprite) Error!void {
    if (emitter.upload_count >= limits.uploads_max) return error.UploadBoundOverflow;
    const bytes_count: u32 = std.math.cast(u32, sprite.bytes.len) orelse return error.UploadBytesOverflow;
    const next_bytes_count = std.math.add(u32, emitter.upload_bytes_count, bytes_count) catch return error.UploadBytesOverflow;
    if (next_bytes_count > limits.upload_bytes_max) return error.UploadBytesOverflow;
    @memcpy(emitter.upload_bytes[emitter.upload_bytes_count..next_bytes_count], sprite.bytes);
    emitter.uploads[emitter.upload_count] = .{
        .resource = resource,
        .rect = .{ .x_px = 0, .y_px = 0, .width_px = sprite.width_px, .height_px = sprite.height_px },
        .bytes_ptr = &emitter.upload_bytes[emitter.upload_bytes_count],
        .bytes_count = bytes_count,
        .stride_bytes = sprite.stride_bytes,
        .format = uploadFormat(sprite.color_mode),
        .upload_seq = 0,
    };
    emitter.upload_byte_offsets[emitter.upload_count] = emitter.upload_bytes_count;
    emitter.upload_bytes_count = next_bytes_count;
    emitter.upload_count += 1;
}

fn appendCommand(comptime limits: Limits, emitter: *Emitter(limits), command: c.HowlRenderSurfaceCommand) Error!void {
    if (emitter.command_count >= limits.commands_max) return error.CommandBoundOverflow;
    emitter.commands[emitter.command_count] = command;
    emitter.command_count += 1;
}

fn appendRetire(comptime limits: Limits, emitter: *Emitter(limits), resource: ResourceId, retire_seq: u32) Error!void {
    if (emitter.retire_count >= limits.retires_max) return error.RetireBoundOverflow;
    emitter.retires[emitter.retire_count] = .{ .resource = resource, .retire_seq = retire_seq };
    emitter.retire_count += 1;
}

fn emptySurface() Surface {
    return .{
        .surface_version = c.HOWL_RENDER_SURFACE_VERSION,
        .reserved0 = 0,
        .token = .{ .snapshot_seq = 0, .surface_seq = 0, .geometry_epoch = 0, .resource_epoch = 0 },
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .damage = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX },
        .creates = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_CREATES_MAX },
        .uploads = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_UPLOADS_MAX, .bytes_count_total = 0, .bytes_count_max = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX },
        .commands = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_COMMANDS_MAX },
        .retires = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_RETIRES_MAX },
    };
}

fn emptyGlyphs() c.HowlRenderGlyphRunSpan {
    return .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX };
}

fn zeroResource() ResourceId {
    return .{ .value = 0, .generation = 0, .kind = 0 };
}

fn spriteResource(sprite: Sprite, value: u64) ResourceId {
    return .{
        .value = value,
        .generation = 1,
        .kind = switch (sprite.color_mode) {
            .alpha => c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
            .color => c.HOWL_RENDER_RESOURCE_SPRITE_COLOR,
        },
    };
}

fn uploadFormat(color_mode: ColorMode) u32 {
    return switch (color_mode) {
        .alpha => c.HOWL_RENDER_UPLOAD_ALPHA8,
        .color => c.HOWL_RENDER_UPLOAD_RGBA8,
    };
}

test "render surface surface emitter realizes fill pass order equal to oracle" {
    const limits = Limits{ .commands_max = 5, .glyph_refs_max = 5 };
    const clear = [_]Fill{.{ .rect = rect(0, 0, 2, 1), .color_rgba = 0x000000ff }};
    const background = [_]Fill{.{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xff0000ff }};
    const decoration = [_]Fill{.{ .rect = rect(1, 0, 1, 1), .color_rgba = 0x00ff00ff }};
    const cursor = [_]Fill{.{ .rect = rect(0, 0, 2, 1), .color_rgba = 0x0000ff80 }};
    var pixels: [8]u8 = undefined;
    try realizeFixture(limits, .{
        .render_px = .{ .width = 2, .height = 1 },
        .clear_fills = &clear,
        .background_fills = &background,
        .decoration_fills = &decoration,
        .cursor_fills = &cursor,
    }, &pixels);
    const oracle = [_]u8{ 127, 0, 128, 255, 0, 127, 128, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "render surface surface emitter realizes kitty dim alpha sprite equal to full rgba oracle" {
    const limits = Limits{
        .creates_max = 1,
        .uploads_max = 1,
        .commands_max = 1,
        .retires_max = 1,
        .upload_bytes_max = 2,
    };
    const sprite_bytes = [_]u8{ 255, 255 };
    const sprites = [_]Sprite{.{
        .rect = rect(0, 0, 2, 1),
        .color_rgba = 0xff000066,
        .bytes = &sprite_bytes,
        .width_px = 2,
        .height_px = 1,
        .stride_bytes = 2,
        .color_mode = .alpha,
    }};
    var pixels: [8]u8 = undefined;
    try realizeFixture(limits, .{
        .render_px = .{ .width = 2, .height = 1 },
        .sprites = &sprites,
    }, &pixels);
    const oracle = [_]u8{ 102, 0, 0, 255, 102, 0, 0, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "render surface surface emitter realizes color sprite equal to oracle" {
    const limits = Limits{
        .creates_max = 1,
        .uploads_max = 1,
        .commands_max = 1,
        .retires_max = 1,
        .upload_bytes_max = 4,
    };
    const sprite_bytes = [_]u8{ 0, 255, 0, 128 };
    const sprites = [_]Sprite{.{
        .rect = rect(0, 0, 1, 1),
        .color_rgba = 0,
        .bytes = &sprite_bytes,
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 4,
        .color_mode = .color,
    }};
    var pixels: [4]u8 = undefined;
    try realizeFixture(limits, .{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    }, &pixels);
    const oracle = [_]u8{ 0, 128, 0, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "render surface surface emitter batches two glyph refs into one run command" {
    const limits = Limits{ .commands_max = 1, .glyph_refs_max = 2 };
    var emitter = Emitter(limits).init();
    try emitter_testing.appendGlyphRef(limits, &emitter, glyphRefForTest(1));
    try emitter_testing.appendGlyphRef(limits, &emitter, glyphRefForTest(2));
    emitter_testing.publishSurface(limits, &emitter);

    const surface_value = emitter.surface();
    try std.testing.expectEqual(@as(u32, 1), surface_value.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, surface_value.commands.ptr[0].kind);
    try std.testing.expectEqual(@as(u32, 2), surface_value.commands.ptr[0].glyphs.count);
    try std.testing.expectEqual(@as(u32, 1), surface_value.commands.ptr[0].glyphs.ptr[0].glyph_id);
    try std.testing.expectEqual(@as(u32, 2), surface_value.commands.ptr[0].glyphs.ptr[1].glyph_id);
}

test "render surface surface emitter starts a second glyph run after run capacity" {
    const glyphs_max: u32 = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX + 1;
    const limits = Limits{ .commands_max = 2, .glyph_refs_max = glyphs_max };
    var emitter = Emitter(limits).init();
    var glyph_index: u32 = 0;
    while (glyph_index < glyphs_max) : (glyph_index += 1) {
        try emitter_testing.appendGlyphRef(limits, &emitter, glyphRefForTest(glyph_index + 1));
    }
    emitter_testing.publishSurface(limits, &emitter);

    const surface_value = emitter.surface();
    try std.testing.expectEqual(@as(u32, 2), surface_value.commands.count);
    try std.testing.expectEqual(@as(u32, c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX), surface_value.commands.ptr[0].glyphs.count);
    try std.testing.expectEqual(@as(u32, 1), surface_value.commands.ptr[1].glyphs.count);
    try std.testing.expectEqual(@as(u32, c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX), surface_value.commands.ptr[0].glyphs.ptr[c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX - 1].glyph_id);
    try std.testing.expectEqual(glyphs_max, surface_value.commands.ptr[1].glyphs.ptr[0].glyph_id);
}

test "render surface surface emitter emits sprite retires after final use" {
    const limits = Limits{
        .creates_max = 1,
        .uploads_max = 1,
        .commands_max = 1,
        .retires_max = 1,
        .upload_bytes_max = 1,
    };
    const sprite_bytes = [_]u8{255};
    const sprites = [_]Sprite{.{
        .rect = rect(0, 0, 1, 1),
        .color_rgba = 0xffffffff,
        .bytes = &sprite_bytes,
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 1,
        .color_mode = .alpha,
    }};
    var emitter = Emitter(limits).init();
    const surface = try emitTesting(limits, &emitter, &.{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    });
    try std.testing.expectEqual(@as(u32, 1), surface.retires.count);
    try std.testing.expectEqual(@as(u64, 1), surface.retires.ptr[0].retire_seq);
    var pixels: [4]u8 = undefined;
    try realize.realize(surface, &pixels, null);
    const oracle = [_]u8{ 255, 255, 255, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "render surface surface emitter rejects command bound overflow" {
    const limits = Limits{ .commands_max = 1, .glyph_refs_max = 1 };
    const fills = [_]Fill{
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff },
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff },
    };
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.CommandBoundOverflow, emitTesting(limits, &emitter, &.{
        .render_px = .{ .width = 1, .height = 1 },
        .background_fills = &fills,
    }));
}

test "render surface surface emitter rejects upload bound overflow" {
    const limits = Limits{
        .creates_max = 2,
        .uploads_max = 1,
        .commands_max = 2,
        .retires_max = 2,
        .upload_bytes_max = 2,
    };
    const one = [_]u8{255};
    const sprites = [_]Sprite{
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff, .bytes = &one, .width_px = 1, .height_px = 1, .stride_bytes = 1, .color_mode = .alpha },
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff, .bytes = &one, .width_px = 1, .height_px = 1, .stride_bytes = 1, .color_mode = .alpha },
    };
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.UploadBoundOverflow, emitTesting(limits, &emitter, &.{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    }));
}

test "render surface surface emitter rejects retire bound overflow" {
    const limits = Limits{
        .creates_max = 2,
        .uploads_max = 2,
        .commands_max = 2,
        .retires_max = 1,
        .upload_bytes_max = 2,
    };
    const one = [_]u8{255};
    const sprites = [_]Sprite{
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff, .bytes = &one, .width_px = 1, .height_px = 1, .stride_bytes = 1, .color_mode = .alpha },
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff, .bytes = &one, .width_px = 1, .height_px = 1, .stride_bytes = 1, .color_mode = .alpha },
    };
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.RetireBoundOverflow, emitTesting(limits, &emitter, &.{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    }));
}

test "render surface surface emitter rejects upload byte total overflow" {
    const limits = Limits{
        .creates_max = 1,
        .uploads_max = 1,
        .commands_max = 1,
        .retires_max = 1,
        .upload_bytes_max = 1,
    };
    const two = [_]u8{ 255, 255 };
    const sprites = [_]Sprite{.{
        .rect = rect(0, 0, 2, 1),
        .color_rgba = 0xffffffff,
        .bytes = &two,
        .width_px = 2,
        .height_px = 1,
        .stride_bytes = 2,
        .color_mode = .alpha,
    }};
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.UploadBytesOverflow, emitTesting(limits, &emitter, &.{
        .render_px = .{ .width = 2, .height = 1 },
        .sprites = &sprites,
    }));
}

test "render surface surface emitter leaves oracle path independent after emission failure" {
    const limits = Limits{ .commands_max = 1, .glyph_refs_max = 1 };
    const fill = [_]Fill{.{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xff0000ff }};
    const too_many = [_]Fill{
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0x00ff00ff },
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0x0000ffff },
    };
    var emitter = Emitter(limits).init();
    const accepted = try emitTesting(limits, &emitter, &.{
        .render_px = .{ .width = 1, .height = 1 },
        .background_fills = &fill,
    });
    try std.testing.expectError(error.CommandBoundOverflow, emitTesting(limits, &emitter, &.{
        .render_px = .{ .width = 1, .height = 1 },
        .background_fills = &too_many,
    }));
    try std.testing.expectEqual(@as(*const Surface, accepted), emitter.surface());
    var pixels: [4]u8 = undefined;
    try realize.realize(emitter.surface(), &pixels, null);
    const oracle = [_]u8{ 255, 0, 0, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "render surface surface emitter realizes prepared fill surface equal to full rgba oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const clear = [_]contract.TextClearDraw{clearDraw(0, 0, 2, 1, rgba(0, 0, 0, 255))};
    const background = [_]contract.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(255, 0, 0, 255))};
    const decoration = [_]contract.TextDecorationDraw{decorationDraw(1, 0, 1, 1, rgba(0, 255, 0, 255))};
    const cursor = [_]contract.TextCursorDraw{cursorDraw(0, 0, 2, 1, rgba(0, 0, 255, 128))};
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

test "render surface surface emitter fresh emission initializes undefined storage before publish" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(255, 0, 0, 255))};
    const prepared = preparedSurface(.{ .background_draws = &background, .width_px = 2, .height_px = 1 });
    const oracle = try prepared_buffer.compose(allocator, null, &session, &prepared);
    defer allocator.free(oracle);

    var emitter: Emitter(.{}) = undefined;
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPreparedFresh(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(@TypeOf(surface.surface_version), c.HOWL_RENDER_SURFACE_VERSION), surface.surface_version);
    try std.testing.expectEqual(@as(u64, 1), surface.token.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 1), surface.token.surface_seq);
    try std.testing.expectEqual(@as(u64, 1), surface.token.geometry_epoch);
    try std.testing.expectEqual(@as(u16, 2), surface.render_px.width);
    try std.testing.expectEqual(@as(u16, 1), surface.render_px.height);
    try std.testing.expectEqual(@as(u16, 1), surface.cell_px.width);
    try std.testing.expectEqual(@as(u16, 1), surface.cell_px.height);
    try std.testing.expectEqual(@as(u16, 2), surface.grid.cols);
    try std.testing.expectEqual(@as(u16, 1), surface.grid.rows);
    try std.testing.expectEqual(@as(u32, 1), surface.damage.count);
    try std.testing.expect(surface.damage.ptr != null);
    try std.testing.expectEqual(@as(@TypeOf(surface.damage.count_max), c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX), surface.damage.count_max);
    try std.testing.expectEqual(@as(u32, 0), surface.creates.count);
    try std.testing.expect(surface.creates.ptr == null);
    try std.testing.expectEqual(@as(@TypeOf(surface.creates.count_max), c.HOWL_RENDER_SURFACE_CREATES_MAX), surface.creates.count_max);
    try std.testing.expectEqual(@as(u32, 0), surface.uploads.count);
    try std.testing.expect(surface.uploads.ptr == null);
    try std.testing.expectEqual(@as(@TypeOf(surface.uploads.count_max), c.HOWL_RENDER_SURFACE_UPLOADS_MAX), surface.uploads.count_max);
    try std.testing.expectEqual(@as(u32, 0), surface.uploads.bytes_count_total);
    try std.testing.expectEqual(@as(@TypeOf(surface.uploads.bytes_count_max), c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX), surface.uploads.bytes_count_max);
    try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
    try std.testing.expect(surface.commands.ptr != null);
    try std.testing.expectEqual(@as(@TypeOf(surface.commands.count_max), c.HOWL_RENDER_SURFACE_COMMANDS_MAX), surface.commands.count_max);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, surface.commands.ptr[0].kind);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[1].kind);
    try std.testing.expectEqual(@as(u32, 0), surface.retires.count);
    try std.testing.expect(surface.retires.ptr == null);
    try std.testing.expectEqual(@as(@TypeOf(surface.retires.count_max), c.HOWL_RENDER_SURFACE_RETIRES_MAX), surface.retires.count_max);

    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try realize.realize(surface, realized, null);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "render surface surface emitter emits full prepared surface clear before fills" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(255, 0, 0, 255))};
    const prepared = preparedSurface(.{ .background_draws = &background, .width_px = 2, .height_px = 1 });
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, surface.commands.ptr[0].kind);
    try std.testing.expectEqual(@as(i32, 0), surface.commands.ptr[0].rect.x_px);
    try std.testing.expectEqual(@as(i32, 0), surface.commands.ptr[0].rect.y_px);
    try std.testing.expectEqual(@as(u16, 2), surface.commands.ptr[0].rect.width_px);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[0].rect.height_px);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[1].kind);
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter keeps partial prepared surface patch shaped" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(255, 0, 0, 255))};
    const prepared = preparedSurface(.{ .background_draws = &background, .width_px = 2, .height_px = 1, .full_redraw = false });
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 1), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[0].kind);
}

test "render surface surface emitter skips zero area prepared fills" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 0, 1, rgba(255, 0, 0, 255)),
        backgroundDraw(0, 0, 1, 0, rgba(0, 255, 0, 255)),
        backgroundDraw(0, 0, 1, 1, rgba(0, 0, 255, 255)),
    };
    const prepared = preparedSurface(.{ .background_draws = &background, .width_px = 1, .height_px = 1 });
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, surface.commands.ptr[0].kind);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[1].kind);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[1].rect.width_px);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[1].rect.height_px);
}

test "render surface surface emitter clips prepared fills to surface" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(-1, 0, 2, 1, rgba(255, 0, 0, 255)),
        backgroundDraw(1, 0, 2, 1, rgba(0, 255, 0, 255)),
    };
    const prepared = preparedSurface(.{ .background_draws = &background, .width_px = 2, .height_px = 1 });
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 3), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[1].kind);
    try std.testing.expectEqual(@as(i32, 0), surface.commands.ptr[1].rect.x_px);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[1].rect.width_px);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[2].kind);
    try std.testing.expectEqual(@as(i32, 1), surface.commands.ptr[2].rect.x_px);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[2].rect.width_px);
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
    const prepared = preparedSurface(.{ .background_draws = &background, .width_px = 4, .height_px = 1 });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[1].kind);
    try std.testing.expectEqual(@as(i32, 0), surface.commands.ptr[1].rect.x_px);
    try std.testing.expectEqual(@as(i32, 0), surface.commands.ptr[1].rect.y_px);
    try std.testing.expectEqual(@as(u16, 4), surface.commands.ptr[1].rect.width_px);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[1].rect.height_px);
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
    const decoration = [_]contract.TextDecorationDraw{decorationDraw(0, 0, 1, 1, rgba(4, 5, 6, 255))};
    const prepared = preparedSurface(.{ .background_draws = &background, .decoration_draws = &decoration, .width_px = 5, .height_px = 2 });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 6), surface.commands.count);
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter realizes prepared alpha sprite surface equal to full rgba oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{ 255, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{spriteDraw(11, 0, 0, 2, 1, rgba(255, 0, 0, 128))};
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 11, 2, 1, .alpha, &sprite_bytes, .{})};
    const prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 2, .height_px = 1 });
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
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 111, 1, 1, .alpha, &sprite_bytes, .{})};
    const prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 2, .height_px = 1 });

    const PreparedEmitter = Emitter(.{ .commands_max = 2, .glyph_refs_max = 2 });
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, surface.commands.ptr[1].kind);
    try std.testing.expectEqual(@as(u32, 2), surface.commands.ptr[1].glyphs.count);
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter skips fully offscreen prepared alpha sprites" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{255};
    var sprite_draws = [_]contract.TextSpriteDraw{spriteDraw(114, 2, 0, 1, 1, rgba(255, 255, 255, 255))};
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 114, 1, 1, .alpha, &sprite_bytes, .{})};
    const prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 1, .height_px = 1 });

    const PreparedEmitter = Emitter(.{ .commands_max = 2, .glyph_refs_max = 2 });
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 0), surface.creates.count);
    try std.testing.expectEqual(@as(u32, 0), surface.uploads.count);
    try std.testing.expectEqual(@as(u32, 1), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, surface.commands.ptr[0].kind);
    try std.testing.expectEqual(@as(u32, 0), resources.atlas_count);
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
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 112, 1, 1, .alpha, &sprite_bytes, .{})};
    const prepared = preparedSurface(.{ .sprite_draws = sprite_draws, .raster_outputs = &raster_outputs, .width_px = @intCast(draws_len), .height_px = 1 });

    const glyphs_max: u32 = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    const commands_expected = std.math.divCeil(u32, glyphs_max, c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX) catch unreachable;
    try std.testing.expectEqual(commands_expected + 1, surface.commands.count);
    try std.testing.expect(surface.commands.count < c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, surface.commands.ptr[1].kind);
    try std.testing.expectEqual(@as(u32, c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX), surface.commands.ptr[1].glyphs.count);
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
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 113, 1, 1, .alpha, &sprite_bytes, .{})};
    const prepared = preparedSurface(.{ .sprite_draws = sprite_draws, .raster_outputs = &raster_outputs, .width_px = @intCast(draws_len), .height_px = 1 });

    const PreparedEmitter = Emitter(.{ .commands_max = 1, .glyph_refs_max = draws_len });
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    try std.testing.expectError(error.CommandBoundOverflow, emitter.emitPrepared(&resources, &session, &prepared));
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().commands.count);
    try std.testing.expectEqual(@as(u32, 0), resources.atlas_count);
}

test "render surface surface emitter emits more than old alpha atlas entry cap" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    var index: u32 = 0;
    while (index <= sprite_resource_store.persistent_sprite_resources_max) : (index += 1) {
        var sprite_bytes = [_]u8{@intCast((index % 251) + 1)};
        var sprite_draws = [_]contract.TextSpriteDraw{spriteDraw(10_000 + index, 0, 0, 1, 1, rgba(255, 255, 255, 255))};
        var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 10_000 + index, 1, 1, .alpha, &sprite_bytes, .{})};
        const prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 1, .height_px = 1 });

        const surface = try emitter.emitPrepared(&resources, &session, &prepared);
        try std.testing.expectEqual(@as(u32, 1), surface.uploads.count);
        try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
        try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, surface.commands.ptr[1].kind);
    }
    try std.testing.expectEqual(sprite_resource_store.persistent_sprite_resources_max + 1, resources.atlas_count);
}

test "render surface surface emitter emits more than old alpha atlas hard cap" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const old_alpha_atlas_entry_limit: u32 = 1024;
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    var index: u32 = 0;
    while (index <= old_alpha_atlas_entry_limit) : (index += 1) {
        var sprite_bytes = [_]u8{@intCast((index % 251) + 1)};
        var sprite_draws = [_]contract.TextSpriteDraw{spriteDraw(20_000 + index, 0, 0, 1, 1, rgba(255, 255, 255, 255))};
        var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 20_000 + index, 1, 1, .alpha, &sprite_bytes, .{})};
        const prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 1, .height_px = 1 });

        const surface = try emitter.emitPrepared(&resources, &session, &prepared);
        try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, surface.commands.ptr[1].kind);
    }
    try std.testing.expectEqual(old_alpha_atlas_entry_limit + 1, resources.atlas_count);
}

test "render surface surface emitter realizes prepared color sprite surface equal to full rgba oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{ 0, 255, 0, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{spriteDraw(12, 0, 0, 1, 1, rgba(255, 0, 0, 255))};
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 12, 1, 1, .color, &sprite_bytes, .{})};
    const prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 1, .height_px = 1 });
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
    var sprite_draws = [_]contract.TextSpriteDraw{spriteDraw(13, 0, 0, 3, 2, rgba(0, 0, 255, 255))};
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 13, 3, 2, .alpha, &sprite_bytes, .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 2 })};
    const prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 3, .height_px = 2 });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter persists prepared sprite resource across surfaces" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{ 255, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{spriteDraw(31, 0, 0, 2, 1, rgba(255, 0, 0, 128))};
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 31, 2, 1, .alpha, &sprite_bytes, .{})};
    const prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 2, .height_px = 1 });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface1 = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(@as(u32, 1), surface1.creates.count);
    try std.testing.expectEqual(@as(u32, 1), surface1.uploads.count);
    try std.testing.expectEqual(@as(u32, 2), surface1.commands.count);
    try std.testing.expectEqual(@as(u32, 0), surface1.retires.count);
    const resource = surface1.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    try std.testing.expect(resource.value != 0);
    try std.testing.expectEqual(@as(u32, 1), resource.generation);

    const retained = try allocator.create(realize.ResourceStore);
    defer allocator.destroy(retained);
    retained.count = 0;
    retained.bytes_count = 0;
    const oracle = try prepared_buffer.compose(allocator, null, &session, &prepared);
    defer allocator.free(oracle);
    const realized1 = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized1);
    try realize.realizeRetained(surface1, realized1, null, retained);
    try std.testing.expectEqualSlices(u8, oracle, realized1);

    const surface2 = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(@as(u32, 0), surface2.creates.count);
    try std.testing.expectEqual(@as(u32, 0), surface2.uploads.count);
    try std.testing.expectEqual(@as(u32, 2), surface2.commands.count);
    try std.testing.expectEqual(@as(u32, 0), surface2.retires.count);
    try std.testing.expectEqual(resource.value, surface2.commands.ptr[1].glyphs.ptr[0].atlas_resource.value);
    try std.testing.expectEqual(resource.generation, surface2.commands.ptr[1].glyphs.ptr[0].atlas_resource.generation);
    const realized2 = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized2);
    try realize.realizeRetained(surface2, realized2, null, retained);
    try std.testing.expectEqualSlices(u8, oracle, realized2);
}

test "render surface surface emitter reused alpha atlas sprite skips uploads on second emission" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{ 255, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{spriteDraw(32, 0, 0, 2, 1, rgba(255, 255, 255, 255))};
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 32, 2, 1, .alpha, &sprite_bytes, .{})};
    const prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 2, .height_px = 1 });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();

    const first_surface = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(@as(u32, 1), first_surface.uploads.count);
    try std.testing.expectEqual(@as(u32, 2), emitter.upload_bytes_count);

    const second_surface = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(@as(u32, 0), second_surface.uploads.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.upload_bytes_count);
}

test "render surface surface emitter reused persistent color sprite skips uploads on second emission" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var sprite_draws = [_]contract.TextSpriteDraw{spriteDraw(33, 0, 0, 2, 1, rgba(255, 255, 255, 255))};
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 33, 2, 1, .color, &sprite_bytes, .{})};
    const prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 2, .height_px = 1 });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();

    const first_surface = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(@as(u32, 1), first_surface.uploads.count);
    try std.testing.expectEqual(@as(u32, 8), emitter.upload_bytes_count);

    const second_surface = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(@as(u32, 0), second_surface.uploads.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.upload_bytes_count);
}

test "render surface surface emitter allocates distinct monotonic sprite resources" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var first_bytes = [_]u8{255};
    var first_draws = [_]contract.TextSpriteDraw{spriteDraw(41, 0, 0, 1, 1, rgba(255, 255, 255, 255))};
    var first_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 41, 1, 1, .alpha, &first_bytes, .{})};
    var second_bytes = [_]u8{128};
    var second_draws = [_]contract.TextSpriteDraw{spriteDraw(42, 0, 0, 1, 1, rgba(255, 255, 255, 255))};
    var second_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 42, 1, 1, .alpha, &second_bytes, .{})};
    const first = preparedSurface(.{ .sprite_draws = &first_draws, .raster_outputs = &first_outputs, .width_px = 1, .height_px = 1 });
    const second = preparedSurface(.{ .sprite_draws = &second_draws, .raster_outputs = &second_outputs, .width_px = 1, .height_px = 1 });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface1 = try emitter.emitPrepared(&resources, &session, &first);
    const first_resource = surface1.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    const surface2 = try emitter.emitPrepared(&resources, &session, &second);
    const second_resource = surface2.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    try std.testing.expectEqual(@as(u64, 1), first_resource.value);
    try std.testing.expectEqual(first_resource.value, second_resource.value);
    try std.testing.expectEqual(@as(u32, 1), second_resource.generation);
}

test "render surface surface emitter allocates distinct resource for changed sprite bytes" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var first_bytes = [_]u8{255};
    var first_draws = [_]contract.TextSpriteDraw{spriteDraw(43, 0, 0, 1, 1, rgba(255, 255, 255, 255))};
    var first_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 43, 1, 1, .alpha, &first_bytes, .{})};
    var second_bytes = [_]u8{128};
    var second_draws = [_]contract.TextSpriteDraw{spriteDraw(43, 0, 0, 1, 1, rgba(255, 255, 255, 255))};
    var second_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 43, 1, 1, .alpha, &second_bytes, .{})};
    const first = preparedSurface(.{ .sprite_draws = &first_draws, .raster_outputs = &first_outputs, .width_px = 1, .height_px = 1 });
    const second = preparedSurface(.{ .sprite_draws = &second_draws, .raster_outputs = &second_outputs, .width_px = 1, .height_px = 1 });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface1 = try emitter.emitPrepared(&resources, &session, &first);
    const first_resource = surface1.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    const surface2 = try emitter.emitPrepared(&resources, &session, &second);
    const second_resource = surface2.commands.ptr[1].glyphs.ptr[0].atlas_resource;
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
    var first_draws = [_]contract.TextSpriteDraw{spriteDraw(44, 0, 0, 1, 1, rgba(255, 255, 255, 255))};
    var first_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 44, 1, 1, .alpha, &first_bytes, .{})};
    var second_bytes = [_]u8{ 255, 128 };
    var second_draws = [_]contract.TextSpriteDraw{spriteDraw(44, 0, 0, 2, 1, rgba(255, 255, 255, 255))};
    var second_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 44, 2, 1, .alpha, &second_bytes, .{})};
    const first = preparedSurface(.{ .sprite_draws = &first_draws, .raster_outputs = &first_outputs, .width_px = 2, .height_px = 1 });
    const second = preparedSurface(.{ .sprite_draws = &second_draws, .raster_outputs = &second_outputs, .width_px = 2, .height_px = 1 });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface1 = try emitter.emitPrepared(&resources, &session, &first);
    const first_resource = surface1.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    const surface2 = try emitter.emitPrepared(&resources, &session, &second);
    const second_resource = surface2.commands.ptr[1].glyphs.ptr[0].atlas_resource;
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
    var draws = [_]contract.TextSpriteDraw{spriteDraw(51, 0, 0, 2, 1, rgba(255, 255, 255, 255))};
    var outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 51, 2, 1, .alpha, &bytes, .{})};
    const prepared = preparedSurface(.{ .sprite_draws = &draws, .raster_outputs = &outputs, .width_px = 2, .height_px = 1 });

    var emitter = Emitter(.{ .commands_max = 1, .glyph_refs_max = 1, .upload_bytes_max = 1 }).init();
    var resources = sprite_resource_store.SpriteResourceStore.init();
    try std.testing.expectError(error.UploadBytesOverflow, emitter.emitPrepared(&resources, &session, &prepared));
    try std.testing.expectEqual(@as(u32, 0), resources.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().creates.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().commands.count);
}

test "render surface surface emitter fresh failure restores retained resource admission state" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var alpha_bytes = [_]u8{255};
    var color_bytes = [_]u8{ 1, 2, 3, 4 };
    var accepted_draws = [_]contract.TextSpriteDraw{
        spriteDraw(52, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
        spriteDraw(53, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var accepted_outputs = [_]rasterizer.RasterSpriteOutput{
        test_support.rasterOutput(allocator, 52, 1, 1, .alpha, &alpha_bytes, .{}),
        test_support.rasterOutput(allocator, 53, 1, 1, .color, &color_bytes, .{}),
    };
    const accepted = preparedSurface(.{ .sprite_draws = &accepted_draws, .raster_outputs = &accepted_outputs, .width_px = 2, .height_px = 1 });

    var accepted_emitter = Emitter(.{}).init();
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const accepted_surface = try accepted_emitter.emitPreparedFresh(&resources, &session, &accepted);
    try std.testing.expectEqual(@as(u32, 2), accepted_surface.uploads.count);
    try std.testing.expectEqual(@as(u32, 1), resources.count);
    try std.testing.expectEqual(@as(u32, 4), resources.bytes_count);
    try std.testing.expectEqual(@as(u32, 1), resources.atlas_count);
    try std.testing.expectEqual(@as(u64, 3), resources.value_next);
    try std.testing.expectEqual(@as(?u32, 0), resources.last_resource_entry_index);
    try std.testing.expectEqual(@as(?u32, 0), resources.last_atlas_entry_index);
    const rollback = resources.admissionRollback();
    const accepted_entry = resources.entries[0];
    const accepted_atlas_entry = resources.atlas_entries[0];

    var fail_color_bytes = [_]u8{ 5, 6, 7, 8 };
    var fail_alpha_bytes = [_]u8{128};
    var fail_draws = [_]contract.TextSpriteDraw{
        spriteDraw(54, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
        spriteDraw(55, 1, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var fail_outputs = [_]rasterizer.RasterSpriteOutput{
        test_support.rasterOutput(allocator, 54, 1, 1, .color, &fail_color_bytes, .{}),
        test_support.rasterOutput(allocator, 55, 1, 1, .alpha, &fail_alpha_bytes, .{}),
    };
    const failing = preparedSurface(.{ .sprite_draws = &fail_draws, .raster_outputs = &fail_outputs, .width_px = 2, .height_px = 1 });

    var failing_emitter = Emitter(.{ .commands_max = 2, .glyph_refs_max = 2, .creates_max = 2, .uploads_max = 2, .upload_bytes_max = 5 }).init();
    try std.testing.expectError(error.CommandBoundOverflow, failing_emitter.emitPreparedFresh(&resources, &session, &failing));
    try std.testing.expectEqual(rollback.count, resources.count);
    try std.testing.expectEqual(rollback.bytes_count, resources.bytes_count);
    try std.testing.expectEqual(rollback.value_next, resources.value_next);
    try std.testing.expectEqual(rollback.atlas_resource, resources.atlas_resource);
    try std.testing.expectEqual(rollback.atlas_count, resources.atlas_count);
    try std.testing.expectEqual(rollback.atlas_next_x, resources.atlas_next_x);
    try std.testing.expectEqual(rollback.atlas_next_y, resources.atlas_next_y);
    try std.testing.expectEqual(rollback.atlas_row_height, resources.atlas_row_height);
    try std.testing.expectEqual(rollback.last_resource_entry_index, resources.last_resource_entry_index);
    try std.testing.expectEqual(rollback.last_atlas_entry_index, resources.last_atlas_entry_index);
    try std.testing.expectEqual(accepted_entry, resources.entries[0]);
    try std.testing.expectEqual(accepted_atlas_entry, resources.atlas_entries[0]);
    try std.testing.expectEqualSlices(u8, &color_bytes, resources.bytes[0..resources.bytes_count]);
}

test "render surface surface emitter resource id exhaustion preserves accepted state" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var bytes = [_]u8{ 255, 255, 255, 255 };
    var draws = [_]contract.TextSpriteDraw{spriteDraw(61, 0, 0, 1, 1, rgba(255, 255, 255, 255))};
    var outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 61, 1, 1, .color, &bytes, .{})};
    const prepared = preparedSurface(.{ .sprite_draws = &draws, .raster_outputs = &outputs, .width_px = 1, .height_px = 1 });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    resources.value_next = 0;
    try std.testing.expectError(error.ResourceBoundOverflow, emitter.emitPrepared(&resources, &session, &prepared));
    try std.testing.expectEqual(@as(u32, 0), resources.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().creates.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().commands.count);
}

test "render surface surface emitter emits transient sprite beyond persistent budget" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var bytes = [_]u8{ 255, 255, 255, 255 };
    var draws = [_]contract.TextSpriteDraw{spriteDraw(62, 0, 0, 1, 1, rgba(255, 255, 255, 255))};
    var outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 62, 1, 1, .color, &bytes, .{})};
    const prepared = preparedSurface(.{ .sprite_draws = &draws, .raster_outputs = &outputs, .width_px = 1, .height_px = 1 });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    fillResourcesForTest(&resources, sprite_resource_store.persistent_sprite_resources_max);
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(sprite_resource_store.persistent_sprite_resources_max, resources.count);
    try std.testing.expectEqual(@as(u32, 1), surface.creates.count);
    try std.testing.expectEqual(@as(u32, 1), surface.uploads.count);
    try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
    try std.testing.expectEqual(@as(u32, 1), surface.retires.count);
    try std.testing.expectEqual(surface.commands.ptr[1].resource.value, surface.retires.ptr[0].resource.value);
    try std.testing.expectEqual(@as(u64, 2), surface.retires.ptr[0].retire_seq);
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
    var outputs = [_]rasterizer.RasterSpriteOutput{
        test_support.rasterOutput(allocator, 63, 1, 1, .color, &first_bytes, .{}),
        test_support.rasterOutput(allocator, 64, 1, 1, .color, &second_bytes, .{}),
    };
    const prepared = preparedSurface(.{ .sprite_draws = &draws, .raster_outputs = &outputs, .width_px = 1, .height_px = 1 });

    var emitter = Emitter(.{ .commands_max = 3, .glyph_refs_max = 3, .retires_max = 1 }).init();
    var resources = sprite_resource_store.SpriteResourceStore.init();
    fillResourcesForTest(&resources, sprite_resource_store.persistent_sprite_resources_max);
    try std.testing.expectError(error.RetireBoundOverflow, emitter.emitPrepared(&resources, &session, &prepared));
    try std.testing.expectEqual(sprite_resource_store.persistent_sprite_resources_max, resources.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().commands.count);
}

test "render surface surface emitter rejects missing prepared sprite without mutating accepted surface" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(255, 0, 0, 255))};
    var accepted_prepared = preparedSurface(.{ .background_draws = &background, .width_px = 1, .height_px = 1 });
    var missing_sprite_draws = [_]contract.TextSpriteDraw{spriteDraw(99, 0, 0, 1, 1, rgba(255, 255, 255, 255))};
    var missing_prepared = preparedSurface(.{ .sprite_draws = &missing_sprite_draws, .width_px = 1, .height_px = 1 });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const accepted_surface = try emitter.emitPrepared(&resources, &session, &accepted_prepared);
    try std.testing.expectError(error.MissingPreparedSprite, emitter.emitPrepared(&resources, &session, &missing_prepared));
    try std.testing.expectEqual(accepted_surface, emitter.surface());

    const oracle = try prepared_buffer.compose(allocator, null, &session, &accepted_prepared);
    defer allocator.free(oracle);
    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try realize.realize(emitter.surface(), realized, null);
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
    const background = [_]contract.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(9, 8, 7, 255))};
    const prepared = preparedSurface(.{ .background_draws = &background, .width_px = 2, .height_px = 1, .full_redraw = false });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, &base);
}

fn expectPreparedEmissionEqualsCompose(allocator: std.mem.Allocator, session: *text_session.TextSession, prepared: *const prepared_surface.PreparedSurface, base_pixels: ?[]const u8) !void {
    const oracle = try prepared_buffer.compose(allocator, base_pixels, session, prepared);
    defer allocator.free(oracle);
    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, session, prepared);
    try realize.realize(surface, realized, base_pixels);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

const PreparedOptions = struct {
    clear_draws: []const contract.TextClearDraw = &.{},
    background_draws: []const contract.TextBackgroundDraw = &.{},
    sprite_draws: []const contract.TextSpriteDraw = &.{},
    decoration_draws: []const contract.TextDecorationDraw = &.{},
    cursor_draws: []const contract.TextCursorDraw = &.{},
    raster_outputs: []rasterizer.RasterSpriteOutput = &.{},
    width_px: u16,
    height_px: u16,
    full_redraw: bool = true,
};

fn preparedSurface(options: PreparedOptions) prepared_surface.PreparedSurface {
    return .{
        .allocator = std.testing.allocator,
        .request = .{ .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = if (options.full_redraw) 0 else 1, .damage_kind = if (options.full_redraw) .full else .partial } },
        .geometry_epoch = 1,
        .render_px = .{ .width = options.width_px, .height = options.height_px },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = options.width_px, .rows = options.height_px },
        .text_surface = .{
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

fn clearDraw(x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) contract.TextClearDraw {
    return .{ .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = 0, .cell_span = 1 };
}

fn backgroundDraw(x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) contract.TextBackgroundDraw {
    return .{ .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = 0, .cell_span = 1 };
}

fn decorationDraw(x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) contract.TextDecorationDraw {
    return .{ .kind = .underline, .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = 0, .cell_span = 1 };
}

fn cursorDraw(x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) contract.TextCursorDraw {
    return .{ .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color };
}

fn spriteDraw(key: u64, x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) contract.TextSpriteDraw {
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
