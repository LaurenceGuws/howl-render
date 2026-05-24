const std = @import("std");
const surface = @import("surface.zig");
const surface_text = @import("surface_text.zig");
const contract = @import("../text/contract.zig");
const text = @import("../text/text.zig");

pub fn compose(
    allocator: std.mem.Allocator,
    base_pixels: ?[]const u8,
    session: *surface_text.SurfaceText,
    prepared: *const surface.PreparedSurface,
) ![]u8 {
    const width = prepared.render_px.width;
    const height = prepared.render_px.height;
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    const pixels_len: u32 = @as(u32, width) * @as(u32, height) * 4;
    const pixels = try allocator.alloc(u8, @intCast(pixels_len));
    errdefer allocator.free(pixels);
    std.debug.assert(pixels.len == pixels_len);
    seedSurfacePixels(pixels, base_pixels);
    var composer = Composer{
        .pixels = pixels,
        .width = width,
        .height = height,
        .session = session,
        .prepared = prepared,
    };
    try composePreparedSurface(&composer, prepared);
    return pixels;
}

const ComposePass = enum {
    clear,
    graphics_below_bg,
    background,
    graphics_below_text,
    decoration,
    sprites,
    graphics_above_text,
    cursor,
};

const Composer = struct {
    pixels: []u8,
    width: u16,
    height: u16,
    session: *surface_text.SurfaceText,
    prepared: *const surface.PreparedSurface,

    fn clear(self: *Composer) !void {
        drawColorSpan(self.pixels, self.width, self.height, self.prepared.text_frame.scene.scene.clear_draws);
    }

    fn graphics_below_bg(self: *Composer, start: u32, end: u32) !void {
        drawGraphicsRange(self.pixels, self.width, self.height, self.session, &self.prepared.graphics, start, end);
    }

    fn background(self: *Composer) !void {
        drawColorSpan(self.pixels, self.width, self.height, self.prepared.text_frame.scene.scene.background_draws);
    }

    fn decoration(self: *Composer) !void {
        drawDecorationSpan(self.pixels, self.width, self.height, self.prepared.text_frame.scene.scene.decoration_draws);
    }

    fn sprites(self: *Composer) !void {
        try drawSprites(self.pixels, self.width, self.height, self.session, self.prepared);
    }

    fn graphics_below_text(self: *Composer, start: u32, end: u32) !void {
        drawGraphicsRange(self.pixels, self.width, self.height, self.session, &self.prepared.graphics, start, end);
    }

    fn graphics_above_text(self: *Composer, start: u32, end: u32) !void {
        drawGraphicsRange(self.pixels, self.width, self.height, self.session, &self.prepared.graphics, start, end);
    }

    fn cursor(self: *Composer) !void {
        drawColorSpan(self.pixels, self.width, self.height, self.prepared.text_frame.scene.scene.cursor_draws);
    }
};

fn composePreparedSurface(composer: anytype, prepared: *const surface.PreparedSurface) !void {
    const graphics = &prepared.graphics;
    const below_bg_end = graphics.below_bg_count;
    const below_text_end = std.math.add(u32, below_bg_end, graphics.below_text_count) catch unreachable;
    const above_text_end = std.math.add(u32, below_text_end, graphics.above_text_count) catch unreachable;
    std.debug.assert(above_text_end == graphics.placements.len);

    try composer.clear();
    try composer.graphics_below_bg(0, below_bg_end);
    try composer.background();
    try composer.graphics_below_text(below_bg_end, below_text_end);
    try composer.decoration();
    try composer.sprites();
    try composer.graphics_above_text(below_text_end, above_text_end);
    try composer.cursor();
}

fn seedSurfacePixels(pixels: []u8, base_pixels: ?[]const u8) void {
    const base = base_pixels orelse {
        clearSurfacePixels(pixels);
        return;
    };
    // Partial prepared frames are realized here against the render-owned
    // retained base. Hosts only ever consume one complete prepared image.
    std.debug.assert(base.len == pixels.len);
    @memcpy(pixels, base);
}

const SpriteRaster = struct {
    pixels: []const u8,
    stride: u16,
    color_mode: contract.SpriteColorMode,
    visual_bounds: text.Rasterizer.SpriteBounds,
};

