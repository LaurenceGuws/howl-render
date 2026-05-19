const std = @import("std");
const Render = @import("../howl_render.zig");
const surface_buffer = @import("surface_buffer.zig");
const surface_text = @import("surface_text.zig");

pub fn Owner(comptime Ffi: type) type {
    return struct {
        session_owner: *surface_text.SurfaceTextOwner,
        prepared: Render.PreparedSurface,
        snapshot_seq: u64,
        dirty_epoch: u64,
        geometry_epoch: u64,
        required_base_seq: u64,
        required_surface_epoch: u64,
        render_px: Ffi.FfiPixelSize,
        cell_px: Ffi.FfiCellSize,
        grid: Ffi.FfiGridSize,
        prepare_metrics: Ffi.FfiSurfaceMetrics,
        damage_kind: u8,
        rgba_pixels: []u8 = &.{},
        uploads_committed: u64,
        missing_glyphs: u64,
        resolve_metrics: Ffi.FfiSurfaceMetrics,

        pub fn destroy(self: *@This()) void {
            self.prepared.deinit();
            freeOwnedSlice(u8, &self.rgba_pixels);
            std.heap.c_allocator.destroy(self);
        }
    };
}

pub fn create(comptime Ffi: type, session_owner: *surface_text.SurfaceTextOwner, value: Render.PreparedSurface) !*Owner(Ffi) {
    var owner = try std.heap.c_allocator.create(Owner(Ffi));
    errdefer std.heap.c_allocator.destroy(owner);
    owner.* = ownerBase(Ffi, session_owner, value);
    errdefer owner.destroy();
    try copySurfaceBuffer(Ffi, owner);
    return owner;
}

fn ownerBase(comptime Ffi: type, session_owner: *surface_text.SurfaceTextOwner, value: Render.PreparedSurface) Owner(Ffi) {
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
        .prepare_metrics = prepareMetrics(Ffi, value),
        .damage_kind = @intFromEnum(value.damageKind()),
        .uploads_committed = value.text_frame.raster_plan.outputs.len,
        .missing_glyphs = value.text_frame.scene.scene.missing.len,
        .resolve_metrics = resolveMetrics(Ffi, value),
    };
}

fn prepareMetrics(comptime Ffi: type, value: Render.PreparedSurface) Ffi.FfiSurfaceMetrics {
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

fn resolveMetrics(comptime Ffi: type, value: Render.PreparedSurface) Ffi.FfiSurfaceMetrics {
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

fn copySurfaceBuffer(comptime Ffi: type, owner: *Owner(Ffi)) !void {
    const damage_kind = owner.prepared.damageKind();
    const base_pixels = if (damage_kind == .partial)
        owner.session_owner.requiredRetainedSurfaceBase(&owner.prepared)
    else blk: {
        std.debug.assert(damage_kind == .full);
        break :blk null;
    };
    owner.rgba_pixels = try surface_buffer.compose(
        std.heap.c_allocator,
        base_pixels,
        &owner.session_owner.session,
        &owner.prepared,
    );
}

pub fn fromHandle(comptime Ffi: type, handle: Ffi.PreparedSurfaceHandle) ?*Owner(Ffi) {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

pub fn infoOut(comptime Ffi: type, owner: *Owner(Ffi)) Ffi.FfiPreparedSurfaceInfo {
    return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok), .snapshot_seq = owner.snapshot_seq, .dirty_epoch = owner.dirty_epoch, .geometry_epoch = owner.geometry_epoch, .required_base_seq = owner.required_base_seq, .required_surface_epoch = owner.required_surface_epoch, .render_px = owner.render_px, .cell_px = owner.cell_px, .grid = owner.grid, .prepare_metrics = owner.prepare_metrics, .damage_kind = owner.damage_kind };
}

pub fn bufferOut(comptime Ffi: type, owner: *Owner(Ffi)) Ffi.FfiPreparedSurfaceBuffer {
    return .{
        .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok),
        .rgba_pixels = span(Ffi.FfiByteSpan, owner.rgba_pixels),
        .uploads_committed = owner.uploads_committed,
    };
}

pub fn diagnosticsOut(comptime Ffi: type, owner: *Owner(Ffi)) Ffi.FfiPreparedSurfaceDiagnostics {
    return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok), .missing_glyphs = owner.missing_glyphs, .resolve_metrics = owner.resolve_metrics };
}

fn freeOwnedSlice(comptime T: type, buffer: *[]T) void {
    if (buffer.*.len == 0) return;
    std.heap.c_allocator.free(buffer.*);
    buffer.* = &.{};
}

fn span(comptime Span: type, items: anytype) Span {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}
