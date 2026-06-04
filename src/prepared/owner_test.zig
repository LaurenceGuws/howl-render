const std = @import("std");
const geometry_contract = @import("../render/geometry_contract.zig");
const prepared_buffer = @import("buffer.zig");
const prepared_owner = @import("owner.zig");
const prepared_surface = @import("surface.zig");
const render_surface_emitter = @import("render_surface_emitter.zig");
const render_surface_realizer = @import("../render/render_surface_realizer.zig");
const text_session = @import("../session/text.zig");
const text = @import("../text/text.zig");
const contract = @import("../text/contract.zig");

const Owner = prepared_owner.Owner;
const RenderSurfaceEmissionFailure = prepared_owner.RenderSurfaceEmissionFailure;

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
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.missing_prepared_sprite, owner.renderSurfaceEmissionFailure());
}

test "owner exports prepared info and required upload count truth" {
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{ undefined, undefined, undefined };
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
        .damage_kind = 1,
        .uploads_required = 3,
        .render_surface_emission_failure = .upload_bytes_overflow,
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
                    .clear_draws = &.{},
                    .background_draws = &.{},
                    .sprite_draws = &.{},
                    .decoration_draws = &.{},
                    .cursor_draws = &.{},
                    .raster_requests = &.{},
                    .missing = &.{},
                    .full_redraw = false,
                },
                .owned = false,
            },
            .raster_plan = .{ .allocator = std.testing.allocator, .outputs = raster_outputs[0..], .owned = false },
        },
    };

    owner.required_base_seq = owner.prepared.preparedSurfaceToken().required_base_seq;
    owner.damage_kind = @intFromEnum(owner.prepared.damageKind());

    const info = owner.info();
    try std.testing.expectEqual(@as(u64, 7), info.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 6), info.required_base_seq);
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.upload_bytes_overflow, owner.renderSurfaceEmissionFailure());

    const buffer = owner.buffer();
    try std.testing.expectEqual(@as(u64, 3), buffer.uploads_required);
}

test "owner maps every render-surface emission error to local failure" {
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.command_bound_overflow, prepared_owner.testing.renderSurfaceEmissionFailureFromError(error.CommandBoundOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.create_bound_overflow, prepared_owner.testing.renderSurfaceEmissionFailureFromError(error.CreateBoundOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.damage_bound_overflow, prepared_owner.testing.renderSurfaceEmissionFailureFromError(error.DamageBoundOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.retire_bound_overflow, prepared_owner.testing.renderSurfaceEmissionFailureFromError(error.RetireBoundOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.resource_bound_overflow, prepared_owner.testing.renderSurfaceEmissionFailureFromError(error.ResourceBoundOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.upload_bound_overflow, prepared_owner.testing.renderSurfaceEmissionFailureFromError(error.UploadBoundOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.upload_bytes_overflow, prepared_owner.testing.renderSurfaceEmissionFailureFromError(error.UploadBytesOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.invalid_prepared_sprite, prepared_owner.testing.renderSurfaceEmissionFailureFromError(error.InvalidPreparedSprite));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.missing_prepared_sprite, prepared_owner.testing.renderSurfaceEmissionFailureFromError(error.MissingPreparedSprite));
}

test "owner validates realized uploads and host surface dimensions before submit" {
    const render_px = geometry_contract.PixelSize{ .width = 11, .height = 12 };

    try std.testing.expect(prepared_owner.testing.executionMatchesPrepared(render_px, .{
        .host_surface = .{ .host_surface_id = 1, .width = 11, .height = 12 },
    }));
    try std.testing.expect(!prepared_owner.testing.executionMatchesPrepared(render_px, .{
        .host_surface = .{ .host_surface_id = 1, .width = 10, .height = 12 },
    }));
    try std.testing.expect(!prepared_owner.testing.executionMatchesPrepared(render_px, .{
        .host_surface = .{ .host_surface_id = 1, .width = 11, .height = 13 },
    }));
}

test "render surface prepared owner surface equals explicit rgba oracle" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 2, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    var sprite_bytes = [_]u8{ 255, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{spriteDraw(21, 0, 0, 2, 1, rgba(255, 0, 0, 128))};
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(allocator, 21, 2, 1, .alpha, &sprite_bytes, .{})};
    var prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 2,
        .height_px = 1,
    });

    const oracle = try prepared_buffer.compose(allocator, null, &session_owner.session, &prepared);
    defer allocator.free(oracle);
    const owner = try Owner.create(session_owner, &prepared);
    const surface = owner.renderSurface().?;
    try std.testing.expectEqual(@as(u32, 1), surface.uploads.count);
    try std.testing.expect(surface.uploads.ptr[0].bytes_ptr != null);
    const upload_bytes_ptr = surface.uploads.ptr[0].bytes_ptr;

    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try render_surface_realizer.realize(surface, realized, null);
    try std.testing.expectEqual(upload_bytes_ptr, owner.renderSurface().?.uploads.ptr[0].bytes_ptr);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "render surface prepared owner partial surface equals explicit base rgba oracle" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 2, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const base = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255 };
    const background = [_]contract.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(9, 8, 7, 255))};
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
    try render_surface_realizer.realize(owner.renderSurface().?, realized, &base);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "render surface prepared owner releases render_surface payload with handle" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const background = [_]contract.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255))};
    var prepared = preparedSurface(.{ .background_draws = &background, .width_px = 1, .height_px = 1 });

    const owner = try Owner.create(session_owner, &prepared);
    try std.testing.expectEqual(@as(u32, 2), owner.renderSurface().?.commands.count);

    owner.release();

    try std.testing.expect(owner.render_surface_payload == null);
}

