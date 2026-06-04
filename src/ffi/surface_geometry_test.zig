const std = @import("std");
const support = @import("test_support.zig");
const c = support.c;

test "render ffi lifecycle exports geometry and layout contract" {
    const handle = support.text.init(.{ .surface_px = .{ .width = 32, .height = 32 }, .font_size_px = 8 });
    defer support.text.deinit(handle);
    try std.testing.expect(handle != null);
    const layout = support.geometry.deriveLayout(handle, .{ .width = 32, .height = 32 }, .{ .width = 32, .height = 32 });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, layout.status);
    try std.testing.expect(layout.cell_px.width > 0);
    try std.testing.expect(layout.cell_px.height > 0);
    const geometry = support.geometry.syncGeometry(handle, .{ .render_px = .{ .width = 32, .height = 32 }, .grid_px = .{ .width = 32, .height = 32 } });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, geometry.status);
    try std.testing.expect(geometry.geometry_epoch != 0);
}
