const std = @import("std");
const geometry = @import("../render/grid_geometry.zig");
const geometry_contract = @import("../render/geometry_contract.zig");

test {
    _ = @import("../protocol_v0/realize.zig");
}

test "render frame pixel geometry clamps to drawable size" {
    const frame = geometry_contract.FramePixels{ .render_width = 0, .render_height = -2, .grid_width = 80, .grid_height = 24 };
    try std.testing.expectEqual(@as(u16, 1), frame.renderWidth());
    try std.testing.expectEqual(@as(u16, 1), frame.renderHeight());
    try std.testing.expectEqual(@as(u16, 80), frame.gridWidth());
    try std.testing.expectEqual(@as(u16, 24), frame.gridHeight());
}

test "surface geometry derives grid deterministically" {
    const grid = geometry.deriveGridSize(.{ .width = 80, .height = 48 }, .{ .width = 8, .height = 16 });
    try std.testing.expectEqual(@as(u16, 10), grid.cols);
    try std.testing.expectEqual(@as(u16, 3), grid.rows);

    const frame_grid = try geometry.deriveGridForFrame(
        .{ .width = 800, .height = 600 },
        .{ .width = 640, .height = 320 },
        .{ .width = 8, .height = 16 },
    );
    try std.testing.expectEqual(@as(u16, 80), frame_grid.cols);
    try std.testing.expectEqual(@as(u16, 20), frame_grid.rows);
}
