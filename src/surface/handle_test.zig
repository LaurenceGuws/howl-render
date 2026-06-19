const std = @import("std");
const geometry = @import("../geometry.zig");
const prepared_buffer = @import("compositor.zig");
const prepared_handle = @import("handle.zig");
const prepared_surface = @import("prepared_surface.zig");
const render_surface_emitter = @import("emitter.zig");
const render_surface_realizer = @import("realizer.zig");
const render_session = @import("../render_session.zig");
const rasterizer = @import("../text/raster/rasterizer.zig");
const render = @import("../grid/scene.zig");
const test_support = @import("../c/test_support.zig");

const PreparedHandle = prepared_handle.PreparedHandle;
const RenderSurfaceEmissionFailure = render_surface_emitter.RenderSurfaceEmissionFailure;

test "create reports missing-sprite diagnostic without double free" {
    const session_owner = render_session.TextSessionOwner.create(std.heap.c_allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    var sprite_draws = [_]render.TextSpriteDraw{.{
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
        .text_surface = .{
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
    const handle = try PreparedHandle.create(session_owner, &owned_prepared);
    try std.testing.expect(handle.renderSurface() == null);
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.missing_prepared_sprite, handle.renderSurfaceEmissionFailure());
}

test "prepared surface exports info and required upload count truth" {
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{ undefined, undefined, undefined };
    const surface = prepared_surface.PreparedSurface{
        .allocator = std.testing.allocator,
        .request = .{ .token = .{ .snapshot_seq = 7, .dirty_epoch = 8, .geometry_epoch = 1, .damage_base_seq = 6, .damage_kind = .partial } },
        .geometry_epoch = 9,
        .render_px = .{ .width = 11, .height = 12 },
        .cell_px = .{ .width = 2, .height = 3 },
        .grid = .{ .cols = 4, .rows = 5 },
        .text_surface = .{
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
        .render_surface_emission_failure = .upload_bytes_overflow,
    };

    const info = surface.info();
    try std.testing.expectEqual(@as(u64, 7), info.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 6), info.required_base_seq);
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.upload_bytes_overflow, surface.render_surface_emission_failure);

    const buffer = surface.buffer();
    try std.testing.expectEqual(@as(u64, 3), buffer.uploads_required);
}

test "emitter maps every render-surface emission error to local failure" {
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.command_bound_overflow, render_surface_emitter.emissionFailureFromError(error.CommandBoundOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.create_bound_overflow, render_surface_emitter.emissionFailureFromError(error.CreateBoundOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.damage_bound_overflow, render_surface_emitter.emissionFailureFromError(error.DamageBoundOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.retire_bound_overflow, render_surface_emitter.emissionFailureFromError(error.RetireBoundOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.resource_bound_overflow, render_surface_emitter.emissionFailureFromError(error.ResourceBoundOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.upload_bound_overflow, render_surface_emitter.emissionFailureFromError(error.UploadBoundOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.upload_bytes_overflow, render_surface_emitter.emissionFailureFromError(error.UploadBytesOverflow));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.invalid_prepared_sprite, render_surface_emitter.emissionFailureFromError(error.InvalidPreparedSprite));
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.missing_prepared_sprite, render_surface_emitter.emissionFailureFromError(error.MissingPreparedSprite));
}

test "prepared handle testing validates realized uploads and host surface dimensions before submit" {
    const render_px = geometry.PixelSize{ .width = 11, .height = 12 };

    try std.testing.expect(prepared_handle.testing.executionMatchesPrepared(render_px, .{
        .host_surface = .{ .host_surface_id = 1, .width = 11, .height = 12 },
    }));
    try std.testing.expect(!prepared_handle.testing.executionMatchesPrepared(render_px, .{
        .host_surface = .{ .host_surface_id = 1, .width = 10, .height = 12 },
    }));
    try std.testing.expect(!prepared_handle.testing.executionMatchesPrepared(render_px, .{
        .host_surface = .{ .host_surface_id = 1, .width = 11, .height = 13 },
    }));
}

test "render surface prepared owner surface equals kitty dim rgba oracle" {
    const allocator = std.testing.allocator;
    const session_owner = render_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 2, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    var sprite_bytes = [_]u8{ 255, 255 };
    var sprite_draws = [_]render.TextSpriteDraw{spriteDraw(21, 0, 0, 2, 1, rgba(255, 0, 0, 102))};
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 21, 2, 1, .alpha, &sprite_bytes, .{})};
    var prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 2,
        .height_px = 1,
    });

    const oracle = try prepared_buffer.compose(allocator, null, &session_owner.session, &prepared);
    defer allocator.free(oracle);
    const handle = try PreparedHandle.create(session_owner, &prepared);
    const surface = handle.renderSurface().?;
    const surface_ptr = surface;
    const commands_ptr = surface.commands.ptr;
    try std.testing.expectEqual(@as(u32, 1), surface.uploads.count);
    try std.testing.expect(surface.uploads.ptr[0].bytes_ptr != null);
    const upload_bytes_ptr = surface.uploads.ptr[0].bytes_ptr;

    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try render_surface_realizer.realize(surface, realized, null);
    try std.testing.expectEqual(surface_ptr, handle.renderSurface().?);
    try std.testing.expectEqual(commands_ptr, handle.renderSurface().?.commands.ptr);
    try std.testing.expectEqual(upload_bytes_ptr, handle.renderSurface().?.uploads.ptr[0].bytes_ptr);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "prepared handle fresh alpha atlas sprite emits zero uploads on second create" {
    const allocator = std.testing.allocator;
    const session_owner = render_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 2, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    var sprite_bytes = [_]u8{ 255, 128 };
    var sprite_draws = [_]render.TextSpriteDraw{spriteDraw(22, 0, 0, 2, 1, rgba(255, 255, 255, 255))};
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 22, 2, 1, .alpha, &sprite_bytes, .{})};
    var first_prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 2, .height_px = 1 });
    var second_prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 2, .height_px = 1 });

    const first = try PreparedHandle.create(session_owner, &first_prepared);
    try std.testing.expectEqual(@as(u32, 1), first.renderSurface().?.uploads.count);
    const atlas_resource = first.renderSurface().?.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    try std.testing.expect(atlas_resource.value != 0);

    const second = try PreparedHandle.create(session_owner, &second_prepared);
    try std.testing.expectEqual(@as(u32, 0), second.renderSurface().?.creates.count);
    try std.testing.expectEqual(@as(u32, 0), second.renderSurface().?.uploads.count);
    try std.testing.expectEqual(atlas_resource.value, second.renderSurface().?.commands.ptr[1].glyphs.ptr[0].atlas_resource.value);
}

