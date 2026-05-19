const std = @import("std");
const Render = @import("../howl_render.zig");
const prepared_surface = @import("prepared_surface_ffi.zig");
const surface = @import("surface.zig");
const surface_text = @import("surface_text.zig");
const text_support = @import("../text/font/ft_hb/support.zig");

const OwnedVtSurface = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    scroll_row: u64,
    is_alternate_screen: bool,
    full_damage: bool,
    cells: []Render.SurfaceCell,
    cursor: Render.SurfaceCursorInfo,
    dirty_rows: []bool = &.{},
    dirty_cols_start: []u16 = &.{},
    dirty_cols_end: []u16 = &.{},

    fn deinit(self: *OwnedVtSurface) void {
        self.allocator.free(self.cells);
        if (self.dirty_rows.len > 0) self.allocator.free(self.dirty_rows);
        if (self.dirty_cols_start.len > 0) self.allocator.free(self.dirty_cols_start);
        if (self.dirty_cols_end.len > 0) self.allocator.free(self.dirty_cols_end);
        self.* = undefined;
    }

    fn frameData(self: *const OwnedVtSurface) Render.SurfaceFrameData {
        return .{
            .viewport = .{
                .cols = self.cols,
                .rows = self.rows,
                .scroll_row = @intCast(self.scroll_row),
                .is_alternate_screen = self.is_alternate_screen,
            },
            .grid = .{
                .cells = self.cells,
                .cols = self.cols,
                .rows = self.rows,
            },
            .cursor = self.cursor,
            .damage = .{
                .full = self.full_damage,
                .dirty_rows = self.dirty_rows,
                .dirty_cols_start = self.dirty_cols_start,
                .dirty_cols_end = self.dirty_cols_end,
            },
        };
    }
};

pub fn ownerFromHandle(comptime Ffi: type, handle: Ffi.SurfaceTextHandle) ?*surface_text.SurfaceTextOwner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

pub fn deriveFrameLayout(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, render_px: Ffi.FfiPixelSize, grid_px: Ffi.FfiPixelSize) Ffi.FfiFrameLayoutResult {
    const owner = ownerFromHandle(Ffi, handle) orelse return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle), .cell_px = .{ .width = 0, .height = 0 }, .grid = .{ .cols = 0, .rows = 0 } };
    const layout = owner.session.deriveFrameLayout(owner.config, pixelIn(render_px), pixelIn(grid_px)) catch {
        return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument), .cell_px = .{ .width = 0, .height = 0 }, .grid = .{ .cols = 0, .rows = 0 } };
    };
    return .{ .status = 0, .cell_px = .{ .width = layout.cell_px.width, .height = layout.cell_px.height }, .grid = .{ .cols = layout.grid.cols, .rows = layout.grid.rows } };
}

pub fn init(comptime Ffi: type, config: Ffi.FfiSurfaceTextConfig) Ffi.SurfaceTextHandle {
    if (config.surface_px.width == 0 or config.surface_px.height == 0) return null;
    const owner = surface_text.SurfaceTextOwner.create(.{ .surface_px = pixelIn(config.surface_px), .font_size_px = @max(config.font_size_px, 1) }) orelse return null;
    return @ptrCast(owner);
}

pub fn deinit(comptime Ffi: type, handle: Ffi.SurfaceTextHandle) void {
    const owner = ownerFromHandle(Ffi, handle) orelse return;
    owner.destroy();
}

pub fn setFontSize(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, font_size_px: u16) c_int {
    const owner = ownerFromHandle(Ffi, handle) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle);
    if (font_size_px == 0) return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
    owner.config.font_size_px = @max(font_size_px, 1);
    owner.flow.setFontSizePx(owner.config.font_size_px);
    owner.invalidateTextState();
    return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
}

pub fn setFontPath(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, ptr: ?[*]const u8, len: usize) c_int {
    const owner = ownerFromHandle(Ffi, handle) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle);
    if (len > 0 and ptr == null) return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
    if (len == 0 or ptr == null) {
        owner.setOwnedFontPath(null);
        return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
    }
    // Stage the replacement path first so allocation failure leaves the live
    // owner state untouched.
    const owned = std.heap.c_allocator.dupeZ(u8, ptr.?[0..len]) catch return @intFromEnum(Ffi.HowlRenderCallStatus.failed);
    owner.setOwnedFontPath(owned);
    return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
}

