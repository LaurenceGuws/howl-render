const generated_special = @import("generated_special.zig");

pub fn rasterizeGeneratedBlockAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    switch (codepoint) {
        0x2580...0x259f => rasterizeBlockElementAlpha(pixels, width, height, codepoint),
        0x2800...0x28ff => rasterizeBrailleAlpha(pixels, width, height, @intCast(codepoint - 0x2800)),
        else => unreachable,
    }
}

fn rasterizeBlockElementAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    switch (codepoint) {
        0x2580 => fillRows(pixels, width, height, 0, 4),
        0x2581...0x2587 => |block| fillRows(pixels, width, height, @intCast(0x2588 - block), 8),
        0x2588 => generated_special.fillRectAlpha(pixels, width, 0, 0, width, height, 255),
        0x2589...0x258f => |block| fillCols(pixels, width, height, 0, @intCast(0x2590 - block)),
        0x2590 => fillCols(pixels, width, height, 4, 8),
        0x2591 => fillShade(pixels, width, height, .light),
        0x2592 => fillShade(pixels, width, height, .medium),
        0x2593 => fillShade(pixels, width, height, .dark),
        0x2594 => fillRows(pixels, width, height, 0, 1),
        0x2595 => fillCols(pixels, width, height, 7, 8),
        0x2596 => fillQuadrant(pixels, width, height, .bottom_left),
        0x2597 => fillQuadrant(pixels, width, height, .bottom_right),
        0x2598 => fillQuadrant(pixels, width, height, .top_left),
        0x2599 => fillQuadrants(pixels, width, height, &.{ .top_left, .bottom_left, .bottom_right }),
        0x259a => fillQuadrants(pixels, width, height, &.{ .top_left, .bottom_right }),
        0x259b => fillQuadrants(pixels, width, height, &.{ .top_left, .top_right, .bottom_left }),
        0x259c => fillQuadrants(pixels, width, height, &.{ .top_left, .top_right, .bottom_right }),
        0x259d => fillQuadrant(pixels, width, height, .top_right),
        0x259e => fillQuadrants(pixels, width, height, &.{ .top_right, .bottom_left }),
        0x259f => fillQuadrants(pixels, width, height, &.{ .top_right, .bottom_left, .bottom_right }),
        else => {},
    }
}

fn fillRows(pixels: []u8, width: u16, height: u16, start_eighth: u16, end_eighth: u16) void {
    var eighth = start_eighth;
    while (eighth < end_eighth) : (eighth += 1) {
        const range = generated_special.eighthPartitionRange(height, eighth);
        if (range.end > range.start) generated_special.fillRectAlpha(pixels, width, 0, range.start, width, range.end - range.start, 255);
    }
}

fn fillCols(pixels: []u8, width: u16, height: u16, start_eighth: u16, end_eighth: u16) void {
    var eighth = start_eighth;
    while (eighth < end_eighth) : (eighth += 1) {
        const range = generated_special.eighthPartitionRange(width, eighth);
        if (range.end > range.start) generated_special.fillRectAlpha(pixels, width, range.start, 0, range.end - range.start, height, 255);
    }
}

const BlockQuadrant = enum { top_left, top_right, bottom_left, bottom_right };

fn fillQuadrants(pixels: []u8, width: u16, height: u16, quadrants: []const BlockQuadrant) void {
    for (quadrants) |quadrant| fillQuadrant(pixels, width, height, quadrant);
}

fn fillQuadrant(pixels: []u8, width: u16, height: u16, quadrant: BlockQuadrant) void {
    const half_w = width / 2;
    const half_h = height / 2;
    const x = switch (quadrant) {
        .top_left, .bottom_left => 0,
        .top_right, .bottom_right => half_w,
    };
    const y = switch (quadrant) {
        .top_left, .top_right => 0,
        .bottom_left, .bottom_right => half_h,
    };
    generated_special.fillRectAlpha(pixels, width, x, y, width - x - if (x == 0) width - half_w else 0, height - y - if (y == 0) height - half_h else 0, 255);
}

const ShadeDensity = enum { light, medium, dark };

fn fillShade(pixels: []u8, width: u16, height: u16, density: ShadeDensity) void {
    const alpha: u8 = switch (density) {
        .light => 0x40,
        .medium => 0x80,
        .dark => 0xc0,
    };
    generated_special.fillRectAlpha(pixels, width, 0, 0, width, height, alpha);
}

