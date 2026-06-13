const std = @import("std");
const contract = @import("../contract.zig");

pub fn rasterizeGeneratedBoxAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32, box_drawing: contract.BoxDrawingRasterMetrics) void {
    switch (codepoint) {
        0x2504 => rasterizeDashedBoxLine(pixels, width, height, .horizontal, box_drawing.light_stroke_px, 2),
        0x2505 => rasterizeDashedBoxLine(pixels, width, height, .horizontal, box_drawing.heavy_stroke_px, 2),
        0x2506 => rasterizeDashedBoxLine(pixels, width, height, .vertical, box_drawing.light_stroke_px, 2),
        0x2507 => rasterizeDashedBoxLine(pixels, width, height, .vertical, box_drawing.heavy_stroke_px, 2),
        0x2508 => rasterizeDashedBoxLine(pixels, width, height, .horizontal, box_drawing.light_stroke_px, 3),
        0x2509 => rasterizeDashedBoxLine(pixels, width, height, .horizontal, box_drawing.heavy_stroke_px, 3),
        0x250a => rasterizeDashedBoxLine(pixels, width, height, .vertical, box_drawing.light_stroke_px, 3),
        0x250b => rasterizeDashedBoxLine(pixels, width, height, .vertical, box_drawing.heavy_stroke_px, 3),
        0x254c => rasterizeDashedBoxLine(pixels, width, height, .horizontal, box_drawing.light_stroke_px, 1),
        0x254d => rasterizeDashedBoxLine(pixels, width, height, .horizontal, box_drawing.heavy_stroke_px, 1),
        0x254e => rasterizeDashedBoxLine(pixels, width, height, .vertical, box_drawing.light_stroke_px, 1),
        0x254f => rasterizeDashedBoxLine(pixels, width, height, .vertical, box_drawing.heavy_stroke_px, 1),
        0x2500...0x2503, 0x250c...0x254b, 0x2550...0x256c, 0x2574...0x257f => rasterizeBoxLines(pixels, width, height, lineSpec(codepoint) orelse unreachable, box_drawing),
        0x2571 => rasterizeCrossLine(pixels, width, height, false, box_drawing),
        0x2572 => rasterizeCrossLine(pixels, width, height, true, box_drawing),
        0x2573 => {
            rasterizeCrossLine(pixels, width, height, false, box_drawing);
            rasterizeCrossLine(pixels, width, height, true, box_drawing);
        },
        0x256d => rasterizeRoundedCorner(pixels, width, height, .top_left, box_drawing),
        0x256e => rasterizeRoundedCorner(pixels, width, height, .top_right, box_drawing),
        0x256f => rasterizeRoundedCorner(pixels, width, height, .bottom_right, box_drawing),
        0x2570 => rasterizeRoundedCorner(pixels, width, height, .bottom_left, box_drawing),
        else => unreachable,
    }
}

pub const RoundedCorner = enum { top_left, top_right, bottom_left, bottom_right };
pub const BoxLineStyle = enum { none, light, heavy, double };
pub const BoxLines = struct {
    up: BoxLineStyle = .none,
    right: BoxLineStyle = .none,
    down: BoxLineStyle = .none,
    left: BoxLineStyle = .none,
};

pub fn lineSpec(cp: u32) ?BoxLines {
    return lineSpecLight(cp) orelse lineSpecHeavy(cp) orelse lineSpecDouble(cp) orelse lineSpecHalf(cp);
}