test "prepared handle fresh persistent color sprite emits zero uploads on second create" {
    const allocator = std.testing.allocator;
    const session_owner = render_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 2, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    var sprite_bytes = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var sprite_draws = [_]render.TextSpriteDraw{spriteDraw(23, 0, 0, 2, 1, rgba(255, 255, 255, 255))};
    var raster_outputs = [_]rasterizer.RasterSpriteOutput{test_support.rasterOutput(allocator, 23, 2, 1, .color, &sprite_bytes, .{})};
    var first_prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 2, .height_px = 1 });
    var second_prepared = preparedSurface(.{ .sprite_draws = &sprite_draws, .raster_outputs = &raster_outputs, .width_px = 2, .height_px = 1 });

    const first = try PreparedHandle.create(session_owner, &first_prepared);
    try std.testing.expectEqual(@as(u32, 1), first.renderSurface().?.creates.count);
    try std.testing.expectEqual(@as(u32, 1), first.renderSurface().?.uploads.count);
    const resource = first.renderSurface().?.commands.ptr[1].resource;
    try std.testing.expect(resource.value != 0);

    const second = try PreparedHandle.create(session_owner, &second_prepared);
    try std.testing.expectEqual(@as(u32, 0), second.renderSurface().?.creates.count);
    try std.testing.expectEqual(@as(u32, 0), second.renderSurface().?.uploads.count);
    try std.testing.expectEqual(resource.value, second.renderSurface().?.commands.ptr[1].resource.value);
}

test "render surface prepared owner partial surface equals explicit base rgba oracle" {
    const allocator = std.testing.allocator;
    const session_owner = render_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 2, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const base = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255 };
    const background = [_]render.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(9, 8, 7, 255))};
    var prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 2,
        .height_px = 1,
        .full_redraw = false,
    });

    const oracle = try prepared_buffer.compose(allocator, &base, &session_owner.session, &prepared);
    defer allocator.free(oracle);
    const handle = try PreparedHandle.create(session_owner, &prepared);
    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try render_surface_realizer.realize(handle.renderSurface().?, realized, &base);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "prepared handle releases render_surface payload with handle" {
    const allocator = std.testing.allocator;
    const session_owner = render_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const background = [_]render.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255))};
    var prepared = preparedSurface(.{ .background_draws = &background, .width_px = 1, .height_px = 1 });

    const handle = try PreparedHandle.create(session_owner, &prepared);
    try std.testing.expectEqual(@as(u32, 2), handle.renderSurface().?.commands.count);

    handle.release();

    try std.testing.expect(handle.render_surface_payload == null);
}

test "prepared handle release is idempotent and stays not live" {
    const allocator = std.testing.allocator;
    const session_owner = render_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const background = [_]render.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255))};
    var prepared = preparedSurface(.{ .background_draws = &background, .width_px = 1, .height_px = 1 });
    const handle = try PreparedHandle.create(session_owner, &prepared);

    handle.release();
    handle.release();

    try std.testing.expectEqual(prepared_handle.PreparedHandle.State.released, handle.state);
    try std.testing.expect(!handle.isLive());
    try std.testing.expect(handle.render_surface_payload == null);
}

