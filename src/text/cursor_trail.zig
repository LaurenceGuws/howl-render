const std = @import("std");

pub const Target = struct {
    left_px: f32,
    right_px: f32,
    top_px: f32,
    bottom_px: f32,
    visible: bool,
};

pub const Config = struct {
    decay_fast_s: f32,
    decay_slow_s: f32,
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

    pub fn update(self: *CursorTrail, config: Config, now_ns: u64, cursor_visible: bool) bool {
        std.debug.assert(config.decay_fast_s > 0);
        std.debug.assert(config.decay_slow_s > 0);
        const previous_needs_render = self.needs_render;
        if (self.updated_at_ns < now_ns) {
            const dt_s = @as(f32, @floatFromInt(now_ns - self.updated_at_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s));
            self.updateCorners(config, dt_s);
            self.updateOpacity(config, dt_s, cursor_visible);
        }
        self.updateNeedsRender();
        self.updated_at_ns = now_ns;
        return self.needs_render or previous_needs_render;
    }

    fn updateCorners(self: *CursorTrail, config: Config, dt_s: f32) void {
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
            const decay = if (min_dot == max_dot) config.decay_slow_s else config.decay_slow_s + (config.decay_fast_s - config.decay_slow_s) * (dot[index] - min_dot) / (max_dot - min_dot);
            const step = 1.0 - @exp2(-10.0 * dt_s / decay);
            self.corner_x[index] += dx[index] * step;
            self.corner_y[index] += dy[index] * step;
        }
    }

    fn updateOpacity(self: *CursorTrail, config: Config, dt_s: f32, cursor_visible: bool) void {
        const delta = dt_s / config.decay_slow_s;
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

fn norm(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}

test "cursor trail corners ease toward target" {
    var trail = CursorTrail{};
    trail.snapToTarget(.{ .left_px = 0, .right_px = 8, .top_px = 0, .bottom_px = 16, .visible = true }, 1);
    trail.setTarget(.{ .left_px = 32, .right_px = 40, .top_px = 0, .bottom_px = 16, .visible = true });

    try std.testing.expect(trail.update(.{ .decay_fast_s = 0.1, .decay_slow_s = 0.4 }, 1 + 16 * std.time.ns_per_ms, true));
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
    while (index < 80 and trail.update(.{ .decay_fast_s = 0.1, .decay_slow_s = 0.4 }, now_ns + 16 * std.time.ns_per_ms, true)) : (index += 1) {
        now_ns += 16 * std.time.ns_per_ms;
    }
    try std.testing.expect(!trail.needs_render);
    try std.testing.expect(trail.corner_x[0] >= 39.5);
}

test "cursor trail opacity follows cursor visibility" {
    var trail = CursorTrail{};
    trail.snapToTarget(.{ .left_px = 0, .right_px = 8, .top_px = 0, .bottom_px = 16, .visible = true }, 1);
    try std.testing.expectEqual(@as(f32, 1), trail.opacity);

    _ = trail.update(.{ .decay_fast_s = 0.1, .decay_slow_s = 0.4 }, 1 + 100 * std.time.ns_per_ms, false);
    try std.testing.expect(trail.opacity < 1);
    try std.testing.expect(trail.opacity > 0);
}
