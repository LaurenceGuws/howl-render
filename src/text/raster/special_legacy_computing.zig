const std = @import("std");
const generated_special = @import("generated_special.zig");

const PointF = generated_special.PointF;
const Range = generated_special.Range;

pub fn rasterizeGeneratedEightBarAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    if (codepoint <= 0x1fb75) {
        rasterizeEightBarAlpha(pixels, width, height, @intCast(codepoint - 0x1fb6f), false);
    } else {
        rasterizeEightBarAlpha(pixels, width, height, @intCast(codepoint - 0x1fb75), true);
    }
}

pub fn rasterizeGeneratedSextantAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    const sextant = switch (codepoint) {
        0x1fb00...0x1fb13 => @as(u8, @intCast(codepoint - 0x1fb00 + 1)),
        0x1fb14...0x1fb27 => @as(u8, @intCast(codepoint - 0x1fb00 + 2)),
        0x1fb28...0x1fb3b => @as(u8, @intCast(codepoint - 0x1fb00 + 3)),
        else => unreachable,
    };
    rasterizeSextantAlpha(pixels, width, height, sextant);
}

pub fn rasterizeEightBarAlpha(pixels: []u8, width: u16, height: u16, which: u8, horizontal: bool) void {
    const x_range: Range = if (horizontal) .{ .start = 0, .end = width } else generated_special.eighthPartitionRange(width, @as(u16, which));
    const y_range: Range = if (horizontal) generated_special.eighthPartitionRange(height, @as(u16, which)) else .{ .start = 0, .end = height };
    if (x_range.end > x_range.start and y_range.end > y_range.start) {
        generated_special.fillRectAlpha(pixels, width, x_range.start, y_range.start, x_range.end - x_range.start, y_range.end - y_range.start, 255);
    }
}

pub fn rasterizeGeneratedOctantAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    const octant = generatedOctantPattern(codepoint) orelse unreachable;
    rasterizeOctantAlpha(pixels, width, height, octant);
}

pub fn generatedOctantPattern(codepoint: u32) ?u8 {
    return switch (codepoint) {
        0x1cd00...0x1cde5 => @intCast(codepoint - 0x1cd00),
        0x1fbe6 => 0xe6,
        0x1fbe7 => 0xe7,
        else => null,
    };
}

pub fn rasterizeGeneratedSmoothMosaicAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    const index = codepoint - 0x1fb3c;
    const lower = index < 0x16;
    const shape = if (lower) index else index - 0x16;
    const points = smoothMosaicPoints(@intCast(shape));
    drawSmoothMosaic(pixels, width, height, lower, points[0], points[1]);
}

pub fn smoothMosaicPoints(shape: u8) [2]PointF {
    const one_third = 1.0 / 3.0;
    const two_thirds = 2.0 / 3.0;
    return switch (shape) {
        0x00 => .{ .{ .x = 0.0, .y = two_thirds }, .{ .x = 0.5, .y = 1.0 } },
        0x01 => .{ .{ .x = 0.0, .y = two_thirds }, .{ .x = 1.0, .y = 1.0 } },
        0x02 => .{ .{ .x = 0.0, .y = one_third }, .{ .x = 0.5, .y = 1.0 } },
        0x03 => .{ .{ .x = 0.0, .y = one_third }, .{ .x = 1.0, .y = 1.0 } },
        0x04 => .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.5, .y = 1.0 } },
        0x05 => .{ .{ .x = 0.0, .y = one_third }, .{ .x = 0.5, .y = 0.0 } },
        0x06 => .{ .{ .x = 0.0, .y = one_third }, .{ .x = 1.0, .y = 0.0 } },
        0x07 => .{ .{ .x = 0.0, .y = two_thirds }, .{ .x = 0.5, .y = 0.0 } },
        0x08 => .{ .{ .x = 0.0, .y = two_thirds }, .{ .x = 1.0, .y = 0.0 } },
        0x09 => .{ .{ .x = 0.0, .y = 1.0 }, .{ .x = 0.5, .y = 0.0 } },
        0x0a => .{ .{ .x = 0.0, .y = two_thirds }, .{ .x = 1.0, .y = one_third } },
        0x0b => .{ .{ .x = 0.5, .y = 1.0 }, .{ .x = 1.0, .y = two_thirds } },
        0x0c => .{ .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = two_thirds } },
        0x0d => .{ .{ .x = 0.5, .y = 1.0 }, .{ .x = 1.0, .y = one_third } },
        0x0e => .{ .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = one_third } },
        0x0f => .{ .{ .x = 0.5, .y = 1.0 }, .{ .x = 1.0, .y = 0.0 } },
        0x10 => .{ .{ .x = 0.5, .y = 0.0 }, .{ .x = 1.0, .y = one_third } },
        0x11 => .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = one_third } },
        0x12 => .{ .{ .x = 0.5, .y = 0.0 }, .{ .x = 1.0, .y = two_thirds } },
        0x13 => .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = two_thirds } },
        0x14 => .{ .{ .x = 0.5, .y = 0.0 }, .{ .x = 1.0, .y = 1.0 } },
        0x15 => .{ .{ .x = 0.0, .y = one_third }, .{ .x = 1.0, .y = two_thirds } },
        else => unreachable,
    };
}

