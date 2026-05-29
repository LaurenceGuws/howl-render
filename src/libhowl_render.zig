const pending_state = @import("pending_state.zig");
const prepare_request = @import("prepare_request.zig");
const prepared_surface = @import("prepared_surface.zig");
const publish_slot = @import("publish_slot.zig");
const submission = @import("submission.zig");
const surface_geometry = @import("surface_geometry.zig");
const surface_text = @import("surface_text.zig");

comptime {
    @export(&surface_geometry.deriveLayout, .{ .name = "howl_render_surface_text_derive_layout" });
    @export(&surface_text.init, .{ .name = "howl_render_surface_text_init" });
    @export(&surface_text.deinit, .{ .name = "howl_render_surface_text_deinit" });
    @export(&surface_text.isValidFont, .{ .name = "howl_render_surface_text_is_valid_font" });
    @export(&surface_text.setFontSize, .{ .name = "howl_render_surface_text_set_font_size_px" });
    @export(&surface_text.setFontPath, .{ .name = "howl_render_surface_text_set_font_path" });
    @export(&surface_text.setFallbackFontPaths, .{ .name = "howl_render_surface_text_set_fallback_font_paths" });
    @export(&surface_text.setCursorBlinkVisible, .{ .name = "howl_render_surface_text_set_cursor_blink_visible" });
    @export(&surface_geometry.syncGeometry, .{ .name = "howl_render_surface_text_sync_geometry" });
    @export(&publish_slot.reservePublishSlot, .{ .name = "howl_render_surface_text_reserve_publish_slot" });
    @export(&publish_slot.commitPublishSlot, .{ .name = "howl_render_surface_text_commit_publish_slot" });
    @export(&publish_slot.rejectPublishSlot, .{ .name = "howl_render_surface_text_reject_publish_slot" });
    @export(&publish_slot.cancelPublishSlot, .{ .name = "howl_render_surface_text_cancel_publish_slot" });
    @export(&prepare_request.takePrepareRequest, .{ .name = "howl_render_surface_text_take_prepare_request" });
    @export(&submission.publishPrepared, .{ .name = "howl_render_surface_text_publish_prepared" });
    @export(&submission.publishPreparedHandle, .{ .name = "howl_render_surface_text_publish_prepared_handle" });
    @export(&submission.takeSubmitDecision, .{ .name = "howl_render_surface_text_take_submit_decision" });
    @export(&submission.takeSubmitHandle, .{ .name = "howl_render_surface_text_take_submit_handle" });
    @export(&submission.acceptSubmitted, .{ .name = "howl_render_surface_text_accept_submitted" });
    @export(&pending_state.pendingState, .{ .name = "howl_render_surface_text_pending_state" });
    @export(&prepared_surface.prepareHandle, .{ .name = "howl_render_surface_text_prepare_handle" });
    @export(&prepared_surface.release, .{ .name = "howl_render_prepared_surface_release" });
    @export(&prepared_surface.describe, .{ .name = "howl_render_prepared_surface_describe" });
    @export(&prepared_surface.buffer, .{ .name = "howl_render_prepared_surface_buffer" });
    @export(&prepared_surface.diagnostics, .{ .name = "howl_render_prepared_surface_diagnostics" });
    @export(&submission.submit, .{ .name = "howl_render_surface_text_submit" });
    @export(&submission.submitHandle, .{ .name = "howl_render_surface_text_submit_handle" });
}
