const std = @import("std");
const support = @import("test_support.zig");
const c = support.c;

test "render ffi missing handles report shipped contract" {
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, support.text.setFontSize(null, 12));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, support.text.isValidFont(null));
    var session_work = std.mem.zeroes(c.HowlRenderSessionWorkState);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, support.work.workState(null, &session_work));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, session_work.status);
}

test "render ffi text-session invalid arguments report shipped contract" {
    const handle = support.text.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer support.text.deinit(handle);
    try std.testing.expect(handle != null);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.text.setFontSize(handle, 0));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.text.setFontPath(handle, null, 1));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.text.setFallbackFontPaths(handle, null, 1));
}

test "render ffi text-session invalid font path stays bounded" {
    const handle = support.text.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer support.text.deinit(handle);
    try std.testing.expect(handle != null);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, support.text.setFontPath(handle, "/definitely/not/a/font".ptr, "/definitely/not/a/font".len));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_FAILED, support.text.isValidFont(handle));
}
