const std = @import("std");
const fallback = @import("../../raster/fallback.zig");

const AlphaCorner = enum { top_left, top_right, bottom_left, bottom_right };
const Edge = enum { left, top, right, bottom };
const Range = struct { start: u16, end: u16 };
const PointF = struct { x: f64, y: f64 };

pub fn rasterizeSpecialSpriteAlpha(dst: []u8, width: u16, height: u16, codepoint: u32) void {
    const w = @max(width, 1);
    const h = @max(height, 1);
    switch (codepoint) {
        0xe0d6 => drawAlphaTriangle(dst, w, h, false, true),
        0xe0d7 => drawAlphaTriangle(dst, w, h, true, true),
        0xee00 => drawAlphaProgressBar(dst, w, h, .left, false),
        0xee01 => drawAlphaProgressBar(dst, w, h, .middle, false),
        0xee02 => drawAlphaProgressBar(dst, w, h, .right, false),
        0xee03 => drawAlphaProgressBar(dst, w, h, .left, true),
        0xee04 => drawAlphaProgressBar(dst, w, h, .middle, true),
        0xee05 => drawAlphaProgressBar(dst, w, h, .right, true),
        0xee06 => drawAlphaSpinner(dst, w, h, 235, 305),
        0xee07 => drawAlphaSpinner(dst, w, h, 270, 390),
        0xee08 => drawAlphaSpinner(dst, w, h, 315, 470),
        0xee09 => drawAlphaSpinner(dst, w, h, 360, 540),
        0xee0a => drawAlphaSpinner(dst, w, h, 80, 220),
        0xee0b => drawAlphaSpinner(dst, w, h, 170, 270),
        0x25cb => drawAlphaSpinner(dst, w, h, 0, 360),
        0x25c9 => drawAlphaFishEye(dst, w, h),
        0x25cf => drawAlphaFilledCircle(dst, w, h, 1.0, 0.0, false),
        0x25d6 => drawAlphaFilledD(dst, w, h, false),
        0x25d7 => drawAlphaFilledD(dst, w, h, true),
        0x25dc => drawAlphaSpinner(dst, w, h, 180, 270),
        0x25dd => drawAlphaSpinner(dst, w, h, 270, 360),
        0x25de => drawAlphaSpinner(dst, w, h, 360, 450),
        0x25df => drawAlphaSpinner(dst, w, h, 450, 540),
        0x25e0 => drawAlphaSpinner(dst, w, h, 180, 360),
        0x25e1 => drawAlphaSpinner(dst, w, h, 0, 180),
        0x25e2 => drawAlphaCornerTriangle(dst, w, h, .bottom_right),
        0x25e3 => drawAlphaCornerTriangle(dst, w, h, .bottom_left),
        0x25e4 => drawAlphaCornerTriangle(dst, w, h, .top_left),
        0x25e5 => drawAlphaCornerTriangle(dst, w, h, .top_right),
        0x1fb3c...0x1fb67 => drawAlphaSmoothMosaicCodepoint(dst, w, h, codepoint),
        0x1fb68...0x1fb6f => drawAlphaHalfTriangleCodepoint(dst, w, h, codepoint),
        0x1fb7c...0x1fb8b => drawAlphaEightBlockCodepoint(dst, w, h, codepoint),
        0x1fb8c => drawAlphaShade(dst, w, h, .{ .xnum = 12, .light = true }),
        0x1fb8d => drawAlphaShade(dst, w, h, .{ .xnum = 12, .light = true, .invert = true }),
        0x1fb8e => drawAlphaShade(dst, w, h, .{ .xnum = 12, .light = true, .which_half = .left }),
        0x1fb8f => drawAlphaShade(dst, w, h, .{ .xnum = 12, .light = true, .which_half = .right }),
        0x1fb90 => drawAlphaShade(dst, w, h, .{ .xnum = 12, .light = true, .which_half = .top }),
        0x1fb91 => drawAlphaShade(dst, w, h, .{ .xnum = 12, .light = true, .fill_blank = true, .which_half = .bottom }),
        0x1fb92 => drawAlphaShade(dst, w, h, .{ .xnum = 12, .light = true, .fill_blank = true, .which_half = .top }),
        0x1fb93 => drawAlphaShade(dst, w, h, .{ .xnum = 12, .invert = true, .fill_blank = true, .which_half = .left }),
        0x1fb94 => drawAlphaShade(dst, w, h, .{ .xnum = 12, .invert = true, .fill_blank = true, .which_half = .right }),
        0x1fb95 => drawAlphaShade(dst, w, h, .{ .xnum = 12, .invert = true, .fill_blank = true, .which_half = .top }),
        0x1fb96 => drawAlphaShade(dst, w, h, .{ .xnum = 12, .invert = true, .fill_blank = true, .which_half = .bottom }),
        0x1fb97 => drawAlphaShade(dst, w, h, .{ .xnum = 4, .ynum = 4 }),
        0x1fb98 => drawAlphaCrossShade(dst, w, h, false),
        0x1fb99 => drawAlphaCrossShade(dst, w, h, true),
        0x1fb9a => {
            drawAlphaHalfTriangle(dst, w, h, .bottom, false);
            drawAlphaHalfTriangle(dst, w, h, .top, false);
        },
        0x1fb9b => {
            drawAlphaHalfTriangle(dst, w, h, .left, false);
            drawAlphaHalfTriangle(dst, w, h, .right, false);
        },
        0x1fb9c => {
            drawAlphaShade(dst, w, h, .{ .xnum = 12 });
            applyAlphaCornerMask(dst, w, h, .top_left);
        },
        0x1fb9d => {
            drawAlphaShade(dst, w, h, .{ .xnum = 12 });
            applyAlphaCornerMask(dst, w, h, .top_right);
        },
        0x1fb9e => {
            drawAlphaShade(dst, w, h, .{ .xnum = 12 });
            applyAlphaCornerMask(dst, w, h, .bottom_right);
        },
        0x1fb9f => {
            drawAlphaShade(dst, w, h, .{ .xnum = 12 });
            applyAlphaCornerMask(dst, w, h, .bottom_left);
        },
        0x1fba0...0x1fbae => drawAlphaMidLinesCodepoint(dst, w, h, codepoint),
        0xf5d0...0xf60d => drawAlphaBranchCodepoint(dst, w, h, codepoint),
        else => {},
    }
}

pub fn rasterizeFallbackGlyph(dst: []u8, cell_w: u16, cell_h: u16, codepoint: u21, gw: u16, gh: u16) void {
    fallback.rasterAsciiOrPlaceholder(dst, cell_w, codepoint, gw, gh);
    _ = cell_h;
}

