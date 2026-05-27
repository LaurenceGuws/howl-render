const std = @import("std");
const abi = @import("../ffi_types.zig");
const prepared_surface_owner = @import("prepared_surface_owner.zig");
const pipeline = @import("pipeline.zig");
const queue = @import("queue.zig");
const surface = @import("surface.zig");
const surface_text = @import("surface_text.zig");
const text_support = @import("../text/font/ft_hb/support.zig");

fn ownerFromHandle(handle: abi.SurfaceTextHandle) ?*surface_text.SurfaceTextOwner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

pub fn isValidFont(handle: abi.SurfaceTextHandle) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    return if (owner.isValidFont())
        @intFromEnum(abi.HowlRenderCallStatus.ok)
    else
        @intFromEnum(abi.HowlRenderCallStatus.failed);
}

pub fn deriveFrameLayout(handle: abi.SurfaceTextHandle, render_px: abi.FfiPixelSize, grid_px: abi.FfiPixelSize) callconv(.c) abi.FfiFrameLayoutResult {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.missing_handle), .cell_px = .{ .width = 0, .height = 0 }, .grid = .{ .cols = 0, .rows = 0 } };
    const layout = owner.session.deriveFrameLayout(owner.config, pixelIn(render_px), pixelIn(grid_px)) catch {
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .cell_px = .{ .width = 0, .height = 0 }, .grid = .{ .cols = 0, .rows = 0 } };
    };
    return .{ .status = 0, .cell_px = .{ .width = layout.cell_px.width, .height = layout.cell_px.height }, .grid = .{ .cols = layout.grid.cols, .rows = layout.grid.rows } };
}

pub fn init(config: abi.FfiSurfaceTextConfig) callconv(.c) abi.SurfaceTextHandle {
    if (config.surface_px.width == 0 or config.surface_px.height == 0) return null;
    if (config.font_size_px == 0) return null;
    const owner = surface_text.SurfaceTextOwner.create(std.heap.c_allocator, .{ .surface_px = pixelIn(config.surface_px), .font_size_px = config.font_size_px }) orelse return null;
    return @ptrCast(owner);
}

pub fn deinit(handle: abi.SurfaceTextHandle) callconv(.c) void {
    const owner = ownerFromHandle(handle) orelse return;
    owner.destroy();
}

pub fn setFontSize(handle: abi.SurfaceTextHandle, font_size_px: u16) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    if (font_size_px == 0) return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    owner.setFontSizePx(font_size_px);
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

// The C ABI owns architecture-sized byte lengths at this seam.
// We convert immediately into a byte slice and do not retain architecture-sized state in the owner.
pub fn setFontPath(handle: abi.SurfaceTextHandle, ptr: ?[*]const u8, len: usize) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    if (len > 0 and ptr == null) return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    owner.setFontPathBytes(if (len == 0 or ptr == null) null else ptr.?[0..len]) catch {
        return @intFromEnum(abi.HowlRenderCallStatus.failed);
    };
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

// The C ABI owns architecture-sized pointer counts at this seam.
// We translate immediately into FallbackFontCount before owner code touches the value.
pub fn setFallbackFontPaths(handle: abi.SurfaceTextHandle, ptrs: ?[*]const ?[*]const u8, count: usize) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    if (count > text_support.max_fallback_fonts) return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    const path_count = text_support.fallbackFontCount(@intCast(count)) orelse unreachable;
    if (path_count > 0 and ptrs == null) return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    const raw_paths = if (path_count == 0) &.{} else ptrs.?[0..@intCast(text_support.fallbackFontLen(path_count))];
    owner.setFallbackFontPathPtrs(raw_paths) catch |err| {
        return @intFromEnum(switch (err) {
            error.InvalidArgument => abi.HowlRenderCallStatus.invalid_argument,
            error.OutOfMemory => abi.HowlRenderCallStatus.failed,
        });
    };
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn setCursorBlinkVisible(handle: abi.SurfaceTextHandle, visible: u8) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    _ = owner.flow.setCursorBlinkVisible(visible != 0);
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn syncGeometry(handle: abi.SurfaceTextHandle, geometry: abi.FfiGeometry) callconv(.c) abi.FfiGeometryResponse {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.missing_handle), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    const layout = owner.session.deriveFrameLayout(owner.config, pixelIn(geometry.render_px), pixelIn(geometry.grid_px)) catch {
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    };
    return geometryOut(owner.flow.syncGeometry(.{
        .render_px = pixelIn(geometry.render_px),
        .grid_px = pixelIn(geometry.grid_px),
        .cell_px = layout.cell_px,
    }) catch return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.failed), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 });
}

pub fn publishVtSource(handle: abi.SurfaceTextHandle, source_in: abi.FfiVtSurface) callconv(.c) abi.FfiVtPublishResult {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.missing_handle), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    const source = vtSurfaceIn(owner.allocator, source_in) catch {
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    return vtPublishResultOut(owner.flow.acceptSource(source));
}

