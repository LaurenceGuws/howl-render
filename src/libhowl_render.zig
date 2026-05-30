const text_session = @import("text_session.zig");
const surface_geometry = @import("surface_geometry.zig");
const vt_surface = @import("vt_surface.zig");
const prepared_surface = @import("prepared_surface.zig");
const prepare_request = @import("ffi/prepare_request.zig");
const submission = @import("submission.zig");
const work_state = @import("work_state.zig");

comptime {
    @export(&text_session.init, .{ .name = "howl_render_text_session_init" });
    @export(&text_session.deinit, .{ .name = "howl_render_text_session_deinit" });
    @export(&text_session.setFontSize, .{ .name = "howl_render_text_session_set_font_size_px" });
    @export(&text_session.setFontPath, .{ .name = "howl_render_text_session_set_font_path" });
    @export(&text_session.setFallbackFontPaths, .{ .name = "howl_render_text_session_set_fallback_font_paths" });
    @export(&text_session.setCursorBlinkVisible, .{ .name = "howl_render_text_session_set_cursor_blink_visible" });
    @export(&text_session.isValidFont, .{ .name = "howl_render_text_session_is_valid_font" });
    @export(&surface_geometry.deriveLayout, .{ .name = "howl_render_text_session_derive_layout" });
    @export(&surface_geometry.syncGeometry, .{ .name = "howl_render_text_session_sync_geometry" });
    @export(&vt_surface.reserveVtSurfaceSlot, .{ .name = "howl_render_text_session_reserve_vt_surface_slot" });
    @export(&vt_surface.commitVtSurface, .{ .name = "howl_render_text_session_commit_vt_surface" });
    @export(&vt_surface.rejectVtSurface, .{ .name = "howl_render_text_session_reject_vt_surface" });
    @export(&vt_surface.cancelVtSurface, .{ .name = "howl_render_text_session_cancel_vt_surface" });
    @export(&prepared_surface.prepareHandle, .{ .name = "howl_render_text_session_prepare_handle" });
    @export(&prepare_request.takePrepareRequest, .{ .name = "howl_render_text_session_take_prepare_request" });
    @export(&submission.publishPrepared, .{ .name = "howl_render_text_session_publish_prepared" });
    @export(&submission.publishPreparedHandle, .{ .name = "howl_render_text_session_publish_prepared_handle" });
    @export(&submission.takeSubmitDecision, .{ .name = "howl_render_text_session_take_submit_decision" });
    @export(&submission.takeSubmitHandle, .{ .name = "howl_render_text_session_take_submit_handle" });
    @export(&submission.acceptSubmitted, .{ .name = "howl_render_text_session_accept_submitted" });
    @export(&submission.submit, .{ .name = "howl_render_text_session_submit" });
    @export(&submission.submitHandle, .{ .name = "howl_render_text_session_submit_handle" });
    @export(&work_state.workState, .{ .name = "howl_render_text_session_work_state" });
    @export(&prepared_surface.release, .{ .name = "howl_render_prepared_surface_release" });
    @export(&prepared_surface.describe, .{ .name = "howl_render_prepared_surface_describe" });
    @export(&prepared_surface.buffer, .{ .name = "howl_render_prepared_surface_buffer" });
    @export(&prepared_surface.diagnostics, .{ .name = "howl_render_prepared_surface_diagnostics" });
}
