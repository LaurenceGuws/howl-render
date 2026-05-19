const std = @import("std");
const abi = @import("../ffi_types.zig");
const pipeline = @import("pipeline.zig");
const surface = @import("surface.zig");
const surface_buffer = @import("surface_buffer.zig");
const surface_text = @import("surface_text.zig");

pub const Owner = struct {
    session_owner: *surface_text.SurfaceTextOwner,
    prepared: surface.PreparedSurface,
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    required_surface_epoch: u64,
    render_px: abi.FfiPixelSize,
    cell_px: abi.FfiCellSize,
    grid: abi.FfiGridSize,
    prepare_metrics: abi.FfiSurfaceMetrics,
    damage_kind: u8,
    rgba_pixels: []u8 = &.{},
    uploads_committed: u64,
    missing_glyphs: u64,
    resolve_metrics: abi.FfiSurfaceMetrics,

    pub const SubmitResult = union(enum) {
        rendered: surface.RenderSurfaceFeedback,
        needs_prepare,
        failed,
    };

    pub fn create(
        session_owner: *surface_text.SurfaceTextOwner,
        value: surface.PreparedSurface,
    ) !*Owner {
        var owner = try std.heap.c_allocator.create(Owner);
        errdefer std.heap.c_allocator.destroy(owner);
        owner.* = ownerBase(session_owner, value);
        errdefer owner.destroy();
        try owner.copySurfaceBuffer();
        return owner;
    }

    pub fn fromHandle(handle: abi.PreparedSurfaceHandle) ?*Owner {
        const owned = handle orelse return null;
        return @ptrCast(@alignCast(owned));
    }

    pub fn destroy(self: *Owner) void {
        self.prepared.deinit();
        freeOwnedBytes(&self.rgba_pixels);
        std.heap.c_allocator.destroy(self);
    }

    pub fn info(self: *Owner) abi.FfiPreparedSurfaceInfo {
        return .{
            .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
            .snapshot_seq = self.snapshot_seq,
            .dirty_epoch = self.dirty_epoch,
            .geometry_epoch = self.geometry_epoch,
            .required_base_seq = self.required_base_seq,
            .required_surface_epoch = self.required_surface_epoch,
            .render_px = self.render_px,
            .cell_px = self.cell_px,
            .grid = self.grid,
            .prepare_metrics = self.prepare_metrics,
            .damage_kind = self.damage_kind,
        };
    }

    pub fn buffer(self: *Owner) abi.FfiPreparedSurfaceBuffer {
        return .{
            .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
            .rgba_pixels = byteSpan(self.rgba_pixels),
            .uploads_committed = self.uploads_committed,
        };
    }

    pub fn diagnostics(self: *Owner) abi.FfiPreparedSurfaceDiagnostics {
        return .{
            .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
            .missing_glyphs = self.missing_glyphs,
            .resolve_metrics = self.resolve_metrics,
        };
    }

    pub fn submit(
        self: *Owner,
        session_owner: *surface_text.SurfaceTextOwner,
        prepared_frame: pipeline.PreparedFrame,
        execution: surface_text.SurfaceText.RenderSurfaceExecutionInput,
    ) SubmitResult {
        if (self.session_owner != session_owner) return .failed;
        if (!samePreparedFrame(self.prepared.pipelineFrame(), prepared_frame)) {
            return .needs_prepare;
        }
        const feedback = session_owner.session.submitSurface(&self.prepared, execution) catch {
            return .failed;
        };
        if (feedback.content_valid) {
            session_owner.retainSurfaceImage(
                &self.rgba_pixels,
                self.prepared.render_px.width,
                self.prepared.render_px.height,
                feedback.surface.epoch,
            );
        } else {
            session_owner.clearRetainedSurface();
        }
        self.destroy();
        return .{ .rendered = feedback };
    }

    fn copySurfaceBuffer(self: *Owner) !void {
        const base_pixels = switch (self.prepared.damageKind()) {
            .partial => self.session_owner.requiredRetainedSurfaceBase(&self.prepared),
            .full => null,
            else => unreachable,
        };
        self.rgba_pixels = try surface_buffer.compose(
            std.heap.c_allocator,
            base_pixels,
            &self.session_owner.session,
            &self.prepared,
        );
    }
};

fn ownerBase(session_owner: *surface_text.SurfaceTextOwner, value: surface.PreparedSurface) Owner {
    return .{
        .session_owner = session_owner,
        .prepared = value,
        .snapshot_seq = value.request.token.snapshot_seq,
        .dirty_epoch = value.request.token.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .required_base_seq = value.pipelineFrame().required_base_seq,
        .required_surface_epoch = value.required_surface_epoch,
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .grid = .{ .cols = value.grid.cols, .rows = value.grid.rows },
        .prepare_metrics = preparedMetricsOut(value),
        .damage_kind = @intFromEnum(value.damageKind()),
        .uploads_committed = value.text_frame.raster_plan.outputs.len,
        .missing_glyphs = value.text_frame.scene.scene.missing.len,
        .resolve_metrics = resolveMetricsOut(value),
    };
}

fn preparedMetricsOut(value: surface.PreparedSurface) abi.FfiSurfaceMetrics {
    return .{
        .sync_us = value.prepare_metrics.sync_us,
        .copy_us = value.prepare_metrics.copy_us,
        .render_us = value.prepare_metrics.surface_us,
        .glyphs = 0,
        .fills = 0,
        .clear_fills = 0,
        .background_fills = 0,
        .decoration_fills = 0,
        .cursor_fills = 0,
        .uploads = 0,
        .face_checks = 0,
        .face_cache_hits = 0,
        .shape_requests = 0,
        .shape_cache_hits = 0,
        .fallback_hits = 0,
        .fallback_misses = 0,
        .missing_glyphs = 0,
    };
}

fn resolveMetricsOut(value: surface.PreparedSurface) abi.FfiSurfaceMetrics {
    return .{
        .sync_us = 0,
        .copy_us = 0,
        .render_us = 0,
        .glyphs = 0,
        .fills = 0,
        .clear_fills = 0,
        .background_fills = 0,
        .decoration_fills = 0,
        .cursor_fills = 0,
        .uploads = 0,
        .face_checks = value.resolve.counters.face_checks,
        .face_cache_hits = value.resolve.counters.face_cache_hits,
        .shape_requests = value.resolve.counters.shape_requests,
        .shape_cache_hits = value.resolve.counters.shape_cache_hits,
        .fallback_hits = value.resolve.counters.fallback_hits,
        .fallback_misses = value.resolve.counters.fallback_misses,
        .missing_glyphs = value.resolve.counters.missing_glyphs,
    };
}

fn freeOwnedBytes(items: *[]u8) void {
    if (items.*.len == 0) return;
    std.heap.c_allocator.free(items.*);
    items.* = &.{};
}

fn byteSpan(items: []u8) abi.FfiByteSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn samePreparedFrame(a: pipeline.PreparedFrame, b: pipeline.PreparedFrame) bool {
    return a.token.snapshot_seq == b.token.snapshot_seq and
        a.token.dirty_epoch == b.token.dirty_epoch and
        a.token.geometry_epoch == b.token.geometry_epoch and
        a.token.damage_base_seq == b.token.damage_base_seq and
        a.token.damage_kind == b.token.damage_kind and
        a.required_base_seq == b.required_base_seq and
        a.required_target_epoch == b.required_target_epoch;
}
