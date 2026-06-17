const std = @import("std");
const support = @import("test_support.zig");
const c = support.c;
const handle_owner = @import("text_session_handle.zig");

test "render abi prepare request requires render state" {
    const handle = support.text.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer support.text.deinit(handle);
    try std.testing.expect(handle != null);
    var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_FAILED, support.prepare.takePrepareRequest(handle, null, &request));
}

test "render abi prepare request missing handle leaves output zeroed" {
    var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
    const status = support.prepare.takePrepareRequest(null, null, &request);
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_FAILED, status);
    try std.testing.expectEqual(std.mem.zeroes(c.HowlRenderPrepareRequest), request);
}

test "render ffi invalid prepare requests fail and leave output handle null" {
    const handle = support.text.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer support.text.deinit(handle);
    try std.testing.expect(handle != null);
    var zero_snapshot = support.validFullPrepareRequest();
    zero_snapshot.snapshot_seq = 0;
    try support.expectPrepareHandleFailedWithNullOutput(handle, zero_snapshot);
    var zero_dirty = support.validFullPrepareRequest();
    zero_dirty.dirty_epoch = 0;
    try support.expectPrepareHandleFailedWithNullOutput(handle, zero_dirty);
    var zero_geometry = support.validFullPrepareRequest();
    zero_geometry.geometry_epoch = 0;
    try support.expectPrepareHandleFailedWithNullOutput(handle, zero_geometry);
    var none_kind = support.validFullPrepareRequest();
    none_kind.damage_kind = support.damageNone();
    try support.expectPrepareHandleFailedWithNullOutput(handle, none_kind);
    var unknown_kind = support.validFullPrepareRequest();
    unknown_kind.damage_kind = 2;
    try support.expectPrepareHandleFailedWithNullOutput(handle, unknown_kind);
    var full_nonzero_damage_base = support.validFullPrepareRequest();
    full_nonzero_damage_base.damage_base_seq = 1;
    try support.expectPrepareHandleFailedWithNullOutput(handle, full_nonzero_damage_base);
    var partial_zero_damage_base = support.validPartialPrepareRequest();
    partial_zero_damage_base.damage_base_seq = 0;
    try support.expectPrepareHandleFailedWithNullOutput(handle, partial_zero_damage_base);
}

test "render abi take prepare request stores latest render state token on session owner" {
    const handle = try support.createTestTextSessionHandle();
    defer support.text.deinit(handle);

    const geometry = support.geometry.syncGeometry(handle, .{
        .render_px = .{ .width = 16, .height = 16 },
        .grid_px = .{ .width = 16, .height = 16 },
    });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, geometry.status);
    try std.testing.expect(geometry.changed != 0);

    const render_state = try support.createRenderState(1, 1, "A");
    defer support.destroyRenderState(render_state);

    var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_READY, support.prepare.takePrepareRequest(handle, render_state, &request));
    try std.testing.expect(request.snapshot_seq != 0);
    try std.testing.expectEqual(@as(u64, 1), request.geometry_epoch);

    const owner = handle_owner.textSessionOwner(handle) orelse return error.TestUnexpectedResult;
    try std.testing.expect(owner.latest_render_state != null);
    try std.testing.expect(owner.latest_render_state_handle == render_state);
    try std.testing.expect(owner.prepare_request != null);
}
