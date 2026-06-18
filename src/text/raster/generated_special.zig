const std = @import("std");
const render = @import("../../libhowl_render.zig");
const special_glyphs = @import("../special_glyphs.zig");
const special_block_braille = @import("special_block_braille.zig");
const special_box = @import("special_box.zig");
const special_legacy_computing = @import("special_legacy_computing.zig");
const special_powerline = @import("special_powerline.zig");

pub fn rasterizeGeneratedSpecialAlpha(pixels: []u8, width_px: u16, height_px: u16, codepoint: u32) bool {
    const light = @as(u16, 2);
    return rasterizeGeneratedSpecialAlphaWithMetrics(pixels, width_px, height_px, codepoint, .{
        .light_stroke_px = light,
        .heavy_stroke_px = @intCast(@min(@as(u32, light) * 2, std.math.maxInt(u16))),
    });
}

pub fn rasterizeGeneratedSpecialAlphaWithMetrics(pixels: []u8, width_px: u16, height_px: u16, codepoint: u32, box_drawing: render.BoxDrawingRasterMetrics) bool {
    std.debug.assert(pixels.len <= std.math.maxInt(u32));
    std.debug.assert(@as(u32, @intCast(pixels.len)) >= @as(u32, width_px) * @as(u32, height_px));
    if (!special_glyphs.isGeneratedSpecialSupported(codepoint)) return false;
    @memset(pixels, 0);
    const width = @max(width_px, 1);
    const height = @max(height_px, 1);
    if (generatedSpecialFamily(codepoint)) |family| {
        rasterizeSupportedGeneratedSpecialAlpha(pixels, width, height, codepoint, box_drawing, family);
        return true;
    }
    return false;
}

fn rasterizeSupportedGeneratedSpecialAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32, box_drawing: render.BoxDrawingRasterMetrics, family: GeneratedSpecialFamily) void {
    switch (family) {
        .box => special_box.rasterizeGeneratedBoxAlpha(pixels, width, height, codepoint, box_drawing),
        .powerline => special_powerline.rasterizeGeneratedPowerlineAlpha(pixels, width, height, codepoint, box_drawing),
        .powerline_triangle => special_powerline.rasterizeGeneratedPowerlineTriangleAlpha(pixels, width, height, codepoint),
        .block => special_block_braille.rasterizeGeneratedBlockAlpha(pixels, width, height, codepoint),
        .eight_bar => special_legacy_computing.rasterizeGeneratedEightBarAlpha(pixels, width, height, codepoint),
        .smooth_mosaic => special_legacy_computing.rasterizeGeneratedSmoothMosaicAlpha(pixels, width, height, codepoint),
        .half_triangle => special_legacy_computing.rasterizeGeneratedHalfTriangleAlpha(pixels, width, height, codepoint),
        .eight_bar_composite => special_legacy_computing.rasterizeGeneratedEightBarCompositeAlpha(pixels, width, height, codepoint),
        .shade_corner_cross => special_legacy_computing.rasterizeGeneratedShadeCornerCrossAlpha(pixels, width, height, codepoint),
        .mid_line => special_legacy_computing.rasterizeGeneratedMidLineAlpha(pixels, width, height, codepoint),
        .sextant => special_legacy_computing.rasterizeGeneratedSextantAlpha(pixels, width, height, codepoint),
        .octant => special_legacy_computing.rasterizeGeneratedOctantAlpha(pixels, width, height, codepoint),
        .branch => special_legacy_computing.rasterizeGeneratedBranchAlpha(pixels, width, height, codepoint),
    }
}

const GeneratedSpecialFamily = enum {
    box,
    powerline,
    powerline_triangle,
    block,
    eight_bar,
    smooth_mosaic,
    half_triangle,
    eight_bar_composite,
    shade_corner_cross,
    mid_line,
    sextant,
    octant,
    branch,
};

