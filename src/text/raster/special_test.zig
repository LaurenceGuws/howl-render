const std = @import("std");

const contract = @import("../contract.zig");
const special_glyphs = @import("../classify/special_glyphs.zig");
const special = @import("special.zig");

const Range = struct { start: u16, end: u16 };
const RoundedCorner = enum { top_left, top_right, bottom_left, bottom_right };

test "undercurl raster request generates alpha mask" {
    const req = special.requestForUndercurl(.{ .value = 7 }, 24, 16, .{ .stroke_px = 2, .amplitude_px = 3, .period_px = 12, .y_px = 12 });
    const bytes = pixelCount(req.width_px, req.height_px);
    var pixels = [_]u8{0} ** (24 * 16);
    try std.testing.expectEqual(bytes, count32(pixels));
    special.rasterizeUndercurlAlpha(&pixels, req.width_px, req.height_px, req.decoration);
    const lit = countLit(&pixels);
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit < count32(pixels));
}

test "generated special support table matches rasterizer dispatch" {
    const RangeCase = struct { start: u32, end: u32 };
    const cases = [_]RangeCase{
        .{ .start = 0x2500, .end = 0x257f },
        .{ .start = 0x2580, .end = 0x259f },
        .{ .start = 0x2800, .end = 0x28ff },
        .{ .start = 0xe0b0, .end = 0xe0bf },
        .{ .start = 0x1fb70, .end = 0x1fb75 },
        .{ .start = 0x1fb76, .end = 0x1fb7b },
        .{ .start = 0x1fb00, .end = 0x1fb13 },
        .{ .start = 0x1fb14, .end = 0x1fb27 },
        .{ .start = 0x1fb28, .end = 0x1fb3b },
        .{ .start = 0x1cd00, .end = 0x1cde5 },
        .{ .start = 0x1fbe6, .end = 0x1fbe7 },
    };

    for (cases) |case| {
        var cp = case.start;
        while (cp <= case.end) : (cp += 1) {
            try std.testing.expect(special_glyphs.isGeneratedSpecialSupported(cp));
            var pixels = [_]u8{0} ** (12 * 18);
            try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, 12, 18, cp));
        }
    }

    try std.testing.expect(special_glyphs.isGeneratedSpecialSupported(0x1fb93));
    var pixels = [_]u8{0} ** (12 * 18);
    try std.testing.expect(!special.rasterizeGeneratedSpecialAlpha(&pixels, 12, 18, 0x1fb93));
    try std.testing.expect(!special.rasterizeGeneratedSpecialAlpha(&pixels, 12, 18, 0x1fbae));
}

test "generated special raster draws braille dots" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2801));
    var other = [_]u8{0} ** (width * height);
    try std.testing.expect(!special.rasterizeGeneratedSpecialAlpha(&other, width, height, 'A'));
    var top_left: u16 = 0;
    var bottom_right: u16 = 0;
    for (0..height) |yy| {
        for (0..width) |xx| {
            const x: u16 = @intCast(xx);
            const y: u16 = @intCast(yy);
            const alpha = pixels[pixelOffset(width, x, y)];
            if (alpha == 0) continue;
            if (x < width / 2 and y < height / 4) top_left += 1;
            if (x >= width / 2 and y >= height * 3 / 4) bottom_right += 1;
        }
    }
    try std.testing.expect(top_left > 0);
    try std.testing.expectEqual(@as(u16, 0), bottom_right);
}

test "generated braille preserves gaps at small cell sizes" {
    const width = 6;
    const height = 12;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x28ff));

    var blank_col = false;
    for (0..width) |xx| {
        const x: u16 = @intCast(xx);
        var lit = false;
        for (0..height) |yy| {
            if (pixels[pixelOffset(width, x, @intCast(yy))] != 0) lit = true;
        }
        if (!lit) blank_col = true;
    }
    var blank_row = false;
    for (0..height) |yy| {
        const y: u16 = @intCast(yy);
        var lit = false;
        for (0..width) |xx| {
            if (pixels[pixelOffset(width, @intCast(xx), y)] != 0) lit = true;
        }
        if (!lit) blank_row = true;
    }

    try std.testing.expect(blank_col);
    try std.testing.expect(blank_row);
}

