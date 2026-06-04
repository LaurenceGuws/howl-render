const std = @import("std");
const support = @import("test_support.zig");
const c = support.c;

test "render ffi submit seams accept valid tokens and reject invalid prepared tokens" {
    const handle = support.text.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer support.text.deinit(handle);
    try std.testing.expect(handle != null);
    var prepared = std.mem.zeroes(c.HowlRenderPreparedSurfaceToken);
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_DECISION_IDLE, support.submit.takeSubmitDecision(handle, &prepared));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, support.submit.publishPrepared(handle, support.validFullPreparedSurfaceToken()));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, support.submit.publishPrepared(handle, support.validPartialPreparedSurfaceToken()));
    const prepared_handle = try support.createPreparedHandle(handle);
    defer support.prepared.release(prepared_handle);
    var zero_snapshot = support.validFullPreparedSurfaceToken();
    zero_snapshot.snapshot_seq = 0;
    try support.expectInvalidPreparedSurfaceTokenRejected(handle, prepared_handle, zero_snapshot);
}

test "render ffi prepared handle publish and direct submit lifecycle stays bounded" {
    const handle = try support.createTestTextSessionHandle();
    defer support.text.deinit(handle);
    const prepared_handle = try support.createPreparedHandle(handle);
    const token = try support.preparedSurfaceTokenFromHandle(prepared_handle);
    const execution = support.validExecutionInput();
    var result = std.mem.zeroes(c.HowlRenderSubmitResult);
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_RENDERED, support.submit.submit(handle, prepared_handle, token, &execution, &result));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, result.status);
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_FAILED, support.submit.submit(handle, prepared_handle, token, &execution, null));
}

test "render ffi published handle submit lifecycle and cross-session rejection stay bounded" {
    const handle_a = try support.createTestTextSessionHandle();
    defer support.text.deinit(handle_a);
    const handle_b = try support.createTestTextSessionHandle();
    defer support.text.deinit(handle_b);
    const prepared_handle = try support.createPreparedHandle(handle_a);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.submit.publishPreparedHandle(handle_b, prepared_handle));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, support.submit.publishPreparedHandle(handle_a, prepared_handle));
    var submit_handle: c.HowlRenderPreparedSurfaceHandle = null;
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT, support.submit.takeSubmitHandle(handle_a, &submit_handle));
    try std.testing.expect(submit_handle == prepared_handle);
    const execution = support.validExecutionInput();
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_RENDERED, support.submit.submitHandle(handle_a, prepared_handle, &execution, null));
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_FAILED, support.submit.submitHandle(handle_a, prepared_handle, &execution, null));
}