pub fn setFallbackFontPaths(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, ptrs: ?[*]const ?[*]const u8, count: usize) c_int {
    const owner = ownerFromHandle(Ffi, handle) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle);
    // Stage owned fallback paths off to the side so a failed update never
    // leaves dangling fallback pointers in the live owner state.
    var staged = std.ArrayList([:0]u8).empty;
    defer freeOwnedPathList(&staged);
    if (count > text_support.max_fallback_fonts) return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
    if (count == 0) {
        owner.adoptFallbackFontPaths(&staged);
        return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
    }
    const raw_paths = ptrs orelse return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
    const path_count: u8 = @intCast(count);
    staged.ensureTotalCapacity(std.heap.c_allocator, path_count) catch return @intFromEnum(Ffi.HowlRenderCallStatus.failed);
    var i: u8 = 0;
    while (i < path_count) : (i += 1) {
        const raw = raw_paths[i] orelse return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
        const owned = std.heap.c_allocator.dupeZ(u8, std.mem.sliceTo(raw, 0)) catch return @intFromEnum(Ffi.HowlRenderCallStatus.failed);
        staged.appendAssumeCapacity(owned);
    }
    owner.adoptFallbackFontPaths(&staged);
    return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
}

pub fn syncGeometry(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, geometry: Ffi.FfiGeometry) Ffi.FfiGeometryResponse {
    const owner = ownerFromHandle(Ffi, handle) orelse return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    return geometryOut(Ffi, owner.flow.syncGeometry(geometryIn(Ffi, geometry)));
}

pub fn surfaceQuery(comptime Ffi: type, handle: Ffi.SurfaceTextHandle) Ffi.FfiSurfaceQuery {
    const owner = ownerFromHandle(Ffi, handle) orelse return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle), .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .font_size_px = 0, .epoch = 0 };
    return surfaceQueryOut(Ffi, owner.flow.surfaceQuery());
}

pub fn publishVtSnapshot(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, snapshot_in: Ffi.FfiVtSnapshot) Ffi.FfiVtPublishResult {
    const owner = ownerFromHandle(Ffi, handle) orelse return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle), .published = 0, .queued = 0, .damage_kind = @intFromEnum(Render.FramePipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    const snapshot = vtSnapshotIn(snapshot_in) orelse return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(Render.FramePipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    return vtPublishResultOut(Ffi, owner.flow.acceptSnapshot(snapshot));
}

pub fn takePrepareRequest(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, out: ?*Ffi.FfiPrepareRequest) Ffi.HowlRenderPrepareStatus {
    const owner = ownerFromHandle(Ffi, handle) orelse return .failed;
    const prepare_out = out orelse return .failed;
    const request = owner.flow.prepare() orelse return .idle;
    prepare_out.* = prepareRequestOut(Ffi, request, owner.flow.pendingState().target_valid);
    return .ready;
}

pub fn publishPrepared(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, prepared_in: Ffi.FfiPreparedFrame) c_int {
    const owner = ownerFromHandle(Ffi, handle) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle);
    const prepared = preparedFrameIn(prepared_in) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
    owner.flow.publishPrepared(prepared);
    return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
}

pub fn takeSubmitDecision(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, out: ?*Ffi.FfiPreparedFrame) Ffi.HowlRenderSubmitDecisionStatus {
    const owner = ownerFromHandle(Ffi, handle) orelse return .failed;
    const prepared_out = out orelse return .failed;
    return switch (owner.flow.submit()) {
        .idle => .idle,
        .stale => .stale,
        .submit => |prepared| blk: {
            prepared_out.* = preparedFrameOut(Ffi, prepared);
            break :blk .submit;
        },
        .needs_full_prepare => .needs_prepare,
    };
}

pub fn acceptSubmitted(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, prepared_in: Ffi.FfiPreparedFrame, surface_in: Ffi.FfiSurfaceHandle, content_valid: u8) c_int {
    const owner = ownerFromHandle(Ffi, handle) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle);
    const prepared = preparedFrameIn(prepared_in) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
    owner.flow.acceptSubmitted(.{
        .token = prepared.token,
        .target_epoch = surface_in.epoch,
        .content_valid = content_valid != 0,
    });
    return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
}

pub fn markPresented(comptime Ffi: type, handle: Ffi.SurfaceTextHandle) void {
    const owner = ownerFromHandle(Ffi, handle) orelse return;
    owner.flow.markPresented();
}