test "generated braille uses antialiased dots when possible" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x28ff));
    try std.testing.expect(hasPartialAlpha(&pixels));
}

test "generated special raster draws powerline triangle" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0xe0b0));
    const lit = countLit(&pixels);
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit > count32(pixels) / 4);
    try std.testing.expect(pixels[0] < 128);
}

test "generated special raster draws powerline separator" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0xe0b1));
    const lit = countLit(&pixels);
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit < count32(pixels) / 2);
}

test "generated special raster draws cubic powerline D" {
    const width = 16;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0xe0b4));
    try std.testing.expect(pixels[(height / 2) * width] != 0);
    try std.testing.expect(pixels[(height / 2) * width + width - 2] != 0);
    try std.testing.expect(pixels[(height - 1) * width] != 0);
    try std.testing.expect(pixels[width - 1] < 255);
    try std.testing.expect(hasPartialAlpha(&pixels));
}

test "generated special raster draws stroked powerline D" {
    const width = 16;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0xe0b5));
    const lit = countLit(&pixels);
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit < count32(pixels) / 2);
}

test "generated special raster draws eighth block" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2581));
    var top_lit: u16 = 0;
    var bottom_lit: u16 = 0;
    for (0..height) |yy| {
        for (0..width) |xx| {
            const x: u16 = @intCast(xx);
            const y: u16 = @intCast(yy);
            if (pixels[pixelOffset(width, x, y)] == 0) continue;
            if (y < height / 2) top_lit += 1 else bottom_lit += 1;
        }
    }
    try std.testing.expectEqual(@as(u16, 0), top_lit);
    try std.testing.expect(bottom_lit > 0);
}

test "generated special raster draws quadrant block" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2598));
    try std.testing.expect(pixels[0] != 0);
    try std.testing.expectEqual(@as(u8, 0), pixels[width - 1]);
    try std.testing.expectEqual(@as(u8, 0), pixels[(height - 1) * width]);
}

test "generated special raster distributes eighth blocks" {
    const width = 10;
    const height = 8;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2595));
    var left_lit: u16 = 0;
    var right_lit: u16 = 0;
    for (0..height) |yy| {
        for (0..width) |xx| {
            const x: u16 = @intCast(xx);
            const y: u16 = @intCast(yy);
            if (pixels[pixelOffset(width, x, y)] == 0) continue;
            if (x < width - 1) left_lit += 1 else right_lit += 1;
        }
    }
    try std.testing.expectEqual(@as(u16, 0), left_lit);
    try std.testing.expectEqual(height, right_lit);
}

test "generated special raster uses uniform shade intensity" {
    const width = 13;
    const height = 13;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2592));
    for (pixels) |alpha| {
        try std.testing.expectEqual(@as(u8, 0x80), alpha);
    }
}

test "generated special raster draws sextants" {
    const width = 8;
    const height = 15;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x1fb00));
    var top_left: u16 = 0;
    var top_right: u16 = 0;
    var lower_rows: u16 = 0;
    for (0..height) |yy| {
        for (0..width) |xx| {
            const x: u16 = @intCast(xx);
            const y: u16 = @intCast(yy);
            if (pixels[pixelOffset(width, x, y)] == 0) continue;
            if (y < height / 3 and x < width / 2) top_left += 1;
            if (y < height / 3 and x >= width / 2) top_right += 1;
            if (y >= height / 3) lower_rows += 1;
        }
    }
    try std.testing.expect(top_left > 0);
    try std.testing.expectEqual(@as(u16, 0), top_right);
    try std.testing.expectEqual(@as(u16, 0), lower_rows);
}

