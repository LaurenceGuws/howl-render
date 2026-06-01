const std = @import("std");
const builtin = @import("builtin");
const c = @import("../ffi.zig").c;
const tokens = @import("../render/tokens.zig");
const geometry_contract = @import("../render/geometry_contract.zig");
const prepared_buffer = @import("buffer.zig");
const prepared_surface = @import("surface.zig");
const prepared_submit_result = @import("submit_result.zig");
const render_surface_emitter = @import("render_surface_emitter.zig");
const render_surface_realizer = @import("../render/render_surface_realizer.zig");
const text_session = @import("../session/text.zig");
const text = @import("../text/text.zig");
const contract = @import("../text/contract.zig");

pub const PreparedSurfaceHandle = ?*anyopaque;

pub const PreparedInfo = struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    render_px: geometry_contract.PixelSize,
    cell_px: geometry_contract.CellSize,
    grid: geometry_contract.GridSize,
    prepare_metrics: prepared_submit_result.Metrics,
    damage_kind: u8,
};

pub const PreparedBuffer = struct {
    uploads_required: u64,
};

pub const PreparedDiagnostics = struct {
    missing_glyphs: u64,
    resolve_metrics: prepared_submit_result.Metrics,
    render_surface_emit_status: i32,
};

pub const Owner = struct {
    pub const State = enum { prepared, published, submit_ready, released, consumed };
    const RenderSurfacePayload = render_surface_emitter.Emitter(.{});

    session_owner: *text_session.TextSessionOwner,
    prepared: prepared_surface.PreparedSurface,
    render_surface_payload: ?*RenderSurfacePayload = null,
    state: State = .prepared,
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    render_px: geometry_contract.PixelSize,
    cell_px: geometry_contract.CellSize,
    grid: geometry_contract.GridSize,
    prepare_metrics: prepared_submit_result.Metrics,
    damage_kind: u8,
    uploads_required: u64,
    missing_glyphs: u64,
    resolve_metrics: prepared_submit_result.Metrics,
    render_surface_emit_status: i32 = c.HOWL_RENDER_SURFACE_EMIT_OK,

    pub const SubmitResult = union(enum) {
        rendered: prepared_submit_result.SubmitResult,
        needs_prepare,
        failed,
    };

    pub fn create(
        session_owner: *text_session.TextSessionOwner,
        value: *prepared_surface.PreparedSurface,
    ) !*Owner {
        var owner = try session_owner.allocator.create(Owner);
        const prepared_allocator = value.allocator;
        owner.* = ownerBase(session_owner, value.*);
        value.* = emptyPreparedSurface(prepared_allocator);
        errdefer owner.destroy();
        try session_owner.registerPreparedHandle(owner);
        owner.emitRenderSurfacePayload() catch |err| {
            owner.render_surface_emit_status = switch (err) {
                error.OutOfMemory => c.HOWL_RENDER_SURFACE_EMIT_ALLOCATION_FAILED,
                else => renderSurfaceEmitStatus(@errorCast(err)),
            };
        };
        return owner;
    }

    pub fn fromHandle(handle: PreparedSurfaceHandle) ?*Owner {
        const owned = handle orelse return null;
        return @ptrCast(@alignCast(owned));
    }

    pub fn destroy(self: *Owner) void {
        self.deinitPayload();
        self.session_owner.allocator.destroy(self);
    }

    pub fn release(self: *Owner) void {
        switch (self.state) {
            .released, .consumed => return,
            .prepared, .published, .submit_ready => {
                self.session_owner.clearCachedPreparedHandle(self);
                self.deinitPayload();
                self.state = .released;
            },
        }
    }

    pub fn isLive(self: *const Owner) bool {
        return switch (self.state) {
            .prepared, .published, .submit_ready => true,
            .released, .consumed => false,
        };
    }

    pub fn markPublished(self: *Owner) bool {
        if (self.state != .prepared) return false;
        self.state = .published;
        return true;
    }

    pub fn markSubmitReady(self: *Owner) bool {
        if (self.state != .published) return false;
        self.state = .submit_ready;
        return true;
    }

    pub fn info(self: *Owner) PreparedInfo {
        return .{
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

    pub fn buffer(self: *Owner) PreparedBuffer {
        return .{
            .uploads_required = self.uploads_required,
        };
    }

    pub fn renderSurface(self: *const Owner) ?*const render_surface_emitter.Surface {
        std.debug.assert(self.isLive());
        const payload = self.render_surface_payload orelse return null;
        return payload.surface();
    }

    pub fn renderSurfaceForTest(self: *const Owner) *const render_surface_emitter.Surface {
        comptime std.debug.assert(builtin.is_test);
        return self.renderSurface().?;
    }

    pub fn renderSurfaceStorageEmptyForTest(self: *const Owner) bool {
        comptime std.debug.assert(builtin.is_test);
        std.debug.assert(!self.isLive());
        return self.render_surface_payload == null;
    }

    pub fn diagnostics(self: *Owner) PreparedDiagnostics {
        return .{
            .missing_glyphs = self.missing_glyphs,
            .resolve_metrics = self.resolve_metrics,
            .render_surface_emit_status = self.render_surface_emit_status,
        };
    }

    pub fn preparedSurfaceToken(self: *const Owner) tokens.PreparedSurfaceToken {
        std.debug.assert(self.isLive());
        return self.prepared.preparedSurfaceToken();
    }

    pub fn belongsToSession(self: *const Owner, session_owner: *text_session.TextSessionOwner) bool {
        return self.session_owner == session_owner;
    }

    pub fn submitOwned(
        self: *Owner,
        session_owner: *text_session.TextSessionOwner,
        execution: text_session.TextSession.SubmitExecution,
    ) SubmitResult {
        if (self.state != .submit_ready) return .failed;
        return self.performSubmit(session_owner, execution);
    }

    fn performSubmit(
        self: *Owner,
        session_owner: *text_session.TextSessionOwner,
        execution: text_session.TextSession.SubmitExecution,
    ) SubmitResult {
        if (!self.belongsToSession(session_owner)) return .failed;
        if (!executionMatchesPrepared(self.render_px, self.uploads_required, execution)) return .failed;
        const result = session_owner.session.submitSurface(&self.prepared, execution) catch {
            return .failed;
        };
        self.consume();
        return .{ .rendered = result };
    }

    pub fn submit(
        self: *Owner,
        session_owner: *text_session.TextSessionOwner,
        prepared_token: tokens.PreparedSurfaceToken,
        execution: text_session.TextSession.SubmitExecution,
    ) SubmitResult {
        if (self.state != .prepared) return .failed;
        if (!self.belongsToSession(session_owner)) return .failed;
        if (!samePreparedSurfaceToken(self.prepared.preparedSurfaceToken(), prepared_token)) {
            return .needs_prepare;
        }
        return self.performSubmit(session_owner, execution);
    }

    fn consume(self: *Owner) void {
        std.debug.assert(self.state == .prepared or self.state == .submit_ready);
        self.session_owner.clearCachedPreparedHandle(self);
        self.deinitPayload();
        self.state = .consumed;
    }

    fn deinitPayload(self: *Owner) void {
        switch (self.state) {
            .released, .consumed => return,
            .prepared, .published, .submit_ready => {},
        }
        self.prepared.deinit();
        self.freeRenderSurfacePayload();
    }

    fn emitRenderSurfacePayload(self: *Owner) !void {
        std.debug.assert(self.render_surface_payload == null);
        const payload = try self.session_owner.allocator.create(RenderSurfacePayload);
        payload.* = .{};
        errdefer self.session_owner.allocator.destroy(payload);
        _ = try payload.emitPrepared(
            &self.session_owner.render_surface_sprite_resources,
            &self.session_owner.session,
            &self.prepared,
        );
        self.render_surface_payload = payload;
    }

    fn freeRenderSurfacePayload(self: *Owner) void {
        const payload = self.render_surface_payload orelse return;
        self.render_surface_payload = null;
        self.session_owner.allocator.destroy(payload);
    }
};

fn ownerBase(session_owner: *text_session.TextSessionOwner, value: prepared_surface.PreparedSurface) Owner {
    return .{
        .session_owner = session_owner,
        .prepared = value,
        .snapshot_seq = value.request.token.snapshot_seq,
        .dirty_epoch = value.request.token.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .required_base_seq = value.preparedSurfaceToken().required_base_seq,
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .grid = .{ .cols = value.grid.cols, .rows = value.grid.rows },
        .prepare_metrics = preparedMetricsOut(value),
        .damage_kind = @intFromEnum(value.damageKind()),
        .uploads_required = value.text_frame.raster_plan.outputs.len,
        .missing_glyphs = value.text_frame.scene.scene.missing.len,
        .resolve_metrics = resolveMetricsOut(value),
        .render_surface_emit_status = c.HOWL_RENDER_SURFACE_EMIT_OK,
    };
}

fn renderSurfaceEmitStatus(err: render_surface_emitter.Error) i32 {
    return switch (err) {
        error.CommandBoundOverflow => c.HOWL_RENDER_SURFACE_EMIT_COMMAND_BOUND_OVERFLOW,
        error.CreateBoundOverflow => c.HOWL_RENDER_SURFACE_EMIT_CREATE_BOUND_OVERFLOW,
        error.DamageBoundOverflow => c.HOWL_RENDER_SURFACE_EMIT_DAMAGE_BOUND_OVERFLOW,
        error.RetireBoundOverflow => c.HOWL_RENDER_SURFACE_EMIT_RETIRE_BOUND_OVERFLOW,
        error.ResourceBoundOverflow => c.HOWL_RENDER_SURFACE_EMIT_RESOURCE_BOUND_OVERFLOW,
        error.UploadBoundOverflow => c.HOWL_RENDER_SURFACE_EMIT_UPLOAD_BOUND_OVERFLOW,
        error.UploadBytesOverflow => c.HOWL_RENDER_SURFACE_EMIT_UPLOAD_BYTES_OVERFLOW,
        error.InvalidPreparedSprite => c.HOWL_RENDER_SURFACE_EMIT_INVALID_PREPARED_SPRITE,
        error.MissingPreparedSprite => c.HOWL_RENDER_SURFACE_EMIT_MISSING_PREPARED_SPRITE,
    };
}

fn emptyPreparedSurface(allocator: std.mem.Allocator) prepared_surface.PreparedSurface {
    return .{
        .allocator = allocator,
        .request = .{ .token = .{
            .snapshot_seq = 0,
            .dirty_epoch = 0,
            .geometry_epoch = 0,
            .damage_base_seq = 0,
            .damage_kind = .full,
        } },
        .geometry_epoch = 0,
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .text_frame = .{
            .scene = .{
                .allocator = allocator,
                .owned = false,
                .scene = .{
                    .clear_draws = &.{},
                    .background_draws = &.{},
                    .sprite_draws = &.{},
                    .decoration_draws = &.{},
                    .cursor_draws = &.{},
                    .raster_requests = &.{},
                    .missing = &.{},
                    .full_redraw = true,
                },
            },
            .raster_plan = .{ .allocator = allocator, .outputs = &.{}, .owned = false },
        },
    };
}

fn preparedMetricsOut(value: prepared_surface.PreparedSurface) prepared_submit_result.Metrics {
    const scene = value.text_frame.scene.scene;
    const clear_fills = count64(scene.clear_draws);
    const background_fills = count64(scene.background_draws);
    const decoration_fills = count64(scene.decoration_draws);
    const cursor_fills = count64(scene.cursor_draws);
    return .{
        .sync_us = value.prepare_metrics.sync_us,
        .copy_us = value.prepare_metrics.copy_us,
        .render_us = value.prepare_metrics.surface_us,
        .glyphs = count64(scene.sprite_draws),
        .fills = clear_fills + background_fills + decoration_fills + cursor_fills,
        .clear_fills = clear_fills,
        .background_fills = background_fills,
        .decoration_fills = decoration_fills,
        .cursor_fills = cursor_fills,
        .uploads = count64(value.text_frame.raster_plan.outputs),
        .face_checks = 0,
        .face_cache_hits = 0,
        .shape_requests = 0,
        .shape_cache_hits = 0,
        .fallback_hits = 0,
        .fallback_misses = 0,
        .missing_glyphs = count64(scene.missing),
    };
}

fn resolveMetricsOut(value: prepared_surface.PreparedSurface) prepared_submit_result.Metrics {
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

fn count64(items: anytype) u64 {
    std.debug.assert(items.len <= std.math.maxInt(u64));
    return @intCast(items.len);
}

fn samePreparedSurfaceToken(a: tokens.PreparedSurfaceToken, b: tokens.PreparedSurfaceToken) bool {
    return a.token.snapshot_seq == b.token.snapshot_seq and
        a.token.dirty_epoch == b.token.dirty_epoch and
        a.token.geometry_epoch == b.token.geometry_epoch and
        a.token.damage_base_seq == b.token.damage_base_seq and
        a.token.damage_kind == b.token.damage_kind and
        a.required_base_seq == b.required_base_seq;
}

fn executionMatchesPrepared(
    render_px: geometry_contract.PixelSize,
    uploads_required: u64,
    execution: text_session.TextSession.SubmitExecution,
) bool {
    if (execution.uploads_committed != uploads_required) return false;
    if (execution.host_surface.width != render_px.width) return false;
    if (execution.host_surface.height != render_px.height) return false;
    return true;
}

test "create reports missing-sprite diagnostic without double free" {
    const session_owner = text_session.TextSessionOwner.create(std.heap.c_allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
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

    const prepared = prepared_surface.PreparedSurface{
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

    var owned_prepared = prepared;
    const owner = try Owner.create(session_owner, &owned_prepared);
    try std.testing.expect(owner.renderSurface() == null);
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_MISSING_PREPARED_SPRITE,
        owner.diagnostics().render_surface_emit_status,
    );
}

test "owner exports prepared metrics and required upload count truth" {
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{
        undefined,
        undefined,
        undefined,
    };
    var clear_draws = [_]contract.TextClearDraw{.{
        .x_px = 0,
        .y_px = 0,
        .width_px = 11,
        .height_px = 12,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .first_cell = 0,
        .cell_span = 1,
    }};
    var background_draws = [_]contract.TextBackgroundDraw{.{
        .x_px = 1,
        .y_px = 2,
        .width_px = 3,
        .height_px = 4,
        .color = .{ .r = 10, .g = 20, .b = 30, .a = 255 },
        .first_cell = 0,
        .cell_span = 1,
    }};
    var sprite_draws = [_]contract.TextSpriteDraw{ .{
        .sprite = .{ .slot = 0, .key = .{ .value = 11 } },
        .x_px = 0,
        .y_px = 0,
        .width_px = 2,
        .height_px = 3,
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .first_cell = 0,
        .cell_span = 1,
    }, .{
        .sprite = .{ .slot = 1, .key = .{ .value = 12 } },
        .x_px = 3,
        .y_px = 0,
        .width_px = 2,
        .height_px = 3,
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .first_cell = 1,
        .cell_span = 1,
    } };
    var decoration_draws = [_]contract.TextDecorationDraw{.{
        .kind = .underline,
        .x_px = 0,
        .y_px = 10,
        .width_px = 4,
        .height_px = 1,
        .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .first_cell = 0,
        .cell_span = 1,
    }};
    var cursor_draws = [_]contract.TextCursorDraw{.{
        .x_px = 8,
        .y_px = 9,
        .width_px = 2,
        .height_px = 3,
        .color = .{ .r = 0, .g = 255, .b = 0, .a = 255 },
    }};
    var missing = [_]contract.MissingGlyph{ .{
        .codepoint = 'x',
        .style = .regular,
        .presentation = .text,
        .reason = .unresolved_codepoint,
    }, .{
        .codepoint = 'y',
        .style = .regular,
        .presentation = .text,
        .reason = .raster_failed,
    } };
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
            .glyphs = 2,
            .fills = 4,
            .clear_fills = 1,
            .background_fills = 1,
            .decoration_fills = 1,
            .cursor_fills = 1,
            .uploads = 3,
            .face_checks = 0,
            .face_cache_hits = 0,
            .shape_requests = 0,
            .shape_cache_hits = 0,
            .fallback_hits = 0,
            .fallback_misses = 0,
            .missing_glyphs = 2,
        },
        .damage_kind = 1,
        .uploads_required = 3,
        .missing_glyphs = 2,
        .resolve_metrics = .{
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
            .face_checks = 5,
            .face_cache_hits = 4,
            .shape_requests = 3,
            .shape_cache_hits = 2,
            .fallback_hits = 1,
            .fallback_misses = 0,
            .missing_glyphs = 2,
        },
        .render_surface_emit_status = c.HOWL_RENDER_SURFACE_EMIT_UPLOAD_BYTES_OVERFLOW,
    };

    owner.prepared = .{
        .allocator = std.testing.allocator,
        .request = .{ .token = .{ .snapshot_seq = 7, .dirty_epoch = 8, .geometry_epoch = 1, .damage_base_seq = 6, .damage_kind = .partial } },
        .geometry_epoch = 9,
        .render_px = .{ .width = 11, .height = 12 },
        .cell_px = .{ .width = 2, .height = 3 },
        .grid = .{ .cols = 4, .rows = 5 },
        .text_frame = .{
            .scene = .{
                .allocator = std.testing.allocator,
                .scene = .{
                    .clear_draws = clear_draws[0..],
                    .background_draws = background_draws[0..],
                    .sprite_draws = sprite_draws[0..],
                    .decoration_draws = decoration_draws[0..],
                    .cursor_draws = cursor_draws[0..],
                    .raster_requests = &.{},
                    .missing = missing[0..],
                    .full_redraw = false,
                },
                .owned = false,
            },
            .raster_plan = .{ .allocator = std.testing.allocator, .outputs = raster_outputs[0..], .owned = false },
        },
        .resolve = .{
            .counters = .{
                .face_checks = 5,
                .face_cache_hits = 4,
                .shape_requests = 3,
                .shape_cache_hits = 2,
                .fallback_hits = 1,
                .fallback_misses = 0,
                .missing_glyphs = 2,
            },
        },
        .prepare_metrics = .{ .sync_us = 13, .copy_us = 14, .surface_us = 15 },
    };

    owner.prepare_metrics = preparedMetricsOut(owner.prepared);
    owner.resolve_metrics = resolveMetricsOut(owner.prepared);
    owner.required_base_seq = owner.prepared.preparedSurfaceToken().required_base_seq;
    owner.damage_kind = @intFromEnum(owner.prepared.damageKind());

    const info = owner.info();
    try std.testing.expectEqual(@as(u64, 7), info.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 6), info.required_base_seq);
    try std.testing.expectEqual(@as(u64, 13), info.prepare_metrics.sync_us);
    try std.testing.expectEqual(@as(u64, 14), info.prepare_metrics.copy_us);
    try std.testing.expectEqual(@as(u64, 15), info.prepare_metrics.render_us);
    try std.testing.expectEqual(@as(u64, 2), info.prepare_metrics.glyphs);
    try std.testing.expectEqual(@as(u64, 4), info.prepare_metrics.fills);
    try std.testing.expectEqual(@as(u64, 1), info.prepare_metrics.clear_fills);
    try std.testing.expectEqual(@as(u64, 1), info.prepare_metrics.background_fills);
    try std.testing.expectEqual(@as(u64, 1), info.prepare_metrics.decoration_fills);
    try std.testing.expectEqual(@as(u64, 1), info.prepare_metrics.cursor_fills);
    try std.testing.expectEqual(@as(u64, 3), info.prepare_metrics.uploads);
    try std.testing.expectEqual(@as(u64, 2), info.prepare_metrics.missing_glyphs);

    const buffer = owner.buffer();
    try std.testing.expectEqual(@as(u64, 3), buffer.uploads_required);

    const diagnostics = owner.diagnostics();
    try std.testing.expectEqual(@as(u64, 2), diagnostics.missing_glyphs);
    try std.testing.expectEqual(@as(u64, 5), diagnostics.resolve_metrics.face_checks);
    try std.testing.expectEqual(@as(u64, 2), diagnostics.resolve_metrics.missing_glyphs);
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_UPLOAD_BYTES_OVERFLOW,
        diagnostics.render_surface_emit_status,
    );
}