pub fn pendingState(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, out: ?*Ffi.FfiPendingState) c_int {
    const owner = ownerFromHandle(Ffi, handle) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle);
    const pending_out = out orelse return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
    pending_out.* = pendingStateOut(Ffi, owner.flow.pendingState());
    return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
}

pub fn takeQueueMetrics(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, out: ?*Ffi.FfiQueueMetrics) c_int {
    const owner = ownerFromHandle(Ffi, handle) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle);
    const metrics_out = out orelse return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
    metrics_out.* = queueMetricsOut(Ffi, owner.flow.takeMetrics());
    return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
}

pub fn prepareHandle(comptime Ffi: type, surface_text_handle: Ffi.SurfaceTextHandle, vt_surface_in: ?*const Ffi.FfiVtSurface, prepare_request: Ffi.FfiPrepareRequest, query: Ffi.FfiSurfaceQuery, prepared_handle_out: ?*Ffi.PreparedSurfaceHandle) Ffi.HowlRenderPrepareStatus {
    const owner = ownerFromHandle(Ffi, surface_text_handle) orelse return .failed;
    const vt_surface_value = vt_surface_in orelse return .failed;
    const request = renderRequestIn(Ffi, prepare_request) orelse return .failed;
    var vt_surface = vtSurfaceIn(Ffi, std.heap.c_allocator, vt_surface_value.*) catch return .failed;
    defer vt_surface.deinit();
    const prepared = owner.session.prepareSurface(std.heap.c_allocator, .{
        .config = owner.config,
        .request = request,
        .query = surfaceQueryIn(query),
        .state = vt_surface.frameData(),
        .target_valid = prepare_request.target_valid != 0,
    }) catch return .failed;
    if (prepared_handle_out) |out| {
        const prepared_owner = prepared_surface.create(Ffi, owner, prepared) catch return .failed;
        out.* = @ptrCast(prepared_owner);
    }
    return .ready;
}

pub fn submit(comptime Ffi: type, surface_text_handle: Ffi.SurfaceTextHandle, prepared_surface_handle: Ffi.PreparedSurfaceHandle, prepared_frame_in: Ffi.FfiPreparedFrame, execution_in: ?*const Ffi.FfiSurfaceExecutionInput, feedback_out: ?*Ffi.FfiSurfaceFeedback) Ffi.HowlRenderSubmitStatus {
    const owner = ownerFromHandle(Ffi, surface_text_handle) orelse return .failed;
    const prepared_owner = prepared_surface.fromHandle(Ffi, prepared_surface_handle) orelse return .failed;
    if (prepared_owner.session_owner != owner) return .failed;
    const execution = execution_in orelse return .failed;
    const prepared_frame = preparedFrameIn(prepared_frame_in) orelse return .failed;
    if (!samePreparedFrame(prepared_owner.prepared.pipelineFrame(), prepared_frame)) return .needs_prepare;
    const submitted = owner.session.submitSurface(&prepared_owner.prepared, executionInputIn(execution.*)) catch return .failed;
    if (feedback_out) |out| out.* = surfaceFeedbackOut(Ffi, submitted);
    if (submitted.content_valid) {
        // Only a successfully submitted complete image can seed the retained
        // base used by later partial prepares.
        owner.retainSurfaceImage(
            &prepared_owner.rgba_pixels,
            prepared_owner.prepared.render_px.width,
            prepared_owner.prepared.render_px.height,
            submitted.surface.epoch,
        );
    } else {
        owner.clearRetainedSurface();
    }
    prepared_owner.destroy();
    return .rendered;
}

fn surfaceFeedbackOut(comptime Ffi: type, value: Render.RenderSurfaceFeedback) Ffi.FfiSurfaceFeedback {
    return .{
        .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok),
        .damage_kind = @intFromEnum(value.damageKind()),
        .surface = .{ .host_surface_id = value.surface.host_surface_id, .width = value.surface.width, .height = value.surface.height, .epoch = value.surface.epoch },
        .metrics = surfaceMetricsOut(Ffi, value.metrics),
    };
}

fn freeOwnedPathList(paths: *std.ArrayList([:0]u8)) void {
    for (paths.items) |path| std.heap.c_allocator.free(path);
    paths.deinit(std.heap.c_allocator);
    paths.* = .empty;
}