test "generated special raster draws upper-range sextant mapping" {
    const width = 8;
    const height = 15;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x1fb14));
    var top_right: u16 = 0;
    var middle_rows: u16 = 0;
    var bottom_left: u16 = 0;
    var bottom_right: u16 = 0;
    for (0..height) |yy| {
        for (0..width) |xx| {
            const x: u16 = @intCast(xx);
            const y: u16 = @intCast(yy);
            if (pixels[pixelOffset(width, x, y)] == 0) continue;
            if (y < height / 3 and x >= width / 2) top_right += 1;
            if (y >= height / 3 and y < height * 2 / 3) middle_rows += 1;
            if (y >= height * 2 / 3 and x < width / 2) bottom_left += 1;
            if (y >= height * 2 / 3 and x >= width / 2) bottom_right += 1;
        }
    }
    try std.testing.expect(top_right > 0);
    try std.testing.expect(middle_rows > 0);
    try std.testing.expect(bottom_left > 0);
    try std.testing.expectEqual(@as(u16, 0), bottom_right);
}

test "generated special raster draws octants" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x1cd00));
    var top_left: u16 = 0;
    var rest: u16 = 0;
    for (0..height) |yy| {
        for (0..width) |xx| {
            const x: u16 = @intCast(xx);
            const y: u16 = @intCast(yy);
            if (pixels[pixelOffset(width, x, y)] == 0) continue;
            if (y >= height / 4 and y < height / 2 and x < width / 2) top_left += 1 else rest += 1;
        }
    }
    try std.testing.expect(top_left > 0);
    try std.testing.expectEqual(@as(u16, 0), rest);
}

test "generated special raster draws terminal octant aliases" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x1fbe6));
    var left_lit: u16 = 0;
    var right_lit: u16 = 0;
    for (0..height) |yy| {
        for (0..width) |xx| {
            const x: u16 = @intCast(xx);
            const y: u16 = @intCast(yy);
            if (pixels[pixelOffset(width, x, y)] == 0) continue;
            if (x < width / 2) left_lit += 1 else right_lit += 1;
        }
    }
    try std.testing.expect(left_lit > 0);
    try std.testing.expectEqual(@as(u16, 0), right_lit);
}

test "generated special raster draws box diagonal lines" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2571));
    const lit = countLit(&pixels);
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit < count32(pixels) / 2);
}

test "generated special raster draws double box lines" {
    const width = 12;
    const height = 18;
    var hline = [_]u8{0} ** (width * height);
    var vline = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&hline, width, height, 0x2550));
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&vline, width, height, 0x2551));

    var h_rows: u16 = 0;
    for (0..height) |yy| {
        const y: u16 = @intCast(yy);
        var row_lit = false;
        for (0..width) |xx| {
            if (hline[pixelOffset(width, @intCast(xx), y)] != 0) row_lit = true;
        }
        if (row_lit) h_rows += 1;
    }
    var v_cols: u16 = 0;
    for (0..width) |xx| {
        const x: u16 = @intCast(xx);
        var col_lit = false;
        for (0..height) |yy| {
            if (vline[pixelOffset(width, x, @intCast(yy))] != 0) col_lit = true;
        }
        if (col_lit) v_cols += 1;
    }

    try std.testing.expect(h_rows >= 2);
    try std.testing.expect(v_cols >= 2);
    try std.testing.expect(hline[(height / 2) * width + width / 2] == 0);
    try std.testing.expect(vline[(height / 2) * width + width / 2] == 0);
}

test "generated special raster draws dashed box lines" {
    const width = 18;
    const height = 18;
    var hline = [_]u8{0} ** (width * height);
    var vline = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&hline, width, height, 0x2504));
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&vline, width, height, 0x2506));

    var h_lit: u16 = 0;
    var h_blank: u16 = 0;
    const y = height / 2;
    for (0..width) |xx| {
        if (hline[pixelOffset(width, @intCast(xx), y)] != 0) h_lit += 1 else h_blank += 1;
    }
    var v_lit: u16 = 0;
    var v_blank: u16 = 0;
    const x = width / 2;
    for (0..height) |yy| {
        if (vline[pixelOffset(width, x, @intCast(yy))] != 0) v_lit += 1 else v_blank += 1;
    }

    try std.testing.expect(h_lit > 0 and h_blank > 0);
    try std.testing.expect(v_lit > 0 and v_blank > 0);
}

