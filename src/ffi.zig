const std = @import("std");
const ffi = @This();
const pipeline = @import("frame/pipeline.zig");
const prepared_surface_owner = @import("frame/prepared_surface_owner.zig");
const surface_text = @import("frame/surface_text.zig");
const queue = @import("frame/queue.zig");
const surface = @import("frame/surface.zig");
const vt_publication = @import("frame/publication.zig");
const text_support = @import("text/font/ft_hb/support.zig");

const PublishScratch = struct {
    owner: *surface_text.SurfaceTextOwner,
    cells: []ffi.FfiVtCell,
};

const ScratchMutex = struct {
    state: std.Io.Mutex = .init,

    fn lock(self: *ScratchMutex) void {
        std.Io.Threaded.mutexLock(&self.state);
    }

    fn unlock(self: *ScratchMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

var publish_scratch_mutex = ScratchMutex{};
var publish_scratch_entries: std.ArrayListUnmanaged(PublishScratch) = .empty;

fn ownerFromHandle(handle: ffi.SurfaceTextHandle) ?*surface_text.SurfaceTextOwner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

pub fn isValidFont(handle: ffi.SurfaceTextHandle) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    return if (owner.isValidFont())
        @intFromEnum(ffi.HowlRenderCallStatus.ok)
    else
        @intFromEnum(ffi.HowlRenderCallStatus.failed);
}

pub fn deriveFrameLayout(handle: ffi.SurfaceTextHandle, render_px: ffi.FfiPixelSize, grid_px: ffi.FfiPixelSize) callconv(.c) ffi.FfiFrameLayoutResult {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.missing_handle), .cell_px = .{ .width = 0, .height = 0 }, .grid = .{ .cols = 0, .rows = 0 } };
    const layout = owner.session.deriveFrameLayout(owner.config, pixelIn(render_px), pixelIn(grid_px)) catch {
        return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument), .cell_px = .{ .width = 0, .height = 0 }, .grid = .{ .cols = 0, .rows = 0 } };
    };
    return .{ .status = 0, .cell_px = .{ .width = layout.cell_px.width, .height = layout.cell_px.height }, .grid = .{ .cols = layout.grid.cols, .rows = layout.grid.rows } };
}

pub fn init(config: ffi.FfiSurfaceTextConfig) callconv(.c) ffi.SurfaceTextHandle {
    if (config.surface_px.width == 0 or config.surface_px.height == 0) return null;
    if (config.font_size_px == 0) return null;
    const owner = surface_text.SurfaceTextOwner.create(std.heap.c_allocator, .{ .surface_px = pixelIn(config.surface_px), .font_size_px = config.font_size_px }) orelse return null;
    return @ptrCast(owner);
}

pub fn deinit(handle: ffi.SurfaceTextHandle) callconv(.c) void {
    const owner = ownerFromHandle(handle) orelse return;
    removePublishScratch(owner);
    owner.destroy();
}

pub fn setFontSize(handle: ffi.SurfaceTextHandle, font_size_px: u16) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    if (font_size_px == 0) return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    owner.setFontSizePx(font_size_px);
    return @intFromEnum(ffi.HowlRenderCallStatus.ok);
}

// The C ffi owns architecture-sized byte lengths at this seam.
// We convert immediately into a byte slice and do not retain architecture-sized state in the owner.
pub fn setFontPath(handle: ffi.SurfaceTextHandle, ptr: ?[*]const u8, len: usize) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    if (len > 0 and ptr == null) return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    owner.setFontPathBytes(if (len == 0 or ptr == null) null else ptr.?[0..len]) catch {
        return @intFromEnum(ffi.HowlRenderCallStatus.failed);
    };
    return @intFromEnum(ffi.HowlRenderCallStatus.ok);
}

// The C ffi owns architecture-sized pointer counts at this seam.
// We translate immediately into FallbackFontCount before owner code touches the value.
pub fn setFallbackFontPaths(handle: ffi.SurfaceTextHandle, ptrs: ?[*]const ?[*]const u8, count: usize) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    if (count > text_support.max_fallback_fonts) return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    const path_count = text_support.fallbackFontCount(@intCast(count)) orelse unreachable;
    if (path_count > 0 and ptrs == null) return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    const raw_paths = if (path_count == 0) &.{} else ptrs.?[0..@intCast(text_support.fallbackFontLen(path_count))];
    owner.setFallbackFontPathPtrs(raw_paths) catch |err| {
        return @intFromEnum(switch (err) {
            error.InvalidArgument => ffi.HowlRenderCallStatus.invalid_argument,
            error.OutOfMemory => ffi.HowlRenderCallStatus.failed,
        });
    };
    return @intFromEnum(ffi.HowlRenderCallStatus.ok);
}

