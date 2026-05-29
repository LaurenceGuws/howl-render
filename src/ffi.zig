const std = @import("std");
pub const c = @cImport({
    @cInclude("howl_render.h");
});
const pipeline = @import("frame/pipeline.zig");
const prepared_surface_owner = @import("frame/prepared_surface_owner.zig");
const surface_text = @import("frame/surface_text.zig");
const queue = @import("frame/queue.zig");
const surface = @import("frame/surface.zig");
const vt_publication = @import("surface/publication_source.zig");
const text_support = @import("text/font/ft_hb/support.zig");

const PublishScratch = struct {
    owner: *surface_text.SurfaceTextOwner,
    cells: []c.HowlVtSurfaceCell,
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

fn ownerFromHandle(handle: c.HowlRenderSurfaceTextHandle) ?*surface_text.SurfaceTextOwner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

pub fn isValidFont(handle: c.HowlRenderSurfaceTextHandle) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    return if (owner.isValidFont())
        c.HOWL_RENDER_CALL_OK
    else
        c.HOWL_RENDER_CALL_FAILED;
}

pub fn deriveFrameLayout(handle: c.HowlRenderSurfaceTextHandle, render_px: c.HowlRenderPixelSize, grid_px: c.HowlRenderPixelSize) callconv(.c) c.HowlRenderFrameLayoutResult {
    const owner = ownerFromHandle(handle) orelse return .{ .status = c.HOWL_RENDER_CALL_MISSING_HANDLE, .cell_px = .{ .width = 0, .height = 0 }, .grid = .{ .cols = 0, .rows = 0 } };
    const layout = owner.session.deriveFrameLayout(owner.config, pixelIn(render_px), pixelIn(grid_px)) catch {
        return .{ .status = c.HOWL_RENDER_CALL_INVALID_ARGUMENT, .cell_px = .{ .width = 0, .height = 0 }, .grid = .{ .cols = 0, .rows = 0 } };
    };
    return .{ .status = 0, .cell_px = .{ .width = layout.cell_px.width, .height = layout.cell_px.height }, .grid = .{ .cols = layout.grid.cols, .rows = layout.grid.rows } };
}

pub fn init(config: c.HowlRenderSurfaceTextConfig) callconv(.c) c.HowlRenderSurfaceTextHandle {
    if (config.surface_px.width == 0 or config.surface_px.height == 0) return null;
    if (config.font_size_px == 0) return null;
    const owner = surface_text.SurfaceTextOwner.create(std.heap.c_allocator, .{ .surface_px = pixelIn(config.surface_px), .font_size_px = config.font_size_px }) orelse return null;
    return @ptrCast(owner);
}

pub fn deinit(handle: c.HowlRenderSurfaceTextHandle) callconv(.c) void {
    const owner = ownerFromHandle(handle) orelse return;
    removePublishScratch(owner);
    owner.destroy();
}

pub fn setFontSize(handle: c.HowlRenderSurfaceTextHandle, font_size_px: u16) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (font_size_px == 0) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.setFontSizePx(font_size_px);
    return c.HOWL_RENDER_CALL_OK;
}

// The C ffi owns architecture-sized byte lengths at this seam.
// We convert immediately into a byte slice and do not retain architecture-sized state in the owner.
pub fn setFontPath(handle: c.HowlRenderSurfaceTextHandle, ptr: ?[*]const u8, len: usize) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (len > 0 and ptr == null) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.setFontPathBytes(if (len == 0 or ptr == null) null else ptr.?[0..len]) catch {
        return c.HOWL_RENDER_CALL_FAILED;
    };
    return c.HOWL_RENDER_CALL_OK;
}