fn drawAlphaRect(dst: []u8, stride: u16, x: u16, y: u16, width: u16, height: u16, alpha: u8) void {
    // Raster geometry stays typed until these final slice-bound checks and writes.
    const stride_index = @as(u32, stride);
    const x_index = @as(u32, x);
    const y_index = @as(u32, y);
    const width_index = @as(u32, width);
    const height_index = @as(u32, height);
    std.debug.assert(x_index + width_index <= stride_index);
    std.debug.assert((y_index + height_index) * stride_index <= dst.len);
    for (y..y + height) |yy| {
        const row = @as(u32, @intCast(yy)) * stride_index;
        for (x..x + width) |xx| dst[@intCast(row + @as(u32, @intCast(xx)))] = alpha;
    }
}
const ProgressSegment = enum { left, middle, right };

const Shade = struct {
    light: bool = false,
    invert: bool = false,
    fill_blank: bool = false,
    which_half: ?Edge = null,
    xnum: u16,
    ynum: u16 = 0,
};

fn drawAlphaShade(dst: []u8, w: u16, h: u16, s: Shade) void {
    const square_width = @max(@as(u16, 1), w / s.xnum);
    const square_height = @max(@as(u16, 1), if (s.ynum != 0) h / s.ynum else square_width);
    var number_of_rows = if (square_height == 0) @as(u16, 0) else h / square_height;
    var number_of_cols = if (square_width == 0) @as(u16, 0) else w / square_width;

    if (number_of_cols > 1 and isOdd(number_of_cols) != isOdd(s.xnum)) number_of_cols -= 1;
    if (number_of_rows > 1 and isOdd(number_of_rows) != isOdd(s.ynum)) number_of_rows -= 1;

    const excess_cols = w -| (square_width * number_of_cols);
    const excess_rows = h -| (square_height * number_of_rows);
    var square_width_extension = if (number_of_cols == 0) 0.0 else @as(f64, @floatFromInt(excess_cols)) / @as(f64, @floatFromInt(number_of_cols));
    var square_height_extension = if (number_of_rows == 0) 0.0 else @as(f64, @floatFromInt(excess_rows)) / @as(f64, @floatFromInt(number_of_rows));

    var rows_start: u16 = 0;
    var rows_end: u16 = number_of_rows;
    var cols_start: u16 = 0;
    var cols_end: u16 = number_of_cols;
    if (s.which_half) |half| switch (half) {
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
    var r = rows_start;
    while (r < rows_end) : (r += 1) {
        old_ey = ey;
        ey = @intFromFloat(@ceil(@as(f64, @floatFromInt(drawn_rows)) * square_height_extension));
        const extra_row = ey != old_ey;
        drawn_rows += 1;

        var drawn_cols: u16 = 0;
        var old_ex: u16 = 0;
        var ex: u16 = 0;
        var c = cols_start;
        while (c < cols_end) : (c += 1) {
            old_ex = ex;
            ex = @intFromFloat(@ceil(@as(f64, @floatFromInt(drawn_cols)) * square_width_extension));
            const extra_col = ex != old_ex;
            drawn_cols += 1;

            if (extra_row) {
                const y = r * square_height + old_ey;
                const offset = @as(u32, y) * @as(u32, w);
                var xc: u16 = 0;
                while (xc < square_width) : (xc += 1) {
                    const x = c * square_width + xc + ex;
                    if (x >= w or y >= h) continue;
                    const p = offset + x;
                    dst[@intCast(p)] = if (s.light) blk: {
                        break :blk if (s.invert) (if (isOdd(c)) 255 else 70) else (if (isOdd(c)) 0 else 70);
                    } else if (isOdd(c) == s.invert) 120 else 30;
                }
            }
            if (extra_col) {
                const x = c * square_width + old_ex;
                var yr: u16 = 0;
                while (yr < square_height) : (yr += 1) {
                    const y = r * square_height + yr + ey;
                    if (x >= w or y >= h) continue;
                    const offset = @as(u32, y) * @as(u32, w);
                    dst[@intCast(offset + x)] = if (s.light) blk: {
                        break :blk if (s.invert) (if (isOdd(r)) 255 else 70) else (if (isOdd(r)) 0 else 70);
                    } else if (isOdd(r) == s.invert) 120 else 30;
                }
            }
            if (extra_row and extra_col) {
                const x = c * square_width + old_ex;
                const y = r * square_height + old_ey;
                if (x < w and y < h) dst[@intCast(@as(u32, y) * @as(u32, w) + @as(u32, x))] = 50;
            }

            const is_blank = s.invert ^ ((isOdd(r) != isOdd(c)) or (s.light and isOdd(r)));
            if (!is_blank) {
                var yr: u16 = 0;
                while (yr < square_height) : (yr += 1) {
                    const y = r * square_height + yr + ey;
                    if (y >= h) continue;
                    const offset = @as(u32, y) * @as(u32, w);
                    var xc: u16 = 0;
                    while (xc < square_width) : (xc += 1) {
                        const x = c * square_width + xc + ex;
                        if (x >= w) continue;
                        dst[@intCast(offset + x)] = 255;
                    }
                }
            }
        }
    }

    if (!s.fill_blank) return;
    var rs: u16 = 0;
    var re: u16 = h;
    var cs: u16 = 0;
    var ce: u16 = w;
    if (s.which_half) |half| switch (half) {
        .bottom => re = h / 2,
        .top => rs = saturatingSubU16(h / 2, 1),
        .right => ce = w / 2,
        .left => cs = saturatingSubU16(w / 2, 1),
    };
    var y: u16 = rs;
    while (y < re) : (y += 1) {
        const offset = @as(u32, y) * @as(u32, w);
        var x: u16 = cs;
        while (x < ce) : (x += 1) dst[@intCast(offset + x)] = 255;
    }
}

fn drawAlphaCrossShade(dst: []u8, w: u16, h: u16, rotate: bool) void {
    const line_thickness = @max(@as(u16, 1), w / 7);
    const delta = line_thickness * 2;
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            const band = if (rotate) (x + y) % delta else (y + w - x) % delta;
            if (band >= line_thickness) continue;
            dst[@intCast(@as(u32, y) * @as(u32, w) + @as(u32, x))] = 255;
        }
    }
}

fn drawAlphaCornerTriangle(dst: []u8, w: u16, h: u16, corner: AlphaCorner) void {
    const wf = @as(f64, @floatFromInt(@as(u32, @max(w, 1)))) - 1.0;
    const hf = @as(f64, @floatFromInt(@as(u32, @max(h, 1)))) - 1.0;
    switch (corner) {
        .top_left => fillTriangle(dst, w, h, .{ .x = 0.0, .y = 0.0 }, .{ .x = wf, .y = 0.0 }, .{ .x = 0.0, .y = hf }),
        .top_right => fillTriangle(dst, w, h, .{ .x = wf, .y = 0.0 }, .{ .x = wf, .y = hf }, .{ .x = 0.0, .y = 0.0 }),
        .bottom_left => fillTriangle(dst, w, h, .{ .x = 0.0, .y = hf }, .{ .x = wf, .y = hf }, .{ .x = 0.0, .y = 0.0 }),
        .bottom_right => fillTriangle(dst, w, h, .{ .x = wf, .y = hf }, .{ .x = wf, .y = 0.0 }, .{ .x = 0.0, .y = hf }),
    }
}

