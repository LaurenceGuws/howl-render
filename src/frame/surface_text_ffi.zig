const std = @import("std");
const Render = @import("../howl_render.zig");
const abi = @import("../ffi_types.zig");
const prepared_surface_owner = @import("prepared_surface_owner.zig");
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

fn ownerFromHandle(handle: abi.SurfaceTextHandle) ?*surface_text.SurfaceTextOwner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
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
    const owner = surface_text.SurfaceTextOwner.create(.{ .surface_px = pixelIn(config.surface_px), .font_size_px = @max(config.font_size_px, 1) }) orelse return null;
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

pub fn setFontPath(handle: abi.SurfaceTextHandle, ptr: ?[*]const u8, len: usize) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    if (len > 0 and ptr == null) return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    owner.setFontPathBytes(if (len == 0 or ptr == null) null else ptr.?[0..len]) catch {
        return @intFromEnum(abi.HowlRenderCallStatus.failed);
    };
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn setFallbackFontPaths(handle: abi.SurfaceTextHandle, ptrs: ?[*]const ?[*]const u8, count: usize) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    if (count > 0 and ptrs == null) return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    const raw_paths = if (count == 0) &.{} else ptrs.?[0..count];
    owner.setFallbackFontPathPtrs(raw_paths) catch |err| {
        return @intFromEnum(switch (err) {
            error.InvalidArgument => abi.HowlRenderCallStatus.invalid_argument,
            error.OutOfMemory => abi.HowlRenderCallStatus.failed,
        });
    };
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn syncGeometry(handle: abi.SurfaceTextHandle, geometry: abi.FfiGeometry) callconv(.c) abi.FfiGeometryResponse {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.missing_handle), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    return geometryOut(owner.flow.syncGeometry(geometryIn(geometry)));
}

pub fn surfaceQuery(handle: abi.SurfaceTextHandle) callconv(.c) abi.FfiSurfaceQuery {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.missing_handle), .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .font_size_px = 0, .epoch = 0 };
    return surfaceQueryOut(owner.flow.surfaceQuery());
}