pub fn lineSpecLight(cp: u32) ?BoxLines {
    return switch (cp) {
        0x2500 => .{ .left = .light, .right = .light },
        0x2501 => .{ .left = .heavy, .right = .heavy },
        0x2502 => .{ .up = .light, .down = .light },
        0x2503 => .{ .up = .heavy, .down = .heavy },
        0x250c => .{ .down = .light, .right = .light },
        0x250d => .{ .down = .light, .right = .heavy },
        0x250e => .{ .down = .heavy, .right = .light },
        0x250f => .{ .down = .heavy, .right = .heavy },
        0x2510 => .{ .down = .light, .left = .light },
        0x2511 => .{ .down = .light, .left = .heavy },
        0x2512 => .{ .down = .heavy, .left = .light },
        0x2513 => .{ .down = .heavy, .left = .heavy },
        0x2514 => .{ .up = .light, .right = .light },
        0x2515 => .{ .up = .light, .right = .heavy },
        0x2516 => .{ .up = .heavy, .right = .light },
        0x2517 => .{ .up = .heavy, .right = .heavy },
        0x2518 => .{ .up = .light, .left = .light },
        0x2519 => .{ .up = .light, .left = .heavy },
        0x251a => .{ .up = .heavy, .left = .light },
        0x251b => .{ .up = .heavy, .left = .heavy },
        0x251c => .{ .up = .light, .down = .light, .right = .light },
        0x251d => .{ .up = .light, .down = .light, .right = .heavy },
        0x251e => .{ .up = .heavy, .right = .light, .down = .light },
        0x251f => .{ .down = .heavy, .right = .light, .up = .light },
        0x2520 => .{ .up = .heavy, .down = .heavy, .right = .light },
        0x2521 => .{ .down = .light, .right = .heavy, .up = .heavy },
        0x2522 => .{ .up = .light, .right = .heavy, .down = .heavy },
        0x2523 => .{ .up = .heavy, .down = .heavy, .right = .heavy },
        0x2524 => .{ .up = .light, .down = .light, .left = .light },
        0x2525 => .{ .up = .light, .down = .light, .left = .heavy },
        0x2526 => .{ .up = .heavy, .left = .light, .down = .light },
        0x2527 => .{ .down = .heavy, .left = .light, .up = .light },
        0x2528 => .{ .up = .heavy, .down = .heavy, .left = .light },
        0x2529 => .{ .down = .light, .left = .heavy, .up = .heavy },
        0x252a => .{ .up = .light, .left = .heavy, .down = .heavy },
        0x252b => .{ .up = .heavy, .down = .heavy, .left = .heavy },
        0x252c => .{ .down = .light, .left = .light, .right = .light },
        0x252d => .{ .left = .heavy, .right = .light, .down = .light },
        0x252e => .{ .right = .heavy, .left = .light, .down = .light },
        0x252f => .{ .down = .light, .left = .heavy, .right = .heavy },
        0x2530 => .{ .down = .heavy, .left = .light, .right = .light },
        0x2531 => .{ .right = .light, .left = .heavy, .down = .heavy },
        0x2532 => .{ .left = .light, .right = .heavy, .down = .heavy },
        0x2533 => .{ .down = .heavy, .left = .heavy, .right = .heavy },
        else => null,
    };
}

pub fn lineSpecHeavy(cp: u32) ?BoxLines {
    return switch (cp) {
        0x2534 => .{ .up = .light, .left = .light, .right = .light },
        0x2535 => .{ .left = .heavy, .right = .light, .up = .light },
        0x2536 => .{ .right = .heavy, .left = .light, .up = .light },
        0x2537 => .{ .up = .light, .left = .heavy, .right = .heavy },
        0x2538 => .{ .up = .heavy, .left = .light, .right = .light },
        0x2539 => .{ .right = .light, .left = .heavy, .up = .heavy },
        0x253a => .{ .left = .light, .right = .heavy, .up = .heavy },
        0x253b => .{ .up = .heavy, .left = .heavy, .right = .heavy },
        0x253c => .{ .up = .light, .down = .light, .left = .light, .right = .light },
        0x253d => .{ .left = .heavy, .right = .light, .up = .light, .down = .light },
        0x253e => .{ .right = .heavy, .left = .light, .up = .light, .down = .light },
        0x253f => .{ .up = .light, .down = .light, .left = .heavy, .right = .heavy },
        0x2540 => .{ .up = .heavy, .down = .light, .left = .light, .right = .light },
        0x2541 => .{ .down = .heavy, .up = .light, .left = .light, .right = .light },
        0x2542 => .{ .up = .heavy, .down = .heavy, .left = .light, .right = .light },
        0x2543 => .{ .left = .heavy, .up = .heavy, .right = .light, .down = .light },
        0x2544 => .{ .right = .heavy, .up = .heavy, .left = .light, .down = .light },
        0x2545 => .{ .left = .heavy, .down = .heavy, .right = .light, .up = .light },
        0x2546 => .{ .right = .heavy, .down = .heavy, .left = .light, .up = .light },
        0x2547 => .{ .down = .light, .up = .heavy, .left = .heavy, .right = .heavy },
        0x2548 => .{ .up = .light, .down = .heavy, .left = .heavy, .right = .heavy },
        0x2549 => .{ .right = .light, .left = .heavy, .up = .heavy, .down = .heavy },
        0x254a => .{ .left = .light, .right = .heavy, .up = .heavy, .down = .heavy },
        0x254b => .{ .up = .heavy, .down = .heavy, .left = .heavy, .right = .heavy },
        else => null,
    };
}

