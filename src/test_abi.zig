const std = @import("std");

test {
    std.testing.refAllDecls(@import("libhowl_render.zig"));
    _ = @import("text_session_test.zig");
    _ = @import("surface_geometry_test.zig");
    _ = @import("prepare_request_test.zig");
    _ = @import("prepared_surface_test.zig");
    _ = @import("submission_test.zig");
}