fn drawAlphaHalfTriangle(dst: []u8, w: u16, h: u16, which: Edge, inverted: bool) void {
    const wf = @as(f64, @floatFromInt(@as(u32, @max(w, 1)))) - 1.0;
    const hf = @as(f64, @floatFromInt(@as(u32, @max(h, 1)))) - 1.0;
    const mx = wf / 2.0;
    const my = hf / 2.0;
    if (inverted) {
        drawAlphaRect(dst, w, 0, 0, w, h, 255);
    }
    switch (which) {
        .left => fillTriangle(dst, w, h, .{ .x = 0.0, .y = 0.0 }, .{ .x = mx, .y = my }, .{ .x = 0.0, .y = hf }),
        .right => fillTriangle(dst, w, h, .{ .x = wf, .y = 0.0 }, .{ .x = mx, .y = my }, .{ .x = wf, .y = hf }),
        .top => fillTriangle(dst, w, h, .{ .x = 0.0, .y = 0.0 }, .{ .x = mx, .y = my }, .{ .x = wf, .y = 0.0 }),
        .bottom => fillTriangle(dst, w, h, .{ .x = 0.0, .y = hf }, .{ .x = mx, .y = my }, .{ .x = wf, .y = hf }),
    }
}

fn drawAlphaSmoothMosaic(dst: []u8, w: u16, h: u16, lower: bool, ax: f64, ay: f64, bx: f64, by: f64) void {
    const wx = @as(f64, @floatFromInt(@max(w, 1) - 1));
    const hy = @as(f64, @floatFromInt(@max(h, 1) - 1));
    const x0 = ax * wx;
    const y0 = ay * hy;
    const x1 = bx * wx;
    const y1 = by * hy;
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            const xf = @as(f64, @floatFromInt(x));
            const yf = @as(f64, @floatFromInt(y));
            const edge_y = lineY(x0, y0, x1, y1, xf);
            if ((lower and yf >= edge_y) or (!lower and yf <= edge_y)) dst[@intCast(@as(u32, y) * @as(u32, w) + @as(u32, x))] = 255;
        }
    }
}

fn drawAlphaSmoothMosaicCodepoint(dst: []u8, w: u16, h: u16, codepoint: u32) void {
    switch (codepoint) {
        0x1fb3c => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 2.0 / 3.0, 0.5, 1.0),
        0x1fb3d => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 2.0 / 3.0, 1.0, 1.0),
        0x1fb3e => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 1.0 / 3.0, 0.5, 1.0),
        0x1fb3f => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 1.0 / 3.0, 1.0, 1.0),
        0x1fb40 => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 0.0, 0.5, 1.0),
        0x1fb41 => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 1.0 / 3.0, 0.5, 0.0),
        0x1fb42 => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 1.0 / 3.0, 1.0, 0.0),
        0x1fb43 => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 2.0 / 3.0, 0.5, 0.0),
        0x1fb44 => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 2.0 / 3.0, 1.0, 0.0),
        0x1fb45 => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 1.0, 0.5, 0.0),
        0x1fb46 => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 2.0 / 3.0, 1.0, 1.0 / 3.0),
        0x1fb47 => drawAlphaSmoothMosaic(dst, w, h, true, 0.5, 1.0, 1.0, 2.0 / 3.0),
        0x1fb48 => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 1.0, 1.0, 2.0 / 3.0),
        0x1fb49 => drawAlphaSmoothMosaic(dst, w, h, true, 0.5, 1.0, 1.0, 1.0 / 3.0),
        0x1fb4a => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 1.0, 1.0, 1.0 / 3.0),
        0x1fb4b => drawAlphaSmoothMosaic(dst, w, h, true, 0.5, 1.0, 1.0, 0.0),
        0x1fb4c => drawAlphaSmoothMosaic(dst, w, h, true, 0.5, 0.0, 1.0, 1.0 / 3.0),
        0x1fb4d => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 0.0, 1.0, 1.0 / 3.0),
        0x1fb4e => drawAlphaSmoothMosaic(dst, w, h, true, 0.5, 0.0, 1.0, 2.0 / 3.0),
        0x1fb4f => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 0.0, 1.0, 2.0 / 3.0),
        0x1fb50 => drawAlphaSmoothMosaic(dst, w, h, true, 0.5, 0.0, 1.0, 1.0),
        0x1fb51 => drawAlphaSmoothMosaic(dst, w, h, true, 0.0, 1.0 / 3.0, 1.0, 2.0 / 3.0),
        0x1fb52 => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 2.0 / 3.0, 0.5, 1.0),
        0x1fb53 => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 2.0 / 3.0, 1.0, 1.0),
        0x1fb54 => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 1.0 / 3.0, 0.5, 1.0),
        0x1fb55 => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 1.0 / 3.0, 1.0, 1.0),
        0x1fb56 => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 0.0, 0.5, 1.0),
        0x1fb57 => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 1.0 / 3.0, 0.5, 0.0),
        0x1fb58 => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 1.0 / 3.0, 1.0, 0.0),
        0x1fb59 => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 2.0 / 3.0, 0.5, 0.0),
        0x1fb5a => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 2.0 / 3.0, 1.0, 0.0),
        0x1fb5b => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 1.0, 0.5, 0.0),
        0x1fb5c => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 2.0 / 3.0, 1.0, 1.0 / 3.0),
        0x1fb5d => drawAlphaSmoothMosaic(dst, w, h, false, 0.5, 1.0, 1.0, 2.0 / 3.0),
        0x1fb5e => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 1.0, 1.0, 2.0 / 3.0),
        0x1fb5f => drawAlphaSmoothMosaic(dst, w, h, false, 0.5, 1.0, 1.0, 1.0 / 3.0),
        0x1fb60 => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 1.0, 1.0, 1.0 / 3.0),
        0x1fb61 => drawAlphaSmoothMosaic(dst, w, h, false, 0.5, 1.0, 1.0, 0.0),
        0x1fb62 => drawAlphaSmoothMosaic(dst, w, h, false, 0.5, 0.0, 1.0, 1.0 / 3.0),
        0x1fb63 => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 0.0, 1.0, 1.0 / 3.0),
        0x1fb64 => drawAlphaSmoothMosaic(dst, w, h, false, 0.5, 0.0, 1.0, 2.0 / 3.0),
        0x1fb65 => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 0.0, 1.0, 2.0 / 3.0),
        0x1fb66 => drawAlphaSmoothMosaic(dst, w, h, false, 0.5, 0.0, 1.0, 1.0),
        0x1fb67 => drawAlphaSmoothMosaic(dst, w, h, false, 0.0, 1.0 / 3.0, 1.0, 2.0 / 3.0),
        else => {},
    }
}