pub fn lineSpecDouble(cp: u32) ?BoxLines {
    return switch (cp) {
        0x2550 => .{ .left = .double, .right = .double },
        0x2551 => .{ .up = .double, .down = .double },
        0x2552 => .{ .down = .light, .right = .double },
        0x2553 => .{ .down = .double, .right = .light },
        0x2554 => .{ .down = .double, .right = .double },
        0x2555 => .{ .down = .light, .left = .double },
        0x2556 => .{ .down = .double, .left = .light },
        0x2557 => .{ .down = .double, .left = .double },
        0x2558 => .{ .up = .light, .right = .double },
        0x2559 => .{ .up = .double, .right = .light },
        0x255a => .{ .up = .double, .right = .double },
        0x255b => .{ .up = .light, .left = .double },
        0x255c => .{ .up = .double, .left = .light },
        0x255d => .{ .up = .double, .left = .double },
        0x255e => .{ .up = .light, .down = .light, .right = .double },
        0x255f => .{ .up = .double, .down = .double, .right = .light },
        0x2560 => .{ .up = .double, .down = .double, .right = .double },
        0x2561 => .{ .up = .light, .down = .light, .left = .double },
        0x2562 => .{ .up = .double, .down = .double, .left = .light },
        0x2563 => .{ .up = .double, .down = .double, .left = .double },
        0x2564 => .{ .down = .light, .left = .double, .right = .double },
        0x2565 => .{ .down = .double, .left = .light, .right = .light },
        0x2566 => .{ .down = .double, .left = .double, .right = .double },
        0x2567 => .{ .up = .light, .left = .double, .right = .double },
        0x2568 => .{ .up = .double, .left = .light, .right = .light },
        0x2569 => .{ .up = .double, .left = .double, .right = .double },
        0x256a => .{ .up = .light, .down = .light, .left = .double, .right = .double },
        0x256b => .{ .up = .double, .down = .double, .left = .light, .right = .light },
        0x256c => .{ .up = .double, .down = .double, .left = .double, .right = .double },
        else => null,
    };
}

pub fn lineSpecHalf(cp: u32) ?BoxLines {
    return switch (cp) {
        0x2574 => .{ .left = .light },
        0x2575 => .{ .up = .light },
        0x2576 => .{ .right = .light },
        0x2577 => .{ .down = .light },
        0x2578 => .{ .left = .heavy },
        0x2579 => .{ .up = .heavy },
        0x257a => .{ .right = .heavy },
        0x257b => .{ .down = .heavy },
        0x257c => .{ .left = .light, .right = .heavy },
        0x257d => .{ .up = .light, .down = .heavy },
        0x257e => .{ .left = .heavy, .right = .light },
        0x257f => .{ .up = .heavy, .down = .light },
        else => null,
    };
}

pub fn rasterizeBoxLines(pixels: []u8, width: u16, height: u16, lines: BoxLines, box_drawing: contract.BoxDrawingRasterMetrics) void {
    const light = @max(box_drawing.light_stroke_px, 1);
    const heavy = @max(box_drawing.heavy_stroke_px, light);

    const h_light = centeredRange(height, height / 2, light);
    const h_heavy = centeredRange(height, height / 2, heavy);
    const h_double_top = (h_light[0] -| light);
    const h_double_bottom = @min(h_light[1] + light, height);

    const v_light = centeredRange(width, width / 2, light);
    const v_heavy = centeredRange(width, width / 2, heavy);
    const v_double_left = (v_light[0] -| light);
    const v_double_right = @min(v_light[1] + light, width);

    const up_bottom = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy[1]
    else if (lines.left != lines.right or lines.down == lines.up)
        if (lines.left == .double or lines.right == .double) h_double_bottom else h_light[1]
    else if (lines.left == .none and lines.right == .none)
        h_light[1]
    else
        h_light[0];

    const down_top = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy[0]
    else if (lines.left != lines.right or lines.up == lines.down)
        if (lines.left == .double or lines.right == .double) h_double_top else h_light[0]
    else if (lines.left == .none and lines.right == .none)
        h_light[0]
    else
        h_light[1];

    const left_right = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy[1]
    else if (lines.up != lines.down or lines.left == lines.right)
        if (lines.up == .double or lines.down == .double) v_double_right else v_light[1]
    else if (lines.up == .none and lines.down == .none)
        v_light[1]
    else
        v_light[0];

    const right_left = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy[0]
    else if (lines.up != lines.down or lines.right == lines.left)
        if (lines.up == .double or lines.down == .double) v_double_left else v_light[0]
    else if (lines.up == .none and lines.down == .none)
        v_light[0]
    else
        v_light[1];

    drawBoxVerticalArm(pixels, width, height, lines.up, 0, up_bottom, v_light, v_heavy, v_double_left, v_double_right, lines.left == .double, lines.right == .double, light);
    drawBoxHorizontalArm(pixels, width, height, lines.right, right_left, width, h_light, h_heavy, h_double_top, h_double_bottom, lines.up == .double, lines.down == .double, light);
    drawBoxVerticalArm(pixels, width, height, lines.down, down_top, height, v_light, v_heavy, v_double_left, v_double_right, lines.left == .double, lines.right == .double, light);
    drawBoxHorizontalArm(pixels, width, height, lines.left, 0, left_right, h_light, h_heavy, h_double_top, h_double_bottom, lines.up == .double, lines.down == .double, light);
}

