const std = @import("std");
const metrics = @import("../text/metrics.zig");
const render = @import("../libhowl_render.zig");

pub const Target = struct {
    left_px: f32,
    right_px: f32,
    top_px: f32,
    bottom_px: f32,
    visible: bool,
};

pub const CursorTrail = struct {
    needs_render: bool = false,
    updated_at_ns: u64 = 0,
    opacity: f32 = 0,
    corner_x: [4]f32 = [_]f32{0} ** 4,
    corner_y: [4]f32 = [_]f32{0} ** 4,
    edge_x: [2]f32 = [_]f32{0} ** 2,
    edge_y: [2]f32 = [_]f32{0} ** 2,

    const corner_edge_x = [4]usize{ 1, 1, 0, 0 };
    const corner_edge_y = [4]usize{ 0, 1, 1, 0 };

    pub fn snapToTarget(self: *CursorTrail, target: Target, now_ns: u64) void {
        self.setTarget(target);
        for (0..4) |index| {
            self.corner_x[index] = self.edge_x[corner_edge_x[index]];
            self.corner_y[index] = self.edge_y[corner_edge_y[index]];
        }
        self.opacity = if (target.visible) 1 else 0;
        self.needs_render = false;
        self.updated_at_ns = now_ns;
    }

    pub fn setTarget(self: *CursorTrail, target: Target) void {
        std.debug.assert(target.right_px >= target.left_px);
        std.debug.assert(target.bottom_px >= target.top_px);
        self.edge_x = .{ target.left_px, target.right_px };
        self.edge_y = .{ target.top_px, target.bottom_px };
    }

    pub fn update(self: *CursorTrail, decay_fast_s: f32, decay_slow_s: f32, now_ns: u64, cursor_visible: bool) bool {
        std.debug.assert(decay_fast_s > 0);
        std.debug.assert(decay_slow_s > 0);
        const previous_needs_render = self.needs_render;
        if (self.updated_at_ns < now_ns) {
            const dt_s = @as(f32, @floatFromInt(now_ns - self.updated_at_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s));
            self.updateCorners(decay_fast_s, decay_slow_s, dt_s);
            self.updateOpacity(decay_slow_s, dt_s, cursor_visible);
        }
        self.updateNeedsRender();
        self.updated_at_ns = now_ns;
        return self.needs_render or previous_needs_render;
    }

    fn updateCorners(self: *CursorTrail, decay_fast_s: f32, decay_slow_s: f32, dt_s: f32) void {
        const cursor_center_x = (self.edge_x[0] + self.edge_x[1]) * 0.5;
        const cursor_center_y = (self.edge_y[0] + self.edge_y[1]) * 0.5;
        const cursor_diag_half = norm(self.edge_x[1] - self.edge_x[0], self.edge_y[1] - self.edge_y[0]) * 0.5;
        if (cursor_diag_half == 0) return;

        var dx = [_]f32{0} ** 4;
        var dy = [_]f32{0} ** 4;
        var dot = [_]f32{0} ** 4;
        var min_dot: f32 = std.math.floatMax(f32);
        var max_dot: f32 = -std.math.floatMax(f32);
        for (0..4) |index| {
            const target_x = self.edge_x[corner_edge_x[index]];
            const target_y = self.edge_y[corner_edge_y[index]];
            dx[index] = target_x - self.corner_x[index];
            dy[index] = target_y - self.corner_y[index];
            const distance = norm(dx[index], dy[index]);
            if (distance < 0.000001) continue;
            dot[index] = (dx[index] * (target_x - cursor_center_x) + dy[index] * (target_y - cursor_center_y)) / cursor_diag_half / distance;
            min_dot = @min(min_dot, dot[index]);
            max_dot = @max(max_dot, dot[index]);
        }
        if (min_dot == std.math.floatMax(f32)) return;

        for (0..4) |index| {
            if (dx[index] == 0 and dy[index] == 0) continue;
            const decay = if (min_dot == max_dot)
                decay_slow_s
            else
                decay_slow_s + (decay_fast_s - decay_slow_s) * (dot[index] - min_dot) / (max_dot - min_dot);
            const step = 1.0 - @exp2(-10.0 * dt_s / decay);
            self.corner_x[index] += dx[index] * step;
            self.corner_y[index] += dy[index] * step;
        }
    }

    fn updateOpacity(self: *CursorTrail, decay_slow_s: f32, dt_s: f32, cursor_visible: bool) void {
        const delta = dt_s / decay_slow_s;
        self.opacity = if (cursor_visible) @min(self.opacity + delta, 1) else @max(self.opacity - delta, 0);
    }

    fn updateNeedsRender(self: *CursorTrail) void {
        self.needs_render = false;
        for (0..4) |index| {
            const dx = @abs(self.edge_x[corner_edge_x[index]] - self.corner_x[index]);
            const dy = @abs(self.edge_y[corner_edge_y[index]] - self.corner_y[index]);
            if (dx >= 0.5 or dy >= 0.5) {
                self.needs_render = true;
                return;
            }
        }
    }
};