test "owner maps every render-surface surface emit error to diagnostics status" {
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_COMMAND_BOUND_OVERFLOW,
        renderSurfaceEmitStatus(error.CommandBoundOverflow),
    );
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_CREATE_BOUND_OVERFLOW,
        renderSurfaceEmitStatus(error.CreateBoundOverflow),
    );
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_DAMAGE_BOUND_OVERFLOW,
        renderSurfaceEmitStatus(error.DamageBoundOverflow),
    );
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_RETIRE_BOUND_OVERFLOW,
        renderSurfaceEmitStatus(error.RetireBoundOverflow),
    );
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_RESOURCE_BOUND_OVERFLOW,
        renderSurfaceEmitStatus(error.ResourceBoundOverflow),
    );
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_UPLOAD_BOUND_OVERFLOW,
        renderSurfaceEmitStatus(error.UploadBoundOverflow),
    );
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_UPLOAD_BYTES_OVERFLOW,
        renderSurfaceEmitStatus(error.UploadBytesOverflow),
    );
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_INVALID_PREPARED_SPRITE,
        renderSurfaceEmitStatus(error.InvalidPreparedSprite),
    );
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_MISSING_PREPARED_SPRITE,
        renderSurfaceEmitStatus(error.MissingPreparedSprite),
    );
}