pub fn drawSmoothMosaic(pixels: []u8, width: u16, height: u16, lower: bool, a: PointF, b: PointF) void {
    const wx = @as(f64, @floatFromInt(width - 1));
    const hy = @as(f64, @floatFromInt(height - 1));
    const x0 = a.x * wx;
    const y0 = a.y * hy;
    const x1 = b.x * wx;
    const y1 = b.y * hy;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const yf = @as(f64, @floatFromInt(y));
            const edge_y = generated_special.lineY(x0, y0, x1, y1, @floatFromInt(x));
            if ((lower and yf >= edge_y) or (!lower and yf <= edge_y)) pixels[generated_special.pixelOffset(width, x, y)] = 255;
        }
    }
}

pub const SpriteEdge = enum { left, top, right, bottom };
pub const AlphaCorner = enum { top_left, top_right, bottom_left, bottom_right };

pub fn rasterizeGeneratedHalfTriangleAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    switch (codepoint) {
        0x1fb68 => drawHalfTriangle(pixels, width, height, .left, true),
        0x1fb69 => drawHalfTriangle(pixels, width, height, .top, true),
        0x1fb6a => drawHalfTriangle(pixels, width, height, .right, true),
        0x1fb6b => drawHalfTriangle(pixels, width, height, .bottom, true),
        0x1fb6c => drawHalfTriangle(pixels, width, height, .left, false),
        0x1fb6d => drawHalfTriangle(pixels, width, height, .right, false),
        0x1fb6e => drawHalfTriangle(pixels, width, height, .top, false),
        0x1fb6f => drawHalfTriangle(pixels, width, height, .bottom, false),
        else => unreachable,
    }
}

pub fn drawHalfTriangle(pixels: []u8, width: u16, height: u16, edge: SpriteEdge, inverted: bool) void {
    const wf = @as(f64, @floatFromInt(width - 1));
    const hf = @as(f64, @floatFromInt(height - 1));
    const mx = wf / 2.0;
    const my = hf / 2.0;
    if (inverted) generated_special.fillRectAlpha(pixels, width, 0, 0, width, height, 255);
    switch (edge) {
        .left => fillTriangleAlpha(pixels, width, height, .{ .x = 0.0, .y = 0.0 }, .{ .x = mx, .y = my }, .{ .x = 0.0, .y = hf }, 255),
        .right => fillTriangleAlpha(pixels, width, height, .{ .x = wf, .y = 0.0 }, .{ .x = mx, .y = my }, .{ .x = wf, .y = hf }, 255),
        .top => fillTriangleAlpha(pixels, width, height, .{ .x = 0.0, .y = 0.0 }, .{ .x = mx, .y = my }, .{ .x = wf, .y = 0.0 }, 255),
        .bottom => fillTriangleAlpha(pixels, width, height, .{ .x = 0.0, .y = hf }, .{ .x = mx, .y = my }, .{ .x = wf, .y = hf }, 255),
    }
}

pub fn rasterizeGeneratedEightBarCompositeAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    switch (codepoint) {
        0x1fb7c => {
            rasterizeEightBarAlpha(pixels, width, height, 0, false);
            rasterizeEightBarAlpha(pixels, width, height, 7, true);
        },
        0x1fb7d => {
            rasterizeEightBarAlpha(pixels, width, height, 0, false);
            rasterizeEightBarAlpha(pixels, width, height, 0, true);
        },
        0x1fb7e => {
            rasterizeEightBarAlpha(pixels, width, height, 7, false);
            rasterizeEightBarAlpha(pixels, width, height, 0, true);
        },
        0x1fb7f => {
            rasterizeEightBarAlpha(pixels, width, height, 7, false);
            rasterizeEightBarAlpha(pixels, width, height, 7, true);
        },
        0x1fb80 => {
            rasterizeEightBarAlpha(pixels, width, height, 0, true);
            rasterizeEightBarAlpha(pixels, width, height, 7, true);
        },
        0x1fb81 => for ([_]u8{ 0, 2, 4, 7 }) |bar| rasterizeEightBarAlpha(pixels, width, height, bar, true),
        0x1fb82...0x1fb86 => |cp| {
            var bar: u8 = 0;
            while (bar <= cp - 0x1fb81) : (bar += 1) rasterizeEightBarAlpha(pixels, width, height, bar, true);
        },
        0x1fb87...0x1fb8b => |cp| {
            var bar: u8 = @intCast(0x1fb8d - cp);
            while (bar < 8) : (bar += 1) rasterizeEightBarAlpha(pixels, width, height, bar, false);
        },
        else => unreachable,
    }
}

pub const SpriteShade = struct { light: bool = false, invert: bool = false, fill_blank: bool = false, half: ?SpriteEdge = null, xnum: u16, ynum: u16 = 0 };

