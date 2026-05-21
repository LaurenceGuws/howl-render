const prepared_surface_ffi = @import("frame/prepared_surface_ffi.zig");
const surface_text_ffi = @import("frame/surface_text_ffi.zig");

comptime {
    @export(&surface_text_ffi.deriveFrameLayout, .{ .name = "howl_render_surface_text_derive_frame_layout" });
    @export(&surface_text_ffi.init, .{ .name = "howl_render_surface_text_init" });
    @export(&surface_text_ffi.deinit, .{ .name = "howl_render_surface_text_deinit" });
    @export(&surface_text_ffi.isValidFont, .{ .name = "howl_render_surface_text_is_valid_font" });
    @export(&surface_text_ffi.setFontSize, .{ .name = "howl_render_surface_text_set_font_size_px" });
    @export(&surface_text_ffi.setFontPath, .{ .name = "howl_render_surface_text_set_font_path" });
    @export(&surface_text_ffi.setFallbackFontPaths, .{ .name = "howl_render_surface_text_set_fallback_font_paths" });
    @export(&surface_text_ffi.syncGeometry, .{ .name = "howl_render_surface_text_sync_geometry" });
    @export(&surface_text_ffi.publishVtSnapshot, .{ .name = "howl_render_surface_text_publish_vt_snapshot" });
    @export(&surface_text_ffi.takePrepareRequest, .{ .name = "howl_render_surface_text_take_prepare_request" });
    @export(&surface_text_ffi.publishPrepared, .{ .name = "howl_render_surface_text_publish_prepared" });
    @export(&surface_text_ffi.takeSubmitDecision, .{ .name = "howl_render_surface_text_take_submit_decision" });
    @export(&surface_text_ffi.acceptSubmitted, .{ .name = "howl_render_surface_text_accept_submitted" });
    @export(&surface_text_ffi.markPresented, .{ .name = "howl_render_surface_text_mark_presented" });
    @export(&surface_text_ffi.pendingState, .{ .name = "howl_render_surface_text_pending_state" });
    @export(&surface_text_ffi.takeQueueMetrics, .{ .name = "howl_render_surface_text_take_queue_metrics" });
    @export(&surface_text_ffi.prepareHandle, .{ .name = "howl_render_surface_text_prepare_handle" });
    @export(&prepared_surface_ffi.release, .{ .name = "howl_render_prepared_surface_release" });
    @export(&prepared_surface_ffi.describe, .{ .name = "howl_render_prepared_surface_describe" });
    @export(&prepared_surface_ffi.buffer, .{ .name = "howl_render_prepared_surface_buffer" });
    @export(&prepared_surface_ffi.diagnostics, .{ .name = "howl_render_prepared_surface_diagnostics" });
    @export(&surface_text_ffi.submit, .{ .name = "howl_render_surface_text_submit" });
}