fn clearSurfacePixels(pixels: []u8) void {
    var i: u32 = 0;
    const limit: u32 = @intCast(pixels.len);
    while (i + 3 < limit) : (i += 4) {
        pixels[@intCast(i)] = 0;
        pixels[@intCast(i + 1)] = 0;
        pixels[@intCast(i + 2)] = 0;
        pixels[@intCast(i + 3)] = 255;
    }
}

fn drawColorSpan(
    pixels: []u8,
    width: u16,
    height: u16,
    span: anytype,
) void {
    for (span) |draw| {
        drawSolidRect(
            pixels,
            width,
            height,
            draw.x_px,
            draw.y_px,
            draw.width_px,
            draw.height_px,
            draw.color,
        );
    }
}

fn drawGraphicsRange(
    pixels: []u8,
    width: u16,
    height: u16,
    session: *surface_text.SurfaceText,
    graphics: *const surface.PreparedGraphics,
    start: u32,
    end: u32,
) void {
    std.debug.assert(start <= end);
    std.debug.assert(end <= graphics.placements.len);
    for (graphics.placements[start..end]) |placement| {
        const image = graphics.images[@intCast(placement.image_index)];
        drawGraphicsPlacement(pixels, width, height, session, image, placement);
    }
}

fn drawGraphicsPlacement(
    pixels: []u8,
    width: u16,
    height: u16,
    session: *surface_text.SurfaceText,
    image: surface.PreparedGraphicsImageRef,
    placement: surface.PreparedGraphicsPlacement,
) void {
    const raster = session.graphicsRaster(image.raster_index) orelse return;
    if (placement.src_x_px >= raster.width or placement.src_y_px >= raster.height) return;
    if (placement.dest_width_px == 0 or placement.dest_height_px == 0) return;
    const src_right = placement.src_x_px + placement.src_width_px;
    const src_bottom = placement.src_y_px + placement.src_height_px;
    if (src_right > raster.width or src_bottom > raster.height) return;
    drawScaledRgbaPlacement(pixels, width, height, raster, placement);
}

fn drawScaledRgbaPlacement(
    pixels: []u8,
    width: u16,
    height: u16,
    raster: surface_text.SurfaceText.GraphicsRasterView,
    placement: surface.PreparedGraphicsPlacement,
) void {
    var dy: u32 = 0;
    while (dy < placement.dest_height_px) : (dy += 1) {
        const dy_i32 = std.math.cast(i32, dy) orelse return;
        const dst_y = placement.dest_y_px + dy_i32;
        if (dst_y < 0 or dst_y >= height) continue;
        const src_y = placement.src_y_px + @as(u32, @intCast((@as(u64, dy) * placement.src_height_px) / placement.dest_height_px));
        var dx: u32 = 0;
        while (dx < placement.dest_width_px) : (dx += 1) {
            const dx_i32 = std.math.cast(i32, dx) orelse return;
            const dst_x = placement.dest_x_px + dx_i32;
            if (dst_x < 0 or dst_x >= width) continue;
            const src_x = placement.src_x_px + @as(u32, @intCast((@as(u64, dx) * placement.src_width_px) / placement.dest_width_px));
            blendRgbaPixel(pixels, width, raster, dst_x, dst_y, src_x, src_y);
        }
    }
}

fn blendRgbaPixel(
    pixels: []u8,
    width: u16,
    raster: surface_text.SurfaceText.GraphicsRasterView,
    dst_x: i32,
    dst_y: i32,
    src_x: u32,
    src_y: u32,
) void {
    const dst_index = (@as(usize, @intCast(dst_y)) * width + @as(usize, @intCast(dst_x))) * 4;
    const src_index = @as(usize, src_y) * raster.stride + @as(usize, src_x) * 4;
    const alpha = raster.pixels_rgba[src_index + 3];
    if (alpha == 0) return;
    if (alpha == 255) {
        @memcpy(pixels[dst_index..][0..4], raster.pixels_rgba[src_index..][0..4]);
        return;
    }
    blendChannel(&pixels[dst_index], raster.pixels_rgba[src_index], alpha);
    blendChannel(&pixels[dst_index + 1], raster.pixels_rgba[src_index + 1], alpha);
    blendChannel(&pixels[dst_index + 2], raster.pixels_rgba[src_index + 2], alpha);
    pixels[dst_index + 3] = 255;
}