test "prepared handle belongs to owning session only" {
    const allocator = std.testing.allocator;
    const owner_a = render_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer owner_a.destroy();
    const owner_b = render_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer owner_b.destroy();

    const background = [_]render.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255))};
    var prepared = preparedSurface(.{ .background_draws = &background, .width_px = 1, .height_px = 1 });
    const handle = try PreparedHandle.create(owner_a, &prepared);

    try std.testing.expect(handle.belongsToSession(owner_a));
    try std.testing.expect(!handle.belongsToSession(owner_b));
}

test "prepared handle reports missing surface when render_surface emission overflows" {
    const allocator = std.testing.allocator;
    const session_owner = render_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    const draws_len: usize = @intCast((render_surface_emitter.Limits{}).commands_max + 1);
    const background_draws = try allocator.alloc(render.TextBackgroundDraw, draws_len);
    defer allocator.free(background_draws);
    for (background_draws) |*draw| draw.* = backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255));
    var prepared = preparedSurface(.{ .background_draws = background_draws, .width_px = 1, .height_px = 1 });

    const handle = try PreparedHandle.create(session_owner, &prepared);

    try std.testing.expect(handle.renderSurface() == null);
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.command_bound_overflow, handle.renderSurfaceEmissionFailure());
    try std.testing.expectEqual(@as(usize, 1), session_owner.pending_prepared.registeredHandleCount());
}

test "prepared handle overflow still consumes prepare surface once" {
    const allocator = std.testing.allocator;
    const session_owner = render_session.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();

    var prepared = try ownedCommandOverflowPreparedSurface(allocator);
    const handle = try PreparedHandle.create(session_owner, &prepared);

    try std.testing.expect(handle.renderSurface() == null);
    try std.testing.expectEqual(RenderSurfaceEmissionFailure.command_bound_overflow, handle.renderSurfaceEmissionFailure());
    try std.testing.expectEqual(@as(u64, 0), prepared.request.token.snapshot_seq);
    try std.testing.expectEqual(@as(usize, 1), session_owner.pending_prepared.registeredHandleCount());
}

test "prepared handle allocation failure is reported in info" {
    var probe_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var session_owner = render_session.TextSessionOwner.create(probe_allocator_state.allocator(), .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
        defer session_owner.destroy();
        const background = [_]render.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255))};
        var prepared = preparedSurface(.{ .background_draws = &background, .width_px = 1, .height_px = 1 });
        const handle = try PreparedHandle.create(session_owner, &prepared);
        handle.release();
    }

    var fail_index: usize = 0;
    while (fail_index < probe_allocator_state.alloc_index) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var session_owner = render_session.TextSessionOwner.create(failing_allocator_state.allocator(), .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse continue;
        defer session_owner.destroy();
        const background = [_]render.TextBackgroundDraw{backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255))};
        var prepared = preparedSurface(.{ .background_draws = &background, .width_px = 1, .height_px = 1 });
        const handle = PreparedHandle.create(session_owner, &prepared) catch continue;
        if (handle.renderSurfaceEmissionFailure() != .allocation_failed) continue;
        try std.testing.expect(handle.renderSurface() == null);
        return;
    }
    return error.MissingAllocationFailureCase;
}

fn ownedCommandOverflowPreparedSurface(allocator: std.mem.Allocator) !prepared_surface.PreparedSurface {
    const draws_len: usize = @intCast((render_surface_emitter.Limits{}).commands_max + 1);
    const background_draws = try allocator.alloc(render.TextBackgroundDraw, draws_len);
    for (background_draws) |*draw| draw.* = backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255));
    return .{
        .allocator = allocator,
        .request = .{ .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full } },
        .geometry_epoch = 1,
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .text_surface = .{
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
        .render_surface_emission_failure = .none,
    };
}

const PreparedOptions = struct {
    clear_draws: []const render.TextClearDraw = &.{},
    background_draws: []const render.TextBackgroundDraw = &.{},
    sprite_draws: []const render.TextSpriteDraw = &.{},
    decoration_draws: []const render.TextDecorationDraw = &.{},
    cursor_draws: []const render.TextCursorDraw = &.{},
    raster_outputs: []rasterizer.RasterSpriteOutput = &.{},
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
        .text_surface = .{
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
        .render_surface_emission_failure = .none,
    };
}

fn backgroundDraw(x: i32, y: i32, width: u16, height: u16, color: render.Rgba8) render.TextBackgroundDraw {
    return .{ .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = 0, .cell_span = 1 };
}

fn spriteDraw(key: u64, x: i32, y: i32, width: u16, height: u16, color: render.Rgba8) render.TextSpriteDraw {
    return .{ .sprite = .{ .slot = 0, .key = .{ .value = key } }, .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = 0, .cell_span = 1 };
}

fn rgba(r: u8, g: u8, b: u8, a: u8) render.Rgba8 {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