pub fn targetFromCursor(cursor: anytype, cell_metrics: render.CellMetrics) ?Target {
    if (cursor.shape == .none) return null;
    const base_left: f32 = @floatFromInt(@as(u32, cursor.primary_extent.col) * @as(u32, cell_metrics.cell_w_px));
    const base_top: f32 = @floatFromInt(@as(u32, cursor.primary_extent.row) * @as(u32, cell_metrics.cell_h_px));
    const full_width: f32 = @floatFromInt(@as(u32, cursor.primary_extent.cols) * @as(u32, cell_metrics.cell_w_px));
    const full_height: f32 = @floatFromInt(@as(u32, cursor.primary_extent.rows) * @as(u32, cell_metrics.cell_h_px));
    const geom = metrics.cursorGeometry(cell_metrics, cursor.beam_thickness, cursor.underline_thickness);
    return switch (cursor.shape) {
        .none => null,
        .block, .hollow => .{ .left_px = base_left, .right_px = base_left + full_width, .top_px = base_top, .bottom_px = base_top + full_height, .visible = cursor.visible },
        .beam => .{ .left_px = base_left, .right_px = base_left + @as(f32, @floatFromInt(geom.beam_w_px)), .top_px = base_top, .bottom_px = base_top + full_height, .visible = cursor.visible },
        .underline => .{
            .left_px = base_left,
            .right_px = base_left + full_width,
            .top_px = base_top + full_height - @as(f32, @floatFromInt(geom.underline_h_px)),
            .bottom_px = base_top + full_height,
            .visible = cursor.visible,
        },
    };
}

fn norm(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}

test "cursor trail corners ease toward target" {
    var trail = CursorTrail{};
    trail.snapToTarget(.{ .left_px = 0, .right_px = 8, .top_px = 0, .bottom_px = 16, .visible = true }, 1);
    trail.setTarget(.{ .left_px = 32, .right_px = 40, .top_px = 0, .bottom_px = 16, .visible = true });

    try std.testing.expect(trail.update(0.1, 0.4, 1 + 16 * std.time.ns_per_ms, true));
    try std.testing.expect(trail.needs_render);
    try std.testing.expect(trail.corner_x[0] > 8);
    try std.testing.expect(trail.corner_x[0] < 40);
}

test "cursor trail settles and returns one final render" {
    var trail = CursorTrail{};
    trail.snapToTarget(.{ .left_px = 0, .right_px = 8, .top_px = 0, .bottom_px = 16, .visible = true }, 1);
    trail.setTarget(.{ .left_px = 32, .right_px = 40, .top_px = 0, .bottom_px = 16, .visible = true });

    var now_ns: u64 = 1;
    var index: u8 = 0;
    while (index < 80 and trail.update(0.1, 0.4, now_ns + 16 * std.time.ns_per_ms, true)) : (index += 1) {
        now_ns += 16 * std.time.ns_per_ms;
    }
    try std.testing.expect(!trail.needs_render);
    try std.testing.expect(trail.corner_x[0] >= 39.5);
}

test "cursor trail opacity follows cursor visibility" {
    var trail = CursorTrail{};
    trail.snapToTarget(.{ .left_px = 0, .right_px = 8, .top_px = 0, .bottom_px = 16, .visible = true }, 1);
    try std.testing.expectEqual(@as(f32, 1), trail.opacity);

    _ = trail.update(0.1, 0.4, 1 + 100 * std.time.ns_per_ms, false);
    try std.testing.expect(trail.opacity < 1);
    try std.testing.expect(trail.opacity > 0);
}

test "cursor trail target follows cursor shape geometry" {
    const cell_metrics = render.CellMetrics{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 };
    var cursor = testCursor(.block);

    var target = targetFromCursor(cursor, cell_metrics).?;
    try std.testing.expectEqual(@as(f32, 16), target.left_px);
    try std.testing.expectEqual(@as(f32, 24), target.right_px);
    try std.testing.expectEqual(@as(f32, 16), target.top_px);
    try std.testing.expectEqual(@as(f32, 32), target.bottom_px);

    cursor.shape = .beam;
    cursor.beam_thickness = 3.5;
    target = targetFromCursor(cursor, cell_metrics).?;
    try std.testing.expect(target.right_px - target.left_px > 1);
    try std.testing.expect(target.right_px - target.left_px < 8);

    cursor.shape = .underline;
    cursor.underline_thickness = 4.0;
    target = targetFromCursor(cursor, cell_metrics).?;
    try std.testing.expect(target.top_px > 16);
    try std.testing.expectEqual(@as(f32, 32), target.bottom_px);

    cursor.shape = .none;
    try std.testing.expect(targetFromCursor(cursor, cell_metrics) == null);
}

fn testCursor(shape: render.CursorShape) struct {
    visible: bool,
    shape: render.CursorShape,
    beam_thickness: f32,
    underline_thickness: f32,
    primary_extent: render.CellExtent,
} {
    return .{
        .visible = true,
        .shape = shape,
        .beam_thickness = 1.5,
        .underline_thickness = 2.0,
        .primary_extent = .{ .row = 1, .col = 2, .rows = 1, .cols = 1 },
    };
}