fn blendChannel(dst: *u8, src: u8, alpha: u8) void {
    const src_part = @as(u16, src) * alpha;
    const dst_part = @as(u16, dst.*) * (255 - alpha);
    dst.* = @intCast((src_part + dst_part + 127) / 255);
}

fn drawDecorationSpan(
    pixels: []u8,
    width: u16,
    height: u16,
    span: []const contract.TextDecorationDraw,
) void {
    for (span) |draw| {
        drawSolidRect(
            pixels,
            width,
            height,
            draw.x_px,
            draw.y_px,
            draw.width_px,
            draw.height_px,
            draw.color,
        );
    }
}

fn drawSprites(
    pixels: []u8,
    width: u16,
    height: u16,
    session: *surface_text.SurfaceText,
    prepared: *const surface.PreparedSurface,
) !void {
    for (prepared.text_frame.scene.scene.sprite_draws) |draw| {
        const sprite = try lookupSprite(session, prepared, draw.sprite.key);
        drawSpriteInstance(pixels, width, height, draw, sprite);
    }
}

fn lookupSprite(
    session: *surface_text.SurfaceText,
    prepared: *const surface.PreparedSurface,
    sprite_key: contract.SpriteKey,
) !SpriteRaster {
    for (prepared.text_frame.raster_plan.outputs) |output| {
        if (output.key.value != sprite_key.value) continue;
        const bounds = output.visualBounds();
        std.debug.assert(output.pixels.len >= packedStrideForOutput(output) * output.height_px);
        return .{
            .pixels = output.pixels,
            .stride = packedStrideForOutput(output),
            .color_mode = output.color_mode,
            .visual_bounds = bounds,
        };
    }
    const cached = session.atlasRaster(sprite_key) orelse return error.MissingSprite;
    const stride: u16 = switch (cached.color_mode) {
        .alpha => cached.width_px,
        .color => @intCast(@as(u32, cached.width_px) * 4),
    };
    std.debug.assert(cached.pixels.len >= @as(u32, stride) * cached.height_px);
    return .{
        .pixels = cached.pixels,
        .stride = stride,
        .color_mode = cached.color_mode,
        .visual_bounds = cached.visual_bounds,
    };
}

fn packedStrideForOutput(output: text.Rasterizer.RasterSpriteOutput) u16 {
    const channels: u16 = switch (output.color_mode) {
        .alpha => 1,
        .color => 4,
    };
    return @intCast(@as(u32, output.width_px) * @as(u32, channels));
}

fn drawSpriteInstance(
    pixels: []u8,
    width: u16,
    height: u16,
    draw: contract.TextSpriteDraw,
    sprite: SpriteRaster,
) void {
    const bounds = if (sprite.visual_bounds.width_px != 0 and
        sprite.visual_bounds.height_px != 0)
        sprite.visual_bounds
    else
        text.Rasterizer.SpriteBounds{
            .x_px = 0,
            .y_px = 0,
            .width_px = draw.width_px,
            .height_px = draw.height_px,
        };
    const dst_origin_x = draw.x_px + bounds.x_px;
    const dst_origin_y = draw.y_px + bounds.y_px;
    const max_w = @min(draw.width_px, bounds.width_px);
    const max_h = @min(draw.height_px, bounds.height_px);
    std.debug.assert(bounds.x_px + max_w <= sprite.stride);
    var yy: u16 = 0;
    while (yy < max_h) : (yy += 1) {
        var xx: u16 = 0;
        while (xx < max_w) : (xx += 1) {
            const dst_x = dst_origin_x + @as(i32, xx);
            const dst_y = dst_origin_y + @as(i32, yy);
            if (dst_x < 0 or dst_y < 0) continue;
            if (dst_x >= @as(i32, width) or dst_y >= @as(i32, height)) continue;
            const src_x = bounds.x_px + xx;
            const src_y = bounds.y_px + yy;
            const src_index = spriteIndex(sprite, src_x, src_y);
            const dst_index: u32 = (@as(u32, @intCast(dst_y)) * @as(u32, width) + @as(u32, @intCast(dst_x))) * 4;
            switch (sprite.color_mode) {
                .alpha => {
                    if (src_index >= sprite.pixels.len) continue;
                    const alpha = sprite.pixels[@intCast(src_index)];
                    if (alpha == 0) continue;
                    const out_alpha: u8 = @intCast(
                        (@as(u16, draw.color.a) * @as(u16, alpha)) / 255,
                    );
                    blendPixel(
                        pixels,
                        dst_index,
                        draw.color.r,
                        draw.color.g,
                        draw.color.b,
                        out_alpha,
                    );
                },
                .color => {
                    if (src_index + 3 >= sprite.pixels.len) continue;
                    blendPixel(
                        pixels,
                        dst_index,
                        sprite.pixels[@intCast(src_index)],
                        sprite.pixels[@intCast(src_index + 1)],
                        sprite.pixels[@intCast(src_index + 2)],
                        sprite.pixels[@intCast(src_index + 3)],
                    );
                },
            }
        }
    }
}

