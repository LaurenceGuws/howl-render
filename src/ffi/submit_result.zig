const std = @import("std");
const c = @import("../ffi.zig").c;
const prepared_submit_result = @import("../prepared/submit_result.zig");
const text_session = @import("../session/text.zig");

pub fn metricsOut(value: prepared_submit_result.Metrics) c.HowlRenderMetrics {
    return .{
        .sync_us = value.sync_us,
        .copy_us = value.copy_us,
        .render_us = value.render_us,
        .glyphs = value.glyphs,
        .fills = value.fills,
        .clear_fills = value.clear_fills,
        .background_fills = value.background_fills,
        .decoration_fills = value.decoration_fills,
        .cursor_fills = value.cursor_fills,
        .uploads = value.uploads,
        .face_checks = value.face_checks,
        .face_cache_hits = value.face_cache_hits,
        .shape_requests = value.shape_requests,
        .shape_cache_hits = value.shape_cache_hits,
        .fallback_hits = value.fallback_hits,
        .fallback_misses = value.fallback_misses,
        .missing_glyphs = value.missing_glyphs,
    };
}

pub fn submitResultOut(value: prepared_submit_result.SubmitResult) c.HowlRenderSubmitResult {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .damage_kind = @intFromEnum(value.damageKind()),
        .host_surface = .{
            .host_surface_id = value.host_surface.host_surface_id,
            .width = value.host_surface.width,
            .height = value.host_surface.height,
        },
        .metrics = metricsOut(value.metrics),
    };
}

pub fn failedSubmitResult() c.HowlRenderSubmitResult {
    return .{
        .status = c.HOWL_RENDER_CALL_FAILED,
        .damage_kind = 0,
        .host_surface = .{ .host_surface_id = 0, .width = 0, .height = 0 },
        .metrics = std.mem.zeroes(c.HowlRenderMetrics),
    };
}

pub fn submitExecutionIn(value: c.HowlRenderSubmitExecution) text_session.TextSession.SubmitExecution {
    return .{
        .host_surface = .{
            .host_surface_id = value.host_surface.host_surface_id,
            .width = value.host_surface.width,
            .height = value.host_surface.height,
        },
        .uploads_committed = value.uploads_committed,
        .render_us = value.render_us,
    };
}
