const std = @import("std");

test {
    std.testing.refAllDecls(@import("libhowl_render.zig"));
    _ = @import("test/ffi.zig");
    _ = @import("test/unit.zig");
}

pub const main = @import("test/benchmark.zig").main;