fn surfaceMetricsOut(comptime Ffi: type, value: Render.RenderMetrics) Ffi.FfiSurfaceMetrics {
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

fn executionInputIn(value: anytype) Render.SurfaceText.RenderSurfaceExecutionInput {
    return .{ .surface = .{ .host_surface_id = value.surface.host_surface_id, .width = value.surface.width, .height = value.surface.height, .epoch = value.surface.epoch }, .uploads_committed = value.uploads_committed, .render_us = value.render_us, .content_valid = value.content_valid != 0 };
}

fn geometryIn(comptime Ffi: type, value: Ffi.FfiGeometry) Render.FrameQueue.Geometry {
    return .{
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
    };
}

fn geometryOut(comptime Ffi: type, value: Render.FrameQueue.GeometryResponse) Ffi.FfiGeometryResponse {
    return .{
        .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok),
        .changed = @intFromBool(value.changed),
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .geometry_epoch = value.geometry_epoch,
    };
}

fn surfaceQueryOut(comptime Ffi: type, value: Render.FrameQueue.SurfaceQuery) Ffi.FfiSurfaceQuery {
    return .{
        .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok),
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .font_size_px = value.font_size_px,
        .epoch = value.epoch,
    };
}

fn vtSnapshotIn(value: anytype) ?Render.FrameQueue.VtSnapshot {
    const damage_kind = damageKindIn(value.damage_kind) orelse return null;
    return .{
        .cols = value.cols,
        .rows = value.rows,
        .scrollback_offset = value.scrollback_offset,
        .snapshot_seq = value.snapshot_seq,
        .is_alternate_screen = value.is_alternate_screen != 0,
        .damage_kind = damage_kind,
    };
}

fn vtPublishResultOut(comptime Ffi: type, value: Render.FrameQueue.VtPublishResult) Ffi.FfiVtPublishResult {
    return .{
        .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok),
        .published = @intFromBool(value.published),
        .queued = @intFromBool(value.queued),
        .damage_kind = @intFromEnum(value.damage_kind),
        .snapshot_seq = value.snapshot_seq,
        .geometry_epoch = value.geometry_epoch,
    };
}

fn pendingStateOut(comptime Ffi: type, value: anytype) Ffi.FfiPendingState {
    return .{
        .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok),
        .source_pending = @intFromBool(value.source_pending),
        .prepare_pending = @intFromBool(value.prepare_pending),
        .submit_pending = @intFromBool(value.submit_pending),
        .target_valid = @intFromBool(value.target_valid),
    };
}

fn queueMetricsOut(comptime Ffi: type, value: anytype) Ffi.FfiQueueMetrics {
    return .{
        .snapshot_publishes = value.snapshot_publishes,
        .snapshot_hidden_drops = value.snapshot_hidden_drops,
        .snapshot_clean_drops = value.snapshot_clean_drops,
        .prepare_requests = value.prepare_requests,
        .prepare_coalesces = value.prepare_coalesces,
        .prepare_forced_full = value.prepare_forced_full,
        .prepare_takes = value.prepare_takes,
        .prepared_publishes = value.prepared_publishes,
        .prepared_coalesces = value.prepared_coalesces,
        .submit_takes = value.submit_takes,
        .submit_valid = value.submit_valid,
        .submit_rejected = value.submit_rejected,
        .full_prepare_requests = value.full_prepare_requests,
        .submitted_accepts = value.submitted_accepts,
        .presents = value.presents,
        .target_invalidations = value.target_invalidations,
    };
}

fn prepareRequestOut(comptime Ffi: type, value: Render.FramePipeline.RenderRequest, target_valid: bool) Ffi.FfiPrepareRequest {
    return .{
        .snapshot_seq = value.token.snapshot_seq,
        .dirty_epoch = value.token.dirty_epoch,
        .geometry_epoch = value.token.geometry_epoch,
        .damage_base_seq = value.token.damage_base_seq,
        .known_target_epoch = value.known_target_epoch,
        .target_valid = @intFromBool(target_valid),
        .damage_kind = @intFromEnum(value.token.damage_kind),
    };
}

fn preparedFrameOut(comptime Ffi: type, value: Render.FramePipeline.PreparedFrame) Ffi.FfiPreparedFrame {
    return .{
        .snapshot_seq = value.token.snapshot_seq,
        .dirty_epoch = value.token.dirty_epoch,
        .geometry_epoch = value.token.geometry_epoch,
        .damage_base_seq = value.token.damage_base_seq,
        .required_base_seq = value.required_base_seq,
        .required_target_epoch = value.required_target_epoch,
        .damage_kind = @intFromEnum(value.token.damage_kind),
    };
}