pub fn rasterizeGeneratedShadeCornerCrossAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    switch (codepoint) {
        0x1fb8c => drawCheckerShade(pixels, width, height, .{ .xnum = 12, .light = true }),
        0x1fb8d => drawCheckerShade(pixels, width, height, .{ .xnum = 12, .light = true, .invert = true }),
        0x1fb8e => drawCheckerShade(pixels, width, height, .{ .xnum = 12, .light = true, .half = .left }),
        0x1fb8f => drawCheckerShade(pixels, width, height, .{ .xnum = 12, .light = true, .half = .right }),
        0x1fb90 => drawCheckerShade(pixels, width, height, .{ .xnum = 12, .light = true, .half = .top }),
        0x1fb91 => drawCheckerShade(pixels, width, height, .{ .xnum = 12, .light = true, .fill_blank = true, .half = .bottom }),
        0x1fb92 => drawCheckerShade(pixels, width, height, .{ .xnum = 12, .light = true, .fill_blank = true, .half = .top }),
        0x1fb93 => drawCheckerShade(pixels, width, height, .{ .xnum = 12, .invert = true, .fill_blank = true, .half = .left }),
        0x1fb94 => drawCheckerShade(pixels, width, height, .{ .xnum = 12, .invert = true, .fill_blank = true, .half = .right }),
        0x1fb95 => drawCheckerShade(pixels, width, height, .{ .xnum = 12, .invert = true, .fill_blank = true, .half = .top }),
        0x1fb96 => drawCheckerShade(pixels, width, height, .{ .xnum = 12, .invert = true, .fill_blank = true, .half = .bottom }),
        0x1fb97 => drawCheckerShade(pixels, width, height, .{ .xnum = 4, .ynum = 4 }),
        0x1fb98 => drawCrossShade(pixels, width, height, false),
        0x1fb99 => drawCrossShade(pixels, width, height, true),
        0x1fb9a => {
            drawHalfTriangle(pixels, width, height, .bottom, false);
            drawHalfTriangle(pixels, width, height, .top, false);
        },
        0x1fb9b => {
            drawHalfTriangle(pixels, width, height, .left, false);
            drawHalfTriangle(pixels, width, height, .right, false);
        },
        0x1fb9c => {
            drawCheckerShade(pixels, width, height, .{ .xnum = 12 });
            applyCornerMask(pixels, width, height, .top_left);
        },
        0x1fb9d => {
            drawCheckerShade(pixels, width, height, .{ .xnum = 12 });
            applyCornerMask(pixels, width, height, .top_right);
        },
        0x1fb9e => {
            drawCheckerShade(pixels, width, height, .{ .xnum = 12 });
            applyCornerMask(pixels, width, height, .bottom_right);
        },
        0x1fb9f => {
            drawCheckerShade(pixels, width, height, .{ .xnum = 12 });
            applyCornerMask(pixels, width, height, .bottom_left);
        },
        else => unreachable,
    }
}

pub fn drawCheckerShade(pixels: []u8, width: u16, height: u16, shade: SpriteShade) void {
    const square_width = @max(@as(u16, 1), width / shade.xnum);
    const square_height = @max(@as(u16, 1), if (shade.ynum != 0) height / shade.ynum else square_width);
    var number_of_rows = height / square_height;
    var number_of_cols = width / square_width;

    if (number_of_cols > 1 and ((number_of_cols & 1) != 0) != ((shade.xnum & 1) != 0)) number_of_cols -= 1;
    if (number_of_rows > 1 and ((number_of_rows & 1) != 0) != ((shade.ynum & 1) != 0)) number_of_rows -= 1;

    const excess_cols = width -| (square_width * number_of_cols);
    const excess_rows = height -| (square_height * number_of_rows);
    var square_width_extension = if (number_of_cols == 0) 0.0 else @as(f64, @floatFromInt(excess_cols)) / @as(f64, @floatFromInt(number_of_cols));
    var square_height_extension = if (number_of_rows == 0) 0.0 else @as(f64, @floatFromInt(excess_rows)) / @as(f64, @floatFromInt(number_of_rows));

    var rows_start: u16 = 0;
    var rows_end: u16 = number_of_rows;
    var cols_start: u16 = 0;
    var cols_end: u16 = number_of_cols;
    if (shade.half) |half| switch (half) {
        .top => {
            rows_end /= 2;
            square_height_extension *= 2.0;
        },
        .bottom => {
            rows_start = number_of_rows / 2;
            square_height_extension *= 2.0;
        },
        .left => {
            cols_end /= 2;
            square_width_extension *= 2.0;
        },
        .right => {
            cols_start = number_of_cols / 2;
            square_width_extension *= 2.0;
        },
    };

    var drawn_rows: u16 = 0;
    var old_ey: u16 = 0;
    var ey: u16 = 0;
    var row = rows_start;
    while (row < rows_end) : (row += 1) {
        old_ey = ey;
        ey = @intFromFloat(@ceil(@as(f64, @floatFromInt(drawn_rows)) * square_height_extension));
        const extra_row = ey != old_ey;
        drawn_rows += 1;

        var drawn_cols: u16 = 0;
        var old_ex: u16 = 0;
        var ex: u16 = 0;
        var col = cols_start;
        while (col < cols_end) : (col += 1) {
            old_ex = ex;
            ex = @intFromFloat(@ceil(@as(f64, @floatFromInt(drawn_cols)) * square_width_extension));
            const extra_col = ex != old_ex;
            drawn_cols += 1;

            if (extra_row) {
                const y = row * square_height + old_ey;
                const offset = @as(u32, y) * @as(u32, width);
                var xc: u16 = 0;
                while (xc < square_width) : (xc += 1) {
                    const x = col * square_width + xc + ex;
                    if (x >= width or y >= height) continue;
                    pixels[@intCast(offset + x)] = if (shade.light) blk: {
                        break :blk if (shade.invert) (if ((col & 1) != 0) 255 else 70) else (if ((col & 1) != 0) 0 else 70);
                    } else if (((col & 1) != 0) == shade.invert) 120 else 30;
                }
            }
            if (extra_col) {
                const x = col * square_width + old_ex;
                var yr: u16 = 0;
                while (yr < square_height) : (yr += 1) {
                    const y = row * square_height + yr + ey;
                    if (x >= width or y >= height) continue;
                    const offset = @as(u32, y) * @as(u32, width);
                    pixels[@intCast(offset + x)] = if (shade.light) blk: {
                        break :blk if (shade.invert) (if ((row & 1) != 0) 255 else 70) else (if ((row & 1) != 0) 0 else 70);
                    } else if (((row & 1) != 0) == shade.invert) 120 else 30;
                }
            }
            if (extra_row and extra_col) {
                const x = col * square_width + old_ex;
                const y = row * square_height + old_ey;
                if (x < width and y < height) pixels[@intCast(@as(u32, y) * @as(u32, width) + @as(u32, x))] = 50;
            }

            const blank = shade.invert ^ ((((row & 1) != 0) != ((col & 1) != 0)) or (shade.light and ((row & 1) != 0)));
            if (!blank) {
                var yr: u16 = 0;
                while (yr < square_height) : (yr += 1) {
                    const y = row * square_height + yr + ey;
                    if (y >= height) continue;
                    const offset = @as(u32, y) * @as(u32, width);
                    var xc: u16 = 0;
                    while (xc < square_width) : (xc += 1) {
                        const x = col * square_width + xc + ex;
                        if (x >= width) continue;
                        pixels[@intCast(offset + x)] = 255;
                    }
                }
            }
        }
    }

    if (!shade.fill_blank) return;
    var rs: u16 = 0;
    var re: u16 = height;
    var cs: u16 = 0;
    var ce: u16 = width;
    if (shade.half) |half| switch (half) {
        .bottom => re = height / 2,
        .top => rs = generated_special.saturatingSubU16(height / 2, 1),
        .right => ce = width / 2,
        .left => cs = generated_special.saturatingSubU16(width / 2, 1),
    };
    var y: u16 = rs;
    while (y < re) : (y += 1) {
        const offset = @as(u32, y) * @as(u32, width);
        var x: u16 = cs;
        while (x < ce) : (x += 1) pixels[@intCast(offset + x)] = 255;
    }
}