fn rasterizeBrailleAlpha(pixels: []u8, width: u16, height: u16, mask: u8) void {
    if (mask == 0) return;
    const layout = brailleLayout(width, height);
    var bit: u8 = 0;
    while (bit < 8) : (bit += 1) {
        if ((mask & (@as(u8, 1) << @intCast(bit))) == 0) continue;
        const dot_number = bit + 1;
        const col: u16 = switch (dot_number) {
            1, 2, 3, 7 => 0,
            else => 1,
        };
        const row: u16 = switch (dot_number) {
            1, 4 => 0,
            2, 5 => 1,
            3, 6 => 2,
            else => 3,
        };
        const x = layout.x[col];
        const y = layout.y[row];
        drawBrailleDotAlpha(pixels, width, height, x, y, layout.dot);
    }
}

fn drawBrailleDotAlpha(pixels: []u8, width: u16, height: u16, x0: u16, y0: u16, dot: u16) void {
    const w = @min(dot, width - x0);
    const h = @min(dot, height - y0);
    if (w == 0 or h == 0) return;
    if (w == 1 and h == 1) {
        pixels[generated_special.pixelOffset(width, x0, y0)] = 255;
        return;
    }

    const coverage = BrailleDotCoverageCtx{
        .cx = @as(f64, @floatFromInt(x0)) + @as(f64, @floatFromInt(w)) / 2.0,
        .cy = @as(f64, @floatFromInt(y0)) + @as(f64, @floatFromInt(h)) / 2.0,
        .rx = @max(@as(f64, @floatFromInt(w)) / 2.0, 0.5),
        .ry = @max(@as(f64, @floatFromInt(h)) / 2.0, 0.5),
    };
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            const alpha = supersampledBrailleDotCoverage(x0 + x, y0 + y, coverage);
            if (alpha == 0) continue;
            const idx = generated_special.pixelOffset(width, x0 + x, y0 + y);
            pixels[idx] = @max(pixels[idx], alpha);
        }
    }
}

const BrailleLayout = struct { dot: u16, x: [2]u16, y: [4]u16 };

fn brailleLayout(width: u16, height: u16) BrailleLayout {
    var dot: i32 = @intCast(@min(width / 4, height / 8));
    var x_spacing: i32 = @intCast(width / 4);
    var y_spacing: i32 = @intCast(height / 8);
    var x_margin = @divFloor(x_spacing, 2);
    var y_margin = @divFloor(y_spacing, 2);
    var x_left: i32 = @as(i32, @intCast(width)) - 2 * x_margin - x_spacing - 2 * dot;
    var y_left: i32 = @as(i32, @intCast(height)) - 2 * y_margin - 3 * y_spacing - 4 * dot;

    if (x_left >= 2 and y_left >= 4 and dot == 0) {
        dot += 1;
        x_left -= 2;
        y_left -= 4;
    }
    if (x_left >= 2 and x_margin == 0) {
        x_margin += 1;
        x_left -= 2;
    }
    if (y_left >= 2 and y_margin == 0) {
        y_margin += 1;
        y_left -= 2;
    }
    if (x_left >= 1) {
        x_spacing += 1;
        x_left -= 1;
    }
    if (y_left >= 3) {
        y_spacing += 1;
        y_left -= 3;
    }
    if (x_left >= 2) {
        x_margin += 1;
        x_left -= 2;
    }
    if (y_left >= 2) {
        y_margin += 1;
        y_left -= 2;
    }
    if (x_left >= 2 and y_left >= 4) {
        dot += 1;
    }

    const safe_dot: u16 = @intCast(@max(dot, 1));
    const x0: u16 = @intCast(@max(x_margin, 0));
    const y0: u16 = @intCast(@max(y_margin, 0));
    return .{
        .dot = safe_dot,
        .x = .{ x0, @intCast(@min(@as(i32, @intCast(width - 1)), x_margin + dot + x_spacing)) },
        .y = .{
            y0,
            @intCast(@min(@as(i32, @intCast(height - 1)), y_margin + dot + y_spacing)),
            @intCast(@min(@as(i32, @intCast(height - 1)), y_margin + 2 * dot + 2 * y_spacing)),
            @intCast(@min(@as(i32, @intCast(height - 1)), y_margin + 3 * dot + 3 * y_spacing)),
        },
    };
}

const BrailleDotCoverageCtx = struct { cx: f64, cy: f64, rx: f64, ry: f64 };

fn supersampledBrailleDotCoverage(x: u16, y: u16, ctx: BrailleDotCoverageCtx) u8 {
    return generated_special.supersampledCoverage(x, y, brailleDotContains, ctx);
}

fn brailleDotContains(px: f64, py: f64, ctx: BrailleDotCoverageCtx) bool {
    const nx = (px - ctx.cx) / ctx.rx;
    const ny = (py - ctx.cy) / ctx.ry;
    return nx * nx + ny * ny <= 1.0;
}