fn renderRequestIn(comptime Ffi: type, value: Ffi.FfiPrepareRequest) ?Render.FramePipeline.RenderRequest {
    const damage_kind = damageKindIn(value.damage_kind) orelse return null;
    return .{
        .token = .{
            .snapshot_seq = value.snapshot_seq,
            .dirty_epoch = value.dirty_epoch,
            .geometry_epoch = value.geometry_epoch,
            .damage_base_seq = value.damage_base_seq,
            .damage_kind = damage_kind,
        },
        .known_target_epoch = value.known_target_epoch,
        .allow_retained_reuse = true,
    };
}

fn preparedFrameIn(value: anytype) ?Render.FramePipeline.PreparedFrame {
    const damage_kind = damageKindIn(value.damage_kind) orelse return null;
    return .{ .token = .{ .snapshot_seq = value.snapshot_seq, .dirty_epoch = value.dirty_epoch, .geometry_epoch = value.geometry_epoch, .damage_base_seq = value.damage_base_seq, .damage_kind = damage_kind }, .required_base_seq = value.required_base_seq, .required_target_epoch = value.required_target_epoch };
}

fn samePreparedFrame(a: Render.FramePipeline.PreparedFrame, b: Render.FramePipeline.PreparedFrame) bool {
    return a.token.snapshot_seq == b.token.snapshot_seq and
        a.token.dirty_epoch == b.token.dirty_epoch and
        a.token.geometry_epoch == b.token.geometry_epoch and
        a.token.damage_base_seq == b.token.damage_base_seq and
        a.token.damage_kind == b.token.damage_kind and
        a.required_base_seq == b.required_base_seq and
        a.required_target_epoch == b.required_target_epoch;
}

fn surfaceQueryIn(value: anytype) Render.SurfaceQuery {
    return .{ .render_px = .{ .width = value.render_px.width, .height = value.render_px.height }, .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height }, .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height }, .font_size_px = value.font_size_px, .epoch = value.epoch };
}

