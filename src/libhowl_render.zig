const ffi = @import("ffi.zig");

comptime {
    @export(&ffi.deriveFrameLayout, .{ .name = "howl_render_surface_text_derive_frame_layout" });
    @export(&ffi.init, .{ .name = "howl_render_surface_text_init" });
    @export(&ffi.deinit, .{ .name = "howl_render_surface_text_deinit" });
    @export(&ffi.isValidFont, .{ .name = "howl_render_surface_text_is_valid_font" });
    @export(&ffi.setFontSize, .{ .name = "howl_render_surface_text_set_font_size_px" });
    @export(&ffi.setFontPath, .{ .name = "howl_render_surface_text_set_font_path" });
    @export(&ffi.setFallbackFontPaths, .{ .name = "howl_render_surface_text_set_fallback_font_paths" });
    @export(&ffi.setCursorBlinkVisible, .{ .name = "howl_render_surface_text_set_cursor_blink_visible" });
    @export(&ffi.syncGeometry, .{ .name = "howl_render_surface_text_sync_geometry" });
    @export(&ffi.reservePublishSlot, .{ .name = "howl_render_surface_text_reserve_publish_slot" });
    @export(&ffi.commitPublishSlot, .{ .name = "howl_render_surface_text_commit_publish_slot" });
    @export(&ffi.rejectPublishSlot, .{ .name = "howl_render_surface_text_reject_publish_slot" });
    @export(&ffi.cancelPublishSlot, .{ .name = "howl_render_surface_text_cancel_publish_slot" });
    @export(&ffi.takePrepareRequest, .{ .name = "howl_render_surface_text_take_prepare_request" });
    @export(&ffi.publishPrepared, .{ .name = "howl_render_surface_text_publish_prepared" });
    @export(&ffi.publishPreparedHandle, .{ .name = "howl_render_surface_text_publish_prepared_handle" });
    @export(&ffi.takeSubmitDecision, .{ .name = "howl_render_surface_text_take_submit_decision" });
    @export(&ffi.takeSubmitHandle, .{ .name = "howl_render_surface_text_take_submit_handle" });
    @export(&ffi.acceptSubmitted, .{ .name = "howl_render_surface_text_accept_submitted" });
    @export(&ffi.pendingState, .{ .name = "howl_render_surface_text_pending_state" });
    @export(&ffi.prepareHandle, .{ .name = "howl_render_surface_text_prepare_handle" });
    @export(&ffi.release, .{ .name = "howl_render_prepared_surface_release" });
    @export(&ffi.describe, .{ .name = "howl_render_prepared_surface_describe" });
    @export(&ffi.buffer, .{ .name = "howl_render_prepared_surface_buffer" });
    @export(&ffi.diagnostics, .{ .name = "howl_render_prepared_surface_diagnostics" });
    @export(&ffi.submit, .{ .name = "howl_render_surface_text_submit" });
    @export(&ffi.submitHandle, .{ .name = "howl_render_surface_text_submit_handle" });
}