fn spriteIndex(sprite: SpriteRaster, src_x: u16, src_y: u16) u32 {
    const row_offset = @as(u32, src_y) * @as(u32, sprite.stride);
    return switch (sprite.color_mode) {
        .alpha => row_offset + src_x,
        .color => row_offset + @as(u32, src_x) * 4,
    };
}

fn drawSolidRect(
    pixels: []u8,
    width: u16,
    height: u16,
    x: i32,
    y: i32,
    rect_w: u16,
    rect_h: u16,
    color: contract.Rgba8,
) void {
    var yy: u16 = 0;
    while (yy < rect_h) : (yy += 1) {
        const dst_y = y + @as(i32, yy);
        if (dst_y < 0 or dst_y >= @as(i32, height)) continue;
        var xx: u16 = 0;
        while (xx < rect_w) : (xx += 1) {
            const dst_x = x + @as(i32, xx);
            if (dst_x < 0 or dst_x >= @as(i32, width)) continue;
            const dst_index: u32 = (@as(u32, @intCast(dst_y)) * @as(u32, width) + @as(u32, @intCast(dst_x))) * 4;
            blendPixel(pixels, dst_index, color.r, color.g, color.b, color.a);
        }
    }
}

fn blendPixel(pixels: []u8, dst_index: u32, r: u8, g: u8, b: u8, a: u8) void {
    const limit: u32 = @intCast(pixels.len);
    if (dst_index + 3 >= limit) return;
    const src_a: u32 = a;
    const inv_a: u32 = 255 - src_a;
    pixels[@intCast(dst_index)] = @intCast(
        (@as(u32, r) * src_a + @as(u32, pixels[@intCast(dst_index)]) * inv_a) / 255,
    );
    pixels[@intCast(dst_index + 1)] = @intCast(
        (@as(u32, g) * src_a + @as(u32, pixels[@intCast(dst_index + 1)]) * inv_a) / 255,
    );
    pixels[@intCast(dst_index + 2)] = @intCast(
        (@as(u32, b) * src_a + @as(u32, pixels[@intCast(dst_index + 2)]) * inv_a) / 255,
    );
    pixels[@intCast(dst_index + 3)] = @intCast(@min(
        @as(u32, 255),
        src_a + (@as(u32, pixels[@intCast(dst_index + 3)]) * inv_a) / 255,
    ));
}

