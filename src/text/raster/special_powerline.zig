const std = @import("std");
const render = @import("../../grid/scene.zig");
const generated_special = @import("generated_special.zig");
const special_box = @import("special_box.zig");

pub fn rasterizeGeneratedPowerlineAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32, box_drawing: render.BoxDrawingRasterMetrics) void {
    switch (codepoint) {
        0xe0b0 => rasterizePowerlineTriangle(pixels, width, height, true, false),
        0xe0b2 => rasterizePowerlineTriangle(pixels, width, height, false, false),
        0xe0b1 => rasterizePowerlineHalfDiagonal(pixels, width, height, true, box_drawing),
        0xe0b3 => rasterizePowerlineHalfDiagonal(pixels, width, height, false, box_drawing),
        0xe0b4 => rasterizePowerlineD(pixels, width, height, true, true, box_drawing),
        0xe0b6 => rasterizePowerlineD(pixels, width, height, false, true, box_drawing),
        0xe0b5 => rasterizePowerlineD(pixels, width, height, true, false, box_drawing),
        0xe0b7 => rasterizePowerlineD(pixels, width, height, false, false, box_drawing),
        0xe0b8 => rasterizePowerlineCornerTriangle(pixels, width, height, .bottom_left),
        0xe0b9, 0xe0bf => special_box.rasterizeCrossLine(pixels, width, height, true, box_drawing),
        0xe0ba => rasterizePowerlineCornerTriangle(pixels, width, height, .bottom_right),
        0xe0bb, 0xe0bd => special_box.rasterizeCrossLine(pixels, width, height, false, box_drawing),
        0xe0bc => rasterizePowerlineCornerTriangle(pixels, width, height, .top_left),
        0xe0be => rasterizePowerlineCornerTriangle(pixels, width, height, .top_right),
        else => unreachable,
    }
}

pub fn rasterizeGeneratedPowerlineTriangleAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    switch (codepoint) {
        0xe0d6 => rasterizePowerlineTriangle(pixels, width, height, false, false),
        0xe0d7 => rasterizePowerlineTriangle(pixels, width, height, true, false),
        else => unreachable,
    }
}

fn rasterizePowerlineTriangle(pixels: []u8, width: u16, height: u16, left: bool, inverted: bool) void {
    const x1: f64 = if (left) 0 else @floatFromInt(width - 1);
    const x2: f64 = if (left) @floatFromInt(width - 1) else 0;
    const y_mid = @as(f64, @floatFromInt(height - 1)) / 2.0;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const coverage = supersampledTriangleCoverage(x, y, .{ .x1 = x1, .x2 = x2, .y_mid = y_mid, .height = height, .inverted = inverted });
            if (coverage != 0) pixels[generated_special.pixelOffset(width, x, y)] = coverage;
        }
    }
}

fn rasterizePowerlineHalfDiagonal(pixels: []u8, width: u16, height: u16, left: bool, box_drawing: render.BoxDrawingRasterMetrics) void {
    const mid = @as(f64, @floatFromInt(height - 1)) / 2.0;
    const line_w = @as(f64, @floatFromInt(@max(box_drawing.light_stroke_px, 1)));
    if (left) {
        generated_special.drawLineAlpha(pixels, width, height, 0, 0, @floatFromInt(width - 1), mid, line_w);
        generated_special.drawLineAlpha(pixels, width, height, @floatFromInt(width - 1), mid, 0, @floatFromInt(height - 1), line_w);
    } else {
        generated_special.drawLineAlpha(pixels, width, height, @floatFromInt(width - 1), 0, 0, mid, line_w);
        generated_special.drawLineAlpha(pixels, width, height, 0, mid, @floatFromInt(width - 1), @floatFromInt(height - 1), line_w);
    }
}

fn rasterizePowerlineD(pixels: []u8, width: u16, height: u16, left: bool, filled: bool, box_drawing: render.BoxDrawingRasterMetrics) void {
    if (filled) {
        rasterizePowerlineFilledD(pixels, width, height, left);
    } else {
        rasterizePowerlineRoundedD(pixels, width, height, left, box_drawing);
    }
}

const CubicBezier = struct {
    start: generated_special.PointF,
    c1: generated_special.PointF,
    c2: generated_special.PointF,
    end: generated_special.PointF,
};

fn rasterizePowerlineFilledD(pixels: []u8, width: u16, height: u16, left: bool) void {
    const max_x = findBezierControlX(width, height);
    const bottom: f64 = @floatFromInt(height);
    const cb = CubicBezier{
        .start = .{ .x = 0, .y = 0 },
        .c1 = .{ .x = @floatFromInt(max_x), .y = 0 },
        .c2 = .{ .x = @floatFromInt(max_x), .y = bottom },
        .end = .{ .x = 0, .y = bottom },
    };

    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const coverage = supersampledFilledDCoverage(x, y, .{ .cb = cb, .width = width, .left = left });
            if (coverage != 0) pixels[generated_special.pixelOffset(width, x, y)] = coverage;
        }
    }
}

const TriangleCoverageCtx = struct { x1: f64, x2: f64, y_mid: f64, height: u16, inverted: bool };
const FilledDCoverageCtx = struct { cb: CubicBezier, width: u16, left: bool };

fn supersampledTriangleCoverage(x: u16, y: u16, ctx: TriangleCoverageCtx) u8 {
    return generated_special.supersampledCoverage(x, y, triangleContains, ctx);
}

fn supersampledFilledDCoverage(x: u16, y: u16, ctx: FilledDCoverageCtx) u8 {
    return generated_special.supersampledCoverage(x, y, filledDContains, ctx);
}

