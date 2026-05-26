const std = @import("std");
const abi = @import("../ffi_types.zig");
const pipeline = @import("pipeline.zig");
const surface = @import("surface.zig");
const surface_buffer = @import("surface_buffer.zig");
const surface_text = @import("surface_text.zig");
const contract = @import("../text/contract.zig");

pub const Owner = struct {
    session_owner: *surface_text.SurfaceTextOwner,
    prepared: surface.PreparedSurface,
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    render_px: abi.FfiPixelSize,
    cell_px: abi.FfiCellSize,
    grid: abi.FfiGridSize,
    prepare_metrics: abi.FfiSurfaceMetrics,
    damage_kind: u8,
    rgba_pixels: []u8 = &.{},
    uploads_required: u64,
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
        var owner = try session_owner.allocator.create(Owner);
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
        freeOwnedBytes(self.session_owner.allocator, &self.rgba_pixels);
        self.session_owner.allocator.destroy(self);
    }

    pub fn info(self: *Owner) abi.FfiPreparedSurfaceInfo {
        return .{
            .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
            .snapshot_seq = self.snapshot_seq,
            .dirty_epoch = self.dirty_epoch,
            .geometry_epoch = self.geometry_epoch,
            .required_base_seq = self.required_base_seq,
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
            // The ABI field name is shipped. At prepare time this is the upload
            // count the host must realize before submit can truthfully report it
            // as committed work.
            .uploads_committed = self.uploads_required,
        };
    }

    pub fn diagnostics(self: *Owner) abi.FfiPreparedSurfaceDiagnostics {
        return .{
            .status = @intFromEnum(abi.HowlRenderCallStatus.ok),
            .missing_glyphs = self.missing_glyphs,
            .resolve_metrics = self.resolve_metrics,
        };
    }

    pub fn pipelineFrame(self: *const Owner) pipeline.PreparedFrame {
        return self.prepared.pipelineFrame();
    }

    pub fn belongsToSession(self: *const Owner, session_owner: *surface_text.SurfaceTextOwner) bool {
        return self.session_owner == session_owner;
    }

    pub fn submitOwned(
        self: *Owner,
        session_owner: *surface_text.SurfaceTextOwner,
        execution: surface_text.SurfaceText.RenderSurfaceExecutionInput,
    ) SubmitResult {
        if (!self.belongsToSession(session_owner)) return .failed;
        const feedback = session_owner.session.submitSurface(&self.prepared, execution) catch {
            return .failed;
        };
        session_owner.retainSurfaceImage(
            &self.rgba_pixels,
            self.prepared.render_px.width,
            self.prepared.render_px.height,
            self.snapshot_seq,
        );
        self.destroy();
        return .{ .rendered = feedback };
    }

    pub fn submit(
        self: *Owner,
        session_owner: *surface_text.SurfaceTextOwner,
        prepared_frame: pipeline.PreparedFrame,
        execution: surface_text.SurfaceText.RenderSurfaceExecutionInput,
    ) SubmitResult {
        if (!self.belongsToSession(session_owner)) return .failed;
        if (!samePreparedFrame(self.prepared.pipelineFrame(), prepared_frame)) {
            return .needs_prepare;
        }
        return self.submitOwned(session_owner, execution);
    }

    fn copySurfaceBuffer(self: *Owner) !void {
        const base_pixels = switch (self.prepared.damageKind()) {
            .partial => self.session_owner.requiredRetainedSurfaceBase(&self.prepared),
            .full => null,
            else => unreachable,
        };
        self.rgba_pixels = try surface_buffer.compose(
            self.session_owner.allocator,
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
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .grid = .{ .cols = value.grid.cols, .rows = value.grid.rows },
        .prepare_metrics = preparedMetricsOut(value),
        .damage_kind = @intFromEnum(value.damageKind()),
        .uploads_required = value.text_frame.raster_plan.outputs.len,
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

fn freeOwnedBytes(allocator: std.mem.Allocator, items: *[]u8) void {
    if (items.*.len == 0) return;
    allocator.free(items.*);
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
        a.required_base_seq == b.required_base_seq;
}

test "create returns missing-sprite without double free" {
    const session_owner = surface_text.SurfaceTextOwner.create(std.heap.c_allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    var sprite_draws = [_]contract.TextSpriteDraw{.{
        .sprite = .{ .slot = 0, .key = .{ .value = 1 } },
        .x_px = 0,
        .y_px = 0,
        .width_px = 1,
        .height_px = 1,
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .first_cell = 0,
        .cell_span = 1,
    }};

    const prepared = surface.PreparedSurface{
        .allocator = std.testing.allocator,
        .request = .{ .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full } },
        .geometry_epoch = 1,
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .text_frame = .{
            .scene = .{
                .allocator = std.testing.allocator,
                .scene = .{
                    .clear_draws = &.{},
                    .background_draws = &.{},
                    .sprite_draws = &sprite_draws,
                    .decoration_draws = &.{},
                    .cursor_draws = &.{},
                    .raster_requests = &.{},
                    .missing = &.{},
                    .full_redraw = true,
                },
                .owned = false,
            },
            .raster_plan = .{ .allocator = std.testing.allocator, .outputs = &.{}, .owned = false },
        },
    };

    try std.testing.expectError(error.MissingSprite, Owner.create(session_owner, prepared));
}

test "owner exports prepared metrics and required upload count truth" {
    var rgba_pixels = [_]u8{ 1, 2, 3, 4 };
    var owner = Owner{
        .session_owner = undefined,
        .prepared = undefined,
        .snapshot_seq = 7,
        .dirty_epoch = 8,
        .geometry_epoch = 9,
        .required_base_seq = 6,
        .render_px = .{ .width = 11, .height = 12 },
        .cell_px = .{ .width = 2, .height = 3 },
        .grid = .{ .cols = 4, .rows = 5 },
        .prepare_metrics = .{
            .sync_us = 13,
            .copy_us = 14,
            .render_us = 15,
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
        },
        .damage_kind = 1,
        .rgba_pixels = rgba_pixels[0..],
        .uploads_required = 3,
        .missing_glyphs = 2,
        .resolve_metrics = std.mem.zeroes(abi.FfiSurfaceMetrics),
    };

    const info = owner.info();
    try std.testing.expectEqual(@as(u64, 7), info.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 13), info.prepare_metrics.sync_us);
    try std.testing.expectEqual(@as(u64, 14), info.prepare_metrics.copy_us);
    try std.testing.expectEqual(@as(u64, 15), info.prepare_metrics.render_us);

    const buffer = owner.buffer();
    try std.testing.expectEqual(@as(usize, 4), buffer.rgba_pixels.len);
    try std.testing.expect(buffer.rgba_pixels.ptr != null);
    try std.testing.expectEqual(@as(u64, 3), buffer.uploads_committed);
}
