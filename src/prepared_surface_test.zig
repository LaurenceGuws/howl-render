const std = @import("std");
const support = @import("test_support.zig");
const c = support.c;

test "render ffi prepared render-surface retrieval status values are stable" {
    try std.testing.expectEqual(@as(i32, 0), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_OK);
    try std.testing.expectEqual(@as(i32, -1), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_MISSING_HANDLE);
    try std.testing.expectEqual(@as(i32, -2), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_INVALID_ARGUMENT);
    try std.testing.expectEqual(@as(i32, 1), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_COMMAND_BOUND_OVERFLOW);
    try std.testing.expectEqual(@as(i32, 2), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_CREATE_BOUND_OVERFLOW);
    try std.testing.expectEqual(@as(i32, 3), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_DAMAGE_BOUND_OVERFLOW);
    try std.testing.expectEqual(@as(i32, 4), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_RETIRE_BOUND_OVERFLOW);
    try std.testing.expectEqual(@as(i32, 5), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_RESOURCE_BOUND_OVERFLOW);
    try std.testing.expectEqual(@as(i32, 6), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_UPLOAD_BOUND_OVERFLOW);
    try std.testing.expectEqual(@as(i32, 7), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_UPLOAD_BYTES_OVERFLOW);
    try std.testing.expectEqual(@as(i32, 8), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_INVALID_PREPARED_SPRITE);
    try std.testing.expectEqual(@as(i32, 9), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_MISSING_PREPARED_SPRITE);
    try std.testing.expectEqual(@as(i32, 10), c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_ALLOCATION_FAILED);
}

test "render ffi prepared render-surface maps every owner emission failure" {
    const Case = struct { failure: support.render_surface_emitter_model_ns.RenderSurfaceEmissionFailure, status: c.HowlRenderPreparedSurfaceRenderSurfaceStatus };
    const cases = [_]Case{
        .{ .failure = .none, .status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_OK },
        .{ .failure = .allocation_failed, .status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_ALLOCATION_FAILED },
        .{ .failure = .command_bound_overflow, .status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_COMMAND_BOUND_OVERFLOW },
        .{ .failure = .create_bound_overflow, .status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_CREATE_BOUND_OVERFLOW },
        .{ .failure = .damage_bound_overflow, .status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_DAMAGE_BOUND_OVERFLOW },
        .{ .failure = .retire_bound_overflow, .status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_RETIRE_BOUND_OVERFLOW },
        .{ .failure = .resource_bound_overflow, .status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_RESOURCE_BOUND_OVERFLOW },
        .{ .failure = .upload_bound_overflow, .status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_UPLOAD_BOUND_OVERFLOW },
        .{ .failure = .upload_bytes_overflow, .status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_UPLOAD_BYTES_OVERFLOW },
        .{ .failure = .invalid_prepared_sprite, .status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_INVALID_PREPARED_SPRITE },
        .{ .failure = .missing_prepared_sprite, .status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_MISSING_PREPARED_SPRITE },
    };
    for (cases) |case| {
        var prepared = support.preparedHandleWithFailure(case.failure);
        var surface_storage = std.mem.zeroes(c.HowlRenderSurface);
        var surface: ?*const c.HowlRenderSurface = &surface_storage;
        try std.testing.expectEqual(case.status, support.prepared.renderSurface(@ptrCast(&prepared), &surface));
        try std.testing.expect(surface == null);
    }
}

test "render ffi prepared surface missing handle and invalid argument statuses stay stable" {
    var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, support.prepared.describe(null, &info));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, info.status);

    var surface: ?*const c.HowlRenderSurface = undefined;
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_MISSING_HANDLE, support.prepared.renderSurface(null, &surface));
    try std.testing.expect(surface == null);

    const handle = try support.createTestTextSessionHandle();
    defer support.text.deinit(handle);
    const prepared_handle = try support.createPreparedHandle(handle);
    defer support.prepared.release(prepared_handle);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.prepared.describe(prepared_handle, null));
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_INVALID_ARGUMENT, support.prepared.renderSurface(prepared_handle, null));
}

test "render ffi prepared info layout excludes render-surface retrieval status" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(c.HowlRenderPreparedSurfaceInfo, "status"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(c.HowlRenderPreparedSurfaceInfo, "snapshot_seq"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(c.HowlRenderPreparedSurfaceInfo, "dirty_epoch"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(c.HowlRenderPreparedSurfaceInfo, "geometry_epoch"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(c.HowlRenderPreparedSurfaceInfo, "required_base_seq"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(c.HowlRenderPreparedSurfaceInfo, "render_px"));
    try std.testing.expectEqual(@as(usize, 44), @offsetOf(c.HowlRenderPreparedSurfaceInfo, "cell_px"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(c.HowlRenderPreparedSurfaceInfo, "grid"));
    try std.testing.expectEqual(@as(usize, 52), @offsetOf(c.HowlRenderPreparedSurfaceInfo, "damage_kind"));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(c.HowlRenderPreparedSurfaceInfo));
}

test "render ffi prepared surface describe and borrowed surface lifecycle" {
    const handle = try support.createTestTextSessionHandle();
    defer support.text.deinit(handle);
    const prepared_handle = try support.createPreparedHandle(handle);
    var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, support.prepared.describe(prepared_handle, &info));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, info.status);
    var surface: ?*const c.HowlRenderSurface = null;
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_OK, support.prepared.renderSurface(prepared_handle, &surface));
    try std.testing.expect(surface != null);
    support.prepared.release(prepared_handle);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.prepared.describe(prepared_handle, &info));
}

test "render surface prepared ffi borrowed surface realizes explicit rgba oracle" {
    const allocator = std.testing.allocator;
    const session_owner = support.text_session_model_ns.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 2, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();
    const background = [_]support.text_contract_ns.TextBackgroundDraw{support.backgroundDraw(0, 0, 2, 1, support.rgba(1, 2, 3, 255))};
    var prepared_surface_value = support.preparedSurface(.{ .background_draws = &background, .width_px = 2, .height_px = 1 });
    const oracle = try support.prepared_buffer.compose(allocator, null, &session_owner.session, &prepared_surface_value);
    defer allocator.free(oracle);
    const prepared = try support.prepared_handle_model_ns.PreparedHandle.create(session_owner, &prepared_surface_value);
    defer prepared.destroy();
    var surface: ?*const c.HowlRenderSurface = null;
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_OK, support.prepared.renderSurface(@ptrCast(prepared), &surface));
    const value = surface orelse return error.MissingSurface;
    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try support.realizer.realize(value, realized, null);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "render ffi prepared render-surface retrieval reports emission failure" {
    const allocator = std.testing.allocator;
    const session_owner = support.text_session_model_ns.TextSessionOwner.create(allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer session_owner.destroy();
    const draws_len: usize = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    const background_draws = try allocator.alloc(support.text_contract_ns.TextBackgroundDraw, draws_len);
    defer allocator.free(background_draws);
    for (background_draws) |*draw| draw.* = support.backgroundDraw(0, 0, 1, 1, support.rgba(1, 2, 3, 255));
    var prepared_surface_value = support.preparedSurface(.{ .background_draws = background_draws, .width_px = 1, .height_px = 1 });
    const prepared = try support.prepared_handle_model_ns.PreparedHandle.create(session_owner, &prepared_surface_value);
    defer prepared.destroy();
    var surface: ?*const c.HowlRenderSurface = undefined;
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_COMMAND_BOUND_OVERFLOW, support.prepared.renderSurface(@ptrCast(prepared), &surface));
    try std.testing.expect(surface == null);
}