fn drawAlphaHalfTriangleCodepoint(dst: []u8, w: u16, h: u16, codepoint: u32) void {
    switch (codepoint) {
        0x1fb68 => drawAlphaHalfTriangle(dst, w, h, .left, true),
        0x1fb69 => drawAlphaHalfTriangle(dst, w, h, .top, true),
        0x1fb6a => drawAlphaHalfTriangle(dst, w, h, .right, true),
        0x1fb6b => drawAlphaHalfTriangle(dst, w, h, .bottom, true),
        0x1fb6c => drawAlphaHalfTriangle(dst, w, h, .left, false),
        0x1fb6d => drawAlphaHalfTriangle(dst, w, h, .right, false),
        0x1fb6e => drawAlphaHalfTriangle(dst, w, h, .top, false),
        0x1fb6f => drawAlphaHalfTriangle(dst, w, h, .bottom, false),
        else => {},
    }
}

fn drawAlphaEightBlockCodepoint(dst: []u8, w: u16, h: u16, codepoint: u32) void {
    switch (codepoint) {
        0x1fb7c => {
            drawAlphaEightBar(dst, w, h, 0, false);
            drawAlphaEightBar(dst, w, h, 7, true);
        },
        0x1fb7d => {
            drawAlphaEightBar(dst, w, h, 0, false);
            drawAlphaEightBar(dst, w, h, 0, true);
        },
        0x1fb7e => {
            drawAlphaEightBar(dst, w, h, 7, false);
            drawAlphaEightBar(dst, w, h, 0, true);
        },
        0x1fb7f => {
            drawAlphaEightBar(dst, w, h, 7, false);
            drawAlphaEightBar(dst, w, h, 7, true);
        },
        0x1fb80 => {
            drawAlphaEightBar(dst, w, h, 0, true);
            drawAlphaEightBar(dst, w, h, 7, true);
        },
        0x1fb81 => {
            drawAlphaEightBar(dst, w, h, 0, true);
            drawAlphaEightBar(dst, w, h, 2, true);
            drawAlphaEightBar(dst, w, h, 4, true);
            drawAlphaEightBar(dst, w, h, 7, true);
        },
        0x1fb82 => {
            drawAlphaEightBar(dst, w, h, 0, true);
            drawAlphaEightBar(dst, w, h, 1, true);
        },
        0x1fb83 => {
            drawAlphaEightBar(dst, w, h, 0, true);
            drawAlphaEightBar(dst, w, h, 1, true);
            drawAlphaEightBar(dst, w, h, 2, true);
        },
        0x1fb84 => {
            drawAlphaEightBar(dst, w, h, 0, true);
            drawAlphaEightBar(dst, w, h, 1, true);
            drawAlphaEightBar(dst, w, h, 2, true);
            drawAlphaEightBar(dst, w, h, 3, true);
            drawAlphaEightBar(dst, w, h, 4, true);
        },
        0x1fb85 => {
            drawAlphaEightBar(dst, w, h, 0, true);
            drawAlphaEightBar(dst, w, h, 1, true);
            drawAlphaEightBar(dst, w, h, 2, true);
            drawAlphaEightBar(dst, w, h, 3, true);
            drawAlphaEightBar(dst, w, h, 4, true);
            drawAlphaEightBar(dst, w, h, 5, true);
        },
        0x1fb86 => {
            drawAlphaEightBar(dst, w, h, 0, true);
            drawAlphaEightBar(dst, w, h, 1, true);
            drawAlphaEightBar(dst, w, h, 2, true);
            drawAlphaEightBar(dst, w, h, 3, true);
            drawAlphaEightBar(dst, w, h, 4, true);
            drawAlphaEightBar(dst, w, h, 5, true);
            drawAlphaEightBar(dst, w, h, 6, true);
        },
        0x1fb87 => {
            drawAlphaEightBar(dst, w, h, 6, false);
            drawAlphaEightBar(dst, w, h, 7, false);
        },
        0x1fb88 => {
            drawAlphaEightBar(dst, w, h, 5, false);
            drawAlphaEightBar(dst, w, h, 6, false);
            drawAlphaEightBar(dst, w, h, 7, false);
        },
        0x1fb89 => {
            drawAlphaEightBar(dst, w, h, 3, false);
            drawAlphaEightBar(dst, w, h, 4, false);
            drawAlphaEightBar(dst, w, h, 5, false);
            drawAlphaEightBar(dst, w, h, 6, false);
            drawAlphaEightBar(dst, w, h, 7, false);
        },
        0x1fb8a => {
            drawAlphaEightBar(dst, w, h, 2, false);
            drawAlphaEightBar(dst, w, h, 3, false);
            drawAlphaEightBar(dst, w, h, 4, false);
            drawAlphaEightBar(dst, w, h, 5, false);
            drawAlphaEightBar(dst, w, h, 6, false);
            drawAlphaEightBar(dst, w, h, 7, false);
        },
        0x1fb8b => {
            drawAlphaEightBar(dst, w, h, 1, false);
            drawAlphaEightBar(dst, w, h, 2, false);
            drawAlphaEightBar(dst, w, h, 3, false);
            drawAlphaEightBar(dst, w, h, 4, false);
            drawAlphaEightBar(dst, w, h, 5, false);
            drawAlphaEightBar(dst, w, h, 6, false);
            drawAlphaEightBar(dst, w, h, 7, false);
        },
        else => {},
    }
}