test "owner validates realized uploads and host surface dimensions before submit" {
    const render_px = geometry_contract.PixelSize{ .width = 11, .height = 12 };
    const uploads_required: u64 = 3;

    try std.testing.expect(executionMatchesPrepared(render_px, uploads_required, .{
        .host_surface = .{ .host_surface_id = 1, .width = 11, .height = 12 },
        .uploads_committed = 3,
        .render_us = 1,
    }));
    try std.testing.expect(!executionMatchesPrepared(render_px, uploads_required, .{
        .host_surface = .{ .host_surface_id = 1, .width = 11, .height = 12 },
        .uploads_committed = 2,
        .render_us = 1,
    }));
    try std.testing.expect(!executionMatchesPrepared(render_px, uploads_required, .{
        .host_surface = .{ .host_surface_id = 1, .width = 10, .height = 12 },
        .uploads_committed = 3,
        .render_us = 1,
    }));
    try std.testing.expect(!executionMatchesPrepared(render_px, uploads_required, .{
        .host_surface = .{ .host_surface_id = 1, .width = 11, .height = 13 },
        .uploads_committed = 3,
        .render_us = 1,
    }));
}
test "render surface prepared owner surface equals explicit rgba oracle" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(
        allocator,
        .{ .surface_px = .{ .width = 2, .height = 1 } },
    ) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    var sprite_bytes = [_]u8{ 255, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(21, 0, 0, 2, 1, rgba(255, 0, 0, 128)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        21,
        2,
        1,
        .alpha,
        &sprite_bytes,
        .{},
    )};
    var prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 2,
        .height_px = 1,
    });

    const oracle = try prepared_buffer.compose(allocator, null, &session_owner.session, &prepared);
    defer allocator.free(oracle);
    const owner = try Owner.create(session_owner, &prepared);
    const surface = owner.renderSurfaceForTest();
    try std.testing.expectEqual(@as(u32, 1), surface.uploads.count);
    try std.testing.expect(surface.uploads.ptr[0].bytes_ptr != null);
    const upload_bytes_ptr = surface.uploads.ptr[0].bytes_ptr;

    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try render_surface_realizer.realize(surface, realized, null);
    try std.testing.expectEqual(
        upload_bytes_ptr,
        owner.renderSurfaceForTest().uploads.ptr[0].bytes_ptr,
    );
    try std.testing.expectEqualSlices(u8, oracle, realized);
}
test "render surface prepared owner partial surface equals explicit base rgba oracle" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(
        allocator,
        .{ .surface_px = .{ .width = 2, .height = 1 } },
    ) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const base = [_]u8{
        1, 2, 3, 255,
        4, 5, 6, 255,
    };

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(9, 8, 7, 255)),
    };
    var prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 2,
        .height_px = 1,
        .full_redraw = false,
    });

    const oracle = try prepared_buffer.compose(allocator, &base, &session_owner.session, &prepared);
    defer allocator.free(oracle);
    const owner = try Owner.create(session_owner, &prepared);
    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try render_surface_realizer.realize(
        owner.renderSurfaceForTest(),
        realized,
        &base,
    );
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "render surface prepared owner releases render_surface payload with handle" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(
        allocator,
        .{ .surface_px = .{ .width = 1, .height = 1 } },
    ) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255)),
    };
    var prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 1,
        .height_px = 1,
    });

    const owner = try Owner.create(session_owner, &prepared);
    try std.testing.expectEqual(@as(u32, 1), owner.renderSurfaceForTest().commands.count);

    owner.release();

    try std.testing.expect(owner.renderSurfaceStorageEmptyForTest());
}