test "generated box connectors stop at stroke edges" {
    const width = 10;
    const height = 20;
    const box = contract.BoxDrawingRasterMetrics{ .light_stroke_px = 2, .heavy_stroke_px = 4 };
    const h = centeredRange(height, height / 2, box.light_stroke_px);
    const v = centeredRange(width, width / 2, box.light_stroke_px);

    var top_right = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlphaWithMetrics(&top_right, width, height, 0x2510, box));
    try std.testing.expectEqual(@as(u8, 255), top_right[pixelOffset(width, v.start - 1, h.start)]);
    try std.testing.expectEqual(@as(u8, 255), top_right[pixelOffset(width, v.start, h.start)]);
    try std.testing.expectEqual(@as(u8, 255), top_right[pixelOffset(width, v.end - 1, h.start)]);
    try std.testing.expectEqual(@as(u8, 0), top_right[pixelOffset(width, v.end, h.start)]);

    var bottom_left = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlphaWithMetrics(&bottom_left, width, height, 0x2514, box));
    try std.testing.expectEqual(@as(u8, 0), bottom_left[pixelOffset(width, v.start - 1, h.start)]);
    try std.testing.expectEqual(@as(u8, 255), bottom_left[pixelOffset(width, v.start, h.start)]);
    try std.testing.expectEqual(@as(u8, 255), bottom_left[pixelOffset(width, v.end, h.start)]);
}

test "generated tee connectors use centered light joins" {
    const width = 10;
    const height = 20;
    const box = contract.BoxDrawingRasterMetrics{ .light_stroke_px = 2, .heavy_stroke_px = 4 };
    const h = centeredRange(height, height / 2, box.light_stroke_px);
    const v = centeredRange(width, width / 2, box.light_stroke_px);

    var left_tee = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlphaWithMetrics(&left_tee, width, height, 0x251c, box));
    try std.testing.expectEqual(@as(u8, 0), left_tee[pixelOffset(width, v.start - 1, h.start)]);
    try std.testing.expectEqual(@as(u8, 255), left_tee[pixelOffset(width, v.end - 1, h.start)]);
    try std.testing.expectEqual(@as(u8, 255), left_tee[pixelOffset(width, width - 1, h.start)]);
    try std.testing.expectEqual(@as(u8, 255), left_tee[pixelOffset(width, v.start, h.start - 1)]);
    try std.testing.expectEqual(@as(u8, 255), left_tee[pixelOffset(width, v.start, h.end)]);

    var top_tee = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlphaWithMetrics(&top_tee, width, height, 0x252c, box));
    try std.testing.expectEqual(@as(u8, 255), top_tee[pixelOffset(width, v.start - 1, h.start)]);
    try std.testing.expectEqual(@as(u8, 255), top_tee[pixelOffset(width, v.end, h.start)]);
    try std.testing.expectEqual(@as(u8, 255), top_tee[pixelOffset(width, v.start, h.end)]);
    try std.testing.expectEqual(@as(u8, 0), top_tee[pixelOffset(width, v.start, h.start - 1)]);
}

test "generated special raster draws rounded box corners" {
    const width = 18;
    const height = 18;
    const Case = struct {
        cp: u32,
        corner: RoundedCorner,
    };
    const cases = [_]Case{
        .{ .cp = 0x256d, .corner = .top_left },
        .{ .cp = 0x256e, .corner = .top_right },
        .{ .cp = 0x2570, .corner = .bottom_left },
        .{ .cp = 0x256f, .corner = .bottom_right },
    };

    for (cases) |case| {
        var pixels = [_]u8{0} ** (width * height);
        try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, case.cp));
        var lit: u32 = 0;
        var expected_quadrant: u16 = 0;
        var wrong_outer_quadrant: u16 = 0;
        for (0..height) |yy| {
            for (0..width) |xx| {
                const x: u16 = @intCast(xx);
                const y: u16 = @intCast(yy);
                const alpha = pixels[pixelOffset(width, x, y)];
                if (alpha == 0) continue;
                lit += 1;

                const expected = switch (case.corner) {
                    .top_left => x >= width / 2 and y >= height / 2,
                    .top_right => x < width / 2 and y >= height / 2,
                    .bottom_left => x >= width / 2 and y < height / 2,
                    .bottom_right => x < width / 2 and y < height / 2,
                };
                if (expected) expected_quadrant += 1;

                const wrong_outer = switch (case.corner) {
                    .top_left => x < width / 2 and y < height / 2,
                    .top_right => x >= width / 2 and y < height / 2,
                    .bottom_left => x < width / 2 and y >= height / 2,
                    .bottom_right => x >= width / 2 and y >= height / 2,
                };
                if (wrong_outer) wrong_outer_quadrant += 1;
            }
        }

        try std.testing.expect(lit > 0);
        try std.testing.expect(lit < count32(pixels) / 2);
        try std.testing.expect(hasPartialAlpha(&pixels));
        try std.testing.expect(expected_quadrant > 0);
        try std.testing.expectEqual(@as(u16, 0), wrong_outer_quadrant);
    }
}