// The C ffi owns architecture-sized pointer counts at this seam.
// We translate immediately into FallbackFontCount before owner code touches the value.
pub fn setFallbackFontPaths(handle: c.HowlRenderSurfaceTextHandle, ptrs: ?[*]const ?[*]const u8, count: usize) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (count > text_support.max_fallback_fonts) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    const path_count = text_support.fallbackFontCount(@intCast(count)) orelse unreachable;
    if (path_count > 0 and ptrs == null) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    const raw_paths = if (path_count == 0) &.{} else ptrs.?[0..@intCast(text_support.fallbackFontLen(path_count))];
    owner.setFallbackFontPathPtrs(raw_paths) catch |err| {
        return switch (err) {
            error.InvalidArgument => c.HOWL_RENDER_CALL_INVALID_ARGUMENT,
            error.OutOfMemory => c.HOWL_RENDER_CALL_FAILED,
        };
    };
    return c.HOWL_RENDER_CALL_OK;
}

pub fn setCursorBlinkVisible(handle: c.HowlRenderSurfaceTextHandle, visible: u8) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    _ = owner.flow.setCursorBlinkVisible(visible != 0);
    return c.HOWL_RENDER_CALL_OK;
}

pub fn syncGeometry(handle: c.HowlRenderSurfaceTextHandle, geometry: c.HowlRenderGeometry) callconv(.c) c.HowlRenderGeometryResponse {
    const owner = ownerFromHandle(handle) orelse return .{ .status = c.HOWL_RENDER_CALL_MISSING_HANDLE, .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    const layout = owner.session.deriveFrameLayout(owner.config, pixelIn(geometry.render_px), pixelIn(geometry.grid_px)) catch {
        return .{ .status = c.HOWL_RENDER_CALL_INVALID_ARGUMENT, .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    };
    return geometryOut(owner.flow.syncGeometry(.{
        .render_px = pixelIn(geometry.render_px),
        .grid_px = pixelIn(geometry.grid_px),
        .cell_px = layout.cell_px,
    }) catch return .{ .status = c.HOWL_RENDER_CALL_FAILED, .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 });
}

pub fn reservePublishSlot(handle: c.HowlRenderSurfaceTextHandle, cols: u16, rows: u16, out: ?*c.HowlRenderPublishSlot) callconv(.c) c_int {
    const slot_out = out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    slot_out.* = std.mem.zeroes(c.HowlRenderPublishSlot);
    const owner = ownerFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (cols == 0 or rows == 0) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    const slot = owner.flow.reservePublishSlot(cols, rows) catch return c.HOWL_RENDER_CALL_FAILED;
    const cells = reservePublishScratch(owner, slot.cells.len) catch {
        owner.flow.cancelPublishSlot();
        return c.HOWL_RENDER_CALL_FAILED;
    };
    slot_out.* = publishSlotOut(slot, cells);
    return c.HOWL_RENDER_CALL_OK;
}

pub fn commitPublishSlot(handle: c.HowlRenderSurfaceTextHandle, commit: c.HowlRenderPublishSlotCommit) callconv(.c) c.HowlRenderVtPublishResult {
    const owner = ownerFromHandle(handle) orelse return .{ .status = c.HOWL_RENDER_CALL_MISSING_HANDLE, .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    const reserved = if (owner.flow.publication_state.reserved) |*value| value else {
        owner.flow.cancelPublishSlot();
        return .{ .status = c.HOWL_RENDER_CALL_INVALID_ARGUMENT, .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    const cursor = cursorIn(commit.cursor) orelse {
        owner.flow.cancelPublishSlot();
        return .{ .status = c.HOWL_RENDER_CALL_INVALID_ARGUMENT, .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    if (commit.snapshot_seq == 0) {
        owner.flow.cancelPublishSlot();
        return .{ .status = c.HOWL_RENDER_CALL_INVALID_ARGUMENT, .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    }
    copyPublishScratch(owner, reserved.cells) catch {
        owner.flow.cancelPublishSlot();
        return .{ .status = c.HOWL_RENDER_CALL_INVALID_ARGUMENT, .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    for (reserved.cells) |cell| {
        validatePublicationCellValue(cell) catch {
            owner.flow.cancelPublishSlot();
            return .{ .status = c.HOWL_RENDER_CALL_INVALID_ARGUMENT, .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
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
        return .{ .status = c.HOWL_RENDER_CALL_INVALID_ARGUMENT, .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    return vtPublishResultOut(result);
}

pub fn rejectPublishSlot(handle: c.HowlRenderSurfaceTextHandle, snapshot_seq: u64) callconv(.c) c.HowlRenderVtPublishResult {
    const owner = ownerFromHandle(handle) orelse return .{ .status = c.HOWL_RENDER_CALL_MISSING_HANDLE, .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    if (snapshot_seq == 0) return .{ .status = c.HOWL_RENDER_CALL_INVALID_ARGUMENT, .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    return vtPublishResultWithStatus(owner.flow.rejectPublishSlot(snapshot_seq), c.HOWL_RENDER_CALL_FAILED);
}

pub fn cancelPublishSlot(handle: c.HowlRenderSurfaceTextHandle) callconv(.c) void {
    const owner = ownerFromHandle(handle) orelse return;
    owner.flow.cancelPublishSlot();
}

pub fn takePrepareRequest(handle: c.HowlRenderSurfaceTextHandle, out: ?*c.HowlRenderPrepareRequest) callconv(.c) c_int {
    const prepare_out = out orelse return c.HOWL_RENDER_PREPARE_FAILED;
    prepare_out.* = std.mem.zeroes(c.HowlRenderPrepareRequest);
    const owner = ownerFromHandle(handle) orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const request = owner.flow.prepare() orelse return c.HOWL_RENDER_PREPARE_IDLE;
    prepare_out.* = prepareRequestOut(request);
    return c.HOWL_RENDER_PREPARE_READY;
}

pub fn publishPrepared(handle: c.HowlRenderSurfaceTextHandle, prepared_in: c.HowlRenderPreparedFrame) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepared = preparedFrameIn(prepared_in) orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.flow.publishPrepared(prepared);
    return c.HOWL_RENDER_CALL_OK;
}

pub fn publishPreparedHandle(handle: c.HowlRenderSurfaceTextHandle, prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepared_owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (!prepared_owner.belongsToSession(owner)) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!prepared_owner.markPublished()) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.prepared_submit_handle = null;
    owner.prepared_publish_handle = opaquePreparedHandle(prepared_surface_handle);
    owner.flow.publishPrepared(prepared_owner.pipelineFrame());
    return c.HOWL_RENDER_CALL_OK;
}

pub fn takeSubmitDecision(handle: c.HowlRenderSurfaceTextHandle, out: ?*c.HowlRenderPreparedFrame) callconv(.c) c_int {
    const prepared_out = out orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    prepared_out.* = std.mem.zeroes(c.HowlRenderPreparedFrame);
    const owner = ownerFromHandle(handle) orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    return switch (owner.flow.submit()) {
        .idle => c.HOWL_RENDER_SUBMIT_DECISION_IDLE,
        .stale => c.HOWL_RENDER_SUBMIT_DECISION_STALE,
        .submit => |prepared| blk: {
            prepared_out.* = preparedFrameOut(prepared);
            break :blk c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT;
        },
        .needs_full_prepare => c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE,
    };
}

pub fn takeSubmitHandle(handle: c.HowlRenderSurfaceTextHandle, out: ?*c.HowlRenderPreparedSurfaceHandle) callconv(.c) c_int {
    const prepared_out = out orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    prepared_out.* = null;
    const owner = ownerFromHandle(handle) orelse return c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
    return switch (owner.flow.submit()) {
        .idle => c.HOWL_RENDER_SUBMIT_DECISION_IDLE,
        .stale => blk: {
            owner.prepared_publish_handle = null;
            owner.prepared_submit_handle = null;
            break :blk c.HOWL_RENDER_SUBMIT_DECISION_STALE;
        },
        .needs_full_prepare => blk: {
            owner.prepared_publish_handle = null;
            owner.prepared_submit_handle = null;
            break :blk c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE;
        },
        .submit => |prepared| blk: {
            const prepared_handle = owner.prepared_publish_handle orelse break :blk c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
            const prepared_owner = prepared_surface_owner.Owner.fromHandle(prepared_handle) orelse break :blk c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
            if (!prepared_owner.isLive()) {
                owner.prepared_publish_handle = null;
                owner.prepared_submit_handle = null;
                break :blk c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
            }
            if (!samePreparedFrame(prepared_owner.pipelineFrame(), prepared)) break :blk c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
            if (!prepared_owner.markSubmitReady()) break :blk c.HOWL_RENDER_SUBMIT_DECISION_FAILED;
            owner.prepared_publish_handle = null;
            owner.prepared_submit_handle = prepared_handle;
            prepared_out.* = abiPreparedHandle(prepared_handle);
            break :blk c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT;
        },
    };
}

pub fn acceptSubmitted(handle: c.HowlRenderSurfaceTextHandle, prepared_in: c.HowlRenderPreparedFrame) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepared = preparedFrameIn(prepared_in) orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.flow.acceptSubmitted(.{
        .token = prepared.token,
    });
    return c.HOWL_RENDER_CALL_OK;
}

pub fn submitHandle(surface_text_handle: c.HowlRenderSurfaceTextHandle, prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle, execution_in: ?*const c.HowlRenderSurfaceExecutionInput, feedback_out: ?*c.HowlRenderSurfaceFeedback) callconv(.c) c_int {
    if (feedback_out) |out| out.* = failedSurfaceFeedback();
    const owner = ownerFromHandle(surface_text_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const execution = execution_in orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    if (owner.prepared_submit_handle != opaquePreparedHandle(prepared_surface_handle)) return c.HOWL_RENDER_SUBMIT_FAILED;
    const prepared_owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    if (!prepared_owner.isLive()) {
        owner.prepared_submit_handle = null;
        return c.HOWL_RENDER_SUBMIT_FAILED;
    }
    const submitted = prepared_owner.pipelineFrame().token;
    return switch (prepared_owner.submitOwned(owner, executionInputIn(execution.*))) {
        .rendered => |feedback| blk: {
            owner.prepared_submit_handle = null;
            owner.flow.acceptSubmitted(.{ .token = submitted });
            if (feedback_out) |out| out.* = surfaceFeedbackOut(feedback);
            break :blk c.HOWL_RENDER_SUBMIT_RENDERED;
        },
        .needs_prepare => c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE,
        .failed => c.HOWL_RENDER_SUBMIT_FAILED,
    };
}

pub fn pendingState(handle: c.HowlRenderSurfaceTextHandle, out: ?*c.HowlRenderPendingState) callconv(.c) c_int {
    const pending_out = out;
    const owner = ownerFromHandle(handle) orelse {
        if (pending_out) |value| value.* = pendingStateFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
        return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    };
    const value = pending_out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    value.* = pendingStateOut(owner.flow.pendingState());
    return c.HOWL_RENDER_CALL_OK;
}

pub fn prepareHandle(surface_text_handle: c.HowlRenderSurfaceTextHandle, prepare_request: c.HowlRenderPrepareRequest, prepared_handle_out: ?*c.HowlRenderPreparedSurfaceHandle) callconv(.c) c_int {
    const prepared_out = prepared_handle_out;
    if (prepared_out) |value| value.* = null;
    const owner = ownerFromHandle(surface_text_handle) orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const value = prepared_out orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const token = prepareTokenIn(prepare_request) orelse return c.HOWL_RENDER_PREPARE_FAILED;
    const prepared_owner = owner.prepareHandle(token) catch return c.HOWL_RENDER_PREPARE_FAILED;
    value.* = @ptrCast(prepared_owner);
    return c.HOWL_RENDER_PREPARE_READY;
}

pub fn submit(surface_text_handle: c.HowlRenderSurfaceTextHandle, prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle, prepared_frame_in: c.HowlRenderPreparedFrame, execution_in: ?*const c.HowlRenderSurfaceExecutionInput, feedback_out: ?*c.HowlRenderSurfaceFeedback) callconv(.c) c_int {
    if (feedback_out) |out| out.* = failedSurfaceFeedback();
    const owner = ownerFromHandle(surface_text_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const prepared_owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const execution = execution_in orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    const prepared_frame = preparedFrameIn(prepared_frame_in) orelse return c.HOWL_RENDER_SUBMIT_FAILED;
    return switch (prepared_owner.submit(owner, prepared_frame, executionInputIn(execution.*))) {
        .rendered => |submitted| blk: {
            if (feedback_out) |out| out.* = surfaceFeedbackOut(submitted);
            break :blk c.HOWL_RENDER_SUBMIT_RENDERED;
        },
        .needs_prepare => c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE,
        .failed => c.HOWL_RENDER_SUBMIT_FAILED,
    };
}

pub fn release(prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle) callconv(.c) void {
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse return;
    owner.release();
}

pub fn describe(prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle, info_out: ?*c.HowlRenderPreparedSurfaceInfo) callconv(.c) c_int {
    const out = info_out;
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse {
        if (out) |value| value.* = infoFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
        return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    };
    const value = out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!owner.isLive()) {
        value.* = infoFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
        return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    }
    value.* = preparedInfoOut(owner.info());
    return c.HOWL_RENDER_CALL_OK;
}

pub fn buffer(prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle, buffer_out: ?*c.HowlRenderPreparedSurfaceBuffer) callconv(.c) c_int {
    const out = buffer_out;
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse {
        if (out) |value| value.* = bufferFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
        return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    };
    const value = out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!owner.isLive()) {
        value.* = bufferFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
        return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    }
    value.* = preparedBufferOut(owner.buffer());
    return c.HOWL_RENDER_CALL_OK;
}

pub fn diagnostics(prepared_surface_handle: c.HowlRenderPreparedSurfaceHandle, diagnostics_out: ?*c.HowlRenderPreparedSurfaceDiagnostics) callconv(.c) c_int {
    const out = diagnostics_out;
    const owner = prepared_surface_owner.Owner.fromHandle(prepared_surface_handle) orelse {
        if (out) |value| value.* = diagnosticsFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
        return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    };
    const value = out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!owner.isLive()) {
        value.* = diagnosticsFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
        return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    }
    value.* = preparedDiagnosticsOut(owner.diagnostics());
    return c.HOWL_RENDER_CALL_OK;
}

fn preparedInfoOut(value: prepared_surface_owner.PreparedInfo) c.HowlRenderPreparedSurfaceInfo {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
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

fn infoFailure(status: c_int) c.HowlRenderPreparedSurfaceInfo {
    return .{
        .status = status,
        .snapshot_seq = 0,
        .dirty_epoch = 0,
        .geometry_epoch = 0,
        .required_base_seq = 0,
        .render_px = .{ .width = 0, .height = 0 },
        .cell_px = .{ .width = 0, .height = 0 },
        .grid = .{ .cols = 0, .rows = 0 },
        .prepare_metrics = std.mem.zeroes(c.HowlRenderSurfaceMetrics),
        .damage_kind = 0,
    };
}

fn preparedBufferOut(value: prepared_surface_owner.PreparedBuffer) c.HowlRenderPreparedSurfaceBuffer {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .rgba_pixels = byteSpan(value.rgba_pixels),
        .uploads_committed = value.uploads_required,
    };
}

fn bufferFailure(status: c_int) c.HowlRenderPreparedSurfaceBuffer {
    return .{
        .status = status,
        .rgba_pixels = .{ .ptr = null, .len = 0 },
        .uploads_committed = 0,
    };
}

fn preparedDiagnosticsOut(value: prepared_surface_owner.PreparedDiagnostics) c.HowlRenderPreparedSurfaceDiagnostics {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .missing_glyphs = value.missing_glyphs,
        .resolve_metrics = surfaceMetricsOut(value.resolve_metrics),
    };
}

fn diagnosticsFailure(status: c_int) c.HowlRenderPreparedSurfaceDiagnostics {
    return .{
        .status = status,
        .missing_glyphs = 0,
        .resolve_metrics = std.mem.zeroes(c.HowlRenderSurfaceMetrics),
    };
}

fn surfaceFeedbackOut(value: surface.RenderSurfaceFeedback) c.HowlRenderSurfaceFeedback {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .damage_kind = @intFromEnum(value.damageKind()),
        .surface = .{ .host_surface_id = value.surface.host_surface_id, .width = value.surface.width, .height = value.surface.height },
        .metrics = surfaceMetricsOut(value.metrics),
    };
}

fn failedSurfaceFeedback() c.HowlRenderSurfaceFeedback {
    return .{
        .status = c.HOWL_RENDER_CALL_FAILED,
        .damage_kind = 0,
        .surface = .{ .host_surface_id = 0, .width = 0, .height = 0 },
        .metrics = std.mem.zeroes(c.HowlRenderSurfaceMetrics),
    };
}

fn surfaceMetricsOut(value: surface.RenderMetrics) c.HowlRenderSurfaceMetrics {
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

fn executionInputIn(value: c.HowlRenderSurfaceExecutionInput) surface_text.SurfaceText.RenderSurfaceExecutionInput {
    return .{ .surface = .{ .host_surface_id = value.surface.host_surface_id, .width = value.surface.width, .height = value.surface.height }, .uploads_committed = value.uploads_committed, .render_us = value.render_us };
}

fn geometryOut(value: surface.GeometryResponse) c.HowlRenderGeometryResponse {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .changed = @intFromBool(value.changed),
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .geometry_epoch = value.geometry_epoch,
    };
}

fn vtPublishResultOut(value: queue.VtPublishResult) c.HowlRenderVtPublishResult {
    return vtPublishResultWithStatus(value, c.HOWL_RENDER_CALL_OK);
}

fn vtPublishResultWithStatus(value: queue.VtPublishResult, status: c_int) c.HowlRenderVtPublishResult {
    return .{
        .status = status,
        .published = @intFromBool(value.published),
        .queued = @intFromBool(value.queued),
        .damage_kind = @intFromEnum(value.damage_kind),
        .snapshot_seq = value.snapshot_seq,
        .geometry_epoch = value.geometry_epoch,
    };
}

fn publishSlotOut(value: queue.PublicationSlot, cells: []c.HowlVtSurfaceCell) c.HowlRenderPublishSlot {
    std.debug.assert(cells.len == value.cells.len);
    return .{
        .cells = .{ .ptr = if (cells.len == 0) null else cells.ptr, .len = cells.len },
        .dirty_rows = .{ .ptr = if (value.dirty_rows.len == 0) null else value.dirty_rows.ptr, .len = value.dirty_rows.len },
        .dirty_cols_start = .{ .ptr = if (value.dirty_cols_start.len == 0) null else value.dirty_cols_start.ptr, .len = value.dirty_cols_start.len },
        .dirty_cols_end = .{ .ptr = if (value.dirty_cols_end.len == 0) null else value.dirty_cols_end.ptr, .len = value.dirty_cols_end.len },
    };
}

fn reservePublishScratch(owner: *surface_text.SurfaceTextOwner, cell_count: usize) ![]c.HowlVtSurfaceCell {
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
        const cells = try std.heap.c_allocator.alloc(c.HowlVtSurfaceCell, cell_count);
        if (entry.cells.len != 0) std.heap.c_allocator.free(entry.cells);
        entry.cells = cells;
    }
    @memset(entry.cells, std.mem.zeroes(c.HowlVtSurfaceCell));
    return entry.cells;
}

fn copyPublishScratch(owner: *surface_text.SurfaceTextOwner, out: []vt_publication.SourceCell) !void {
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

fn opaquePreparedHandle(handle: c.HowlRenderPreparedSurfaceHandle) prepared_surface_owner.PreparedSurfaceHandle {
    return if (handle) |value| @ptrCast(value) else null;
}

fn abiPreparedHandle(handle: prepared_surface_owner.PreparedSurfaceHandle) c.HowlRenderPreparedSurfaceHandle {
    return if (handle) |value| @ptrCast(value) else null;
}

fn pendingStateOut(value: queue.PendingState) c.HowlRenderPendingState {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .source_pending = @intFromBool(value.source_pending),
        .prepare_pending = @intFromBool(value.prepare_pending),
        .submit_pending = @intFromBool(value.submit_pending),
    };
}

fn pendingStateFailure(status: c_int) c.HowlRenderPendingState {
    return .{
        .status = status,
        .source_pending = 0,
        .prepare_pending = 0,
        .submit_pending = 0,
    };
}

fn prepareRequestOut(value: pipeline.RenderRequest) c.HowlRenderPrepareRequest {
    return .{
        .snapshot_seq = value.token.snapshot_seq,
        .dirty_epoch = value.token.dirty_epoch,
        .geometry_epoch = value.token.geometry_epoch,
        .damage_base_seq = value.token.damage_base_seq,
        .damage_kind = @intFromEnum(value.token.damage_kind),
    };
}

fn preparedFrameOut(value: pipeline.PreparedFrame) c.HowlRenderPreparedFrame {
    return .{
        .snapshot_seq = value.token.snapshot_seq,
        .dirty_epoch = value.token.dirty_epoch,
        .geometry_epoch = value.token.geometry_epoch,
        .damage_base_seq = value.token.damage_base_seq,
        .required_base_seq = value.required_base_seq,
        .damage_kind = @intFromEnum(value.token.damage_kind),
    };
}

fn prepareTokenIn(value: c.HowlRenderPrepareRequest) ?pipeline.SnapshotToken {
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

fn preparedFrameIn(value: c.HowlRenderPreparedFrame) ?pipeline.PreparedFrame {
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

fn byteSpanIn(span: c.HowlRenderByteSpan) ![]const u8 {
    if (span.len == 0) return &.{};
    if (span.ptr == null) return error.InvalidSurfaceSource;
    return span.ptr[0..span.len];
}

fn byteSpan(items: []u8) c.HowlRenderByteSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn cellValueIn(value: c.HowlVtSurfaceCell) !surface.Cell {
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

fn publicationCellValueIn(value: c.HowlVtSurfaceCell) !vt_publication.SourceCell {
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

fn validateCellValue(value: c.HowlVtSurfaceCell) !void {
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

fn validatePublicationCellValue(value: vt_publication.SourceCell) !void {
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

fn colorStateIn(value: c.HowlVtRenderColorState) vt_publication.SourceColors {
    var palette: [256]vt_publication.SourceRgb = undefined;
    for (value.palette, 0..) |color, index| palette[index] = .{ .r = color.r, .g = color.g, .b = color.b };
    return .{
        .foreground = .{ .r = value.foreground.r, .g = value.foreground.g, .b = value.foreground.b },
        .background = .{ .r = value.background.r, .g = value.background.g, .b = value.background.b },
        .cursor = .{ .r = value.cursor.r, .g = value.cursor.g, .b = value.cursor.b },
        .palette = palette,
    };
}

fn selectionIn(value: c.HowlVtSelection) vt_publication.SourceSelection {
    return .{
        .active = value.active,
        .selecting = value.selecting,
        .start = .{ .row = value.start.row, .col = value.start.col },
        .end = .{ .row = value.end.row, .col = value.end.col },
    };
}

fn colorValueIn(value: c.HowlVtColor) !surface.Color {
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

fn cursorIn(value: c.HowlVtCursor) ?surface.CursorInfo {
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

fn pixelIn(value: c.HowlRenderPixelSize) surface.PixelSize {
    return .{ .width = value.width, .height = value.height };
}