fn drawAlphaMidLinesCodepoint(dst: []u8, w: u16, h: u16, codepoint: u32) void {
    switch (codepoint) {
        0x1fba0 => drawAlphaMidLines(dst, w, h, &.{.top_left}),
        0x1fba1 => drawAlphaMidLines(dst, w, h, &.{.top_right}),
        0x1fba2 => drawAlphaMidLines(dst, w, h, &.{.bottom_left}),
        0x1fba3 => drawAlphaMidLines(dst, w, h, &.{.bottom_right}),
        0x1fba4 => drawAlphaMidLines(dst, w, h, &.{ .top_left, .bottom_left }),
        0x1fba5 => drawAlphaMidLines(dst, w, h, &.{ .top_right, .bottom_right }),
        0x1fba6 => drawAlphaMidLines(dst, w, h, &.{ .bottom_right, .bottom_left }),
        0x1fba7 => drawAlphaMidLines(dst, w, h, &.{ .top_right, .top_left }),
        0x1fba8 => drawAlphaMidLines(dst, w, h, &.{ .bottom_right, .top_left }),
        0x1fba9 => drawAlphaMidLines(dst, w, h, &.{ .bottom_left, .top_right }),
        0x1fbaa => drawAlphaMidLines(dst, w, h, &.{ .bottom_left, .top_right, .bottom_right }),
        0x1fbab => drawAlphaMidLines(dst, w, h, &.{ .bottom_left, .top_left, .bottom_right }),
        0x1fbac => drawAlphaMidLines(dst, w, h, &.{ .top_right, .top_left, .bottom_right }),
        0x1fbad => drawAlphaMidLines(dst, w, h, &.{ .top_right, .top_left, .bottom_left }),
        0x1fbae => drawAlphaMidLines(dst, w, h, &.{ .top_right, .bottom_right, .top_left, .bottom_left }),
        else => {},
    }
}

fn drawAlphaBranchCodepoint(dst: []u8, w: u16, h: u16, codepoint: u32) void {
    switch (codepoint) {
        0xf5d0 => drawAlphaBranchLine(dst, w, h, .hline),
        0xf5d1 => drawAlphaBranchLine(dst, w, h, .vline),
        0xf5d2 => drawAlphaBranchLine(dst, w, h, .fade_right),
        0xf5d3 => drawAlphaBranchLine(dst, w, h, .fade_left),
        0xf5d4 => drawAlphaBranchLine(dst, w, h, .fade_bottom),
        0xf5d5 => drawAlphaBranchLine(dst, w, h, .fade_top),
        0xf5d6 => drawAlphaBranchArc(dst, w, h, .bottom_right),
        0xf5d7 => drawAlphaBranchArc(dst, w, h, .bottom_left),
        0xf5d8 => drawAlphaBranchArc(dst, w, h, .top_right),
        0xf5d9 => drawAlphaBranchArc(dst, w, h, .top_left),
        0xf5da => {
            drawAlphaBranchLine(dst, w, h, .vline);
            drawAlphaBranchArc(dst, w, h, .top_right);
        },
        0xf5db => {
            drawAlphaBranchLine(dst, w, h, .vline);
            drawAlphaBranchArc(dst, w, h, .bottom_right);
        },
        0xf5dc => {
            drawAlphaBranchArc(dst, w, h, .top_right);
            drawAlphaBranchArc(dst, w, h, .bottom_right);
        },
        0xf5dd => {
            drawAlphaBranchLine(dst, w, h, .vline);
            drawAlphaBranchArc(dst, w, h, .top_left);
        },
        0xf5de => {
            drawAlphaBranchLine(dst, w, h, .vline);
            drawAlphaBranchArc(dst, w, h, .bottom_left);
        },
        0xf5df => {
            drawAlphaBranchArc(dst, w, h, .top_left);
            drawAlphaBranchArc(dst, w, h, .bottom_left);
        },
        0xf5e0 => {
            drawAlphaBranchArc(dst, w, h, .bottom_left);
            drawAlphaBranchLine(dst, w, h, .hline);
        },
        0xf5e1 => {
            drawAlphaBranchArc(dst, w, h, .bottom_right);
            drawAlphaBranchLine(dst, w, h, .hline);
        },
        0xf5e2 => {
            drawAlphaBranchArc(dst, w, h, .bottom_right);
            drawAlphaBranchArc(dst, w, h, .bottom_left);
        },
        0xf5e3 => {
            drawAlphaBranchArc(dst, w, h, .top_left);
            drawAlphaBranchLine(dst, w, h, .hline);
        },
        0xf5e4 => {
            drawAlphaBranchArc(dst, w, h, .top_right);
            drawAlphaBranchLine(dst, w, h, .hline);
        },
        0xf5e5 => {
            drawAlphaBranchArc(dst, w, h, .top_right);
            drawAlphaBranchArc(dst, w, h, .top_left);
        },
        0xf5e6 => {
            drawAlphaBranchLine(dst, w, h, .vline);
            drawAlphaBranchArc(dst, w, h, .top_left);
            drawAlphaBranchArc(dst, w, h, .top_right);
        },
        0xf5e7 => {
            drawAlphaBranchLine(dst, w, h, .vline);
            drawAlphaBranchArc(dst, w, h, .bottom_left);
            drawAlphaBranchArc(dst, w, h, .bottom_right);
        },
        0xf5e8 => {
            drawAlphaBranchLine(dst, w, h, .hline);
            drawAlphaBranchArc(dst, w, h, .bottom_left);
            drawAlphaBranchArc(dst, w, h, .top_left);
        },
        0xf5e9 => {
            drawAlphaBranchLine(dst, w, h, .hline);
            drawAlphaBranchArc(dst, w, h, .top_right);
            drawAlphaBranchArc(dst, w, h, .bottom_right);
        },
        0xf5ea => {
            drawAlphaBranchLine(dst, w, h, .vline);
            drawAlphaBranchArc(dst, w, h, .top_left);
            drawAlphaBranchArc(dst, w, h, .bottom_right);
        },
        0xf5eb => {
            drawAlphaBranchLine(dst, w, h, .vline);
            drawAlphaBranchArc(dst, w, h, .top_right);
            drawAlphaBranchArc(dst, w, h, .bottom_left);
        },
        0xf5ec => {
            drawAlphaBranchLine(dst, w, h, .hline);
            drawAlphaBranchArc(dst, w, h, .top_left);
            drawAlphaBranchArc(dst, w, h, .bottom_right);
        },
        0xf5ed => {
            drawAlphaBranchLine(dst, w, h, .hline);
            drawAlphaBranchArc(dst, w, h, .top_right);
            drawAlphaBranchArc(dst, w, h, .bottom_left);
        },
        0xf5ee => drawAlphaBranchNode(dst, w, h, .{ .filled = true }),
        0xf5ef => drawAlphaBranchNode(dst, w, h, .{}),
        0xf5f0 => drawAlphaBranchNode(dst, w, h, .{ .right = true, .filled = true }),
        0xf5f1 => drawAlphaBranchNode(dst, w, h, .{ .right = true }),
        0xf5f2 => drawAlphaBranchNode(dst, w, h, .{ .left = true, .filled = true }),
        0xf5f3 => drawAlphaBranchNode(dst, w, h, .{ .left = true }),
        0xf5f4 => drawAlphaBranchNode(dst, w, h, .{ .left = true, .right = true, .filled = true }),
        0xf5f5 => drawAlphaBranchNode(dst, w, h, .{ .left = true, .right = true }),
        0xf5f6 => drawAlphaBranchNode(dst, w, h, .{ .down = true, .filled = true }),
        0xf5f7 => drawAlphaBranchNode(dst, w, h, .{ .down = true }),
        0xf5f8 => drawAlphaBranchNode(dst, w, h, .{ .up = true, .filled = true }),
        0xf5f9 => drawAlphaBranchNode(dst, w, h, .{ .up = true }),
        0xf5fa => drawAlphaBranchNode(dst, w, h, .{ .up = true, .down = true, .filled = true }),
        0xf5fb => drawAlphaBranchNode(dst, w, h, .{ .up = true, .down = true }),
        0xf5fc => drawAlphaBranchNode(dst, w, h, .{ .right = true, .down = true, .filled = true }),
        0xf5fd => drawAlphaBranchNode(dst, w, h, .{ .right = true, .down = true }),
        0xf5fe => drawAlphaBranchNode(dst, w, h, .{ .left = true, .down = true, .filled = true }),
        0xf5ff => drawAlphaBranchNode(dst, w, h, .{ .left = true, .down = true }),
        0xf600 => drawAlphaBranchNode(dst, w, h, .{ .up = true, .right = true, .filled = true }),
        0xf601 => drawAlphaBranchNode(dst, w, h, .{ .up = true, .right = true }),
        0xf602 => drawAlphaBranchNode(dst, w, h, .{ .up = true, .left = true, .filled = true }),
        0xf603 => drawAlphaBranchNode(dst, w, h, .{ .up = true, .left = true }),
        0xf604 => drawAlphaBranchNode(dst, w, h, .{ .up = true, .down = true, .right = true, .filled = true }),
        0xf605 => drawAlphaBranchNode(dst, w, h, .{ .up = true, .down = true, .right = true }),
        0xf606 => drawAlphaBranchNode(dst, w, h, .{ .up = true, .down = true, .left = true, .filled = true }),
        0xf607 => drawAlphaBranchNode(dst, w, h, .{ .up = true, .down = true, .left = true }),
        0xf608 => drawAlphaBranchNode(dst, w, h, .{ .down = true, .left = true, .right = true, .filled = true }),
        0xf609 => drawAlphaBranchNode(dst, w, h, .{ .down = true, .left = true, .right = true }),
        0xf60a => drawAlphaBranchNode(dst, w, h, .{ .up = true, .left = true, .right = true, .filled = true }),
        0xf60b => drawAlphaBranchNode(dst, w, h, .{ .up = true, .left = true, .right = true }),
        0xf60c => drawAlphaBranchNode(dst, w, h, .{ .up = true, .down = true, .left = true, .right = true, .filled = true }),
        0xf60d => drawAlphaBranchNode(dst, w, h, .{ .up = true, .down = true, .left = true, .right = true }),
        else => {},
    }
}