test "render surface prepared owner reports missing surface when render_surface emission overflows" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(
        allocator,
        .{ .surface_px = .{ .width = 1, .height = 1 } },
    ) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const draws_len: usize = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    const background_draws = try allocator.alloc(contract.TextBackgroundDraw, draws_len);
    defer allocator.free(background_draws);
    for (background_draws) |*draw| {
        draw.* = backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255));
    }
    var prepared = preparedSurface(.{
        .background_draws = background_draws,
        .width_px = 1,
        .height_px = 1,
    });

    const owner = try Owner.create(session_owner, &prepared);

    try std.testing.expect(owner.renderSurface() == null);
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_COMMAND_BOUND_OVERFLOW,
        owner.diagnostics().render_surface_emit_status,
    );
    try std.testing.expectEqual(@as(usize, 1), session_owner.prepared_handles.items.len);
}

test "render surface prepared owner overflow still consumes prepare surface once" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(
        allocator,
        .{ .surface_px = .{ .width = 1, .height = 1 } },
    ) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    var prepared = try ownedCommandOverflowPreparedSurface(allocator);
    const owner = try Owner.create(session_owner, &prepared);

    try std.testing.expect(owner.renderSurface() == null);
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_EMIT_COMMAND_BOUND_OVERFLOW,
        owner.diagnostics().render_surface_emit_status,
    );
    try std.testing.expectEqual(@as(u64, 0), prepared.request.token.snapshot_seq);
    try std.testing.expectEqual(@as(usize, 1), session_owner.prepared_handles.items.len);
}