pub fn reservePublishSlot(handle: abi.SurfaceTextHandle, cols: u16, rows: u16, out: ?*abi.FfiPublishSlot) callconv(.c) c_int {
    const slot_out = out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    slot_out.* = std.mem.zeroes(abi.FfiPublishSlot);
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    if (cols == 0 or rows == 0) return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    const slot = owner.flow.reservePublishSlot(cols, rows) catch return @intFromEnum(abi.HowlRenderCallStatus.failed);
    slot_out.* = publishSlotOut(slot);
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn commitPublishSlot(handle: abi.SurfaceTextHandle, commit: abi.FfiPublishSlotCommit) callconv(.c) abi.FfiVtPublishResult {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.missing_handle), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    const reserved = owner.flow.publication_state.reserved orelse {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    const cursor = cursorIn(commit.cursor) orelse {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    if (commit.snapshot_seq == 0) {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    }
    for (reserved.cells) |cell| {
        validateCellValue(cell) catch {
            owner.flow.cancelPublishSlot();
            return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
        };
    }
    const graphics_images = graphicsImagesIn(commit.graphics_images) catch {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    const graphics_placements = graphicsPlacementsIn(commit.graphics_placements) catch {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    const graphics_virtual_placements = graphicsVirtualPlacementsIn(commit.graphics_virtual_placements) catch {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    const graphics_placeholder_runs = graphicsPlaceholderRunsIn(commit.graphics_placeholder_runs) catch {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    const graphics_payload_bytes = byteSpanIn(commit.graphics_payload_bytes) catch {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    if (graphics_images.len != commit.graphics.image_count or graphics_placements.len != commit.graphics.placement_count or graphics_virtual_placements.len != commit.graphics.virtual_placement_count or graphics_placeholder_runs.len != commit.graphics.placeholder_run_count) {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    }
    const result = owner.flow.commitPublishSlot(.{
        .history_count = commit.history_count,
        .scroll_row = commit.scroll_row,
        .snapshot_seq = commit.snapshot_seq,
        .is_alternate_screen = commit.is_alternate_screen != 0,
        .cursor = cursor,
        .colors = commit.colors,
        .selection = commit.selection,
        .graphics = commit.graphics,
        .graphics_images = graphics_images,
        .graphics_placements = graphics_placements,
        .graphics_virtual_placements = graphics_virtual_placements,
        .graphics_placeholder_runs = graphics_placeholder_runs,
        .graphics_payload_bytes = graphics_payload_bytes,
    }) catch |err| {
        std.debug.panic(
            "render commitPublishSlot rejected: err={s} snapshot_seq={d} alt={} rows={d} cols={d} history_count={d} scroll_row={d} graphics=(images={d} placements={d} virtuals={d} placeholders={d} alt={d} pub={d} dirty={d}) payload_len={d}",
            .{
                @errorName(err),
                commit.snapshot_seq,
                commit.is_alternate_screen != 0,
                reserved.dirty_rows.len,
                if (reserved.dirty_rows.len == 0) 0 else reserved.cells.len / reserved.dirty_rows.len,
                commit.history_count,
                commit.scroll_row,
                commit.graphics.image_count,
                commit.graphics.placement_count,
                commit.graphics.virtual_placement_count,
                commit.graphics.placeholder_run_count,
                commit.graphics.is_alternate_screen,
                commit.graphics.publication_seq,
                commit.graphics.dirty_generation,
                graphics_payload_bytes.len,
            },
        );
    };
    return vtPublishResultOut(result);
}

pub fn rejectPublishSlot(handle: abi.SurfaceTextHandle, snapshot_seq: u64) callconv(.c) abi.FfiVtPublishResult {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.missing_handle), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    if (snapshot_seq == 0) return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    return vtPublishResultWithStatus(owner.flow.rejectPublishSlot(snapshot_seq), .failed);
}

pub fn cancelPublishSlot(handle: abi.SurfaceTextHandle) callconv(.c) void {
    const owner = ownerFromHandle(handle) orelse return;
    owner.flow.cancelPublishSlot();
}

pub fn takePrepareRequest(handle: abi.SurfaceTextHandle, out: ?*abi.FfiPrepareRequest) callconv(.c) abi.HowlRenderPrepareStatus {
    const prepare_out = out orelse return .failed;
    prepare_out.* = std.mem.zeroes(abi.FfiPrepareRequest);
    const owner = ownerFromHandle(handle) orelse return .failed;
    const request = owner.flow.prepare() orelse return .idle;
    prepare_out.* = prepareRequestOut(request);
    return .ready;
}

pub fn publishPrepared(handle: abi.SurfaceTextHandle, prepared_in: abi.FfiPreparedFrame) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const prepared = preparedFrameIn(prepared_in) orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    owner.flow.publishPrepared(prepared);
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn publishPreparedHandle(handle: abi.SurfaceTextHandle, prepared_surface_handle: abi.PreparedSurfaceHandle) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const prepared_owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    if (!prepared_owner.belongsToSession(owner)) return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    if (!prepared_owner.markPublished()) return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    owner.prepared_submit_handle = null;
    owner.prepared_publish_handle = prepared_surface_handle;
    owner.flow.publishPrepared(prepared_owner.pipelineFrame());
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn takeSubmitDecision(handle: abi.SurfaceTextHandle, out: ?*abi.FfiPreparedFrame) callconv(.c) abi.HowlRenderSubmitDecisionStatus {
    const prepared_out = out orelse return .failed;
    prepared_out.* = std.mem.zeroes(abi.FfiPreparedFrame);
    const owner = ownerFromHandle(handle) orelse return .failed;
    return switch (owner.flow.submit()) {
        .idle => .idle,
        .stale => .stale,
        .submit => |prepared| blk: {
            prepared_out.* = preparedFrameOut(prepared);
            break :blk .submit;
        },
        .needs_full_prepare => .needs_prepare,
    };
}

pub fn takeSubmitHandle(handle: abi.SurfaceTextHandle, out: ?*abi.PreparedSurfaceHandle) callconv(.c) abi.HowlRenderSubmitDecisionStatus {
    const prepared_out = out orelse return .failed;
    prepared_out.* = null;
    const owner = ownerFromHandle(handle) orelse return .failed;
    return switch (owner.flow.submit()) {
        .idle => .idle,
        .stale => blk: {
            owner.prepared_publish_handle = null;
            owner.prepared_submit_handle = null;
            break :blk .stale;
        },
        .needs_full_prepare => blk: {
            owner.prepared_publish_handle = null;
            owner.prepared_submit_handle = null;
            break :blk .needs_prepare;
        },
        .submit => |prepared| blk: {
            const prepared_handle = owner.prepared_publish_handle orelse break :blk .failed;
            const prepared_owner = prepared_surface_owner.Owner.fromHandle(prepared_handle) orelse break :blk .failed;
            if (!prepared_owner.isLive()) {
                owner.prepared_publish_handle = null;
                owner.prepared_submit_handle = null;
                break :blk .failed;
            }
            if (!samePreparedFrame(prepared_owner.pipelineFrame(), prepared)) break :blk .failed;
            if (!prepared_owner.markSubmitReady()) break :blk .failed;
            owner.prepared_publish_handle = null;
            owner.prepared_submit_handle = prepared_handle;
            prepared_out.* = prepared_handle;
            break :blk .submit;
        },
    };
}

pub fn acceptSubmitted(handle: abi.SurfaceTextHandle, prepared_in: abi.FfiPreparedFrame) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const prepared = preparedFrameIn(prepared_in) orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    owner.flow.acceptSubmitted(.{
        .token = prepared.token,
    });
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn submitHandle(surface_text_handle: abi.SurfaceTextHandle, prepared_surface_handle: abi.PreparedSurfaceHandle, execution_in: ?*const abi.FfiSurfaceExecutionInput, feedback_out: ?*abi.FfiSurfaceFeedback) callconv(.c) abi.HowlRenderSubmitStatus {
    if (feedback_out) |out| out.* = failedSurfaceFeedback();
    const owner = ownerFromHandle(surface_text_handle) orelse return .failed;
    const execution = execution_in orelse return .failed;
    if (owner.prepared_submit_handle != prepared_surface_handle) return .failed;
    const prepared_owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return .failed;
    if (!prepared_owner.isLive()) {
        owner.prepared_submit_handle = null;
        return .failed;
    }
    const submitted = prepared_owner.pipelineFrame().token;
    return switch (prepared_owner.submitOwned(owner, executionInputIn(execution.*))) {
        .rendered => |feedback| blk: {
            owner.prepared_submit_handle = null;
            owner.flow.acceptSubmitted(.{ .token = submitted });
            if (feedback_out) |out| out.* = surfaceFeedbackOut(feedback);
            break :blk .rendered;
        },
        .needs_prepare => .needs_prepare,
        .failed => .failed,
    };
}

pub fn pendingState(handle: abi.SurfaceTextHandle, out: ?*abi.FfiPendingState) callconv(.c) c_int {
    const pending_out = out;
    const owner = ownerFromHandle(handle) orelse {
        if (pending_out) |value| value.* = pendingStateFailure(@intFromEnum(abi.HowlRenderCallStatus.missing_handle));
        return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    };
    const value = pending_out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    value.* = pendingStateOut(owner.flow.pendingState());
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn prepareHandle(surface_text_handle: abi.SurfaceTextHandle, prepare_request: abi.FfiPrepareRequest, prepared_handle_out: ?*abi.PreparedSurfaceHandle) callconv(.c) abi.HowlRenderPrepareStatus {
    const prepared_out = prepared_handle_out;
    if (prepared_out) |value| value.* = null;
    const owner = ownerFromHandle(surface_text_handle) orelse return .failed;
    const value = prepared_out orelse return .failed;
    const token = prepareTokenIn(prepare_request) orelse return .failed;
    const prepared_owner = owner.prepareHandle(token) catch return .failed;
    value.* = @ptrCast(prepared_owner);
    return .ready;
}

pub fn submit(surface_text_handle: abi.SurfaceTextHandle, prepared_surface_handle: abi.PreparedSurfaceHandle, prepared_frame_in: abi.FfiPreparedFrame, execution_in: ?*const abi.FfiSurfaceExecutionInput, feedback_out: ?*abi.FfiSurfaceFeedback) callconv(.c) abi.HowlRenderSubmitStatus {
    if (feedback_out) |out| out.* = failedSurfaceFeedback();
    const owner = ownerFromHandle(surface_text_handle) orelse return .failed;
    const prepared_owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return .failed;
    const execution = execution_in orelse return .failed;
    const prepared_frame = preparedFrameIn(prepared_frame_in) orelse return .failed;
    return switch (prepared_owner.submit(owner, prepared_frame, executionInputIn(execution.*))) {
        .rendered => |submitted| blk: {
            if (feedback_out) |out| out.* = surfaceFeedbackOut(submitted);
            break :blk .rendered;
        },
        .needs_prepare => .needs_prepare,
        .failed => .failed,
    };
}

fn surfaceFeedbackOut(value: surface.RenderSurfaceFeedback) abi.FfiSurfaceFeedback {
    return .{
        .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
        .damage_kind = @intFromEnum(value.damageKind()),
        .surface = .{ .host_surface_id = value.surface.host_surface_id, .width = value.surface.width, .height = value.surface.height },
        .metrics = surfaceMetricsOut(value.metrics),
    };
}

fn failedSurfaceFeedback() abi.FfiSurfaceFeedback {
    return .{
        .status = @intFromEnum(abi.HowlRenderCallStatus.failed),
        .damage_kind = 0,
        .surface = .{ .host_surface_id = 0, .width = 0, .height = 0 },
        .metrics = std.mem.zeroes(abi.FfiSurfaceMetrics),
    };
}

fn surfaceMetricsOut(value: surface.RenderMetrics) abi.FfiSurfaceMetrics {
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

fn executionInputIn(value: abi.FfiSurfaceExecutionInput) surface_text.SurfaceText.RenderSurfaceExecutionInput {
    return .{ .surface = .{ .host_surface_id = value.surface.host_surface_id, .width = value.surface.width, .height = value.surface.height }, .uploads_committed = value.uploads_committed, .render_us = value.render_us };
}

fn geometryOut(value: surface.GeometryResponse) abi.FfiGeometryResponse {
    return .{
        .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
        .changed = @intFromBool(value.changed),
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .geometry_epoch = value.geometry_epoch,
    };
}

fn vtPublishResultOut(value: queue.VtPublishResult) abi.FfiVtPublishResult {
    return vtPublishResultWithStatus(value, .ok);
}

fn vtPublishResultWithStatus(value: queue.VtPublishResult, status: abi.HowlRenderCallStatus) abi.FfiVtPublishResult {
    return .{
        .status = @intFromEnum(status),
        .published = @intFromBool(value.published),
        .queued = @intFromBool(value.queued),
        .damage_kind = @intFromEnum(value.damage_kind),
        .snapshot_seq = value.snapshot_seq,
        .geometry_epoch = value.geometry_epoch,
    };
}

fn publishSlotOut(value: queue.PublicationSlot) abi.FfiPublishSlot {
    return .{
        .cells = .{ .ptr = if (value.cells.len == 0) null else value.cells.ptr, .len = value.cells.len },
        .dirty_rows = .{ .ptr = if (value.dirty_rows.len == 0) null else value.dirty_rows.ptr, .len = value.dirty_rows.len },
        .dirty_cols_start = .{ .ptr = if (value.dirty_cols_start.len == 0) null else value.dirty_cols_start.ptr, .len = value.dirty_cols_start.len },
        .dirty_cols_end = .{ .ptr = if (value.dirty_cols_end.len == 0) null else value.dirty_cols_end.ptr, .len = value.dirty_cols_end.len },
    };
}

fn pendingStateOut(value: queue.PendingState) abi.FfiPendingState {
    return .{
        .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
        .source_pending = @intFromBool(value.source_pending),
        .prepare_pending = @intFromBool(value.prepare_pending),
        .submit_pending = @intFromBool(value.submit_pending),
    };
}

fn pendingStateFailure(status: c_int) abi.FfiPendingState {
    return .{
        .status = status,
        .source_pending = 0,
        .prepare_pending = 0,
        .submit_pending = 0,
    };
}

fn prepareRequestOut(value: pipeline.RenderRequest) abi.FfiPrepareRequest {
    return .{
        .snapshot_seq = value.token.snapshot_seq,
        .dirty_epoch = value.token.dirty_epoch,
        .geometry_epoch = value.token.geometry_epoch,
        .damage_base_seq = value.token.damage_base_seq,
        .damage_kind = @intFromEnum(value.token.damage_kind),
    };
}

fn preparedFrameOut(value: pipeline.PreparedFrame) abi.FfiPreparedFrame {
    return .{
        .snapshot_seq = value.token.snapshot_seq,
        .dirty_epoch = value.token.dirty_epoch,
        .geometry_epoch = value.token.geometry_epoch,
        .damage_base_seq = value.token.damage_base_seq,
        .required_base_seq = value.required_base_seq,
        .damage_kind = @intFromEnum(value.token.damage_kind),
    };
}

fn prepareTokenIn(value: abi.FfiPrepareRequest) ?pipeline.SnapshotToken {
    const damage_kind = damageKindIn(value.damage_kind) orelse return null;
    if (value.snapshot_seq == 0) return null;
    if (value.dirty_epoch == 0) return null;
    if (value.geometry_epoch == 0) return null;
    if (damage_kind == .none) return null;
    switch (damage_kind) {
        .none => unreachable,
        .full => {
            if (value.damage_base_seq != 0) return null;
        },
        .partial => {
            if (value.damage_base_seq == 0) return null;
        },
    }
    return .{
        .snapshot_seq = value.snapshot_seq,
        .dirty_epoch = value.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .damage_base_seq = value.damage_base_seq,
        .damage_kind = damage_kind,
    };
}

fn preparedFrameIn(value: abi.FfiPreparedFrame) ?pipeline.PreparedFrame {
    const damage_kind = damageKindIn(value.damage_kind) orelse return null;
    if (value.snapshot_seq == 0) return null;
    if (value.dirty_epoch == 0) return null;
    if (value.geometry_epoch == 0) return null;
    if (damage_kind == .none) return null;
    switch (damage_kind) {
        .none => unreachable,
        .full => {
            if (value.damage_base_seq != 0) return null;
            if (value.required_base_seq != 0) return null;
        },
        .partial => {
            if (value.damage_base_seq == 0) return null;
            if (value.required_base_seq == 0) return null;
            if (value.required_base_seq != value.damage_base_seq) return null;
        },
    }
    return .{ .token = .{ .snapshot_seq = value.snapshot_seq, .dirty_epoch = value.dirty_epoch, .geometry_epoch = value.geometry_epoch, .damage_base_seq = value.damage_base_seq, .damage_kind = damage_kind }, .required_base_seq = value.required_base_seq };
}

fn samePreparedFrame(a: pipeline.PreparedFrame, b: pipeline.PreparedFrame) bool {
    return a.token.snapshot_seq == b.token.snapshot_seq and
        a.token.dirty_epoch == b.token.dirty_epoch and
        a.token.geometry_epoch == b.token.geometry_epoch and
        a.token.damage_base_seq == b.token.damage_base_seq and
        a.token.damage_kind == b.token.damage_kind and
        a.required_base_seq == b.required_base_seq;
}

fn vtSurfaceIn(allocator: std.mem.Allocator, value: abi.FfiVtSurface) !queue.PublicationSource {
    const cell_count: u32 = @as(u32, value.cols) * @as(u32, value.rows);
    if (value.cells.len != cell_count) return error.InvalidSurfaceSource;

    const source_cells = value.cells.ptr[0..@intCast(cell_count)];
    for (source_cells) |cell| try validateCellValue(cell);
    const cells = try allocator.dupe(abi.FfiVtCell, source_cells);
    errdefer allocator.free(cells);

    const dirty_rows = try dirtyRowsIn(allocator, value.rows, value.dirty_rows);
    errdefer if (dirty_rows.len > 0) allocator.free(dirty_rows);
    const dirty_cols_start = try dirtyColsIn(allocator, value.rows, value.dirty_cols_start);
    errdefer if (dirty_cols_start.len > 0) allocator.free(dirty_cols_start);
    const dirty_cols_end = try dirtyColsIn(allocator, value.rows, value.dirty_cols_end);
    errdefer if (dirty_cols_end.len > 0) allocator.free(dirty_cols_end);
    const graphics_images = try graphicsImagesDup(allocator, value.graphics_images);
    errdefer if (graphics_images.len > 0) allocator.free(graphics_images);
    const graphics_placements = try graphicsPlacementsDup(allocator, value.graphics_placements);
    errdefer if (graphics_placements.len > 0) allocator.free(graphics_placements);
    const graphics_virtual_placements = try graphicsVirtualPlacementsDup(allocator, value.graphics_virtual_placements);
    errdefer if (graphics_virtual_placements.len > 0) allocator.free(graphics_virtual_placements);
    const graphics_placeholder_runs = try graphicsPlaceholderRunsDup(allocator, value.graphics_placeholder_runs);
    errdefer if (graphics_placeholder_runs.len > 0) allocator.free(graphics_placeholder_runs);
    const graphics_payload_bytes = try byteSpanDup(allocator, value.graphics_payload_bytes);
    errdefer if (graphics_payload_bytes.len > 0) allocator.free(graphics_payload_bytes);
    if (graphics_images.len != value.graphics.image_count or graphics_placements.len != value.graphics.placement_count or graphics_virtual_placements.len != value.graphics.virtual_placement_count or graphics_placeholder_runs.len != value.graphics.placeholder_run_count) {
        return error.InvalidSurfaceSource;
    }

    const cursor = cursorIn(value.cursor) orelse return error.InvalidSurfaceSource;
    const source: queue.PublicationSource = .{
        .cols = value.cols,
        .rows = value.rows,
        .history_count = value.history_count,
        .scroll_row = value.scroll_row,
        .snapshot_seq = value.snapshot_seq,
        .dirty_epoch = 0,
        .is_alternate_screen = value.is_alternate_screen != 0,
        .cells = cells,
        .cursor = cursor,
        .colors = value.colors,
        .selection = value.selection,
        .graphics = value.graphics,
        .graphics_images = graphics_images,
        .graphics_placements = graphics_placements,
        .graphics_virtual_placements = graphics_virtual_placements,
        .graphics_placeholder_runs = graphics_placeholder_runs,
        .graphics_payload_bytes = graphics_payload_bytes,
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
    try queue.validatePublicationSourceBoundary(source);
    return source;
}

fn dirtyRowsIn(allocator: std.mem.Allocator, rows: u16, span: abi.FfiByteSpan) ![]u8 {
    if (span.len == 0) return &.{};
    if (span.ptr == null or span.len != rows) return error.InvalidSurfaceSource;
    const out = try allocator.alloc(u8, rows);
    errdefer allocator.free(out);
    @memcpy(out, span.ptr[0..rows]);
    for (out) |dirty| {
        if (dirty > 1) return error.InvalidSurfaceSource;
    }
    return out;
}

fn byteSpanIn(span: abi.FfiByteSpan) ![]const u8 {
    if (span.len == 0) return &.{};
    if (span.ptr == null) return error.InvalidSurfaceSource;
    return span.ptr[0..span.len];
}

fn byteSpanDup(allocator: std.mem.Allocator, span: abi.FfiByteSpan) ![]u8 {
    const bytes = try byteSpanIn(span);
    return try allocator.dupe(u8, bytes);
}

fn dirtyColsIn(allocator: std.mem.Allocator, rows: u16, span: abi.FfiU16Span) ![]u16 {
    if (span.len == 0) return &.{};
    if (span.ptr == null or span.len != rows) return error.InvalidSurfaceSource;
    return try allocator.dupe(u16, span.ptr[0..rows]);
}

fn cellValueIn(value: abi.FfiVtCell) !surface.Cell {
    try validateCellValue(value);
    return .{
        .codepoint = @intCast(value.codepoint),
        .combining_len = value.combining_len,
        .combining = .{
            @intCast(value.combining[0]),
            @intCast(value.combining[1]),
            @intCast(value.combining[2]),
        },
        .flags = .{ .continuation = value.flags.continuation != 0 },
        .fg_color = try colorValueIn(value.fg_color),
        .bg_color = try colorValueIn(value.bg_color),
        .underline_color = try colorValueIn(value.underline_color),
        .underline_style = try underlineStyleValueIn(value.underline_style),
        .attrs = .{
            .bold = value.attrs.bold != 0,
            .dim = value.attrs.dim != 0,
            .italic = value.attrs.italic != 0,
            .underline = value.attrs.underline != 0,
            .underline_color_set = value.attrs.underline_color_set != 0,
            .blink = value.attrs.blink != 0,
            .inverse = value.attrs.inverse != 0,
            .invisible = value.attrs.invisible != 0,
            .strikethrough = value.attrs.strikethrough != 0,
            .selected = value.attrs.selected != 0,
        },
        .link_id = value.link_id,
    };
}

fn validateCellValue(value: abi.FfiVtCell) !void {
    if (value.codepoint > std.math.maxInt(u21)) return error.InvalidSurfaceSource;
    if (value.combining_len > value.combining.len) return error.InvalidSurfaceSource;
    for (value.combining[0..value.combining_len]) |cp| {
        if (cp > std.math.maxInt(u21)) return error.InvalidSurfaceSource;
    }
    _ = try colorValueIn(value.fg_color);
    _ = try colorValueIn(value.bg_color);
    _ = try colorValueIn(value.underline_color);
    _ = try underlineStyleValueIn(value.underline_style);
}

fn colorValueIn(value: abi.FfiVtColor) !surface.Color {
    return switch (value.kind) {
        0 => .{ .kind = .default, .value = 0 },
        1 => blk: {
            if (value.value > std.math.maxInt(u8)) return error.InvalidSurfaceSource;
            break :blk .{ .kind = .indexed, .value = @truncate(value.value) };
        },
        2 => blk: {
            if (value.value > std.math.maxInt(u24)) return error.InvalidSurfaceSource;
            break :blk .{ .kind = .rgb, .value = @truncate(value.value) };
        },
        else => return error.InvalidSurfaceSource,
    };
}

fn damageKindIn(value: u8) ?pipeline.DamageKind {
    return switch (value) {
        @intFromEnum(pipeline.DamageKind.none) => .none,
        @intFromEnum(pipeline.DamageKind.partial) => .partial,
        @intFromEnum(pipeline.DamageKind.full) => .full,
        else => null,
    };
}

fn cursorIn(value: abi.FfiVtCursor) ?surface.CursorInfo {
    const shape = switch (value.shape) {
        0 => surface.CursorShape.block,
        1 => .underline,
        2 => .beam,
        3 => .hollow_block,
        else => return null,
    };
    return .{ .row = value.row, .col = value.col, .visible = value.visible != 0, .shape = shape, .blink = value.blink != 0 };
}

fn graphicsImagesIn(span: abi.FfiVtGraphicsImageSpan) ![]const abi.FfiVtGraphicsImage {
    if (span.len == 0) return &.{};
    if (span.ptr == null) return error.InvalidSurfaceSource;
    return span.ptr[0..span.len];
}

fn graphicsPlacementsIn(span: abi.FfiVtGraphicsPlacementSpan) ![]const abi.FfiVtGraphicsPlacement {
    if (span.len == 0) return &.{};
    if (span.ptr == null) return error.InvalidSurfaceSource;
    return span.ptr[0..span.len];
}

fn graphicsVirtualPlacementsIn(span: abi.FfiVtGraphicsVirtualPlacementSpan) ![]const abi.FfiVtGraphicsVirtualPlacement {
    if (span.len == 0) return &.{};
    if (span.ptr == null) return error.InvalidSurfaceSource;
    return span.ptr[0..span.len];
}

fn graphicsPlaceholderRunsIn(span: abi.FfiVtGraphicsPlaceholderRunSpan) ![]const abi.FfiVtGraphicsPlaceholderRun {
    if (span.len == 0) return &.{};
    if (span.ptr == null) return error.InvalidSurfaceSource;
    return span.ptr[0..span.len];
}

fn graphicsImagesDup(allocator: std.mem.Allocator, span: abi.FfiVtGraphicsImageSpan) ![]abi.FfiVtGraphicsImage {
    const items = try graphicsImagesIn(span);
    return try allocator.dupe(abi.FfiVtGraphicsImage, items);
}

fn graphicsPlacementsDup(allocator: std.mem.Allocator, span: abi.FfiVtGraphicsPlacementSpan) ![]abi.FfiVtGraphicsPlacement {
    const items = try graphicsPlacementsIn(span);
    return try allocator.dupe(abi.FfiVtGraphicsPlacement, items);
}

fn graphicsVirtualPlacementsDup(allocator: std.mem.Allocator, span: abi.FfiVtGraphicsVirtualPlacementSpan) ![]abi.FfiVtGraphicsVirtualPlacement {
    const items = try graphicsVirtualPlacementsIn(span);
    return try allocator.dupe(abi.FfiVtGraphicsVirtualPlacement, items);
}

fn graphicsPlaceholderRunsDup(allocator: std.mem.Allocator, span: abi.FfiVtGraphicsPlaceholderRunSpan) ![]abi.FfiVtGraphicsPlaceholderRun {
    const items = try graphicsPlaceholderRunsIn(span);
    return try allocator.dupe(abi.FfiVtGraphicsPlaceholderRun, items);
}

fn underlineStyleValueIn(value: u8) !surface.UnderlineStyle {
    return switch (value) {
        0 => .straight,
        1 => .double,
        2 => .curly,
        3 => .dotted,
        4 => .dashed,
        else => return error.InvalidSurfaceSource,
    };
}

fn pixelIn(value: abi.FfiPixelSize) surface.PixelSize {
    return .{ .width = value.width, .height = value.height };
}

test "dirtyRowsIn rejects bytes outside boolean domain" {
    const dirty_rows = [_]u8{2};
    try std.testing.expectError(error.InvalidSurfaceSource, dirtyRowsIn(std.testing.allocator, 1, .{
        .ptr = @constCast(dirty_rows[0..].ptr),
        .len = dirty_rows.len,
    }));
}

test "vtSurfaceIn rejects graphics screen identity mismatch" {
    const cells = [_]abi.FfiVtCell{std.mem.zeroes(abi.FfiVtCell)};
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{0};
    const dirty_cols_end = [_]u16{0};

    try std.testing.expectError(error.InvalidGraphicsMetadata, vtSurfaceIn(std.testing.allocator, .{
        .cells = .{ .ptr = @constCast(cells[0..].ptr), .len = cells.len },
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = 0,
        .dirty_rows = .{ .ptr = @constCast(dirty_rows[0..].ptr), .len = dirty_rows.len },
        .dirty_cols_start = .{ .ptr = @constCast(dirty_cols_start[0..].ptr), .len = dirty_cols_start.len },
        .dirty_cols_end = .{ .ptr = @constCast(dirty_cols_end[0..].ptr), .len = dirty_cols_end.len },
        .cursor = std.mem.zeroes(abi.FfiVtCursor),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = std.mem.zeroes(abi.FfiVtSelection),
        .graphics = .{ .image_count = 0, .placement_count = 0, .virtual_placement_count = 0, .placeholder_run_count = 0, .is_alternate_screen = 1, .publication_seq = 1, .dirty_generation = 1 },
        .graphics_images = .{ .ptr = null, .len = 0 },
        .graphics_placements = .{ .ptr = null, .len = 0 },
        .graphics_virtual_placements = .{ .ptr = null, .len = 0 },
        .graphics_placeholder_runs = .{ .ptr = null, .len = 0 },
        .graphics_payload_bytes = .{ .ptr = null, .len = 0 },
    }));
}

test "vtSurfaceIn rejects placeholder run count mismatch" {
    const cells = [_]abi.FfiVtCell{std.mem.zeroes(abi.FfiVtCell)};
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{0};
    const dirty_cols_end = [_]u16{0};

    try std.testing.expectError(error.InvalidSurfaceSource, vtSurfaceIn(std.testing.allocator, .{
        .cells = .{ .ptr = @constCast(cells[0..].ptr), .len = cells.len },
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = 0,
        .dirty_rows = .{ .ptr = @constCast(dirty_rows[0..].ptr), .len = dirty_rows.len },
        .dirty_cols_start = .{ .ptr = @constCast(dirty_cols_start[0..].ptr), .len = dirty_cols_start.len },
        .dirty_cols_end = .{ .ptr = @constCast(dirty_cols_end[0..].ptr), .len = dirty_cols_end.len },
        .cursor = std.mem.zeroes(abi.FfiVtCursor),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = std.mem.zeroes(abi.FfiVtSelection),
        .graphics = .{ .image_count = 0, .placement_count = 0, .virtual_placement_count = 0, .placeholder_run_count = 1, .is_alternate_screen = 0, .publication_seq = 1, .dirty_generation = 1 },
        .graphics_images = .{ .ptr = null, .len = 0 },
        .graphics_placements = .{ .ptr = null, .len = 0 },
        .graphics_virtual_placements = .{ .ptr = null, .len = 0 },
        .graphics_placeholder_runs = .{ .ptr = null, .len = 0 },
        .graphics_payload_bytes = .{ .ptr = null, .len = 0 },
    }));
}

test "vtSurfaceIn rejects placeholder run publication mismatch" {
    const cells = [_]abi.FfiVtCell{std.mem.zeroes(abi.FfiVtCell)};
    const dirty_rows = [_]u8{1};
    const dirty_cols_start = [_]u16{0};
    const dirty_cols_end = [_]u16{0};
    const images = [_]abi.FfiVtGraphicsImage{.{ .image_id = 7, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 0 }};
    const virtual_placements = [_]abi.FfiVtGraphicsVirtualPlacement{.{ .image_id = 7, .placement_id = 9, .source_x = 0, .source_y = 0, .source_width = 1, .source_height = 1, .columns = 1, .rows = 1 }};
    const placeholder_runs = [_]abi.FfiVtGraphicsPlaceholderRun{.{ .image_id = 7, .placement_id = 10, .virtual_placement_index = 0, .run_order = 0, .cell_row = 0, .cell_col = 0, .image_row = 0, .image_col = 0, .columns = 1 }};

    try std.testing.expectError(error.InvalidGraphicsMetadata, vtSurfaceIn(std.testing.allocator, .{
        .cells = .{ .ptr = @constCast(cells[0..].ptr), .len = cells.len },
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .is_alternate_screen = 0,
        .dirty_rows = .{ .ptr = @constCast(dirty_rows[0..].ptr), .len = dirty_rows.len },
        .dirty_cols_start = .{ .ptr = @constCast(dirty_cols_start[0..].ptr), .len = dirty_cols_start.len },
        .dirty_cols_end = .{ .ptr = @constCast(dirty_cols_end[0..].ptr), .len = dirty_cols_end.len },
        .cursor = std.mem.zeroes(abi.FfiVtCursor),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = std.mem.zeroes(abi.FfiVtSelection),
        .graphics = .{ .image_count = 1, .placement_count = 0, .virtual_placement_count = 1, .placeholder_run_count = 1, .is_alternate_screen = 0, .publication_seq = 1, .dirty_generation = 1 },
        .graphics_images = .{ .ptr = @constCast(images[0..].ptr), .len = images.len },
        .graphics_placements = .{ .ptr = null, .len = 0 },
        .graphics_virtual_placements = .{ .ptr = @constCast(virtual_placements[0..].ptr), .len = virtual_placements.len },
        .graphics_placeholder_runs = .{ .ptr = @constCast(placeholder_runs[0..].ptr), .len = placeholder_runs.len },
        .graphics_payload_bytes = .{ .ptr = null, .len = 0 },
    }));
}