const BranchNode = struct {
    up: bool = false,
    right: bool = false,
    down: bool = false,
    left: bool = false,
    filled: bool = false,
};

const BranchEdge = enum { hline, vline, fade_left, fade_right, fade_top, fade_bottom };

fn drawAlphaBranchNode(dst: []u8, w: u16, h: u16, node: BranchNode) void {
    const thick_px: u16 = @max(1, @min(w, h) / 8);
    const float_width = @as(f64, @floatFromInt(w));
    const float_height = @as(f64, @floatFromInt(h));
    const float_thick = @as(f64, @floatFromInt(thick_px));
    const h_top = (h -| thick_px) / 2;
    const v_left = (w -| thick_px) / 2;
    const cx = @as(f64, @floatFromInt(v_left)) + float_thick / 2.0;
    const cy = @as(f64, @floatFromInt(h_top)) + float_thick / 2.0;
    const r = @min(@min(cx, cy), @min(float_width - cx, float_height - cy));

    if (node.up) drawAlphaRect(dst, w, v_left, 0, thick_px, @as(u16, @intFromFloat(@ceil(cy - r + float_thick / 2.0))), 255);
    if (node.right) drawAlphaRect(dst, w, @as(u16, @intFromFloat(@floor(cx + r - float_thick / 2.0))), h_top, w - @as(u16, @intFromFloat(@floor(cx + r - float_thick / 2.0))), thick_px, 255);
    if (node.down) drawAlphaRect(dst, w, v_left, @as(u16, @intFromFloat(@floor(cy + r - float_thick / 2.0))), thick_px, h - @as(u16, @intFromFloat(@floor(cy + r - float_thick / 2.0))), 255);
    if (node.left) drawAlphaRect(dst, w, 0, h_top, @as(u16, @intFromFloat(@ceil(cx - r + float_thick / 2.0))), thick_px, 255);

    drawAlphaCircle(dst, w, h, float_thick, 0.0, 360.0);
    if (node.filled) fillCircleOfRadius(dst, w, h, cx, cy, r, 255);
}

fn drawAlphaBranchLine(dst: []u8, w: u16, h: u16, which: BranchEdge) void {
    const thick: u16 = @max(1, @min(w, h) / 8);
    switch (which) {
        .hline => drawAlphaRect(dst, w, 0, (h -| thick) / 2, w, thick, 255),
        .vline => drawAlphaRect(dst, w, (w -| thick) / 2, 0, thick, h, 255),
        .fade_left, .fade_right, .fade_top, .fade_bottom => drawAlphaRect(dst, w, 0, (h -| thick) / 2, w, thick, 255),
    }
}

fn drawAlphaBranchArc(dst: []u8, w: u16, h: u16, corner: AlphaCorner) void {
    const thick: f64 = @as(f64, @floatFromInt(@max(1, @min(w, h) / 8)));
    switch (corner) {
        .top_left => drawAlphaCircle(dst, w, h, thick, 180.0, 270.0),
        .top_right => drawAlphaCircle(dst, w, h, thick, 270.0, 360.0),
        .bottom_right => drawAlphaCircle(dst, w, h, thick, 0.0, 90.0),
        .bottom_left => drawAlphaCircle(dst, w, h, thick, 90.0, 180.0),
    }
}

fn drawAlphaEightBar(dst: []u8, w: u16, h: u16, which: u8, horizontal: bool) void {
    const x_range = if (horizontal) Range{ .start = 0, .end = w } else eightRange(w, which);
    const y_range = if (horizontal) eightRange(h, which) else Range{ .start = 0, .end = h };
    if (x_range.end > x_range.start and y_range.end > y_range.start) drawAlphaRect(dst, w, x_range.start, y_range.start, x_range.end - x_range.start, y_range.end - y_range.start, 255);
}