test "render surface prepared owner allocation failure remains diagnostic only" {
    var probe_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var session_owner = text_session.TextSessionOwner.create(
            probe_allocator_state.allocator(),
            .{ .surface_px = .{ .width = 1, .height = 1 } },
        ) orelse return error.OutOfMemory;
        defer session_owner.destroy();
        const background = [_]contract.TextBackgroundDraw{
            backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255)),
        };
        var prepared = preparedSurface(.{
            .background_draws = &background,
            .width_px = 1,
            .height_px = 1,
        });
        const owner = try Owner.create(session_owner, &prepared);
        owner.release();
    }

    var fail_index: usize = 0;
    while (fail_index < probe_allocator_state.alloc_index) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var session_owner = text_session.TextSessionOwner.create(
            failing_allocator_state.allocator(),
            .{ .surface_px = .{ .width = 1, .height = 1 } },
        ) orelse continue;
        defer session_owner.destroy();
        const background = [_]contract.TextBackgroundDraw{
            backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255)),
        };
        var prepared = preparedSurface(.{
            .background_draws = &background,
            .width_px = 1,
            .height_px = 1,
        });
        const owner = Owner.create(session_owner, &prepared) catch continue;
        if (owner.diagnostics().render_surface_emit_status !=
            c.HOWL_RENDER_SURFACE_EMIT_ALLOCATION_FAILED) continue;
        try std.testing.expect(owner.renderSurface() == null);
        return;
    }
    return error.MissingAllocationFailureCase;
}
fn ownedCommandOverflowPreparedSurface(
    allocator: std.mem.Allocator,
) !prepared_surface.PreparedSurface {
    const draws_len: usize = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    const background_draws = try allocator.alloc(contract.TextBackgroundDraw, draws_len);
    for (background_draws) |*draw| {
        draw.* = backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255));
    }
    return .{
        .allocator = allocator,
        .request = .{ .token = .{
            .snapshot_seq = 1,
            .dirty_epoch = 1,
            .geometry_epoch = 1,
            .damage_base_seq = 0,
            .damage_kind = .full,
        } },
        .geometry_epoch = 1,
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .text_frame = .{
            .scene = .{
                .allocator = allocator,
                .owned = true,
                .scene = .{
                    .clear_draws = &.{},
                    .background_draws = background_draws,
                    .sprite_draws = &.{},
                    .decoration_draws = &.{},
                    .cursor_draws = &.{},
                    .raster_requests = &.{},
                    .missing = &.{},
                    .full_redraw = true,
                },
            },
            .raster_plan = .{ .allocator = allocator, .outputs = &.{}, .owned = false },
        },
    };
}
const PreparedOptions = struct {
    clear_draws: []const contract.TextClearDraw = &.{},
    background_draws: []const contract.TextBackgroundDraw = &.{},
    sprite_draws: []const contract.TextSpriteDraw = &.{},
    decoration_draws: []const contract.TextDecorationDraw = &.{},
    cursor_draws: []const contract.TextCursorDraw = &.{},
    raster_outputs: []text.Rasterizer.RasterSpriteOutput = &.{},
    width_px: u16,
    height_px: u16,
    full_redraw: bool = true,
};