pub fn publishVtSnapshot(handle: abi.SurfaceTextHandle, snapshot_in: abi.FfiVtSnapshot) callconv(.c) abi.FfiVtPublishResult {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.missing_handle), .published = 0, .queued = 0, .damage_kind = @intFromEnum(Render.FramePipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    const snapshot = vtSnapshotIn(snapshot_in) orelse return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(Render.FramePipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    return vtPublishResultOut(owner.flow.acceptSnapshot(snapshot));
}

pub fn takePrepareRequest(handle: abi.SurfaceTextHandle, out: ?*abi.FfiPrepareRequest) callconv(.c) abi.HowlRenderPrepareStatus {
    const owner = ownerFromHandle(handle) orelse return .failed;
    const prepare_out = out orelse return .failed;
    const request = owner.flow.prepare() orelse return .idle;
    prepare_out.* = prepareRequestOut(request, owner.flow.pendingState().target_valid);
    return .ready;
}

pub fn publishPrepared(handle: abi.SurfaceTextHandle, prepared_in: abi.FfiPreparedFrame) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const prepared = preparedFrameIn(prepared_in) orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    owner.flow.publishPrepared(prepared);
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn takeSubmitDecision(handle: abi.SurfaceTextHandle, out: ?*abi.FfiPreparedFrame) callconv(.c) abi.HowlRenderSubmitDecisionStatus {
    const owner = ownerFromHandle(handle) orelse return .failed;
    const prepared_out = out orelse return .failed;
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

pub fn acceptSubmitted(handle: abi.SurfaceTextHandle, prepared_in: abi.FfiPreparedFrame, surface_in: abi.FfiSurfaceHandle, content_valid: u8) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const prepared = preparedFrameIn(prepared_in) orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    owner.flow.acceptSubmitted(.{
        .token = prepared.token,
        .target_epoch = surface_in.epoch,
        .content_valid = content_valid != 0,
    });
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn markPresented(handle: abi.SurfaceTextHandle) callconv(.c) void {
    const owner = ownerFromHandle(handle) orelse return;
    owner.flow.markPresented();
}

pub fn pendingState(handle: abi.SurfaceTextHandle, out: ?*abi.FfiPendingState) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const pending_out = out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    pending_out.* = pendingStateOut(owner.flow.pendingState());
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn takeQueueMetrics(handle: abi.SurfaceTextHandle, out: ?*abi.FfiQueueMetrics) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const metrics_out = out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    metrics_out.* = queueMetricsOut(owner.flow.takeMetrics());
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn prepareHandle(surface_text_handle: abi.SurfaceTextHandle, vt_surface_in: ?*const abi.FfiVtSurface, prepare_request: abi.FfiPrepareRequest, query: abi.FfiSurfaceQuery, prepared_handle_out: ?*abi.PreparedSurfaceHandle) callconv(.c) abi.HowlRenderPrepareStatus {
    const owner = ownerFromHandle(surface_text_handle) orelse return .failed;
    const vt_surface_value = vt_surface_in orelse return .failed;
    const request = renderRequestIn(prepare_request) orelse return .failed;
    var vt_surface = vtSurfaceIn(std.heap.c_allocator, vt_surface_value.*) catch return .failed;
    defer vt_surface.deinit();
    const prepared = owner.session.prepareSurface(std.heap.c_allocator, .{
        .config = owner.config,
        .request = request,
        .query = surfaceQueryIn(query),
        .state = vt_surface.frameData(),
        .target_valid = prepare_request.target_valid != 0,
    }) catch return .failed;
    if (prepared_handle_out) |out| {
        const prepared_owner = prepared_surface_owner.Owner.create(owner, prepared) catch return .failed;
        out.* = @ptrCast(prepared_owner);
    }
    return .ready;
}

pub fn submit(surface_text_handle: abi.SurfaceTextHandle, prepared_surface_handle: abi.PreparedSurfaceHandle, prepared_frame_in: abi.FfiPreparedFrame, execution_in: ?*const abi.FfiSurfaceExecutionInput, feedback_out: ?*abi.FfiSurfaceFeedback) callconv(.c) abi.HowlRenderSubmitStatus {
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

fn surfaceFeedbackOut(value: Render.RenderSurfaceFeedback) abi.FfiSurfaceFeedback {
    return .{
        .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
        .damage_kind = @intFromEnum(value.damageKind()),
        .surface = .{ .host_surface_id = value.surface.host_surface_id, .width = value.surface.width, .height = value.surface.height, .epoch = value.surface.epoch },
        .metrics = surfaceMetricsOut(value.metrics),
    };
}

fn surfaceMetricsOut(value: Render.RenderMetrics) abi.FfiSurfaceMetrics {
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

fn executionInputIn(value: abi.FfiSurfaceExecutionInput) Render.SurfaceText.RenderSurfaceExecutionInput {
    return .{ .surface = .{ .host_surface_id = value.surface.host_surface_id, .width = value.surface.width, .height = value.surface.height, .epoch = value.surface.epoch }, .uploads_committed = value.uploads_committed, .render_us = value.render_us, .content_valid = value.content_valid != 0 };
}

fn geometryIn(value: abi.FfiGeometry) Render.Geometry {
    return .{
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
    };
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

fn surfaceQueryOut(value: Render.SurfaceQuery) abi.FfiSurfaceQuery {
    return .{
        .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .font_size_px = value.font_size_px,
        .epoch = value.epoch,
    };
}

fn vtSnapshotIn(value: abi.FfiVtSnapshot) ?Render.FrameQueue.VtSnapshot {
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

fn vtPublishResultOut(value: Render.FrameQueue.VtPublishResult) abi.FfiVtPublishResult {
    return .{
        .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
        .published = @intFromBool(value.published),
        .queued = @intFromBool(value.queued),
        .damage_kind = @intFromEnum(value.damage_kind),
        .snapshot_seq = value.snapshot_seq,
        .geometry_epoch = value.geometry_epoch,
    };
}

fn pendingStateOut(value: Render.FrameQueue.PendingState) abi.FfiPendingState {
    return .{
        .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
        .source_pending = @intFromBool(value.source_pending),
        .prepare_pending = @intFromBool(value.prepare_pending),
        .submit_pending = @intFromBool(value.submit_pending),
        .target_valid = @intFromBool(value.target_valid),
    };
}

fn queueMetricsOut(value: Render.FrameQueue.QueueMetrics) abi.FfiQueueMetrics {
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

fn prepareRequestOut(value: Render.FramePipeline.RenderRequest, target_valid: bool) abi.FfiPrepareRequest {
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

fn preparedFrameOut(value: Render.FramePipeline.PreparedFrame) abi.FfiPreparedFrame {
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

fn renderRequestIn(value: abi.FfiPrepareRequest) ?Render.FramePipeline.RenderRequest {
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

fn preparedFrameIn(value: abi.FfiPreparedFrame) ?Render.FramePipeline.PreparedFrame {
    const damage_kind = damageKindIn(value.damage_kind) orelse return null;
    return .{ .token = .{ .snapshot_seq = value.snapshot_seq, .dirty_epoch = value.dirty_epoch, .geometry_epoch = value.geometry_epoch, .damage_base_seq = value.damage_base_seq, .damage_kind = damage_kind }, .required_base_seq = value.required_base_seq, .required_target_epoch = value.required_target_epoch };
}

fn surfaceQueryIn(value: abi.FfiSurfaceQuery) Render.SurfaceQuery {
    return .{ .render_px = .{ .width = value.render_px.width, .height = value.render_px.height }, .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height }, .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height }, .font_size_px = value.font_size_px, .epoch = value.epoch };
}

fn vtSurfaceIn(allocator: std.mem.Allocator, value: abi.FfiVtSurface) !OwnedVtSurface {
    const cell_count: u32 = @as(u32, value.cols) * @as(u32, value.rows);
    if (value.cells.len != cell_count) return error.InvalidSurfaceSource;

    const cells = try allocator.alloc(Render.SurfaceCell, @intCast(cell_count));
    errdefer allocator.free(cells);
    for (cells, 0..) |*dst, idx| dst.* = try cellValueIn(value.cells.ptr[idx]);

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

fn dirtyRowsIn(allocator: std.mem.Allocator, rows: u16, span: abi.FfiByteSpan) ![]bool {
    if (span.len == 0) return &.{};
    if (span.ptr == null or span.len != rows) return error.InvalidSurfaceSource;
    const out = try allocator.alloc(bool, rows);
    for (out, 0..) |*dst, idx| dst.* = span.ptr[idx] != 0;
    return out;
}

fn dirtyColsIn(allocator: std.mem.Allocator, rows: u16, span: abi.FfiU16Span) ![]u16 {
    if (span.len == 0) return &.{};
    if (span.ptr == null or span.len != rows) return error.InvalidSurfaceSource;
    return try allocator.dupe(u16, span.ptr[0..rows]);
}

fn cellValueIn(value: abi.FfiCell) !Render.SurfaceCell {
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

fn colorIn(value: abi.FfiColor) ?Render.SurfaceColor {
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

fn cursorIn(value: abi.FfiCursor) ?Render.SurfaceCursorInfo {
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

fn pixelIn(value: abi.FfiPixelSize) surface.PixelSize {
    return .{ .width = value.width, .height = value.height };
}
