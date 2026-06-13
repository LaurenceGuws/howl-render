const std = @import("std");
const contract = @import("../contract.zig");

pub fn requestForUndercurl(key: contract.SpriteKey, width_px: u16, height_px: u16, decoration: contract.DecorationSpriteRaster) contract.SpriteRasterRequest {
    std.debug.assert(width_px > 0);
    std.debug.assert(height_px > 0);
    return .{
        .kind = .undercurl,
        .key = key,
        .group = .{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = key, .kind = .normal },
        .decoration = decoration,
        .width_px = width_px,
        .height_px = height_px,
        .color_mode = .alpha,
    };
}

pub fn rasterizeUndercurlAlpha(pixels: []u8, width_px: u16, height_px: u16, decoration: contract.DecorationSpriteRaster) void {
    @memset(pixels, 0);
    const width = @max(width_px, 1);
    const height = @max(height_px, 1);
    const max_x = @max(decoration.period_px, 1);
    const cell_width = max_x + 1;
    const xfactor = std.math.tau / @as(f64, @floatFromInt(max_x));
    const half_height = @as(f64, @floatFromInt(@max(decoration.amplitude_px, 1)));
    const thickness: i32 = @intCast(decoration.stroke_px);
    const position = @min(decoration.y_px, height - 1);

    var x: u16 = 0;
    while (x < width) : (x += 1) {
        const cell_x = x % cell_width;
        const wave = half_height * std.math.cos(@as(f64, @floatFromInt(cell_x)) * xfactor);
        const floor_y = std.math.floor(wave);
        const upper_y: i32 = @as(i32, @intFromFloat(std.math.floor(wave - @as(f64, @floatFromInt(thickness)))));
        const lower_y: i32 = @as(i32, @intFromFloat(std.math.ceil(wave)));
        const lower_alpha: u8 = @intFromFloat(@round((wave - floor_y) * 255.0));
        const upper_alpha: u8 = 255 - lower_alpha;

        addAlpha(pixels, width, height, x, position, upper_y, upper_alpha);
        var fill_y = upper_y + 1;
        while (fill_y <= upper_y + thickness) : (fill_y += 1) {
            addAlpha(pixels, width, height, x, position, fill_y, 255);
        }
        addAlpha(pixels, width, height, x, position, lower_y, lower_alpha);
    }
}

fn addAlpha(pixels: []u8, width: u16, height: u16, x: u16, position: u16, y_offset: i32, alpha: u8) void {
    if (alpha == 0) return;
    const raw_y = @as(i32, @intCast(position)) + y_offset;
    const y_clamped = std.math.clamp(raw_y, 0, @as(i32, @intCast(height - 1)));
    const idx = @as(u32, width) * @as(u32, @intCast(y_clamped)) + x;
    pixels[idx] = @intCast(@min(@as(u16, pixels[idx]) + @as(u16, alpha), 255));
}