fn preparedSurface(options: PreparedOptions) prepared_surface.PreparedSurface {
    return .{
        .allocator = std.testing.allocator,
        .request = .{
            .token = .{
                .snapshot_seq = 1,
                .dirty_epoch = 1,
                .geometry_epoch = 1,
                .damage_base_seq = if (options.full_redraw) 0 else 1,
                .damage_kind = if (options.full_redraw) .full else .partial,
            },
        },
        .geometry_epoch = 1,
        .render_px = .{ .width = options.width_px, .height = options.height_px },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = options.width_px, .rows = options.height_px },
        .text_frame = .{
            .scene = .{
                .allocator = std.testing.allocator,
                .owned = false,
                .scene = .{
                    .clear_draws = options.clear_draws,
                    .background_draws = options.background_draws,
                    .sprite_draws = options.sprite_draws,
                    .decoration_draws = options.decoration_draws,
                    .cursor_draws = options.cursor_draws,
                    .raster_requests = &.{},
                    .missing = &.{},
                    .full_redraw = options.full_redraw,
                },
            },
            .raster_plan = .{
                .allocator = std.testing.allocator,
                .outputs = options.raster_outputs,
                .owned = false,
            },
        },
    };
}

fn rasterOutput(
    allocator: std.mem.Allocator,
    key: u64,
    width_px: u16,
    height_px: u16,
    color_mode: contract.SpriteColorMode,
    pixels: []u8,
    visual_bounds: text.Rasterizer.SpriteBounds,
) text.Rasterizer.RasterSpriteOutput {
    return .{
        .allocator = allocator,
        .key = .{ .value = key },
        .width_px = width_px,
        .height_px = height_px,
        .color_mode = color_mode,
        .visual_bounds = visual_bounds,
        .pixels = pixels,
    };
}

fn clearDraw(
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: contract.Rgba8,
) contract.TextClearDraw {
    return .{
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .color = color,
        .first_cell = 0,
        .cell_span = 1,
    };
}

fn backgroundDraw(
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: contract.Rgba8,
) contract.TextBackgroundDraw {
    return .{
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .color = color,
        .first_cell = 0,
        .cell_span = 1,
    };
}

fn decorationDraw(
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: contract.Rgba8,
) contract.TextDecorationDraw {
    return .{
        .kind = .underline,
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .color = color,
        .first_cell = 0,
        .cell_span = 1,
    };
}

fn cursorDraw(
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: contract.Rgba8,
) contract.TextCursorDraw {
    return .{ .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color };
}

fn spriteDraw(
    key: u64,
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: contract.Rgba8,
) contract.TextSpriteDraw {
    return .{
        .sprite = .{ .slot = 0, .key = .{ .value = key } },
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .color = color,
        .first_cell = 0,
        .cell_span = 1,
    };
}

fn rgba(r: u8, g: u8, b: u8, a: u8) contract.Rgba8 {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
