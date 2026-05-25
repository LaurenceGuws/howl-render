const std = @import("std");

test {
    std.testing.refAllDecls(@import("howl_render.zig"));
    _ = @import("test/unit.zig");
}
