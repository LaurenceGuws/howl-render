const std = @import("std");
const geometry = @import("grid_geometry.zig");
const geometry_contract = @import("geometry_contract.zig");

test "render surface pixel geometry clamps to drawable size" {
    const pixels = geometry_contract.SurfacePixels{ .render_width = 0, .render_height = -2, .grid_width = 80, .grid_height = 24 };
    try std.testing.expectEqual(@as(u16, 1), pixels.renderWidth());
    try std.testing.expectEqual(@as(u16, 1), pixels.renderHeight());
    try std.testing.expectEqual(@as(u16, 80), pixels.gridWidth());
    try std.testing.expectEqual(@as(u16, 24), pixels.gridHeight());
}

test "surface geometry derives grid deterministically" {
    const grid = geometry.deriveGridSize(.{ .width = 80, .height = 48 }, .{ .width = 8, .height = 16 });
    try std.testing.expectEqual(@as(u16, 10), grid.cols);
    try std.testing.expectEqual(@as(u16, 3), grid.rows);

    const surface_grid = try geometry.deriveGridForSurface(
        .{ .width = 800, .height = 600 },
        .{ .width = 640, .height = 320 },
        .{ .width = 8, .height = 16 },
    );
    try std.testing.expectEqual(@as(u16, 80), surface_grid.cols);
    try std.testing.expectEqual(@as(u16, 20), surface_grid.rows);
}