pub fn drawCrossShade(pixels: []u8, width: u16, height: u16, rotate: bool) void {
    const line_thickness = @max(@as(u16, 1), width / 7);
    const delta = line_thickness * 2;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const band = if (rotate) (x + y) % delta else (y + width - x) % delta;
            if (band < line_thickness) pixels[generated_special.pixelOffset(width, x, y)] = 255;
        }
    }
}

pub fn applyCornerMask(pixels: []u8, width: u16, height: u16, corner: AlphaCorner) void {
    const wf: f64 = @floatFromInt(width - 1);
    const hf: f64 = @floatFromInt(height - 1);
    const vertices = switch (corner) {
        .top_left => .{ PointF{ .x = 0, .y = 0 }, PointF{ .x = wf, .y = 0 }, PointF{ .x = 0, .y = hf } },
        .top_right => .{ PointF{ .x = wf, .y = 0 }, PointF{ .x = wf, .y = hf }, PointF{ .x = 0, .y = 0 } },
        .bottom_right => .{ PointF{ .x = wf, .y = hf }, PointF{ .x = wf, .y = 0 }, PointF{ .x = 0, .y = hf } },
        .bottom_left => .{ PointF{ .x = 0, .y = hf }, PointF{ .x = wf, .y = hf }, PointF{ .x = 0, .y = 0 } },
    };
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const p = PointF{ .x = @as(f64, @floatFromInt(x)) + 0.5, .y = @as(f64, @floatFromInt(y)) + 0.5 };
            if (!pointInTriangle(p, vertices[0], vertices[1], vertices[2])) pixels[generated_special.pixelOffset(width, x, y)] = 0;
        }
    }
}

pub fn rasterizeGeneratedMidLineAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    const bits: u4 = @intCast(codepoint - 0x1fba0 + 1);
    const corners = [_]AlphaCorner{ .top_left, .top_right, .bottom_left, .bottom_right };
    for (corners, 0..) |corner, index| if ((bits & (@as(u4, 1) << @intCast(index))) != 0) drawMidLine(pixels, width, height, corner);
}

pub fn drawMidLine(pixels: []u8, width: u16, height: u16, corner: AlphaCorner) void {
    const line_width = @max(1.0, @as(f64, @floatFromInt(@max(1, @min(width, height) / 8))));
    const cx = @as(f64, @floatFromInt(width - 1)) / 2.0;
    const cy = @as(f64, @floatFromInt(height - 1)) / 2.0;
    const p0 = switch (corner) {
        .top_left, .bottom_left => PointF{ .x = 0.0, .y = cy },
        .top_right, .bottom_right => PointF{ .x = @floatFromInt(width - 1), .y = cy },
    };
    const p1 = switch (corner) {
        .top_left, .top_right => PointF{ .x = cx, .y = 0.0 },
        .bottom_left, .bottom_right => PointF{ .x = cx, .y = @floatFromInt(height - 1) },
    };
    drawSegmentStrokeAlpha(pixels, width, height, p0, p1, line_width);
}

pub fn rasterizeGeneratedBranchAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    switch (codepoint) {
        0xf5d0 => drawBranchLine(pixels, width, height, .hline),
        0xf5d1 => drawBranchLine(pixels, width, height, .vline),
        0xf5d2 => drawBranchLine(pixels, width, height, .fade_right),
        0xf5d3 => drawBranchLine(pixels, width, height, .fade_left),
        0xf5d4 => drawBranchLine(pixels, width, height, .fade_bottom),
        0xf5d5 => drawBranchLine(pixels, width, height, .fade_top),
        0xf5d6 => drawBranchArc(pixels, width, height, .bottom_right),
        0xf5d7 => drawBranchArc(pixels, width, height, .bottom_left),
        0xf5d8 => drawBranchArc(pixels, width, height, .top_right),
        0xf5d9 => drawBranchArc(pixels, width, height, .top_left),
        0xf5da => {
            drawBranchLine(pixels, width, height, .vline);
            drawBranchArc(pixels, width, height, .top_right);
        },
        0xf5db => {
            drawBranchLine(pixels, width, height, .vline);
            drawBranchArc(pixels, width, height, .bottom_right);
        },
        0xf5dc => {
            drawBranchArc(pixels, width, height, .top_right);
            drawBranchArc(pixels, width, height, .bottom_right);
        },
        0xf5dd => {
            drawBranchLine(pixels, width, height, .vline);
            drawBranchArc(pixels, width, height, .top_left);
        },
        0xf5de => {
            drawBranchLine(pixels, width, height, .vline);
            drawBranchArc(pixels, width, height, .bottom_left);
        },
        0xf5df => {
            drawBranchArc(pixels, width, height, .top_left);
            drawBranchArc(pixels, width, height, .bottom_left);
        },
        0xf5e0 => {
            drawBranchArc(pixels, width, height, .bottom_left);
            drawBranchLine(pixels, width, height, .hline);
        },
        0xf5e1 => {
            drawBranchArc(pixels, width, height, .bottom_right);
            drawBranchLine(pixels, width, height, .hline);
        },
        0xf5e2 => {
            drawBranchArc(pixels, width, height, .bottom_right);
            drawBranchArc(pixels, width, height, .bottom_left);
        },
        0xf5e3 => {
            drawBranchArc(pixels, width, height, .top_left);
            drawBranchLine(pixels, width, height, .hline);
        },
        0xf5e4 => {
            drawBranchArc(pixels, width, height, .top_right);
            drawBranchLine(pixels, width, height, .hline);
        },
        0xf5e5 => {
            drawBranchArc(pixels, width, height, .top_right);
            drawBranchArc(pixels, width, height, .top_left);
        },
        0xf5e6 => {
            drawBranchLine(pixels, width, height, .vline);
            drawBranchArc(pixels, width, height, .top_left);
            drawBranchArc(pixels, width, height, .top_right);
        },
        0xf5e7 => {
            drawBranchLine(pixels, width, height, .vline);
            drawBranchArc(pixels, width, height, .bottom_left);
            drawBranchArc(pixels, width, height, .bottom_right);
        },
        0xf5e8 => {
            drawBranchLine(pixels, width, height, .hline);
            drawBranchArc(pixels, width, height, .bottom_left);
            drawBranchArc(pixels, width, height, .top_left);
        },
        0xf5e9 => {
            drawBranchLine(pixels, width, height, .hline);
            drawBranchArc(pixels, width, height, .top_right);
            drawBranchArc(pixels, width, height, .bottom_right);
        },
        0xf5ea => {
            drawBranchLine(pixels, width, height, .vline);
            drawBranchArc(pixels, width, height, .top_left);
            drawBranchArc(pixels, width, height, .bottom_right);
        },
        0xf5eb => {
            drawBranchLine(pixels, width, height, .vline);
            drawBranchArc(pixels, width, height, .top_right);
            drawBranchArc(pixels, width, height, .bottom_left);
        },
        0xf5ec => {
            drawBranchLine(pixels, width, height, .hline);
            drawBranchArc(pixels, width, height, .top_left);
            drawBranchArc(pixels, width, height, .bottom_right);
        },
        0xf5ed => {
            drawBranchLine(pixels, width, height, .hline);
            drawBranchArc(pixels, width, height, .top_right);
            drawBranchArc(pixels, width, height, .bottom_left);
        },
        0xf5ee => drawBranchNode(pixels, width, height, .{ .filled = true }),
        0xf5ef => drawBranchNode(pixels, width, height, .{}),
        0xf5f0 => drawBranchNode(pixels, width, height, .{ .right = true, .filled = true }),
        0xf5f1 => drawBranchNode(pixels, width, height, .{ .right = true }),
        0xf5f2 => drawBranchNode(pixels, width, height, .{ .left = true, .filled = true }),
        0xf5f3 => drawBranchNode(pixels, width, height, .{ .left = true }),
        0xf5f4 => drawBranchNode(pixels, width, height, .{ .left = true, .right = true, .filled = true }),
        0xf5f5 => drawBranchNode(pixels, width, height, .{ .left = true, .right = true }),
        0xf5f6 => drawBranchNode(pixels, width, height, .{ .down = true, .filled = true }),
        0xf5f7 => drawBranchNode(pixels, width, height, .{ .down = true }),
        0xf5f8 => drawBranchNode(pixels, width, height, .{ .up = true, .filled = true }),
        0xf5f9 => drawBranchNode(pixels, width, height, .{ .up = true }),
        0xf5fa => drawBranchNode(pixels, width, height, .{ .up = true, .down = true, .filled = true }),
        0xf5fb => drawBranchNode(pixels, width, height, .{ .up = true, .down = true }),
        0xf5fc => drawBranchNode(pixels, width, height, .{ .right = true, .down = true, .filled = true }),
        0xf5fd => drawBranchNode(pixels, width, height, .{ .right = true, .down = true }),
        0xf5fe => drawBranchNode(pixels, width, height, .{ .left = true, .down = true, .filled = true }),
        0xf5ff => drawBranchNode(pixels, width, height, .{ .left = true, .down = true }),
        0xf600 => drawBranchNode(pixels, width, height, .{ .up = true, .right = true, .filled = true }),
        0xf601 => drawBranchNode(pixels, width, height, .{ .up = true, .right = true }),
        0xf602 => drawBranchNode(pixels, width, height, .{ .up = true, .left = true, .filled = true }),
        0xf603 => drawBranchNode(pixels, width, height, .{ .up = true, .left = true }),
        0xf604 => drawBranchNode(pixels, width, height, .{ .up = true, .down = true, .right = true, .filled = true }),
        0xf605 => drawBranchNode(pixels, width, height, .{ .up = true, .down = true, .right = true }),
        0xf606 => drawBranchNode(pixels, width, height, .{ .up = true, .down = true, .left = true, .filled = true }),
        0xf607 => drawBranchNode(pixels, width, height, .{ .up = true, .down = true, .left = true }),
        0xf608 => drawBranchNode(pixels, width, height, .{ .down = true, .left = true, .right = true, .filled = true }),
        0xf609 => drawBranchNode(pixels, width, height, .{ .down = true, .left = true, .right = true }),
        0xf60a => drawBranchNode(pixels, width, height, .{ .up = true, .left = true, .right = true, .filled = true }),
        0xf60b => drawBranchNode(pixels, width, height, .{ .up = true, .left = true, .right = true }),
        0xf60c => drawBranchNode(pixels, width, height, .{ .up = true, .down = true, .left = true, .right = true, .filled = true }),
        0xf60d => drawBranchNode(pixels, width, height, .{ .up = true, .down = true, .left = true, .right = true }),
        else => unreachable,
    }
}

