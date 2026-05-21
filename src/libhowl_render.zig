const ffi = @import("ffi.zig");

comptime {
    @export(&ffi.surfaceTextDeriveFrameLayout, .{ .name = "howl_render_surface_text_derive_frame_layout" });
    @export(&ffi.surfaceTextInit, .{ .name = "howl_render_surface_text_init" });
    @export(&ffi.surfaceTextDeinit, .{ .name = "howl_render_surface_text_deinit" });
    @export(&ffi.surfaceTextSetFontSizePx, .{ .name = "howl_render_surface_text_set_font_size_px" });
    @export(&ffi.surfaceTextSetFontPath, .{ .name = "howl_render_surface_text_set_font_path" });
    @export(&ffi.surfaceTextSetFallbackFontPaths, .{ .name = "howl_render_surface_text_set_fallback_font_paths" });
    @export(&ffi.surfaceTextSyncGeometry, .{ .name = "howl_render_surface_text_sync_geometry" });
    @export(&ffi.surfaceTextPublishVtSnapshot, .{ .name = "howl_render_surface_text_publish_vt_snapshot" });
    @export(&ffi.surfaceTextTakePrepareRequest, .{ .name = "howl_render_surface_text_take_prepare_request" });
    @export(&ffi.surfaceTextPublishPrepared, .{ .name = "howl_render_surface_text_publish_prepared" });
    @export(&ffi.surfaceTextTakeSubmitDecision, .{ .name = "howl_render_surface_text_take_submit_decision" });
    @export(&ffi.surfaceTextAcceptSubmitted, .{ .name = "howl_render_surface_text_accept_submitted" });
    @export(&ffi.surfaceTextMarkPresented, .{ .name = "howl_render_surface_text_mark_presented" });
    @export(&ffi.surfaceTextPendingState, .{ .name = "howl_render_surface_text_pending_state" });
    @export(&ffi.surfaceTextTakeQueueMetrics, .{ .name = "howl_render_surface_text_take_queue_metrics" });
    @export(&ffi.surfaceTextPrepareHandle, .{ .name = "howl_render_surface_text_prepare_handle" });
    @export(&ffi.preparedSurfaceRelease, .{ .name = "howl_render_prepared_surface_release" });
    @export(&ffi.preparedSurfaceDescribe, .{ .name = "howl_render_prepared_surface_describe" });
    @export(&ffi.preparedSurfaceBuffer, .{ .name = "howl_render_prepared_surface_buffer" });
    @export(&ffi.preparedSurfaceDiagnostics, .{ .name = "howl_render_prepared_surface_diagnostics" });
    @export(&ffi.surfaceTextSubmit, .{ .name = "howl_render_surface_text_submit" });
}
