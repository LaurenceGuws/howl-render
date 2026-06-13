const std = @import("std");
const c = @import("howl_render_c");

test {
    std.testing.refAllDecls(@import("libhowl_render.zig"));
    _ = @import("text_session_test.zig");
    _ = @import("surface_geometry_test.zig");
    _ = @import("prepare_request_test.zig");
    _ = @import("prepared_surface_test.zig");
    _ = @import("submission_test.zig");
}

test "render c header translation exports shipped entrypoints" {
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_init"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_deinit"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_set_font_size_px"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_set_font_path"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_set_fallback_font_paths"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_set_cursor_blink_visible"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_is_valid_font"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_derive_layout"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_sync_geometry"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_prepare_handle"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_take_prepare_request"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_take_submit_handle"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_accept_submitted"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_submit"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_submit_handle"));
    try std.testing.expect(@hasDecl(c, "howl_render_text_session_work_state"));
    try std.testing.expect(@hasDecl(c, "howl_render_rdr_sfc_release"));
    try std.testing.expect(@hasDecl(c, "howl_render_rdr_sfc_describe"));
    try std.testing.expect(@hasDecl(c, "howl_render_rdr_sfc_render_surface"));
}

test "render c enum values remain stable" {
    try std.testing.expectEqual(@as(c_int, 0), c.HOWL_RENDER_CALL_OK);
    try std.testing.expectEqual(@as(c_int, -1), c.HOWL_RENDER_CALL_MISSING_HANDLE);
    try std.testing.expectEqual(@as(c_int, -2), c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
    try std.testing.expectEqual(@as(c_int, -3), c.HOWL_RENDER_CALL_FAILED);
    try std.testing.expectEqual(@as(c_int, 0), c.HOWL_RENDER_PREPARE_IDLE);
    try std.testing.expectEqual(@as(c_int, 1), c.HOWL_RENDER_PREPARE_READY);
    try std.testing.expectEqual(@as(c_int, -3), c.HOWL_RENDER_PREPARE_FAILED);
    try std.testing.expectEqual(@as(c_int, 0), c.HOWL_RENDER_SUBMIT_IDLE);
    try std.testing.expectEqual(@as(c_int, 1), c.HOWL_RENDER_SUBMIT_RENDERED);
    try std.testing.expectEqual(@as(c_int, 2), c.HOWL_RENDER_SUBMIT_STALE);
    try std.testing.expectEqual(@as(c_int, 3), c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE);
    try std.testing.expectEqual(@as(c_int, -3), c.HOWL_RENDER_SUBMIT_FAILED);
    try std.testing.expectEqual(@as(c_int, 0), c.HOWL_RENDER_SUBMIT_DECISION_IDLE);
    try std.testing.expectEqual(@as(c_int, 1), c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT);
    try std.testing.expectEqual(@as(c_int, 2), c.HOWL_RENDER_SUBMIT_DECISION_STALE);
    try std.testing.expectEqual(@as(c_int, 3), c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE);
    try std.testing.expectEqual(@as(c_int, -3), c.HOWL_RENDER_SUBMIT_DECISION_FAILED);
    try std.testing.expectEqual(@as(c_int, 0), c.HOWL_RENDER_DAMAGE_NONE);
    try std.testing.expectEqual(@as(c_int, 1), c.HOWL_RENDER_DAMAGE_PARTIAL);
    try std.testing.expectEqual(@as(c_int, 3), c.HOWL_RENDER_DAMAGE_FULL);
}

test "render c struct sizes remain stable" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(c.HowlRenderPrepareRequest));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(c.HowlRenderPreparedSurfaceToken));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(c.HowlRenderHostSurface));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(c.HowlRenderSubmitResult));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(c.HowlRenderSessionWorkState));
}