fn drawAlphaCircle(dst: []u8, w: u16, h: u16, line_width_px: f64, start_degrees: f64, end_degrees: f64) void {
    const cx = @as(f64, @floatFromInt(w)) / 2.0;
    const cy = @as(f64, @floatFromInt(h)) / 2.0;
    const radius = @max(0.0, @min(cx, cy) - (line_width_px / 2.0));
    const start = start_degrees * std.math.pi / 180.0;
    const end = end_degrees * std.math.pi / 180.0;
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const dx = px - cx;
            const dy = py - cy;
            const dist = @sqrt(dx * dx + dy * dy);
            if (dist < radius - line_width_px or dist > radius + line_width_px) continue;
            const ang = std.math.atan2(dy, dx);
            const norm = if (ang < 0) ang + std.math.tau else ang;
            const in_arc = if (start <= end) norm >= start and norm <= end else norm >= start or norm <= end;
            if (in_arc) dst[@intCast(@as(u32, y) * @as(u32, w) + @as(u32, x))] = 255;
        }
    }
}

fn drawAlphaFilledCircle(dst: []u8, w: u16, h: u16, scale: f64, gap: f64, invert: bool) void {
    const cx = @as(f64, @floatFromInt(w)) / 2.0;
    const cy = @as(f64, @floatFromInt(h)) / 2.0;
    const radius = @as(f64, @floatFromInt(@min(w, h))) * scale / 2.0 - gap / 2.0;
    const fill: u8 = if (invert) 0 else 255;
    fillCircleOfRadius(dst, w, h, cx, cy, radius, fill);
}

fn drawAlphaFishEye(dst: []u8, w: u16, h: u16) void {
    const cx = @as(f64, @floatFromInt(w)) / 2.0;
    const cy = @as(f64, @floatFromInt(h)) / 2.0;
    const radius = @min(cx, cy);
    const central_radius = (2.0 / 3.0) * radius;
    fillCircleOfRadius(dst, w, h, cx, cy, central_radius, 255);
    const line_width = @max(1.0, (radius - central_radius) / 2.5);
    drawAlphaCircle(dst, w, h, line_width, 0.0, 360.0);
}

fn drawAlphaFilledD(dst: []u8, w: u16, h: u16, left: bool) void {
    const cx = @as(f64, @floatFromInt(w)) / 2.0;
    const cy = @as(f64, @floatFromInt(h)) / 2.0;
    const rx = cx;
    const ry = cy;
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const dy = (py - cy) / @max(ry, 1.0);
            if (@abs(dy) > 1.0) continue;
            const dx = @sqrt(@max(0.0, 1.0 - dy * dy)) * rx;
            const edge_x = if (left) cx + dx else cx - dx;
            if ((left and px <= edge_x) or (!left and px >= edge_x)) dst[@intCast(@as(u32, y) * @as(u32, w) + @as(u32, x))] = 255;
        }
    }
}

fn drawAlphaMidLines(dst: []u8, w: u16, h: u16, corners: []const AlphaCorner) void {
    const line_width = @max(1.0, @as(f64, @floatFromInt(@max(1, @min(w, h) / 8))));
    const cx = @as(f64, @floatFromInt(w -| 1)) / 2.0;
    const cy = @as(f64, @floatFromInt(h -| 1)) / 2.0;
    const l = PointF{ .x = 0.0, .y = cy };
    const t = PointF{ .x = cx, .y = 0.0 };
    const r = PointF{ .x = @as(f64, @floatFromInt(w -| 1)), .y = cy };
    const b = PointF{ .x = cx, .y = @as(f64, @floatFromInt(h -| 1)) };
    for (corners) |corner| {
        const p = switch (corner) {
            .top_left => .{ l, t },
            .top_right => .{ r, t },
            .bottom_left => .{ l, b },
            .bottom_right => .{ r, b },
        };
        drawAlphaSegmentStroke(dst, w, h, p[0], p[1], line_width);
    }
}

fn drawAlphaSegmentStroke(dst: []u8, w: u16, h: u16, p0: PointF, p1: PointF, thickness: f64) void {
    const half = thickness / 2.0;
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const dist = distanceToSegment(px, py, p0, p1);
            const coverage = std.math.clamp(half - dist + 0.5, 0.0, 1.0);
            if (coverage <= 0.0) continue;
            dst[@intCast(@as(u32, y) * @as(u32, w) + @as(u32, x))] = @intFromFloat(@round(coverage * 255.0));
        }
    }
}

fn distanceToSegment(px: f64, py: f64, a: PointF, b: PointF) f64 {
    const abx = b.x - a.x;
    const aby = b.y - a.y;
    const apx = px - a.x;
    const apy = py - a.y;
    const denom = abx * abx + aby * aby;
    if (denom == 0.0) return @sqrt(apx * apx + apy * apy);
    const t = std.math.clamp((apx * abx + apy * aby) / denom, 0.0, 1.0);
    const cx = a.x + t * abx;
    const cy = a.y + t * aby;
    const dx = px - cx;
    const dy = py - cy;
    return @sqrt(dx * dx + dy * dy);
}

fn fillCircleOfRadius(dst: []u8, w: u16, h: u16, cx: f64, cy: f64, radius: f64, alpha: u8) void {
    const limit = radius * radius;
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            const dx = @as(f64, @floatFromInt(x)) - cx;
            const dy = @as(f64, @floatFromInt(y)) - cy;
            if (dx * dx + dy * dy <= limit) dst[@intCast(@as(u32, y) * @as(u32, w) + @as(u32, x))] = alpha;
        }
    }
}

fn lineY(x0: f64, y0: f64, x1: f64, y1: f64, x: f64) f64 {
    const dx = x1 - x0;
    if (dx == 0.0) return @min(y0, y1);
    return y0 + (x - x0) * (y1 - y0) / dx;
}

fn eightRange(size: u16, which: u8) Range {
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

fn applyAlphaCornerMask(dst: []u8, w: u16, h: u16, corner: AlphaCorner) void {
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            const keep = switch (corner) {
                .top_left => insideTriangle(x, y, 0, 0, w -| 1, 0, 0, h -| 1),
                .top_right => insideTriangle(x, y, w -| 1, 0, w -| 1, h -| 1, 0, 0),
                .bottom_left => insideTriangle(x, y, 0, h -| 1, w -| 1, h -| 1, 0, 0),
                .bottom_right => insideTriangle(x, y, w -| 1, h -| 1, w -| 1, 0, 0, h -| 1),
            };
            if (!keep) dst[@intCast(@as(u32, y) * @as(u32, w) + @as(u32, x))] = 0;
        }
    }
}

