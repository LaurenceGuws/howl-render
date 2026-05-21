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

pub fn syncGeometry(handle: abi.SurfaceTextHandle, geometry: abi.FfiGeometry) callconv(.c) abi.FfiGeometryResponse {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.missing_handle), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    const layout = owner.session.deriveFrameLayout(owner.config, pixelIn(geometry.render_px), pixelIn(geometry.grid_px)) catch {
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    };
    return geometryOut(owner.flow.syncGeometry(.{
        .render_px = pixelIn(geometry.render_px),
        .grid_px = pixelIn(geometry.grid_px),
        .cell_px = layout.cell_px,
    }));
}

pub fn publishVtSource(handle: abi.SurfaceTextHandle, source_in: abi.FfiVtSurface) callconv(.c) abi.FfiVtPublishResult {
    const owner = ownerFromHandle(handle) orelse return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.missing_handle), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    const source = vtSurfaceIn(owner.allocator, source_in) catch {
        return .{ .status = @intFromEnum(abi.HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = @intFromEnum(pipeline.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    return vtPublishResultOut(owner.flow.acceptSource(source));
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

pub fn acceptSubmitted(handle: abi.SurfaceTextHandle, prepared_in: abi.FfiPreparedFrame) callconv(.c) c_int {
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    const prepared = preparedFrameIn(prepared_in) orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    owner.flow.acceptSubmitted(.{
        .token = prepared.token,
    });
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn markPresented(handle: abi.SurfaceTextHandle) callconv(.c) void {
    const owner = ownerFromHandle(handle) orelse return;
    owner.flow.markPresented();
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

pub fn takeQueueMetrics(handle: abi.SurfaceTextHandle, out: ?*abi.FfiQueueMetrics) callconv(.c) c_int {
    const metrics_out = out orelse return @intFromEnum(abi.HowlRenderCallStatus.invalid_argument);
    metrics_out.* = std.mem.zeroes(abi.FfiQueueMetrics);
    const owner = ownerFromHandle(handle) orelse return @intFromEnum(abi.HowlRenderCallStatus.missing_handle);
    metrics_out.* = queueMetricsOut(owner.flow.takeMetrics());
    return @intFromEnum(abi.HowlRenderCallStatus.ok);
}

pub fn prepareHandle(surface_text_handle: abi.SurfaceTextHandle, prepare_request: abi.FfiPrepareRequest, prepared_handle_out: ?*abi.PreparedSurfaceHandle) callconv(.c) abi.HowlRenderPrepareStatus {
    const prepared_out = prepared_handle_out;
    if (prepared_out) |value| value.* = null;
    const owner = ownerFromHandle(surface_text_handle) orelse return .failed;
    const value = prepared_out orelse return .failed;
    const request = renderRequestIn(prepare_request) orelse return .failed;
    const prepared = owner.preparePublishedSurface(request) catch return .failed;
    const prepared_owner = prepared_surface_owner.Owner.create(owner, prepared) catch return .failed;
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
    return .{
        .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
        .published = @intFromBool(value.published),
        .queued = @intFromBool(value.queued),
        .damage_kind = @intFromEnum(value.damage_kind),
        .snapshot_seq = value.snapshot_seq,
        .geometry_epoch = value.geometry_epoch,
    };
}

fn pendingStateOut(value: queue.PendingState) abi.FfiPendingState {
    return .{
        .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
        .source_pending = @intFromBool(value.source_pending),
        .prepare_pending = @intFromBool(value.prepare_pending),
        .submit_pending = @intFromBool(value.submit_pending),
        .present_pending = @intFromBool(value.present_pending),
    };
}

fn pendingStateFailure(status: c_int) abi.FfiPendingState {
    return .{
        .status = status,
        .source_pending = 0,
        .prepare_pending = 0,
        .submit_pending = 0,
        .present_pending = 0,
    };
}

fn queueMetricsOut(value: queue.QueueMetrics) abi.FfiQueueMetrics {
    return .{
        .snapshot_publishes = value.snapshot_publishes,
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

fn renderRequestIn(value: abi.FfiPrepareRequest) ?pipeline.RenderRequest {
    const damage_kind = damageKindIn(value.damage_kind) orelse return null;
    return .{
        .token = .{
            .snapshot_seq = value.snapshot_seq,
            .dirty_epoch = value.dirty_epoch,
            .geometry_epoch = value.geometry_epoch,
            .damage_base_seq = value.damage_base_seq,
            .damage_kind = damage_kind,
        },
        .allow_retained_reuse = true,
    };
}

fn preparedFrameIn(value: abi.FfiPreparedFrame) ?pipeline.PreparedFrame {
    const damage_kind = damageKindIn(value.damage_kind) orelse return null;
    return .{ .token = .{ .snapshot_seq = value.snapshot_seq, .dirty_epoch = value.dirty_epoch, .geometry_epoch = value.geometry_epoch, .damage_base_seq = value.damage_base_seq, .damage_kind = damage_kind }, .required_base_seq = value.required_base_seq };
}

fn vtSurfaceIn(allocator: std.mem.Allocator, value: abi.FfiVtSurface) !queue.PublicationSource {
    const cell_count: u32 = @as(u32, value.cols) * @as(u32, value.rows);
    if (value.cells.len != cell_count) return error.InvalidSurfaceSource;

    const cells = try allocator.alloc(surface.Cell, @intCast(cell_count));
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
        .cols = value.cols,
        .rows = value.rows,
        .scroll_row = value.scroll_row,
        .snapshot_seq = value.snapshot_seq,
        .is_alternate_screen = value.is_alternate_screen != 0,
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

fn dirtyBytesSpanIn(rows: u16, span: abi.FfiByteSpan) ?[]const u8 {
    if (rows == 0) return if (span.len == 0) &.{} else null;
    if (span.ptr == null or span.len != rows) return null;
    return span.ptr[0..rows];
}

fn dirtyU16SpanIn(rows: u16, span: abi.FfiU16Span) ?[]const u16 {
    if (rows == 0) return if (span.len == 0) &.{} else null;
    if (span.ptr == null or span.len != rows) return null;
    return span.ptr[0..rows];
}

fn cellValueIn(value: abi.FfiCell) !surface.Cell {
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

fn colorIn(value: abi.FfiColor) ?surface.Color {
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

fn damageKindIn(value: u8) ?pipeline.DamageKind {
    return switch (value) {
        @intFromEnum(pipeline.DamageKind.none) => .none,
        @intFromEnum(pipeline.DamageKind.partial) => .partial,
        @intFromEnum(pipeline.DamageKind.full) => .full,
        else => null,
    };
}

fn cursorIn(value: abi.FfiCursor) ?surface.CursorInfo {
    const shape = switch (value.shape) {
        0 => surface.CursorShape.block,
        1 => .underline,
        2 => .beam,
        3 => .hollow_block,
        else => return null,
    };
    return .{ .row = value.row, .col = value.col, .visible = value.visible != 0, .shape = shape };
}

fn underlineStyleIn(value: u8) ?surface.UnderlineStyle {
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