pub fn drawBoxVerticalArm(pixels: []u8, width: u16, height: u16, style: BoxLineStyle, y0: u16, y1: u16, light_range: [2]u16, heavy_range: [2]u16, double_left: u16, double_right: u16, joins_left_double: bool, joins_right_double: bool, light: u16) void {
    if (y1 <= y0) return;
    switch (style) {
        .none => {},
        .light => fillRectRange(pixels, width, height, light_range[0], y0, light_range[1], y1),
        .heavy => fillRectRange(pixels, width, height, heavy_range[0], y0, heavy_range[1], y1),
        .double => {
            const left_y1 = if (joins_left_double) @min(light_range[0] + light, y1) else y1;
            const right_y1 = if (joins_right_double) @min(light_range[0] + light, y1) else y1;
            fillRectRange(pixels, width, height, double_left, y0, light_range[0], left_y1);
            fillRectRange(pixels, width, height, light_range[1], y0, double_right, right_y1);
        },
    }
}

pub fn drawBoxHorizontalArm(pixels: []u8, width: u16, height: u16, style: BoxLineStyle, x0: u16, x1: u16, light_range: [2]u16, heavy_range: [2]u16, double_top: u16, double_bottom: u16, joins_up_double: bool, joins_down_double: bool, light: u16) void {
    if (x1 <= x0) return;
    switch (style) {
        .none => {},
        .light => fillRectRange(pixels, width, height, x0, light_range[0], x1, light_range[1]),
        .heavy => fillRectRange(pixels, width, height, x0, heavy_range[0], x1, heavy_range[1]),
        .double => {
            const top_x0 = if (joins_up_double) @max((width / 2 -| light / 2) + light, x0) else x0;
            const bottom_x0 = if (joins_down_double) @max((width / 2 -| light / 2) + light, x0) else x0;
            fillRectRange(pixels, width, height, top_x0, double_top, x1, light_range[0]);
            fillRectRange(pixels, width, height, bottom_x0, light_range[1], x1, double_bottom);
        },
    }
}

pub fn fillRectRange(pixels: []u8, stride: u16, canvas_height: u16, x0: u16, y0: u16, x1: u16, y1: u16) void {
    const left = @min(x0, stride);
    const top = @min(y0, canvas_height);
    const right = @min(x1, stride);
    const bottom = @min(y1, canvas_height);
    if (right <= left or bottom <= top) return;

    var yy = top;
    while (yy < bottom) : (yy += 1) {
        const row = @as(u32, stride) * @as(u32, yy);
        var xx = left;
        while (xx < right) : (xx += 1) {
            pixels[@intCast(row + xx)] = 255;
        }
    }
}

pub const BoxLineAxis = enum { horizontal, vertical };

pub fn rasterizeDashedBoxLine(pixels: []u8, width: u16, height: u16, axis: BoxLineAxis, stroke_px: u16, gaps: u16) void {
    const stroke = @max(stroke_px, 1);
    const size = if (axis == .horizontal) width else height;
    const dash_count = @max(gaps + 1, 1);
    const dash_len = @max(size / (dash_count * 2 - 1), stroke);
    var dash: u16 = 0;
    while (dash < dash_count) : (dash += 1) {
        const start = @min(dash * dash_len * 2, size);
        const end = @min(start + dash_len, size);
        if (end <= start) continue;
        if (axis == .horizontal) {
            const y = centeredRange(height, height / 2, stroke);
            if (y[1] > y[0]) fillRectRange(pixels, width, height, start, y[0], end, y[1]);
        } else {
            const x = centeredRange(width, width / 2, stroke);
            if (x[1] > x[0]) fillRectRange(pixels, width, height, x[0], start, x[1], end);
        }
    }
}