test "render surface prepared owner reports missing surface when render_surface emission overflows" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const draws_len: usize = @intCast((render_surface_emitter.Limits{}).commands_max + 1);
    const background_draws = try allocator.alloc(contract.TextBackgroundDraw, draws_len);
    defer allocator.free(background_draws);
    for (background_draws) |*draw| draw.* = backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255));
    var prepared = preparedSurface(.{ .background_draws = background_draws, .width_px = 1, .height_px = 1 });

    const owner = try Owner.create(session_owner, &prepared);

    try std.testing.expect(owner.renderSurface() == null);
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.command_bound_overflow, owner.renderSurfaceEmissionFailure());
    try std.testing.expectEqual(@as(usize, 1), session_owner.prepared_handles.items.len);
}

test "render surface prepared owner overflow still consumes prepare surface once" {
    const allocator = std.testing.allocator;
    const session_owner = text_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    var prepared = try ownedCommandOverflowPreparedSurface(allocator);
    const owner = try Owner.create(session_owner, &prepared);

    try std.testing.expect(owner.renderSurface() == null);
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.command_bound_overflow, owner.renderSurfaceEmissionFailure());
    try std.testing.expectEqual(@as(u64, 0), prepared.request.token.snapshot_seq);
    try std.testing.expectEqual(@as(usize, 1), session_owner.prepared_handles.items.len);
}

test "render surface prepared owner allocation failure is reported in info" {
    var probe_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var session_owner = text_session.TextSessionOwner.create(probe_allocator_state.allocator(), .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
        defer session_owner.destroy();
        const background = [_]contract.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255))};
        var prepared = preparedSurface(.{ .background_draws = &background, .width_px = 1, .height_px = 1 });
        const owner = try Owner.create(session_owner, &prepared);
        owner.release();
    }

    var fail_index: usize = 0;
    while (fail_index < probe_allocator_state.alloc_index) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var session_owner = text_session.TextSessionOwner.create(failing_allocator_state.allocator(), .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse continue;
        defer session_owner.destroy();
        const background = [_]contract.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255))};
        var prepared = preparedSurface(.{ .background_draws = &background, .width_px = 1, .height_px = 1 });
        const owner = Owner.create(session_owner, &prepared) catch continue;
        if (owner.renderSurfaceEmissionFailure() != .allocation_failed) continue;
        try std.testing.expect(owner.renderSurface() == null);
        return;
    }
    return error.MissingAllocationFailureCase;
}

fn ownedCommandOverflowPreparedSurface(allocator: std.mem.Allocator) !prepared_surface.PreparedSurface {
    const draws_len: usize = @intCast((render_surface_emitter.Limits{}).commands_max + 1);
    const background_draws = try allocator.alloc(contract.TextBackgroundDraw, draws_len);
    for (background_draws) |*draw| draw.* = backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255));
    return .{
        .allocator = allocator,
        .request = .{ .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full } },
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
        .request = .{ .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = if (options.full_redraw) 0 else 1, .damage_kind = if (options.full_redraw) .full else .partial } },
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
            .raster_plan = .{ .allocator = std.testing.allocator, .outputs = options.raster_outputs, .owned = false },
        },
    };
}

fn rasterOutput(allocator: std.mem.Allocator, key: u64, width_px: u16, height_px: u16, color_mode: contract.SpriteColorMode, pixels: []u8, visual_bounds: text.Rasterizer.SpriteBounds) text.Rasterizer.RasterSpriteOutput {
    return .{ .allocator = allocator, .key = .{ .value = key }, .width_px = width_px, .height_px = height_px, .color_mode = color_mode, .visual_bounds = visual_bounds, .pixels = pixels };
}

fn backgroundDraw(x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) contract.TextBackgroundDraw {
    return .{ .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = 0, .cell_span = 1 };
}

fn spriteDraw(key: u64, x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) contract.TextSpriteDraw {
    return .{ .sprite = .{ .slot = 0, .key = .{ .value = key } }, .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = 0, .cell_span = 1 };
}

fn rgba(r: u8, g: u8, b: u8, a: u8) contract.Rgba8 {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