pub fn setCursorBlinkVisible(handle: ffi.SurfaceTextHandle, visible: u8) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    _ = owner.flow.setCursorBlinkVisible(visible != 0);
    return @intFromEnum(ffi.HowlRenderCallStatus.ok);
}

pub fn syncGeometry(handle: ffi.SurfaceTextHandle, geometry: ffi.FfiGeometry) callconv(.c) ffi.FfiGeometryResponse {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.missing_handle), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    const layout = owner.session.deriveFrameLayout(owner.config, pixelIn(geometry.render_px), pixelIn(geometry.grid_px)) catch {
        return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    };
    return geometryOut(owner.flow.syncGeometry(.{
        .render_px = pixelIn(geometry.render_px),
        .grid_px = pixelIn(geometry.grid_px),
        .cell_px = layout.cell_px,
    }) catch return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.failed), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 });
}

pub fn reservePublishSlot(handle: ffi.SurfaceTextHandle, cols: u16, rows: u16, out: ?*ffi.FfiPublishSlot) callconv(.c) c_int {
    const slot_out = out orelse return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    slot_out.* = std.mem.zeroes(ffi.FfiPublishSlot);
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    if (cols == 0 or rows == 0) return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    const slot = owner.flow.reservePublishSlot(cols, rows) catch return @intFromEnum(ffi.HowlRenderCallStatus.failed);
    const cells = reservePublishScratch(owner, slot.cells.len) catch {
        owner.flow.cancelPublishSlot();
        return @intFromEnum(ffi.HowlRenderCallStatus.failed);
    };
    slot_out.* = publishSlotOut(slot, cells);
    return @intFromEnum(ffi.HowlRenderCallStatus.ok);
}

pub fn commitPublishSlot(handle: ffi.SurfaceTextHandle, commit: ffi.FfiPublishSlotCommit) callconv(.c) ffi.FfiVtPublishResult {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.missing_handle), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    const reserved = if (owner.flow.publication_state.reserved) |*value| value else {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    const cursor = cursorIn(commit.cursor) orelse {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    if (commit.snapshot_seq == 0) {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    }
    copyPublishScratch(owner, reserved.cells) catch {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    for (reserved.cells) |cell| {
        validatePublicationCellValue(cell) catch {
            owner.flow.cancelPublishSlot();
            return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
        };
    }
    const result = owner.flow.commitPublishSlot(.{
        .history_count = commit.history_count,
        .scroll_row = commit.scroll_row,
        .snapshot_seq = commit.snapshot_seq,
        .is_alternate_screen = commit.is_alternate_screen != 0,
        .cursor = cursor,
        .colors = colorStateIn(commit.colors),
        .selection = selectionIn(commit.selection),
    }) catch {
        owner.flow.cancelPublishSlot();
        return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    return vtPublishResultOut(result);
}

pub fn rejectPublishSlot(handle: ffi.SurfaceTextHandle, snapshot_seq: u64) callconv(.c) ffi.FfiVtPublishResult {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.missing_handle), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    if (snapshot_seq == 0) return .{ .status = @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    return vtPublishResultWithStatus(owner.flow.rejectPublishSlot(snapshot_seq), .failed);
}

pub fn cancelPublishSlot(handle: ffi.SurfaceTextHandle) callconv(.c) void {
    const owner = ownerFromHandle(handle) orelse return;
    owner.flow.cancelPublishSlot();
}

pub fn takePrepareRequest(handle: ffi.SurfaceTextHandle, out: ?*ffi.FfiPrepareRequest) callconv(.c) ffi.HowlRenderPrepareStatus {
    const prepare_out = out orelse return .failed;
    prepare_out.* = std.mem.zeroes(ffi.FfiPrepareRequest);
    const owner = ownerFromHandle(handle) orelse return .failed;
    const request = owner.flow.prepare() orelse return .idle;
    prepare_out.* = prepareRequestOut(request);
    return .ready;
}

pub fn publishPrepared(handle: ffi.SurfaceTextHandle, prepared_in: ffi.FfiPreparedFrame) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    const prepared = preparedFrameIn(prepared_in) orelse return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    owner.flow.publishPrepared(prepared);
    return @intFromEnum(ffi.HowlRenderCallStatus.ok);
}

pub fn publishPreparedHandle(handle: ffi.SurfaceTextHandle, prepared_surface_handle: ffi.PreparedSurfaceHandle) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    const prepared_owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    if (!prepared_owner.belongsToSession(owner)) return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    if (!prepared_owner.markPublished()) return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    owner.prepared_submit_handle = null;
    owner.prepared_publish_handle = opaquePreparedHandle(prepared_surface_handle);
    owner.flow.publishPrepared(prepared_owner.pipelineFrame());
    return @intFromEnum(ffi.HowlRenderCallStatus.ok);
}

pub fn takeSubmitDecision(handle: ffi.SurfaceTextHandle, out: ?*ffi.FfiPreparedFrame) callconv(.c) ffi.HowlRenderSubmitDecisionStatus {
    const prepared_out = out orelse return .failed;
    prepared_out.* = std.mem.zeroes(ffi.FfiPreparedFrame);
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

pub fn takeSubmitHandle(handle: ffi.SurfaceTextHandle, out: ?*ffi.PreparedSurfaceHandle) callconv(.c) ffi.HowlRenderSubmitDecisionStatus {
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
            prepared_out.* = abiPreparedHandle(prepared_handle);
            break :blk .submit;
        },
    };
}