pub fn rasterizeRoundedCorner(pixels: []u8, width: u16, height: u16, corner: RoundedCorner, box_drawing: contract.BoxDrawingRasterMetrics) void {
    const stroke_u = @max(box_drawing.light_stroke_px, 1);
    const stroke = @as(f64, @floatFromInt(stroke_u));
    const hori = centeredRange(height, height / 2, stroke_u);
    const vert = centeredRange(width, width / 2, stroke_u);
    const adjusted_hx = @as(f64, @floatFromInt(vert[0])) + @as(f64, @floatFromInt(vert[1] - vert[0])) / 2.0;
    const adjusted_hy = @as(f64, @floatFromInt(hori[0])) + @as(f64, @floatFromInt(hori[1] - hori[0])) / 2.0;
    const radius = @min(adjusted_hx, adjusted_hy);
    const bx = adjusted_hx - radius;
    const by = adjusted_hy - radius;
    const half_stroke = stroke / 2.0;
    const aa = 0.5;
    const x_shift = switch (corner) {
        .top_right, .bottom_right => adjusted_hx,
        .top_left, .bottom_left => -adjusted_hx,
    };
    const y_shift = switch (corner) {
        .top_left, .top_right => -adjusted_hy,
        .bottom_left, .bottom_right => adjusted_hy,
    };

    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const sample_y = @as(f64, @floatFromInt(y)) + y_shift + 0.5;
            const sample_x = @as(f64, @floatFromInt(x)) + x_shift + 0.5;
            const pos_y = sample_y - adjusted_hy;
            const pos_x = sample_x - adjusted_hx;
            const qx = @abs(pos_x) - bx;
            const qy = @abs(pos_y) - by;
            const dx = if (qx > 0.0) qx else 0.0;
            const dy = if (qy > 0.0) qy else 0.0;
            const dist = @sqrt(dx * dx + dy * dy) + @min(@max(qx, qy), 0.0) - radius;
            const edge_aa: f64 = if (qx > 1e-7 and qy > 1e-7) aa else 0.0;
            const outer = half_stroke - dist;
            const inner = -half_stroke - dist;
            const alpha = smoothStep(-edge_aa, edge_aa, outer) - smoothStep(-edge_aa, edge_aa, inner);
            if (alpha <= 0.0) continue;
            const idx = @as(u32, width) * @as(u32, y) + x;
            pixels[@intCast(idx)] = @max(pixels[@intCast(idx)], @as(u8, @intFromFloat(@round(std.math.clamp(alpha, 0.0, 1.0) * 255.0))));
        }
    }

    snapRoundedCornerConnections(pixels, width, height, corner, stroke_u);
}

pub fn snapRoundedCornerConnections(pixels: []u8, width: u16, height: u16, corner: RoundedCorner, stroke_px: u16) void {
    const h_range = centeredRange(height, height / 2, stroke_px);
    const v_range = centeredRange(width, width / 2, stroke_px);
    const h_x: u16 = switch (corner) {
        .top_left, .bottom_left => width - 1,
        .top_right, .bottom_right => 0,
    };
    const v_y: u16 = switch (corner) {
        .top_left, .top_right => height - 1,
        .bottom_left, .bottom_right => 0,
    };

    var y: u16 = 0;
    while (y < height) : (y += 1) {
        pixels[@intCast(@as(u32, width) * @as(u32, y) + h_x)] = if (y >= h_range[0] and y < h_range[1]) 255 else 0;
    }

    var x: u16 = 0;
    while (x < width) : (x += 1) {
        pixels[@intCast(@as(u32, width) * @as(u32, v_y) + x)] = if (x >= v_range[0] and x < v_range[1]) 255 else 0;
    }
}

pub fn rasterizeCrossLine(pixels: []u8, width: u16, height: u16, left: bool, box_drawing: contract.BoxDrawingRasterMetrics) void {
    const line_w = @as(f64, @floatFromInt(@max(box_drawing.light_stroke_px, 1)));
    const x1: f64 = if (left) 0 else @floatFromInt(width - 1);
    const y1: f64 = 0;
    const x2: f64 = if (left) @floatFromInt(width - 1) else 0;
    const y2: f64 = @floatFromInt(height - 1);
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len2 = @max(dx * dx + dy * dy, 1.0);
    const half = @max(line_w, 1.0) / 2.0;

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
            const idx = @as(u32, width) * @as(u32, y) + x;
            pixels[@intCast(idx)] = @max(pixels[@intCast(idx)], @as(u8, @intFromFloat(@round(coverage * 255.0))));
        }
    }
}

pub fn centeredRange(size: u16, center: u16, thickness: u16) [2]u16 {
    const start = center -| (thickness / 2);
    return .{ start, @min(start + thickness, size) };
}

pub fn smoothStep(edge0: f64, edge1: f64, x: f64) f64 {
    if (edge0 == edge1) return if (x < edge0) 0.0 else 1.0;
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}
