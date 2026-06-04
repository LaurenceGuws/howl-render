const std = @import("std");

test {
    std.testing.refAllDecls(@import("libhowl_render.zig"));
    _ = @import("ffi_test.zig");
}
