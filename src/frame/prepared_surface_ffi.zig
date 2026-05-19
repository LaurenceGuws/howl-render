const std = @import("std");
const Render = @import("../howl_render.zig");
const abi = @import("../ffi_types.zig");
const surface_buffer = @import("surface_buffer.zig");
const surface_text = @import("surface_text.zig");

pub const Owner = struct {
    session_owner: *surface_text.SurfaceTextOwner,
    prepared: Render.PreparedSurface,
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

    pub fn destroy(self: *Owner) void {
        self.prepared.deinit();
        freeOwnedSlice(u8, &self.rgba_pixels);
        std.heap.c_allocator.destroy(self);
    }
};

pub fn create(session_owner: *surface_text.SurfaceTextOwner, value: Render.PreparedSurface) !*Owner {
    var owner = try std.heap.c_allocator.create(Owner);
    errdefer std.heap.c_allocator.destroy(owner);
    owner.* = ownerBase(session_owner, value);
    errdefer owner.destroy();
    try copySurfaceBuffer(owner);
    return owner;
}

fn ownerBase(session_owner: *surface_text.SurfaceTextOwner, value: Render.PreparedSurface) Owner {
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
        .prepare_metrics = prepareMetrics(value),
        .damage_kind = @intFromEnum(value.damageKind()),
        .uploads_committed = value.text_frame.raster_plan.outputs.len,
        .missing_glyphs = value.text_frame.scene.scene.missing.len,
        .resolve_metrics = resolveMetrics(value),
    };
}

fn prepareMetrics(value: Render.PreparedSurface) abi.FfiSurfaceMetrics {
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

fn resolveMetrics(value: Render.PreparedSurface) abi.FfiSurfaceMetrics {
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

fn copySurfaceBuffer(owner: *Owner) !void {
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

pub fn fromHandle(handle: abi.PreparedSurfaceHandle) ?*Owner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

fn infoOut(owner: *Owner) abi.FfiPreparedSurfaceInfo {
    return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.ok), .snapshot_seq = owner.snapshot_seq, .dirty_epoch = owner.dirty_epoch, .geometry_epoch = owner.geometry_epoch, .required_base_seq = owner.required_base_seq, .required_surface_epoch = owner.required_surface_epoch, .render_px = owner.render_px, .cell_px = owner.cell_px, .grid = owner.grid, .prepare_metrics = owner.prepare_metrics, .damage_kind = owner.damage_kind };
}

fn bufferOut(owner: *Owner) abi.FfiPreparedSurfaceBuffer {
    return .{
        .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
        .rgba_pixels = span(owner.rgba_pixels),
        .uploads_committed = owner.uploads_committed,
    };
}

fn diagnosticsOut(owner: *Owner) abi.FfiPreparedSurfaceDiagnostics {
    return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.ok), .missing_glyphs = owner.missing_glyphs, .resolve_metrics = owner.resolve_metrics };
}

pub fn release(prepared_surface_handle: abi.PreparedSurfaceHandle) callconv(.c) void {
    const owner = fromHandle(prepared_surface_handle) orelse return;
    owner.destroy();
}

pub fn describe(prepared_surface_handle: abi.PreparedSurfaceHandle, info_out: ?*abi.FfiPreparedSurfaceInfo) callconv(.c) c_int {
    const owner = fromHandle(prepared_surface_handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const out = info_out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    out.* = infoOut(owner);
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn buffer(prepared_surface_handle: abi.PreparedSurfaceHandle, buffer_out: ?*abi.FfiPreparedSurfaceBuffer) callconv(.c) c_int {
    const owner = fromHandle(prepared_surface_handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const out = buffer_out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    out.* = bufferOut(owner);
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn diagnostics(prepared_surface_handle: abi.PreparedSurfaceHandle, diagnostics_out: ?*abi.FfiPreparedSurfaceDiagnostics) callconv(.c) c_int {
    const owner = fromHandle(prepared_surface_handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const out = diagnostics_out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    out.* = diagnosticsOut(owner);
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

fn freeOwnedSlice(comptime T: type, items: *[]T) void {
    if (items.*.len == 0) return;
    std.heap.c_allocator.free(items.*);
    items.* = &.{};
}

fn span(items: []u8) abi.FfiByteSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}