fn vtSurfaceIn(comptime Ffi: type, allocator: std.mem.Allocator, value: Ffi.FfiVtSurface) !OwnedVtSurface {
    const cell_count: u32 = @as(u32, value.cols) * @as(u32, value.rows);
    if (value.cells.len != cell_count) return error.InvalidSurfaceSource;

    const cells = try allocator.alloc(Render.SurfaceCell, @intCast(cell_count));
    errdefer allocator.free(cells);
    for (cells, 0..) |*dst, idx| dst.* = try cellValueIn(Ffi, value.cells.ptr[idx]);

    const dirty_rows = try dirtyRowsIn(allocator, value.rows, value.dirty_rows);
    errdefer if (dirty_rows.len > 0) allocator.free(dirty_rows);
    const dirty_cols_start = try dirtyColsIn(allocator, value.rows, value.dirty_cols_start);
    errdefer if (dirty_cols_start.len > 0) allocator.free(dirty_cols_start);
    const dirty_cols_end = try dirtyColsIn(allocator, value.rows, value.dirty_cols_end);
    errdefer if (dirty_cols_end.len > 0) allocator.free(dirty_cols_end);

    const cursor = cursorIn(value.cursor) orelse return error.InvalidSurfaceSource;
    return .{
        .allocator = allocator,
        .cols = value.cols,
        .rows = value.rows,
        .scroll_row = value.scroll_row,
        .is_alternate_screen = value.is_alternate_screen != 0,
        .full_damage = value.full_damage != 0,
        .cells = cells,
        .cursor = cursor,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

fn dirtyRowsIn(allocator: std.mem.Allocator, rows: u16, span: anytype) ![]bool {
    if (span.len == 0) return &.{};
    if (span.ptr == null or span.len != rows) return error.InvalidSurfaceSource;
    const out = try allocator.alloc(bool, rows);
    for (out, 0..) |*dst, idx| dst.* = span.ptr[idx] != 0;
    return out;
}

fn dirtyColsIn(allocator: std.mem.Allocator, rows: u16, span: anytype) ![]u16 {
    if (span.len == 0) return &.{};
    if (span.ptr == null or span.len != rows) return error.InvalidSurfaceSource;
    return try allocator.dupe(u16, span.ptr[0..rows]);
}

fn cellValueIn(comptime Ffi: type, value: Ffi.FfiCell) !Render.SurfaceCell {
    if (value.codepoint > std.math.maxInt(u21)) return error.InvalidSurfaceSource;

    const fg_color = colorIn(value.fg_color) orelse return error.InvalidSurfaceSource;
    const bg_color = colorIn(value.bg_color) orelse return error.InvalidSurfaceSource;
    const underline_color = colorIn(value.underline_color) orelse return error.InvalidSurfaceSource;
    const underline_style = underlineStyleIn(value.underline_style) orelse return error.InvalidSurfaceSource;

    return .{
        .codepoint = @intCast(value.codepoint),
        .flags = .{ .continuation = value.flags.continuation != 0 },
        .fg_color = fg_color,
        .bg_color = bg_color,
        .underline_color = underline_color,
        .underline_style = underline_style,
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
        },
        .link_id = value.link_id,
    };
}

fn colorIn(value: anytype) ?Render.SurfaceColor {
    return switch (value.kind) {
        0 => .{ .kind = .default, .value = 0 },
        1 => blk: {
            if (value.value > std.math.maxInt(u8)) return null;
            break :blk .{ .kind = .indexed, .value = @truncate(value.value) };
        },
        2 => blk: {
            if (value.value > std.math.maxInt(u24)) return null;
            break :blk .{ .kind = .rgb, .value = @truncate(value.value) };
        },
        else => null,
    };
}

fn damageKindIn(value: u8) ?Render.FramePipeline.DamageKind {
    return switch (value) {
        @intFromEnum(Render.FramePipeline.DamageKind.none) => .none,
        @intFromEnum(Render.FramePipeline.DamageKind.partial) => .partial,
        @intFromEnum(Render.FramePipeline.DamageKind.full) => .full,
        else => null,
    };
}

fn cursorIn(value: anytype) ?Render.SurfaceCursorInfo {
    const shape = switch (value.shape) {
        0 => Render.SurfaceCursorShape.block,
        1 => .underline,
        2 => .beam,
        3 => .hollow_block,
        else => return null,
    };
    return .{ .row = value.row, .col = value.col, .visible = value.visible != 0, .shape = shape };
}

fn underlineStyleIn(value: u8) ?Render.UnderlineStyle {
    return switch (value) {
        0 => .straight,
        1 => .double,
        2 => .curly,
        3 => .dotted,
        4 => .dashed,
        else => null,
    };
}

fn pixelIn(value: anytype) surface.PixelSize {
    return .{ .width = value.width, .height = value.height };
}

const TestFfi = struct {
    pub const FfiCellFlags = extern struct {
        continuation: u8,
        reserved0: u8 = 0,
        reserved1: u8 = 0,
        reserved2: u8 = 0,
    };

    pub const FfiColor = extern struct {
        kind: u8,
        value: u32,
    };

    pub const FfiCellAttrs = extern struct {
        bold: u8 = 0,
        dim: u8 = 0,
        italic: u8 = 0,
        underline: u8 = 0,
        underline_color_set: u8 = 0,
        blink: u8 = 0,
        inverse: u8 = 0,
        invisible: u8 = 0,
        strikethrough: u8 = 0,
    };

    pub const FfiCell = extern struct {
        codepoint: u32,
        flags: FfiCellFlags,
        fg_color: FfiColor,
        bg_color: FfiColor,
        underline_color: FfiColor,
        underline_style: u8,
        reserved0: u8 = 0,
        reserved1: u8 = 0,
        reserved2: u8 = 0,
        attrs: FfiCellAttrs,
        link_id: u32,
    };

    pub const FfiCursor = extern struct {
        row: u16,
        col: u16,
        visible: u8,
        shape: u8,
    };

    pub const FfiCellSpan = extern struct {
        ptr: [*c]const FfiCell,
        len: u16,
    };

    pub const FfiByteSpan = extern struct {
        ptr: [*c]const u8,
        len: u16,
    };

    pub const FfiU16Span = extern struct {
        ptr: [*c]const u16,
        len: u16,
    };

    pub const FfiVtSurface = extern struct {
        cells: FfiCellSpan,
        cols: u16,
        rows: u16,
        scroll_row: u64,
        is_alternate_screen: u8,
        full_damage: u8,
        reserved1: u16 = 0,
        dirty_rows: FfiByteSpan,
        dirty_cols_start: FfiU16Span,
        dirty_cols_end: FfiU16Span,
        cursor: FfiCursor,
    };

    pub const FfiPrepareRequest = extern struct {
        snapshot_seq: u64,
        dirty_epoch: u64,
        geometry_epoch: u64,
        damage_base_seq: u64,
        known_target_epoch: u64,
        target_valid: u8,
        damage_kind: u8,
        reserved0: u16 = 0,
    };

    pub const FfiPreparedFrame = extern struct {
        snapshot_seq: u64,
        dirty_epoch: u64,
        geometry_epoch: u64,
        damage_base_seq: u64,
        required_base_seq: u64,
        required_target_epoch: u64,
        damage_kind: u8,
        reserved0: u8 = 0,
        reserved1: u16 = 0,
    };
};

fn testCell() TestFfi.FfiCell {
    return .{
        .codepoint = 'a',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{},
        .link_id = 0,
    };
}

fn testCursor(shape: u8) TestFfi.FfiCursor {
    return .{ .row = 0, .col = 0, .visible = 1, .shape = shape };
}

fn testVtSurface(cells: []const TestFfi.FfiCell, cursor: TestFfi.FfiCursor) TestFfi.FfiVtSurface {
    return .{
        .cells = .{ .ptr = if (cells.len == 0) null else cells.ptr, .len = @intCast(cells.len) },
        .cols = 1,
        .rows = 1,
        .scroll_row = 0,
        .is_alternate_screen = 0,
        .full_damage = 1,
        .dirty_rows = .{ .ptr = null, .len = 0 },
        .dirty_cols_start = .{ .ptr = null, .len = 0 },
        .dirty_cols_end = .{ .ptr = null, .len = 0 },
        .cursor = cursor,
    };
}

test "renderRequestIn rejects invalid damage kind" {
    const request: TestFfi.FfiPrepareRequest = .{
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .geometry_epoch = 1,
        .damage_base_seq = 0,
        .known_target_epoch = 0,
        .target_valid = 0,
        .damage_kind = 2,
    };
    try std.testing.expect(renderRequestIn(TestFfi, request) == null);
}

test "preparedFrameIn rejects invalid damage kind" {
    const prepared: TestFfi.FfiPreparedFrame = .{
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .geometry_epoch = 1,
        .damage_base_seq = 0,
        .required_base_seq = 0,
        .required_target_epoch = 0,
        .damage_kind = 2,
    };
    try std.testing.expect(preparedFrameIn(prepared) == null);
}

test "vtSurfaceIn rejects invalid color kind" {
    var cell = testCell();
    cell.fg_color.kind = 9;
    const cells = [_]TestFfi.FfiCell{cell};
    try std.testing.expectError(
        error.InvalidSurfaceSource,
        vtSurfaceIn(TestFfi, std.testing.allocator, testVtSurface(&cells, testCursor(0))),
    );
}

test "vtSurfaceIn rejects rgb value outside u24" {
    var cell = testCell();
    cell.fg_color.kind = 2;
    cell.fg_color.value = std.math.maxInt(u24) + 1;
    const cells = [_]TestFfi.FfiCell{cell};
    try std.testing.expectError(
        error.InvalidSurfaceSource,
        vtSurfaceIn(TestFfi, std.testing.allocator, testVtSurface(&cells, testCursor(0))),
    );
}

test "vtSurfaceIn rejects invalid cursor shape" {
    const cells = [_]TestFfi.FfiCell{testCell()};
    try std.testing.expectError(
        error.InvalidSurfaceSource,
        vtSurfaceIn(TestFfi, std.testing.allocator, testVtSurface(&cells, testCursor(9))),
    );
}

test "vtSurfaceIn rejects invalid underline style" {
    var cell = testCell();
    cell.underline_style = 9;
    const cells = [_]TestFfi.FfiCell{cell};
    try std.testing.expectError(
        error.InvalidSurfaceSource,
        vtSurfaceIn(TestFfi, std.testing.allocator, testVtSurface(&cells, testCursor(0))),
    );
}

test "vtSurfaceIn rejects extra cells beyond declared grid" {
    const cells = [_]TestFfi.FfiCell{ testCell(), testCell() };
    try std.testing.expectError(
        error.InvalidSurfaceSource,
        vtSurfaceIn(TestFfi, std.testing.allocator, testVtSurface(&cells, testCursor(0))),
    );
}