fn triangleContains(px: f64, py: f64, ctx: TriangleCoverageCtx) bool {
    const upper = generated_special.lineY(ctx.x1, 0, ctx.x2, ctx.y_mid, px);
    const lower = generated_special.lineY(ctx.x1, @floatFromInt(ctx.height - 1), ctx.x2, ctx.y_mid, px);
    return (py >= upper and py <= lower) != ctx.inverted;
}

fn filledDContains(px_raw: f64, py: f64, ctx: FilledDCoverageCtx) bool {
    const px = if (ctx.left) px_raw else @as(f64, @floatFromInt(ctx.width - 1)) - px_raw;
    const t = findBezierTForX(ctx.cb, px);
    if (bezierX(ctx.cb, t) > @as(f64, @floatFromInt(ctx.width - 1)) + 0.5) return false;
    const upper = bezierY(ctx.cb, t);
    const lower = bezierY(ctx.cb, 1.0 - t);
    return py >= upper and py <= lower;
}

fn rasterizePowerlineRoundedD(pixels: []u8, width: u16, height: u16, left: bool, box_drawing: render.BoxDrawingRasterMetrics) void {
    const gap = @max(box_drawing.light_stroke_px, 1);
    const half_gap = @as(f64, @floatFromInt(gap)) / 2.0;
    const curve_w = if (width > gap) width - gap else width;
    const curve_h = if (height > gap) height - gap else height;
    const max_x = findBezierControlX(curve_w, curve_h);
    const cb = CubicBezier{
        .start = .{ .x = 0, .y = 0 },
        .c1 = .{ .x = @floatFromInt(max_x), .y = 0 },
        .c2 = .{ .x = @floatFromInt(max_x), .y = @floatFromInt(curve_h - 1) },
        .end = .{ .x = 0, .y = @floatFromInt(curve_h - 1) },
    };
    drawCubicStrokeAlpha(pixels, width, height, cb, @floatFromInt(@max(gap, 1)), half_gap, left);
}

fn findBezierControlX(width: u16, height: u16) u16 {
    var cx: u16 = width - 1;
    var last = cx;
    while (cx < width * 4) : (cx += 1) {
        const cb = CubicBezier{
            .start = .{ .x = 0, .y = 0 },
            .c1 = .{ .x = @floatFromInt(cx), .y = 0 },
            .c2 = .{ .x = @floatFromInt(cx), .y = @floatFromInt(height - 1) },
            .end = .{ .x = 0, .y = @floatFromInt(height - 1) },
        };
        if (bezierX(cb, 0.5) > @as(f64, @floatFromInt(width - 1))) return last;
        last = cx;
    }
    return last;
}

fn findBezierTForX(cb: CubicBezier, x: f64) f64 {
    var lo: f64 = 0;
    var hi: f64 = 0.5;
    var i: u8 = 0;
    while (i < 24) : (i += 1) {
        const mid = (lo + hi) / 2.0;
        if (bezierX(cb, mid) < x) lo = mid else hi = mid;
    }
    return (lo + hi) / 2.0;
}

fn drawCubicStrokeAlpha(pixels: []u8, width: u16, height: u16, cb: CubicBezier, line_width: f64, y_offset: f64, left: bool) void {
    const samples = 96;
    const half = @max(line_width, 1.0) / 2.0;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const px = @as(f64, @floatFromInt(if (left) x else width - 1 - x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5 - y_offset;
            var min_d2 = std.math.floatMax(f64);
            var i: u16 = 0;
            while (i <= samples) : (i += 1) {
                const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(samples));
                const sx = bezierX(cb, t);
                const sy = bezierY(cb, t);
                const dx = px - sx;
                const dy = py - sy;
                min_d2 = @min(min_d2, dx * dx + dy * dy);
            }
            const coverage = std.math.clamp(half - @sqrt(min_d2) + 0.5, 0.0, 1.0);
            if (coverage <= 0) continue;
            pixels[generated_special.pixelOffset(width, x, y)] = @intFromFloat(@round(coverage * 255.0));
        }
    }
}

fn bezierX(cb: CubicBezier, t: f64) f64 {
    return bezierValue(cb.start.x, cb.c1.x, cb.c2.x, cb.end.x, t);
}

fn bezierY(cb: CubicBezier, t: f64) f64 {
    return bezierValue(cb.start.y, cb.c1.y, cb.c2.y, cb.end.y, t);
}

fn bezierValue(start: f64, c1: f64, c2: f64, end: f64, t: f64) f64 {
    const u = 1.0 - t;
    return u * u * u * start + 3.0 * t * u * (u * c1 + t * c2) + t * t * t * end;
}

const PowerlineCorner = enum { top_left, top_right, bottom_left, bottom_right };

fn rasterizePowerlineCornerTriangle(pixels: []u8, width: u16, height: u16, corner: PowerlineCorner) void {
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const xf = @as(f64, @floatFromInt(x)) + 0.5;
            const yf = @as(f64, @floatFromInt(y)) + 0.5;
            const diag_down = generated_special.lineY(0, 0, @floatFromInt(width - 1), @floatFromInt(height - 1), xf);
            const diag_up = generated_special.lineY(@floatFromInt(width - 1), 0, 0, @floatFromInt(height - 1), xf);
            const inside = switch (corner) {
                .top_left => yf <= diag_up,
                .top_right => yf <= diag_down,
                .bottom_left => yf >= diag_down,
                .bottom_right => yf >= diag_up,
            };
            if (inside) pixels[generated_special.pixelOffset(width, x, y)] = 255;
        }
    }
}
