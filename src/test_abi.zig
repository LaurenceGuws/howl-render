const std = @import("std");
const c = @import("howl_render_c");

test {
    std.testing.refAllDecls(@import("libhowl_render.zig"));
}

test "render c enum values remain stable" {
    try std.testing.expectEqual(@as(c_int, 0), c.HOWL_RENDER_CALL_OK);
    try std.testing.expectEqual(@as(c_int, -1), c.HOWL_RENDER_CALL_MISSING_HANDLE);
    try std.testing.expectEqual(@as(c_int, -2), c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
    try std.testing.expectEqual(@as(c_int, -3), c.HOWL_RENDER_CALL_FAILED);
    try std.testing.expectEqual(@as(c_int, 0), c.HOWL_RENDER_DAMAGE_NONE);
    try std.testing.expectEqual(@as(c_int, 1), c.HOWL_RENDER_DAMAGE_PARTIAL);
    try std.testing.expectEqual(@as(c_int, 3), c.HOWL_RENDER_DAMAGE_FULL);
}