test "compose preserves retained content outside partial updates" {
    var session = surface_text.SurfaceText.init(std.heap.c_allocator);
    defer session.deinit();

    const allocator = std.testing.allocator;
    const base = try allocator.alloc(u8, 4 * 4 * 4);
    defer allocator.free(base);
    @memset(base, 7);

    var clear_draws = try allocator.alloc(contract.TextClearDraw, 1);
    defer allocator.free(clear_draws);
    clear_draws[0] = .{
        .x_px = 0,
        .y_px = 0,
        .width_px = 2,
        .height_px = 1,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .first_cell = 0,
        .cell_span = 2,
    };

    var background_draws = try allocator.alloc(contract.TextBackgroundDraw, 1);
    defer allocator.free(background_draws);
    background_draws[0] = .{
        .x_px = 0,
        .y_px = 0,
        .width_px = 2,
        .height_px = 1,
        .color = .{ .r = 90, .g = 20, .b = 10, .a = 255 },
        .first_cell = 0,
        .cell_span = 2,
    };

    var prepared = surface.PreparedSurface{
        .allocator = allocator,
        .request = .{
            .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial },
        },
        .geometry_epoch = 1,
        .render_px = .{ .width = 4, .height = 4 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 4, .rows = 4 },
        .text_frame = .{
            .scene = .{
                .allocator = allocator,
                .owned = false,
                .scene = .{
                    .clear_draws = clear_draws,
                    .background_draws = background_draws,
                    .sprite_draws = &.{},
                    .decoration_draws = &.{},
                    .cursor_draws = &.{},
                    .raster_requests = &.{},
                    .missing = &.{},
                    .full_redraw = false,
                },
            },
            .raster_plan = .{ .allocator = allocator, .outputs = &.{}, .owned = false },
        },
    };

    const pixels = try compose(allocator, base, &session, &prepared);
    defer allocator.free(pixels);

    try std.testing.expectEqual(@as(u8, 90), pixels[0]);
    try std.testing.expectEqual(@as(u8, 20), pixels[1]);
    try std.testing.expectEqual(@as(u8, 10), pixels[2]);
    try std.testing.expectEqual(@as(u8, 7), pixels[8]);
    try std.testing.expectEqual(@as(u8, 7), pixels[9]);
    try std.testing.expectEqual(@as(u8, 7), pixels[10]);
}

const ComposeTrace = struct {
    passes: std.ArrayList(ComposePass),

    fn clear(self: *ComposeTrace) !void {
        try self.passes.append(std.testing.allocator, .clear);
    }

    fn graphics_below_bg(self: *ComposeTrace, start: u32, end: u32) !void {
        std.debug.assert(end >= start);
        try self.passes.append(std.testing.allocator, .graphics_below_bg);
    }

    fn background(self: *ComposeTrace) !void {
        try self.passes.append(std.testing.allocator, .background);
    }

    fn decoration(self: *ComposeTrace) !void {
        try self.passes.append(std.testing.allocator, .decoration);
    }

    fn sprites(self: *ComposeTrace) !void {
        try self.passes.append(std.testing.allocator, .sprites);
    }

    fn graphics_below_text(self: *ComposeTrace, start: u32, end: u32) !void {
        std.debug.assert(end >= start);
        try self.passes.append(std.testing.allocator, .graphics_below_text);
    }

    fn graphics_above_text(self: *ComposeTrace, start: u32, end: u32) !void {
        std.debug.assert(end >= start);
        try self.passes.append(std.testing.allocator, .graphics_above_text);
    }

    fn cursor(self: *ComposeTrace) !void {
        try self.passes.append(std.testing.allocator, .cursor);
    }
};

fn testPreparedSurface(
    allocator: std.mem.Allocator,
    clear_draws: []const contract.TextClearDraw,
    background_draws: []const contract.TextBackgroundDraw,
    decoration_draws: []const contract.TextDecorationDraw,
    cursor_draws: []const contract.TextCursorDraw,
    graphics: surface.PreparedGraphics,
) surface.PreparedSurface {
    return .{
        .allocator = allocator,
        .request = .{
            .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial },
        },
        .geometry_epoch = 1,
        .render_px = .{ .width = 4, .height = 4 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 4, .rows = 4 },
        .graphics = graphics,
        .text_frame = .{
            .scene = .{
                .allocator = allocator,
                .owned = false,
                .scene = .{
                    .clear_draws = clear_draws,
                    .background_draws = background_draws,
                    .sprite_draws = &.{},
                    .decoration_draws = decoration_draws,
                    .cursor_draws = cursor_draws,
                    .raster_requests = &.{},
                    .missing = &.{},
                    .full_redraw = false,
                },
            },
            .raster_plan = .{ .allocator = allocator, .outputs = &.{}, .owned = false },
        },
    };
}