pub const BranchNode = struct { up: bool = false, right: bool = false, down: bool = false, left: bool = false, filled: bool = false };
pub const BranchEdge = enum { hline, vline, fade_left, fade_right, fade_top, fade_bottom };

pub fn drawBranchNode(pixels: []u8, width: u16, height: u16, node: BranchNode) void {
    const thick_px: u16 = @max(1, @min(width, height) / 8);
    const float_width = @as(f64, @floatFromInt(width));
    const float_height = @as(f64, @floatFromInt(height));
    const float_thick = @as(f64, @floatFromInt(thick_px));
    const h_top = (height -| thick_px) / 2;
    const v_left = (width -| thick_px) / 2;
    const cx = @as(f64, @floatFromInt(v_left)) + float_thick / 2.0;
    const cy = @as(f64, @floatFromInt(h_top)) + float_thick / 2.0;
    const r = @min(@min(cx, cy), @min(float_width - cx, float_height - cy));

    if (node.up) generated_special.fillRectAlpha(pixels, width, v_left, 0, thick_px, @intFromFloat(@ceil(cy - r + float_thick / 2.0)), 255);
    if (node.right) generated_special.fillRectAlpha(pixels, width, @intFromFloat(@floor(cx + r - float_thick / 2.0)), h_top, width - @as(u16, @intFromFloat(@floor(cx + r - float_thick / 2.0))), thick_px, 255);
    if (node.down) generated_special.fillRectAlpha(pixels, width, v_left, @intFromFloat(@floor(cy + r - float_thick / 2.0)), thick_px, height - @as(u16, @intFromFloat(@floor(cy + r - float_thick / 2.0))), 255);
    if (node.left) generated_special.fillRectAlpha(pixels, width, 0, h_top, @intFromFloat(@ceil(cx - r + float_thick / 2.0)), thick_px, 255);

    drawCircleArcAlpha(pixels, width, height, float_thick, 0.0, 360.0);
    if (node.filled) fillCircleAlpha(pixels, width, height, cx, cy, r, 255);
}

pub fn drawBranchLine(pixels: []u8, width: u16, height: u16, edge: BranchEdge) void {
    const thick: u16 = @max(1, @min(width, height) / 8);
    switch (edge) {
        .hline => generated_special.fillRectAlpha(pixels, width, 0, (height -| thick) / 2, width, thick, 255),
        .vline => generated_special.fillRectAlpha(pixels, width, (width -| thick) / 2, 0, thick, height, 255),
        .fade_left, .fade_right, .fade_top, .fade_bottom => generated_special.fillRectAlpha(pixels, width, 0, (height -| thick) / 2, width, thick, 255),
    }
}

pub fn drawBranchArc(pixels: []u8, width: u16, height: u16, corner: AlphaCorner) void {
    const thick: f64 = @as(f64, @floatFromInt(@max(1, @min(width, height) / 8)));
    switch (corner) {
        .top_left => drawCircleArcAlpha(pixels, width, height, thick, 180.0, 270.0),
        .top_right => drawCircleArcAlpha(pixels, width, height, thick, 270.0, 360.0),
        .bottom_right => drawCircleArcAlpha(pixels, width, height, thick, 0.0, 90.0),
        .bottom_left => drawCircleArcAlpha(pixels, width, height, thick, 90.0, 180.0),
    }
}

pub fn fillTriangleAlpha(pixels: []u8, width: u16, height: u16, p0: PointF, p1: PointF, p2: PointF, alpha: u8) void {
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            if (pointInTriangle(.{ .x = @as(f64, @floatFromInt(x)) + 0.5, .y = @as(f64, @floatFromInt(y)) + 0.5 }, p0, p1, p2)) pixels[generated_special.pixelOffset(width, x, y)] = alpha;
        }
    }
}

pub fn pointInTriangle(point: PointF, a: PointF, b: PointF, c: PointF) bool {
    const area = triangleEdge(a, b, c);
    if (area == 0) return false;
    const w0 = triangleEdge(b, c, point);
    const w1 = triangleEdge(c, a, point);
    const w2 = triangleEdge(a, b, point);
    return if (area > 0) w0 >= 0 and w1 >= 0 and w2 >= 0 else w0 <= 0 and w1 <= 0 and w2 <= 0;
}