test "generated rounded corners align with straight box arms" {
    const width = 10;
    const height = 20;
    const box = contract.BoxDrawingRasterMetrics{ .light_stroke_px = 2, .heavy_stroke_px = 4 };
    var corner = [_]u8{0} ** (width * height);
    var hline = [_]u8{0} ** (width * height);
    var vline = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlphaWithMetrics(&corner, width, height, 0x256d, box));
    try std.testing.expect(special.rasterizeGeneratedSpecialAlphaWithMetrics(&hline, width, height, 0x2500, box));
    try std.testing.expect(special.rasterizeGeneratedSpecialAlphaWithMetrics(&vline, width, height, 0x2502, box));

    var corner_h_rows: u16 = 0;
    var hline_rows: u16 = 0;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        if (corner[pixelOffset(width, width - 1, y)] != 0) corner_h_rows += 1;
        if (hline[pixelOffset(width, width - 1, y)] != 0) hline_rows += 1;
    }

    var corner_v_cols: u16 = 0;
    var vline_cols: u16 = 0;
    var x: u16 = 0;
    while (x < width) : (x += 1) {
        if (corner[pixelOffset(width, x, height - 1)] != 0) corner_v_cols += 1;
        if (vline[pixelOffset(width, x, height - 1)] != 0) vline_cols += 1;
    }

    try std.testing.expectEqual(hline_rows, corner_h_rows);
    try std.testing.expectEqual(vline_cols, corner_v_cols);
}

test "generated rounded corners honor box drawing thickness" {
    const width = 24;
    const height = 24;
    var thin = [_]u8{0} ** (width * height);
    var thick = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlphaWithMetrics(&thin, width, height, 0x256d, .{ .light_stroke_px = 1, .heavy_stroke_px = 2 }));
    try std.testing.expect(special.rasterizeGeneratedSpecialAlphaWithMetrics(&thick, width, height, 0x256d, .{ .light_stroke_px = 4, .heavy_stroke_px = 8 }));

    const thin_lit = countLit(&thin);
    const thick_lit = countLit(&thick);
    try std.testing.expect(thick_lit > thin_lit * 2);
}

test "generated special raster draws box crossing diagonals" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2573));
    try std.testing.expect(pixels[(height / 2) * width + width / 2] != 0);
    try std.testing.expect(countLit(&pixels) > @as(u32, width));
}

test "generated special raster draws powerline diagonal aliases" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(special.rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0xe0b9));
    const lit = countLit(&pixels);
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit < count32(pixels) / 2);
}

fn centeredRange(size: u16, center: u16, thickness: u16) Range {
    const start = saturatingSubU16(center, thickness / 2);
    return .{ .start = start, .end = @min(start + thickness, size) };
}

fn pixelOffset(width: u16, x: u16, y: u16) u32 {
    return @as(u32, width) * @as(u32, y) + x;
}

fn pixelCount(width: u16, height: u16) u32 {
    return @as(u32, width) * @as(u32, height);
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

fn countLit(pixels: []const u8) u32 {
    var lit: u32 = 0;
    for (pixels) |alpha| {
        if (alpha != 0) lit += 1;
    }
    return lit;
}

fn hasPartialAlpha(pixels: []const u8) bool {
    for (pixels) |alpha| {
        if (alpha > 0 and alpha < 255) return true;
    }
    return false;
}

fn saturatingSubU16(value: u16, delta: u16) u16 {
    return if (value > delta) value - delta else 0;
}
