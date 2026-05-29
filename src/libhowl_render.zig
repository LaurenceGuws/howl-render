const pending_state = @import("pending_state.zig");
const prepare_request = @import("prepare_request.zig");
const prepared_surface = @import("prepared_surface.zig");
const publish_slot = @import("publish_slot.zig");
const submission = @import("submission.zig");
const surface_geometry = @import("surface_geometry.zig");
const text_session = @import("text_session.zig");

comptime {
    @export(&surface_geometry.deriveLayout, .{ .name = "howl_render_text_session_derive_layout" });
    @export(&text_session.init, .{ .name = "howl_render_text_session_init" });
    @export(&text_session.deinit, .{ .name = "howl_render_text_session_deinit" });
    @export(&text_session.isValidFont, .{ .name = "howl_render_text_session_is_valid_font" });
    @export(&text_session.setFontSize, .{ .name = "howl_render_text_session_set_font_size_px" });
    @export(&text_session.setFontPath, .{ .name = "howl_render_text_session_set_font_path" });
    @export(&text_session.setFallbackFontPaths, .{ .name = "howl_render_text_session_set_fallback_font_paths" });
    @export(&text_session.setCursorBlinkVisible, .{ .name = "howl_render_text_session_set_cursor_blink_visible" });
    @export(&surface_geometry.syncGeometry, .{ .name = "howl_render_text_session_sync_geometry" });
    @export(&publish_slot.reservePublishSlot, .{ .name = "howl_render_text_session_reserve_publish_slot" });
    @export(&publish_slot.commitPublishSlot, .{ .name = "howl_render_text_session_commit_publish_slot" });
    @export(&publish_slot.rejectPublishSlot, .{ .name = "howl_render_text_session_reject_publish_slot" });
    @export(&publish_slot.cancelPublishSlot, .{ .name = "howl_render_text_session_cancel_publish_slot" });
    @export(&prepare_request.takePrepareRequest, .{ .name = "howl_render_text_session_take_prepare_request" });
    @export(&submission.publishPrepared, .{ .name = "howl_render_text_session_publish_prepared" });
    @export(&submission.publishPreparedHandle, .{ .name = "howl_render_text_session_publish_prepared_handle" });
    @export(&submission.takeSubmitDecision, .{ .name = "howl_render_text_session_take_submit_decision" });
    @export(&submission.takeSubmitHandle, .{ .name = "howl_render_text_session_take_submit_handle" });
    @export(&submission.acceptSubmitted, .{ .name = "howl_render_text_session_accept_submitted" });
    @export(&pending_state.pendingState, .{ .name = "howl_render_text_session_pending_state" });
    @export(&prepared_surface.prepareHandle, .{ .name = "howl_render_text_session_prepare_handle" });
    @export(&prepared_surface.release, .{ .name = "howl_render_prepared_surface_release" });
    @export(&prepared_surface.describe, .{ .name = "howl_render_prepared_surface_describe" });
    @export(&prepared_surface.buffer, .{ .name = "howl_render_prepared_surface_buffer" });
    @export(&prepared_surface.diagnostics, .{ .name = "howl_render_prepared_surface_diagnostics" });
    @export(&submission.submit, .{ .name = "howl_render_text_session_submit" });
    @export(&submission.submitHandle, .{ .name = "howl_render_text_session_submit_handle" });
}