pub fn triangleEdge(a: PointF, b: PointF, c: PointF) f64 {
    return (c.x - a.x) * (b.y - a.y) - (c.y - a.y) * (b.x - a.x);
}

pub fn drawSegmentStrokeAlpha(pixels: []u8, width: u16, height: u16, p0: PointF, p1: PointF, thickness: f64) void {
    const half = thickness / 2.0;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const dist = distanceToSegment(@as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5, p0, p1);
            const coverage = std.math.clamp(half - dist + 0.5, 0.0, 1.0);
            if (coverage > 0.0) pixels[generated_special.pixelOffset(width, x, y)] = @intFromFloat(@round(coverage * 255.0));
        }
    }
}

pub fn distanceToSegment(px: f64, py: f64, a: PointF, b: PointF) f64 {
    const abx = b.x - a.x;
    const aby = b.y - a.y;
    const denom = abx * abx + aby * aby;
    if (denom == 0.0) return @sqrt((px - a.x) * (px - a.x) + (py - a.y) * (py - a.y));
    const t = std.math.clamp(((px - a.x) * abx + (py - a.y) * aby) / denom, 0.0, 1.0);
    const cx = a.x + t * abx;
    const cy = a.y + t * aby;
    return @sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
}

pub fn fillCircleAlpha(pixels: []u8, width: u16, height: u16, cx: f64, cy: f64, radius: f64, alpha: u8) void {
    const limit = radius * radius;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const dx = @as(f64, @floatFromInt(x)) - cx;
            const dy = @as(f64, @floatFromInt(y)) - cy;
            if (dx * dx + dy * dy <= limit) pixels[generated_special.pixelOffset(width, x, y)] = alpha;
        }
    }
}

pub fn drawCircleArcAlpha(pixels: []u8, width: u16, height: u16, line_width_px: f64, start_degrees: f64, end_degrees: f64) void {
    const cx = @as(f64, @floatFromInt(width)) / 2.0;
    const cy = @as(f64, @floatFromInt(height)) / 2.0;
    const radius = @max(0.0, @min(cx, cy) - (line_width_px / 2.0));
    const start = start_degrees * std.math.pi / 180.0;
    const end = end_degrees * std.math.pi / 180.0;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const dx = px - cx;
            const dy = py - cy;
            const dist = @sqrt(dx * dx + dy * dy);
            if (dist < radius - line_width_px or dist > radius + line_width_px) continue;
            const angle = std.math.atan2(dy, dx);
            const norm = if (angle < 0) angle + std.math.tau else angle;
            const in_arc = if (start <= end) norm >= start and norm <= end else norm >= start or norm <= end;
            if (in_arc) pixels[generated_special.pixelOffset(width, x, y)] = 255;
        }
    }
}

pub fn rasterizeOctantAlpha(pixels: []u8, width: u16, height: u16, which: u8) void {
    const mask = octantMask(which);
    if ((mask & 0x01) != 0) fillOctantSegment(pixels, width, height, 0, true);
    if ((mask & 0x02) != 0) fillOctantSegment(pixels, width, height, 1, true);
    if ((mask & 0x04) != 0) fillOctantSegment(pixels, width, height, 2, true);
    if ((mask & 0x08) != 0) fillOctantSegment(pixels, width, height, 3, true);
    if ((mask & 0x10) != 0) fillOctantSegment(pixels, width, height, 0, false);
    if ((mask & 0x20) != 0) fillOctantSegment(pixels, width, height, 1, false);
    if ((mask & 0x40) != 0) fillOctantSegment(pixels, width, height, 2, false);
    if ((mask & 0x80) != 0) fillOctantSegment(pixels, width, height, 3, false);
}

pub fn fillOctantSegment(pixels: []u8, width: u16, height: u16, which: u8, left: bool) void {
    const y_range = fourthRange(height, which);
    const x0: u16 = if (left) 0 else width / 2;
    const x1: u16 = if (left) width / 2 else width;
    if (x1 > x0 and y_range.end > y_range.start) generated_special.fillRectAlpha(pixels, width, x0, y_range.start, x1 - x0, y_range.end - y_range.start, 255);
}