fn insideTriangle(px: u16, py: u16, ax: u16, ay: u16, bx: u16, by: u16, cx: u16, cy: u16) bool {
    const p = PointF{ .x = @as(f64, @floatFromInt(px)) + 0.5, .y = @as(f64, @floatFromInt(py)) + 0.5 };
    const a = PointF{ .x = @as(f64, @floatFromInt(ax)), .y = @as(f64, @floatFromInt(ay)) };
    const b = PointF{ .x = @as(f64, @floatFromInt(bx)), .y = @as(f64, @floatFromInt(by)) };
    const c = PointF{ .x = @as(f64, @floatFromInt(cx)), .y = @as(f64, @floatFromInt(cy)) };
    const area = edge(a, b, c);
    if (area == 0) return false;
    const w0 = edge(b, c, p);
    const w1 = edge(c, a, p);
    const w2 = edge(a, b, p);
    return if (area > 0) w0 >= 0 and w1 >= 0 and w2 >= 0 else w0 <= 0 and w1 <= 0 and w2 <= 0;
}

fn drawAlphaTriangle(dst: []u8, w: u16, h: u16, left: bool, inverted: bool) void {
    _ = inverted;
    const x0: f64 = if (left) 0.0 else @as(f64, @floatFromInt(w - 1));
    const x1: f64 = if (left) @as(f64, @floatFromInt(w - 1)) else 0.0;
    const y1 = @as(f64, @floatFromInt(h - 1));
    const y2 = @as(f64, @floatFromInt(h / 2));
    const points = [_]PointF{
        .{ .x = x0, .y = 0.0 },
        .{ .x = x1, .y = y2 },
        .{ .x = x0, .y = y1 },
    };
    fillTriangle(dst, w, h, points[0], points[1], points[2]);
}

fn drawAlphaProgressBar(dst: []u8, w: u16, h: u16, segment: ProgressSegment, filled: bool) void {
    const th_h: u16 = @max(1, h / 8);
    const th_v: u16 = th_h;
    switch (segment) {
        .left => {
            drawAlphaRect(dst, w, 0, 0, @max(1, th_v + 1), h, 255);
            drawAlphaRect(dst, w, 0, 0, w, @max(1, th_h + 1), 255);
            drawAlphaRect(dst, w, 0, h - @max(1, th_h + 1), w, @max(1, th_h + 1), 255);
        },
        .middle => {
            drawAlphaRect(dst, w, 0, 0, w, @max(1, th_h + 1), 255);
            drawAlphaRect(dst, w, 0, h - @max(1, th_h + 1), w, @max(1, th_h + 1), 255);
        },
        .right => {
            drawAlphaRect(dst, w, w - @max(1, th_v + 1), 0, @max(1, th_v + 1), h, 255);
            drawAlphaRect(dst, w, 0, 0, w, @max(1, th_h + 1), 255);
            drawAlphaRect(dst, w, 0, h - @max(1, th_h + 1), w, @max(1, th_h + 1), 255);
        },
    }
    if (!filled) return;
    const x1: u16 = switch (segment) {
        .left => @min(@max(1, w / 3), w),
        .middle => 0,
        .right => 0,
    };
    const x2: u16 = switch (segment) {
        .left => w,
        .middle => w,
        .right => @max(1, w - @max(1, w / 3)),
    };
    const y1: u16 = @min(@max(1, h / 4), h);
    const y2: u16 = h - y1;
    if (x2 > x1 and y2 > y1) drawAlphaRect(dst, w, x1, y1, x2 - x1, y2 - y1, 255);
}

fn drawAlphaSpinner(dst: []u8, w: u16, h: u16, start_degrees: u16, end_degrees: u16) void {
    const cx = @as(f64, @floatFromInt(w)) / 2.0;
    const cy = @as(f64, @floatFromInt(h)) / 2.0;
    const line_width = @as(f64, @floatFromInt(@max(1, @min(w, h) / 8)));
    const radius = @max(0.0, @min(cx, cy) - (line_width / 2.0));
    const start = @as(f64, @floatFromInt(start_degrees)) * std.math.pi / 180.0;
    const end = @as(f64, @floatFromInt(end_degrees)) * std.math.pi / 180.0;
    for (0..h) |yy| {
        for (0..w) |xx| {
            const px = @as(f64, @floatFromInt(xx)) + 0.5;
            const py = @as(f64, @floatFromInt(yy)) + 0.5;
            const dx = px - cx;
            const dy = py - cy;
            const dist = @sqrt(dx * dx + dy * dy);
            if (dist < radius - line_width or dist > radius + line_width) continue;
            const ang = std.math.atan2(dy, dx);
            const norm = if (ang < 0) ang + std.math.tau else ang;
            const in_arc = if (start <= end) norm >= start and norm <= end else norm >= start or norm <= end;
            if (!in_arc) continue;
            const off = pixelOffset(w, @intCast(xx), @intCast(yy));
            dst[@intCast(off)] = 255;
        }
    }
}

fn isOdd(value: u16) bool {
    return (value & 1) != 0;
}

fn saturatingSubU16(a: u16, b: u16) u16 {
    return if (a > b) a - b else 0;
}

fn fillTriangle(dst: []u8, w: u16, h: u16, p0: PointF, p1: PointF, p2: PointF) void {
    const min_x = @as(u16, @intFromFloat(@max(0.0, @floor(@min(p0.x, @min(p1.x, p2.x))))));
    const max_x = @as(u16, @intFromFloat(@min(@as(f64, @floatFromInt(w - 1)), @ceil(@max(p0.x, @max(p1.x, p2.x))))));
    const min_y = @as(u16, @intFromFloat(@max(0.0, @floor(@min(p0.y, @min(p1.y, p2.y))))));
    const max_y = @as(u16, @intFromFloat(@min(@as(f64, @floatFromInt(h - 1)), @ceil(@max(p0.y, @max(p1.y, p2.y))))));
    const area = edge(p0, p1, p2);
    if (area == 0) return;
    for (min_y..max_y + 1) |yy| {
        for (min_x..max_x + 1) |xx| {
            const p = PointF{ .x = @as(f64, @floatFromInt(xx)) + 0.5, .y = @as(f64, @floatFromInt(yy)) + 0.5 };
            const w0 = edge(p1, p2, p);
            const w1 = edge(p2, p0, p);
            const w2 = edge(p0, p1, p);
            const inside = if (area > 0) w0 >= 0 and w1 >= 0 and w2 >= 0 else w0 <= 0 and w1 <= 0 and w2 <= 0;
            if (!inside) continue;
            dst[@intCast(pixelOffset(w, @intCast(xx), @intCast(yy)))] = 255;
        }
    }
}

fn edge(a: PointF, b: PointF, c: PointF) f64 {
    return (c.x - a.x) * (b.y - a.y) - (c.y - a.y) * (b.x - a.x);
}
// Rounded-sprite geometry stays typed until these final pixel-buffer index helpers.
fn pixelRowOffset(width: u16, y: u16) u32 {
    return @as(u32, width) * @as(u32, y);
}

fn pixelOffset(width: u16, x: u16, y: u16) u32 {
    return pixelRowOffset(width, y) + x;
}
