const std = @import("std");
const builtin = @import("builtin");
const tokens = @import("../render/tokens.zig");
const geometry_contract = @import("../render/geometry_contract.zig");
const prepared_surface = @import("surface.zig");
const prepared_submit_result = @import("submit_result.zig");
const prepared_buffer = @import("buffer.zig");
const protocol_v0_emit = @import("../protocol_v0/emit.zig");
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
    rgba_pixels: []u8,
    uploads_required: u64,
};

pub const PreparedDiagnostics = struct {
    missing_glyphs: u64,
    resolve_metrics: prepared_submit_result.Metrics,
};

pub const Owner = struct {
    pub const State = enum { prepared, published, submit_ready, released, consumed };
    const V0Payload = protocol_v0_emit.Emitter(.{});

    session_owner: *text_session.TextSessionOwner,
    prepared: prepared_surface.PreparedSurface,
    v0_payload: V0Payload = V0Payload.init(),
    v0_payload_valid: bool = false,
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
    rgba_pixels: []u8 = &.{},
    uploads_required: u64,
    missing_glyphs: u64,
    resolve_metrics: prepared_submit_result.Metrics,

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
        try owner.copySurfaceBuffer();
        owner.emitV0Payload() catch {};
        try session_owner.registerPreparedHandle(owner);
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
            .rgba_pixels = self.rgba_pixels,
            .uploads_required = self.uploads_required,
        };
    }

    pub fn protocolV0Frame(self: *const Owner) ?*const protocol_v0_emit.Frame {
        std.debug.assert(self.isLive());
        if (!self.v0_payload_valid) return null;
        return self.v0_payload.frame();
    }

    pub fn protocolV0FrameForTest(self: *const Owner) *const protocol_v0_emit.Frame {
        comptime std.debug.assert(builtin.is_test);
        return self.protocolV0Frame().?;
    }

    pub fn protocolV0FrameStorageEmptyForTest(self: *const Owner) bool {
        comptime std.debug.assert(builtin.is_test);
        std.debug.assert(!self.isLive());
        const frame = self.v0_payload.frame();
        if (frame.damage.count != 0) return false;
        if (frame.creates.count != 0) return false;
        if (frame.uploads.count != 0) return false;
        if (frame.commands.count != 0) return false;
        if (frame.retires.count != 0) return false;
        return true;
    }

    pub fn diagnostics(self: *Owner) PreparedDiagnostics {
        return .{
            .missing_glyphs = self.missing_glyphs,
            .resolve_metrics = self.resolve_metrics,
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
        session_owner.retainSurfacePixels(
            &self.rgba_pixels,
            self.prepared.render_px.width,
            self.prepared.render_px.height,
            self.snapshot_seq,
        );
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
        self.v0_payload = V0Payload.init();
        self.v0_payload_valid = false;
        freeOwnedBytes(self.session_owner.allocator, &self.rgba_pixels);
    }

    fn copySurfaceBuffer(self: *Owner) !void {
        const base_pixels = switch (self.prepared.damageKind()) {
            .partial => self.session_owner.requiredRetainedSurfaceBase(&self.prepared),
            .full => null,
            else => unreachable,
        };
        self.rgba_pixels = try prepared_buffer.compose(
            self.session_owner.allocator,
            base_pixels,
            &self.session_owner.session,
            &self.prepared,
        );
    }

    fn emitV0Payload(self: *Owner) !void {
        _ = try self.v0_payload.emitPrepared(
            &self.session_owner.protocol_v0_sprite_resources,
            &self.session_owner.session,
            &self.prepared,
        );
        self.v0_payload_valid = true;
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

fn freeOwnedBytes(allocator: std.mem.Allocator, items: *[]u8) void {
    if (items.*.len == 0) return;
    allocator.free(items.*);
    items.* = &.{};
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

test "create returns missing-sprite without double free" {
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
    try std.testing.expectError(error.MissingSprite, Owner.create(session_owner, &owned_prepared));
}

test "owner exports prepared metrics and required upload count truth" {
    var rgba_pixels = [_]u8{ 1, 2, 3, 4 };
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
        .rgba_pixels = rgba_pixels[0..],
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
    try std.testing.expectEqual(@as(usize, 4), buffer.rgba_pixels.len);
    try std.testing.expectEqual(&rgba_pixels[0], &buffer.rgba_pixels[0]);
    try std.testing.expectEqual(@as(u64, 3), buffer.uploads_required);

    const diagnostics = owner.diagnostics();
    try std.testing.expectEqual(@as(u64, 2), diagnostics.missing_glyphs);
    try std.testing.expectEqual(@as(u64, 5), diagnostics.resolve_metrics.face_checks);
    try std.testing.expectEqual(@as(u64, 2), diagnostics.resolve_metrics.missing_glyphs);
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