test "compose inserts graphics bands at existing composition boundaries" {
    const allocator = std.testing.allocator;

    const clear_draws = try allocator.alloc(contract.TextClearDraw, 1);
    defer allocator.free(clear_draws);
    clear_draws[0] = .{
        .x_px = 0,
        .y_px = 0,
        .width_px = 1,
        .height_px = 1,
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 255 },
        .first_cell = 0,
        .cell_span = 1,
    };

    const background_draws = try allocator.alloc(contract.TextBackgroundDraw, 1);
    defer allocator.free(background_draws);
    background_draws[0] = .{
        .x_px = 0,
        .y_px = 0,
        .width_px = 1,
        .height_px = 1,
        .color = .{ .r = 2, .g = 2, .b = 2, .a = 255 },
        .first_cell = 0,
        .cell_span = 1,
    };

    const decoration_draws = try allocator.alloc(contract.TextDecorationDraw, 1);
    defer allocator.free(decoration_draws);
    decoration_draws[0] = .{
        .kind = .underline,
        .x_px = 0,
        .y_px = 0,
        .width_px = 1,
        .height_px = 1,
        .color = .{ .r = 3, .g = 3, .b = 3, .a = 255 },
        .first_cell = 0,
        .cell_span = 1,
    };

    const cursor_draws = try allocator.alloc(contract.TextCursorDraw, 1);
    defer allocator.free(cursor_draws);
    cursor_draws[0] = .{
        .x_px = 0,
        .y_px = 0,
        .width_px = 1,
        .height_px = 1,
        .color = .{ .r = 4, .g = 4, .b = 4, .a = 255 },
    };

    const images = try allocator.alloc(surface.PreparedGraphicsImageRef, 1);
    defer allocator.free(images);
    images[0] = .{ .image_id = 9, .width = 1, .height = 1, .format = 24, .raster_index = 0 };

    const placements = try allocator.alloc(surface.PreparedGraphicsPlacement, 3);
    defer allocator.free(placements);
    placements[0] = .{
        .image_index = 0,
        .placement_ordinal = 0,
        .z_index = std.math.minInt(i32),
        .layer = .below_bg,
        .dest_x_px = 0,
        .dest_y_px = 0,
        .dest_width_px = 1,
        .dest_height_px = 1,
        .src_x_px = 0,
        .src_y_px = 0,
        .src_width_px = 1,
        .src_height_px = 1,
    };
    placements[1] = .{
        .image_index = 0,
        .placement_ordinal = 1,
        .z_index = -1,
        .layer = .below_text,
        .dest_x_px = 0,
        .dest_y_px = 0,
        .dest_width_px = 1,
        .dest_height_px = 1,
        .src_x_px = 0,
        .src_y_px = 0,
        .src_width_px = 1,
        .src_height_px = 1,
    };
    placements[2] = .{
        .image_index = 0,
        .placement_ordinal = 2,
        .z_index = 0,
        .layer = .above_text,
        .dest_x_px = 0,
        .dest_y_px = 0,
        .dest_width_px = 1,
        .dest_height_px = 1,
        .src_x_px = 0,
        .src_y_px = 0,
        .src_width_px = 1,
        .src_height_px = 1,
    };

    var prepared = testPreparedSurface(
        allocator,
        clear_draws,
        background_draws,
        decoration_draws,
        cursor_draws,
        .{
            .publication_seq = 7,
            .images = images,
            .placements = placements,
            .below_bg_count = 1,
            .below_text_count = 1,
            .above_text_count = 1,
        },
    );

    var trace = ComposeTrace{ .passes = std.ArrayList(ComposePass).empty };
    defer trace.passes.deinit(allocator);

    try composePreparedSurface(&trace, &prepared);

    try std.testing.expectEqualSlices(
        ComposePass,
        &.{
            .clear,
            .graphics_below_bg,
            .background,
            .graphics_below_text,
            .decoration,
            .sprites,
            .graphics_above_text,
            .cursor,
        },
        trace.passes.items,
    );
}