fn generatedSpecialFamily(codepoint: u32) ?GeneratedSpecialFamily {
    return switch (codepoint) {
        0x2500...0x257f => .box,
        0xe0b0...0xe0bf => .powerline,
        0xe0d6...0xe0d7 => .powerline_triangle,
        0x2580...0x259f, 0x2800...0x28ff => .block,
        0x1fb70...0x1fb75, 0x1fb76...0x1fb7b => .eight_bar,
        0x1fb3c...0x1fb67 => .smooth_mosaic,
        0x1fb68...0x1fb6f => .half_triangle,
        0x1fb7c...0x1fb8b => .eight_bar_composite,
        0x1fb8c...0x1fb9f => .shade_corner_cross,
        0x1fba0...0x1fbae => .mid_line,
        0x1fb00...0x1fb3b => .sextant,
        0x1cd00...0x1cde5, 0x1fbe6, 0x1fbe7 => .octant,
        0xf5d0...0xf60d => .branch,
        else => null,
    };
}

pub const Range = struct { start: u16, end: u16 };

pub fn eighthPartitionRange(size: u16, which: u16) Range {
    const thickness = @max(@as(u16, 1), size / 8);
    const block = thickness * 8;
    if (block == size) return .{ .start = thickness * which, .end = thickness * (@as(u16, which) + 1) };
    if (block > size) {
        const start = @min(@as(u16, which) * thickness, saturatingSubU16(size, thickness));
        return .{ .start = start, .end = start + thickness };
    }

    var thicknesses = [_]u16{thickness} ** 8;
    var extra = size - block;
    const order = [_]u8{ 3, 4, 2, 5, 6, 1, 7, 0 };
    for (order) |idx| {
        if (extra == 0) break;
        thicknesses[idx] += 1;
        extra -= 1;
    }
    var pos: u16 = 0;
    var idx: u8 = 0;
    while (idx < which) : (idx += 1) pos += thicknesses[idx];
    return .{ .start = pos, .end = pos + thicknesses[which] };
}

pub const PointF = struct { x: f64, y: f64 };

pub fn supersampledCoverage(x: u16, y: u16, comptime inside: anytype, ctx: anytype) u8 {
    const factor = 4;
    var hits: u16 = 0;
    var sy: u8 = 0;
    while (sy < factor) : (sy += 1) {
        var sx: u8 = 0;
        while (sx < factor) : (sx += 1) {
            const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / factor;
            const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / factor;
            if (inside(px, py, ctx)) hits += 1;
        }
    }
    return @intCast((hits * 255 + (factor * factor / 2)) / (factor * factor));
}

pub fn drawLineAlpha(pixels: []u8, width: u16, height: u16, x1: f64, y1: f64, x2: f64, y2: f64, line_width: f64) void {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len2 = @max(dx * dx + dy * dy, 1.0);
    const half = @max(line_width, 1.0) / 2.0;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const t = std.math.clamp(((px - x1) * dx + (py - y1) * dy) / len2, 0.0, 1.0);
            const cx = x1 + t * dx;
            const cy = y1 + t * dy;
            const dist = @sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
            const coverage = std.math.clamp(half - dist + 0.5, 0.0, 1.0);
            if (coverage <= 0) continue;
            const idx = pixelOffset(width, x, y);
            pixels[idx] = @max(pixels[idx], @as(u8, @intFromFloat(@round(coverage * 255.0))));
        }
    }
}

pub fn lineY(x1: f64, y1: f64, x2: f64, y2: f64, x: f64) f64 {
    if (x1 == x2) return y1;
    const m = (y2 - y1) / (x2 - x1);
    return m * x + y1 - m * x1;
}

pub fn fillRectAlpha(pixels: []u8, stride: u16, x: u16, y: u16, width: u16, height: u16, alpha: u8) void {
    var yy = y;
    while (yy < y + height) : (yy += 1) {
        var xx = x;
        while (xx < x + width) : (xx += 1) {
            pixels[pixelOffset(stride, xx, yy)] = alpha;
        }
    }
}

pub fn saturatingSubU16(a: u16, b: u16) u16 {
    return if (a > b) a - b else 0;
}

pub fn pixelRowOffset(width: u16, y: u16) u32 {
    return @as(u32, width) * @as(u32, y);
}

pub fn pixelOffset(width: u16, x: u16, y: u16) u32 {
    return pixelRowOffset(width, y) + x;
}

pub fn pixelCount(width: u16, height: u16) u32 {
    return @as(u32, width) * @as(u32, height);
}

pub fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}