pub fn fourthRange(size: u16, which: u8) Range {
    const thickness = @max(@as(u16, 1), size / 4);
    const block = thickness * 4;
    if (block == size) return .{ .start = thickness * which, .end = thickness * (@as(u16, which) + 1) };
    if (block > size) {
        const start = @min(@as(u16, which) * thickness, generated_special.saturatingSubU16(size, thickness));
        return .{ .start = start, .end = start + thickness };
    }

    var thicknesses = [_]u16{thickness} ** 4;
    var extra = size - block;
    const order = [_]u8{ 1, 2, 3, 0 };
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

pub fn octantMask(which: u8) u8 {
    const a: u8 = 1;
    const b: u8 = 2;
    const c: u8 = 4;
    const d: u8 = 8;
    const m: u8 = 16;
    const n: u8 = 32;
    const o: u8 = 64;
    const p: u8 = 128;
    const mapping = [_]u8{
        b,                 b | m,             a | b | m,         n,                 a | n,             a | m | n,
        b | n,             a | b | n,         b | m | n,         c,                 a | c,             c | m,
        a | c | m,         a | b | c,         b | c | m,         a | b | c | m,     c | n,             a | c | n,
        c | m | n,         a | c | m | n,     b | c | n,         a | b | c | n,     b | c | m | n,     a | b | c | m | n,
        o,                 a | o,             m | o,             a | m | o,         b | o,             a | b | o,
        b | m | o,         a | b | m | o,     a | n | o,         m | n | o,         a | m | n | o,     b | n | o,
        a | b | n | o,     b | m | n | o,     a | b | m | n | o, c | o,             a | c | o,         c | m | o,
        a | c | m | o,     b | c | o,         a | b | c | o,     b | c | m | o,     a | b | c | m | o, c | n | o,
        a | c | n | o,     c | m | n | o,     a | c | m | n | o, b | c | n | o,     a | b | c | n | o, b | c | m | n | o,
        a | d,             d | m,             a | d | m,         b | d,             a | b | d,         b | d | m,
        a | b | d | m,     d | n,             a | d | n,         d | m | n,         a | d | m | n,     b | d | n,
        a | b | d | n,     b | d | m | n,     a | b | d | m | n, a | c | d,         c | d | m,         a | c | d | m,
        b | c | d,         b | c | d | m,     a | b | c | d | m, c | d | n,         a | c | d | n,     a | c | d | m | n,
        b | c | d | n,     a | b | c | d | n, b | c | d | m | n, d | o,             a | d | o,         d | m | o,
        a | d | m | o,     b | d | o,         a | b | d | o,     b | d | m | o,     a | b | d | m | o, d | n | o,
        a | d | n | o,     d | m | n | o,     a | d | m | n | o, b | d | n | o,     a | b | d | n | o, b | d | m | n | o,
        ~(c | p),          c | d | o,         a | c | d | o,     c | d | m | o,     a | c | d | m | o, b | c | d | o,
        ~(m | n | p),      b | c | d | m | o, ~(n | p),          c | d | n | o,     a | c | d | n | o, c | d | m | n | o,
        ~(b | p),          b | c | d | n | o, ~(m | p),          ~(a | p),          ~p,                a | p,
        m | p,             a | m | p,         b | p,             a | b | p,         b | m | p,         a | b | m | p,
        n | p,             a | n | p,         m | n | p,         a | m | n | p,     b | n | p,         a | b | n | p,
        b | m | n | p,     ~(c | d | o),      c | p,             a | c | p,         c | m | p,         a | c | m | p,
        b | c | p,         a | b | c | p,     b | c | m | p,     ~(d | n | o),      c | n | p,         a | c | n | p,
        c | m | n | p,     ~(b | d | o),      b | c | n | p,     ~(d | m | o),      ~(a | d | o),      ~(d | o),
        a | o | p,         m | o | p,         a | m | o | p,     b | o | p,         b | m | o | p,     a | b | m | o | p,
        n | o | p,         a | n | o | p,     a | m | n | o | p, b | n | o | p,     a | b | n | o | p, b | m | n | o | p,
        c | o | p,         a | c | o | p,     c | m | o | p,     a | c | m | o | p, b | c | o | p,     a | b | c | o | p,
        b | c | m | o | p, ~(n | d),          c | n | o | p,     a | c | n | o | p, c | m | n | o | p, ~(b | d),
        b | c | n | o | p, ~(d | m),          ~(a | d),          ~d,                a | d | p,         d | m | p,
        a | d | m | p,     b | d | p,         a | b | d | p,     b | d | m | p,     a | b | d | m | p, d | n | p,
        a | d | n | p,     d | m | n | p,     a | d | m | n | p, b | d | n | p,     a | b | d | n | p, b | d | m | n | p,
        ~(c | o),          c | d | p,         a | c | d | p,     c | d | m | p,     a | c | d | m | p, b | c | d | p,
        a | b | c | d | p, b | c | d | m | p, ~(n | o),          c | d | n | p,     a | c | d | n | p, c | d | m | n | p,
        ~(b | o),          b | c | d | n | p, ~(m | o),          ~(a | o),          ~o,                d | o | p,
        a | d | o | p,     d | m | o | p,     a | d | m | o | p, b | d | o | p,     a | b | d | o | p, b | d | m | o | p,
        ~(c | n),          d | n | o | p,     a | d | n | o | p, d | m | n | o | p, ~(b | c),          b | d | n | o | p,
        ~(c | m),          ~(a | c),          ~c,                a | c | d | o | p, c | d | m | o | p, ~(b | n),
        b | c | d | o | p, ~(a | n),          ~n,                c | d | n | o | p, ~(b | m),          ~b,
        ~m,                ~a,                b | c,             n | o,
    };
    return mapping[which];
}

pub fn rasterizeSextantAlpha(pixels: []u8, width: u16, height: u16, which: u8) void {
    drawSextantRow(pixels, width, height, which % 4, 0);
    drawSextantRow(pixels, width, height, which / 4, 1);
    drawSextantRow(pixels, width, height, which / 16, 2);
}

pub fn drawSextantRow(pixels: []u8, width: u16, height: u16, row_bits: u8, row: u16) void {
    if ((row_bits & 1) != 0) fillSextantCell(pixels, width, height, row, 0);
    if ((row_bits & 2) != 0) fillSextantCell(pixels, width, height, row, 1);
}

pub fn fillSextantCell(pixels: []u8, width: u16, height: u16, row: u16, col: u16) void {
    const y0: u16 = @intCast(@as(u32, height) * @as(u32, row) / 3);
    const y1: u16 = @intCast(@as(u32, height) * @as(u32, row + 1) / 3);
    const x0: u16 = if (col == 0) 0 else width / 2;
    const x1: u16 = if (col == 0) width / 2 else width;
    if (x1 > x0 and y1 > y0) generated_special.fillRectAlpha(pixels, width, x0, y0, x1 - x0, y1 - y0, 255);
}
