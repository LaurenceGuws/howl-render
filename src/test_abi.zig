const std = @import("std");

test {
    std.testing.refAllDecls(@import("libhowl_render.zig"));
    _ = @import("ffi/text_session_test.zig");
    _ = @import("ffi/surface_geometry_test.zig");
    _ = @import("ffi/vt_surface_test.zig");
    _ = @import("ffi/prepare_request_test.zig");
    _ = @import("ffi/prepared_surface_test.zig");
    _ = @import("ffi/submission_test.zig");
}