pub fn acceptSubmitted(handle: ffi.SurfaceTextHandle, prepared_in: ffi.FfiPreparedFrame) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    const prepared = preparedFrameIn(prepared_in) orelse return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    owner.flow.acceptSubmitted(.{
        .token = prepared.token,
    });
    return @intFromEnum(ffi.HowlRenderCallStatus.ok);
}

pub fn submitHandle(surface_text_handle: ffi.SurfaceTextHandle, prepared_surface_handle: ffi.PreparedSurfaceHandle, execution_in: ?*const ffi.FfiSurfaceExecutionInput, feedback_out: ?*ffi.FfiSurfaceFeedback) callconv(.c) ffi.HowlRenderSubmitStatus {
    if (feedback_out) |out| out.* = failedSurfaceFeedback();
    const owner = ownerFromHandle(surface_text_handle) orelse return .failed;
    const execution = execution_in orelse return .failed;
    if (owner.prepared_submit_handle != opaquePreparedHandle(prepared_surface_handle)) return .failed;
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

pub fn pendingState(handle: ffi.SurfaceTextHandle, out: ?*ffi.FfiPendingState) callconv(.c) c_int {
    const pending_out = out;
    const owner = ownerFromHandle(handle) orelse {
        if (pending_out) |value| value.* = pendingStateFailure(@intFromEnum(ffi.HowlRenderCallStatus.missing_handle));
        return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    };
    const value = pending_out orelse return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    value.* = pendingStateOut(owner.flow.pendingState());
    return @intFromEnum(ffi.HowlRenderCallStatus.ok);
}

pub fn prepareHandle(surface_text_handle: ffi.SurfaceTextHandle, prepare_request: ffi.FfiPrepareRequest, prepared_handle_out: ?*ffi.PreparedSurfaceHandle) callconv(.c) ffi.HowlRenderPrepareStatus {
    const prepared_out = prepared_handle_out;
    if (prepared_out) |value| value.* = null;
    const owner = ownerFromHandle(surface_text_handle) orelse return .failed;
    const value = prepared_out orelse return .failed;
    const token = prepareTokenIn(prepare_request) orelse return .failed;
    const prepared_owner = owner.prepareHandle(token) catch return .failed;
    value.* = @ptrCast(prepared_owner);
    return .ready;
}

pub fn submit(surface_text_handle: ffi.SurfaceTextHandle, prepared_surface_handle: ffi.PreparedSurfaceHandle, prepared_frame_in: ffi.FfiPreparedFrame, execution_in: ?*const ffi.FfiSurfaceExecutionInput, feedback_out: ?*ffi.FfiSurfaceFeedback) callconv(.c) ffi.HowlRenderSubmitStatus {
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

pub fn release(prepared_surface_handle: ffi.PreparedSurfaceHandle) callconv(.c) void {
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return;
    owner.release();
}

pub fn describe(prepared_surface_handle: ffi.PreparedSurfaceHandle, info_out: ?*ffi.FfiPreparedSurfaceInfo) callconv(.c) c_int {
    const out = info_out;
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse {
        if (out) |value| value.* = infoFailure(@intFromEnum(ffi.HowlRenderCallStatus.missing_handle));
        return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    };
    const value = out orelse return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    if (!owner.isLive()) {
        value.* = infoFailure(@intFromEnum(ffi.HowlRenderCallStatus.invalid_argument));
        return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    }
    value.* = preparedInfoOut(owner.info());
    return @intFromEnum(ffi.HowlRenderCallStatus.ok);
}

pub fn buffer(prepared_surface_handle: ffi.PreparedSurfaceHandle, buffer_out: ?*ffi.FfiPreparedSurfaceBuffer) callconv(.c) c_int {
    const out = buffer_out;
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse {
        if (out) |value| value.* = bufferFailure(@intFromEnum(ffi.HowlRenderCallStatus.missing_handle));
        return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    };
    const value = out orelse return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    if (!owner.isLive()) {
        value.* = bufferFailure(@intFromEnum(ffi.HowlRenderCallStatus.invalid_argument));
        return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    }
    value.* = preparedBufferOut(owner.buffer());
    return @intFromEnum(ffi.HowlRenderCallStatus.ok);
}

pub fn diagnostics(prepared_surface_handle: ffi.PreparedSurfaceHandle, diagnostics_out: ?*ffi.FfiPreparedSurfaceDiagnostics) callconv(.c) c_int {
    const out = diagnostics_out;
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse {
        if (out) |value| value.* = diagnosticsFailure(@intFromEnum(ffi.HowlRenderCallStatus.missing_handle));
        return @intFromEnum(ffi.HowlRenderCallStatus.missing_handle);
    };
    const value = out orelse return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    if (!owner.isLive()) {
        value.* = diagnosticsFailure(@intFromEnum(ffi.HowlRenderCallStatus.invalid_argument));
        return @intFromEnum(ffi.HowlRenderCallStatus.invalid_argument);
    }
    value.* = preparedDiagnosticsOut(owner.diagnostics());
    return @intFromEnum(ffi.HowlRenderCallStatus.ok);
}

fn preparedInfoOut(value: prepared_surface_owner.PreparedInfo) ffi.FfiPreparedSurfaceInfo {
    return .{
        .status = @intFromEnum(ffi.HowlRenderCallStatus.ok),
        .snapshot_seq = value.snapshot_seq,
        .dirty_epoch = value.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .required_base_seq = value.required_base_seq,
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .grid = .{ .cols = value.grid.cols, .rows = value.grid.rows },
        .prepare_metrics = surfaceMetricsOut(value.prepare_metrics),
        .damage_kind = value.damage_kind,
    };
}

fn infoFailure(status: c_int) ffi.FfiPreparedSurfaceInfo {
    return .{
        .status = status,
        .snapshot_seq = 0,
        .dirty_epoch = 0,
        .geometry_epoch = 0,
        .required_base_seq = 0,
        .render_px = .{ .width = 0, .height = 0 },
        .cell_px = .{ .width = 0, .height = 0 },
        .grid = .{ .cols = 0, .rows = 0 },
        .prepare_metrics = std.mem.zeroes(ffi.FfiSurfaceMetrics),
        .damage_kind = 0,
    };
}

fn preparedBufferOut(value: prepared_surface_owner.PreparedBuffer) ffi.FfiPreparedSurfaceBuffer {
    return .{
        .status = @intFromEnum(ffi.HowlRenderCallStatus.ok),
        .rgba_pixels = byteSpan(value.rgba_pixels),
        .uploads_committed = value.uploads_required,
    };
}

fn bufferFailure(status: c_int) ffi.FfiPreparedSurfaceBuffer {
    return .{
        .status = status,
        .rgba_pixels = .{ .ptr = null, .len = 0 },
        .uploads_committed = 0,
    };
}

fn preparedDiagnosticsOut(value: prepared_surface_owner.PreparedDiagnostics) ffi.FfiPreparedSurfaceDiagnostics {
    return .{
        .status = @intFromEnum(ffi.HowlRenderCallStatus.ok),
        .missing_glyphs = value.missing_glyphs,
        .resolve_metrics = surfaceMetricsOut(value.resolve_metrics),
    };
}

fn diagnosticsFailure(status: c_int) ffi.FfiPreparedSurfaceDiagnostics {
    return .{
        .status = status,
        .missing_glyphs = 0,
        .resolve_metrics = std.mem.zeroes(ffi.FfiSurfaceMetrics),
    };
}

fn surfaceFeedbackOut(value: surface.RenderSurfaceFeedback) ffi.FfiSurfaceFeedback {
    return .{
        .status = @intFromEnum(ffi.HowlRenderCallStatus.ok),
        .damage_kind = @intFromEnum(value.damageKind()),
        .surface = .{ .host_surface_id = value.surface.host_surface_id, .width = value.surface.width, .height = value.surface.height },
        .metrics = surfaceMetricsOut(value.metrics),
    };
}

fn failedSurfaceFeedback() ffi.FfiSurfaceFeedback {
    return .{
        .status = @intFromEnum(ffi.HowlRenderCallStatus.failed),
        .damage_kind = 0,
        .surface = .{ .host_surface_id = 0, .width = 0, .height = 0 },
        .metrics = std.mem.zeroes(ffi.FfiSurfaceMetrics),
    };
}

fn surfaceMetricsOut(value: surface.RenderMetrics) ffi.FfiSurfaceMetrics {
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

fn executionInputIn(value: ffi.FfiSurfaceExecutionInput) surface_text.SurfaceText.RenderSurfaceExecutionInput {
    return .{ .surface = .{ .host_surface_id = value.surface.host_surface_id, .width = value.surface.width, .height = value.surface.height }, .uploads_committed = value.uploads_committed, .render_us = value.render_us };
}

fn geometryOut(value: surface.GeometryResponse) ffi.FfiGeometryResponse {
    return .{
        .status = @intFromEnum(ffi.HowlRenderCallStatus.ok),
        .changed = @intFromBool(value.changed),
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .geometry_epoch = value.geometry_epoch,
    };
}

fn vtPublishResultOut(value: queue.VtPublishResult) ffi.FfiVtPublishResult {
    return vtPublishResultWithStatus(value, .ok);
}

fn vtPublishResultWithStatus(value: queue.VtPublishResult, status: ffi.HowlRenderCallStatus) ffi.FfiVtPublishResult {
    return .{
        .status = @intFromEnum(status),
        .published = @intFromBool(value.published),
        .queued = @intFromBool(value.queued),
        .damage_kind = @intFromEnum(value.damage_kind),
        .snapshot_seq = value.snapshot_seq,
        .geometry_epoch = value.geometry_epoch,
    };
}

fn publishSlotOut(value: queue.PublicationSlot, cells: []ffi.FfiVtCell) ffi.FfiPublishSlot {
    std.debug.assert(cells.len == value.cells.len);
    return .{
        .cells = .{ .ptr = if (cells.len == 0) null else cells.ptr, .len = cells.len },
        .dirty_rows = .{ .ptr = if (value.dirty_rows.len == 0) null else value.dirty_rows.ptr, .len = value.dirty_rows.len },
        .dirty_cols_start = .{ .ptr = if (value.dirty_cols_start.len == 0) null else value.dirty_cols_start.ptr, .len = value.dirty_cols_start.len },
        .dirty_cols_end = .{ .ptr = if (value.dirty_cols_end.len == 0) null else value.dirty_cols_end.ptr, .len = value.dirty_cols_end.len },
    };
}

fn reservePublishScratch(owner: *surface_text.SurfaceTextOwner, cell_count: usize) ![]ffi.FfiVtCell {
    publish_scratch_mutex.lock();
    defer publish_scratch_mutex.unlock();

    var entry_index: ?usize = null;
    for (publish_scratch_entries.items, 0..) |entry, index| {
        if (entry.owner == owner) {
            entry_index = index;
            break;
        }
    }
    if (entry_index == null) {
        try publish_scratch_entries.append(std.heap.c_allocator, .{ .owner = owner, .cells = &.{} });
        entry_index = publish_scratch_entries.items.len - 1;
    }

    const entry = &publish_scratch_entries.items[entry_index.?];
    if (entry.cells.len != cell_count) {
        const cells = try std.heap.c_allocator.alloc(ffi.FfiVtCell, cell_count);
        if (entry.cells.len != 0) std.heap.c_allocator.free(entry.cells);
        entry.cells = cells;
    }
    @memset(entry.cells, std.mem.zeroes(ffi.FfiVtCell));
    return entry.cells;
}

fn copyPublishScratch(owner: *surface_text.SurfaceTextOwner, out: []vt_publication.Cell) !void {
    publish_scratch_mutex.lock();
    defer publish_scratch_mutex.unlock();

    for (publish_scratch_entries.items) |entry| {
        if (entry.owner != owner) continue;
        if (entry.cells.len != out.len) return error.InvalidSurfaceSource;
        for (entry.cells, out) |src, *dst| dst.* = try publicationCellValueIn(src);
        return;
    }
    return error.InvalidSurfaceSource;
}

fn removePublishScratch(owner: *surface_text.SurfaceTextOwner) void {
    publish_scratch_mutex.lock();
    defer publish_scratch_mutex.unlock();

    for (publish_scratch_entries.items, 0..) |entry, index| {
        if (entry.owner != owner) continue;
        if (entry.cells.len != 0) std.heap.c_allocator.free(entry.cells);
        _ = publish_scratch_entries.swapRemove(index);
        return;
    }
}

fn opaquePreparedHandle(handle: ffi.PreparedSurfaceHandle) prepared_surface_owner.PreparedSurfaceHandle {
    return if (handle) |value| @ptrCast(value) else null;
}

fn abiPreparedHandle(handle: prepared_surface_owner.PreparedSurfaceHandle) ffi.PreparedSurfaceHandle {
    return if (handle) |value| @ptrCast(value) else null;
}

fn pendingStateOut(value: queue.PendingState) ffi.FfiPendingState {
    return .{
        .status = @intFromEnum(ffi.HowlRenderCallStatus.ok),
        .source_pending = @intFromBool(value.source_pending),
        .prepare_pending = @intFromBool(value.prepare_pending),
        .submit_pending = @intFromBool(value.submit_pending),
    };
}

fn pendingStateFailure(status: c_int) ffi.FfiPendingState {
    return .{
        .status = status,
        .source_pending = 0,
        .prepare_pending = 0,
        .submit_pending = 0,
    };
}

fn prepareRequestOut(value: pipeline.RenderRequest) ffi.FfiPrepareRequest {
    return .{
        .snapshot_seq = value.token.snapshot_seq,
        .dirty_epoch = value.token.dirty_epoch,
        .geometry_epoch = value.token.geometry_epoch,
        .damage_base_seq = value.token.damage_base_seq,
        .damage_kind = @intFromEnum(value.token.damage_kind),
    };
}

fn preparedFrameOut(value: pipeline.PreparedFrame) ffi.FfiPreparedFrame {
    return .{
        .snapshot_seq = value.token.snapshot_seq,
        .dirty_epoch = value.token.dirty_epoch,
        .geometry_epoch = value.token.geometry_epoch,
        .damage_base_seq = value.token.damage_base_seq,
        .required_base_seq = value.required_base_seq,
        .damage_kind = @intFromEnum(value.token.damage_kind),
    };
}

fn prepareTokenIn(value: ffi.FfiPrepareRequest) ?pipeline.SnapshotToken {
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

fn preparedFrameIn(value: ffi.FfiPreparedFrame) ?pipeline.PreparedFrame {
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

fn byteSpanIn(span: ffi.FfiByteSpan) ![]const u8 {
    if (span.len == 0) return &.{};
    if (span.ptr == null) return error.InvalidSurfaceSource;
    return span.ptr[0..span.len];
}

fn byteSpan(items: []u8) ffi.FfiByteSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn cellValueIn(value: ffi.FfiVtCell) !surface.Cell {
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

fn publicationCellValueIn(value: ffi.FfiVtCell) !vt_publication.Cell {
    try validateCellValue(value);
    return .{
        .codepoint = value.codepoint,
        .combining_len = value.combining_len,
        .combining = value.combining,
        .flags = .{
            .continuation = value.flags.continuation,
        },
        .fg_color = .{ .kind = value.fg_color.kind, .value = value.fg_color.value },
        .bg_color = .{ .kind = value.bg_color.kind, .value = value.bg_color.value },
        .underline_color = .{ .kind = value.underline_color.kind, .value = value.underline_color.value },
        .underline_style = value.underline_style,
        .attrs = .{
            .bold = value.attrs.bold,
            .dim = value.attrs.dim,
            .italic = value.attrs.italic,
            .underline = value.attrs.underline,
            .underline_color_set = value.attrs.underline_color_set,
            .blink = value.attrs.blink,
            .inverse = value.attrs.inverse,
            .invisible = value.attrs.invisible,
            .strikethrough = value.attrs.strikethrough,
            .selected = value.attrs.selected,
        },
        .link_id = value.link_id,
    };
}

fn validateCellValue(value: ffi.FfiVtCell) !void {
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

fn validatePublicationCellValue(value: vt_publication.Cell) !void {
    if (value.codepoint > std.math.maxInt(u21)) return error.InvalidSurfaceSource;
    if (value.combining_len > value.combining.len) return error.InvalidSurfaceSource;
    for (value.combining[0..value.combining_len]) |cp| {
        if (cp > std.math.maxInt(u21)) return error.InvalidSurfaceSource;
    }
    _ = try colorValueIn(.{ .kind = value.fg_color.kind, .value = value.fg_color.value });
    _ = try colorValueIn(.{ .kind = value.bg_color.kind, .value = value.bg_color.value });
    _ = try colorValueIn(.{ .kind = value.underline_color.kind, .value = value.underline_color.value });
    _ = try underlineStyleValueIn(value.underline_style);
}

fn colorStateIn(value: ffi.FfiVtRenderColorState) vt_publication.RenderColorState {
    var palette: [256]vt_publication.Rgb8 = undefined;
    for (value.palette, 0..) |color, index| palette[index] = .{ .r = color.r, .g = color.g, .b = color.b };
    return .{
        .foreground = .{ .r = value.foreground.r, .g = value.foreground.g, .b = value.foreground.b },
        .background = .{ .r = value.background.r, .g = value.background.g, .b = value.background.b },
        .cursor = .{ .r = value.cursor.r, .g = value.cursor.g, .b = value.cursor.b },
        .palette = palette,
    };
}

fn selectionIn(value: ffi.FfiVtSelection) vt_publication.Selection {
    return .{
        .active = value.active,
        .selecting = value.selecting,
        .start = .{ .row = value.start.row, .col = value.start.col },
        .end = .{ .row = value.end.row, .col = value.end.col },
    };
}

fn colorValueIn(value: ffi.FfiVtColor) !surface.Color {
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

fn cursorIn(value: ffi.FfiVtCursor) ?surface.CursorInfo {
    const shape = switch (value.shape) {
        0 => surface.CursorShape.block,
        1 => .underline,
        2 => .beam,
        3 => .hollow_block,
        else => return null,
    };
    return .{ .row = value.row, .col = value.col, .visible = value.visible != 0, .shape = shape, .blink = value.blink != 0 };
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

fn pixelIn(value: ffi.FfiPixelSize) surface.PixelSize {
    return .{ .width = value.width, .height = value.height };
}
const c_size_t = switch (@sizeOf(*u8)) {
    8 => u64,
    4 => u32,
    else => @compileError("unsupported pointer width"),
};

pub const HowlRenderSurfaceText = opaque {};
pub const HowlRenderPreparedSurfaceObject = opaque {};

pub const SurfaceTextHandle = ?*HowlRenderSurfaceText;
pub const PreparedSurfaceHandle = ?*HowlRenderPreparedSurfaceObject;

pub const HowlRenderCallStatus = enum(c_int) {
    ok = 0,
    missing_handle = -1,
    invalid_argument = -2,
    failed = -3,
};

pub const HowlRenderPrepareStatus = enum(c_int) {
    idle = 0,
    ready = 1,
    failed = -3,
};

pub const HowlRenderSubmitStatus = enum(c_int) {
    idle = 0,
    rendered = 1,
    stale = 2,
    needs_prepare = 3,
    failed = -3,
};

pub const HowlRenderSubmitDecisionStatus = enum(c_int) {
    idle = 0,
    submit = 1,
    stale = 2,
    needs_prepare = 3,
    failed = -3,
};

pub const FfiPixelSize = extern struct {
    width: u16,
    height: u16,
};

pub const FfiCellSize = extern struct {
    width: u16,
    height: u16,
};

pub const FfiRgba8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const FfiGridSize = extern struct {
    cols: u16,
    rows: u16,
};

pub const FfiColorDraw = extern struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: FfiRgba8,
};

pub const FfiSpriteDraw = extern struct {
    slot: u32,
    key: u64,
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: FfiRgba8,
};

pub const FfiDecorationDraw = extern struct {
    kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: FfiRgba8,
};

pub const FfiRasterBounds = extern struct {
    x_px: u16,
    y_px: u16,
    width_px: u16,
    height_px: u16,
};

pub const FfiRasterUpload = extern struct {
    slot: u32,
    key: u64,
    width_px: u16,
    height_px: u16,
    color_mode: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    visual_bounds: FfiRasterBounds,
    pixels_ptr: [*c]const u8,
    pixels_len: c_size_t,
};

pub const FfiColorDrawSpan = extern struct {
    ptr: [*c]const FfiColorDraw,
    len: c_size_t,
};

pub const FfiVtCellFlags = extern struct {
    continuation: u8,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
};

pub const FfiVtColor = extern struct {
    kind: u8,
    value: u32,
};

pub const FfiVtRgb8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const FfiVtRenderColorState = extern struct {
    foreground: FfiVtRgb8,
    background: FfiVtRgb8,
    cursor: FfiVtRgb8,
    palette: [256]FfiVtRgb8,
};

pub const FfiVtCellAttrs = extern struct {
    bold: u8,
    dim: u8,
    italic: u8,
    underline: u8,
    underline_color_set: u8,
    blink: u8,
    inverse: u8,
    invisible: u8,
    strikethrough: u8,
    selected: u8,
};

pub const FfiVtCell = extern struct {
    codepoint: u32,
    combining_len: u8 = 0,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
    combining: [3]u32 = [_]u32{0} ** 3,
    flags: FfiVtCellFlags,
    fg_color: FfiVtColor,
    bg_color: FfiVtColor,
    underline_color: FfiVtColor,
    underline_style: u8,
    reserved3: u8 = 0,
    reserved4: u8 = 0,
    reserved5: u8 = 0,
    attrs: FfiVtCellAttrs,
    link_id: u32,
};

pub const FfiVtCellSpan = extern struct {
    ptr: [*c]const FfiVtCell,
    len: c_size_t,
};

pub const FfiSpriteDrawSpan = extern struct {
    ptr: [*c]const FfiSpriteDraw,
    len: c_size_t,
};

pub const FfiDecorationDrawSpan = extern struct {
    ptr: [*c]const FfiDecorationDraw,
    len: c_size_t,
};

pub const FfiRasterUploadSpan = extern struct {
    ptr: [*c]const FfiRasterUpload,
    len: c_size_t,
};

pub const FfiByteSpan = extern struct {
    ptr: [*c]const u8,
    len: c_size_t,
};

pub const FfiU16Span = extern struct {
    ptr: [*c]const u16,
    len: c_size_t,
};

pub const FfiByteWriteSpan = extern struct {
    ptr: [*c]u8,
    len: c_size_t,
};

pub const FfiU16WriteSpan = extern struct {
    ptr: [*c]u16,
    len: c_size_t,
};

pub const FfiFrameLayoutResult = extern struct {
    status: c_int,
    cell_px: FfiCellSize,
    grid: FfiGridSize,
};

pub const FfiVtCellWriteSpan = extern struct {
    ptr: [*c]FfiVtCell,
    len: c_size_t,
};

pub const FfiVtCursor = extern struct {
    row: u16,
    col: u16,
    visible: u8,
    shape: u8,
    blink: u8,
};

pub const FfiVtSelectionPos = extern struct {
    row: i32,
    col: u16,
    reserved0: u16 = 0,
};

pub const FfiVtSelection = extern struct {
    active: u8,
    selecting: u8,
    reserved0: u16 = 0,
    start: FfiVtSelectionPos,
    end: FfiVtSelectionPos,
};

pub const FfiGeometry = extern struct {
    render_px: FfiPixelSize,
    grid_px: FfiPixelSize,
};

pub const FfiGeometryResponse = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    changed: u8,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
    reserved3: u32 = 0,
    render_px: FfiPixelSize,
    grid_px: FfiPixelSize,
    cell_px: FfiCellSize,
    geometry_epoch: u64,
};

pub const FfiPendingState = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    source_pending: u8,
    prepare_pending: u8,
    submit_pending: u8,
    reserved0: u8 = 0,
};

pub const FfiPrepareRequest = extern struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    damage_base_seq: u64,
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const FfiPreparedFrame = extern struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    damage_base_seq: u64,
    required_base_seq: u64,
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const FfiVtPublishResult = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    published: u8,
    queued: u8,
    damage_kind: u8,
    reserved0: u8 = 0,
    snapshot_seq: u64,
    geometry_epoch: u64,
};

pub const FfiPublishSlot = extern struct {
    cells: FfiVtCellWriteSpan,
    dirty_rows: FfiByteWriteSpan,
    dirty_cols_start: FfiU16WriteSpan,
    dirty_cols_end: FfiU16WriteSpan,
};

pub const FfiPublishSlotCommit = extern struct {
    history_count: u64,
    scroll_row: u64,
    snapshot_seq: u64,
    is_alternate_screen: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    cursor: FfiVtCursor,
    colors: FfiVtRenderColorState,
    selection: FfiVtSelection,
};

pub const FfiSurfaceMetrics = extern struct {
    sync_us: u64,
    copy_us: u64,
    render_us: u64,
    glyphs: u64,
    fills: u64,
    clear_fills: u64,
    background_fills: u64,
    decoration_fills: u64,
    cursor_fills: u64,
    uploads: u64,
    face_checks: u64,
    face_cache_hits: u64,
    shape_requests: u64,
    shape_cache_hits: u64,
    fallback_hits: u64,
    fallback_misses: u64,
    missing_glyphs: u64,
};

pub const FfiSurfaceHandle = extern struct {
    host_surface_id: u64,
    width: u16,
    height: u16,
};

pub const FfiPreparedSurfaceInfo = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    render_px: FfiPixelSize,
    cell_px: FfiCellSize,
    grid: FfiGridSize,
    prepare_metrics: FfiSurfaceMetrics,
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const FfiPreparedSurfaceBuffer = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    rgba_pixels: FfiByteSpan,
    uploads_committed: u64,
};

pub const FfiPreparedSurfaceDiagnostics = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    missing_glyphs: u64,
    resolve_metrics: FfiSurfaceMetrics,
};

pub const FfiSurfaceExecutionInput = extern struct {
    surface: FfiSurfaceHandle,
    uploads_committed: u64,
    render_us: u64,
};

pub const FfiSurfaceFeedback = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    surface: FfiSurfaceHandle,
    metrics: FfiSurfaceMetrics,
};

pub const FfiSurfaceTextConfig = extern struct {
    surface_px: FfiPixelSize,
    font_size_px: u16,
    reserved0: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(FfiPixelSize) == 4);
    std.debug.assert(@sizeOf(FfiCellSize) == 4);
    std.debug.assert(@sizeOf(FfiGridSize) == 4);
    std.debug.assert(@sizeOf(FfiByteSpan) == 16);
    std.debug.assert(@sizeOf(FfiVtColor) == 8);
    std.debug.assert(@sizeOf(FfiVtRgb8) == 3);
    std.debug.assert(@sizeOf(FfiVtRenderColorState) == 777);
    std.debug.assert(@sizeOf(FfiVtCursor) == 8);
}
