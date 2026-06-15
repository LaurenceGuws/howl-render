const std = @import("std");
const support = @import("test_support.zig");
const c = support.c;

test "deleted publish-prepared ABI symbols are absent" {
    try std.testing.expect(!@hasDecl(c, "howl_render_text_session_publish_prepared"));
    try std.testing.expect(!@hasDecl(c, "howl_render_text_session_publish_prepared_handle"));
    try std.testing.expect(!@hasDecl(c, "howl_render_text_session_take_submit_decision"));
    try std.testing.expect(!@hasDecl(c, "howl_render_text_session_accept_submitted"));
    try std.testing.expect(!@hasDecl(c, "howl_render_text_session_submit"));
    try std.testing.expect(!@hasDecl(c, "HowlRenderPreparedSurfaceToken"));
}

test "render ffi submit failure outputs preserve precise ABI status" {
    var result = std.mem.zeroes(c.HowlRenderSubmitResult);
    const execution = support.validExecutionInput();

    const handle = try support.createTestTextSessionHandle();
    defer support.text.deinit(handle);

    result = std.mem.zeroes(c.HowlRenderSubmitResult);
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_FAILED, support.submit.submitHandle(null, null, &execution, &result));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_MISSING_HANDLE, result.status);

    result = std.mem.zeroes(c.HowlRenderSubmitResult);
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_FAILED, support.submit.submitHandle(handle, null, &execution, &result));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, result.status);
}

test "render ffi prepared handle publish and direct submit lifecycle stays bounded" {
    const handle = try support.createTestTextSessionHandle();
    defer support.text.deinit(handle);
    const prepared_handle = try support.createPreparedHandle(handle);
    var submit_handle: c.HowlRenderRdrSfcHandle = null;
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT, support.submit.takeSubmitHandle(handle, &submit_handle));
    try std.testing.expectEqual(prepared_handle, submit_handle);
    const execution = support.validExecutionInput();
    var result = std.mem.zeroes(c.HowlRenderSubmitResult);
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_RENDERED, support.submit.submitHandle(handle, prepared_handle, &execution, &result));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, result.status);
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_FAILED, support.submit.submitHandle(handle, prepared_handle, &execution, null));
}

test "render ffi rdr_sfc handle submit lifecycle stays bounded without publish prepared" {
    const handle_a = try support.createTestTextSessionHandle();
    defer support.text.deinit(handle_a);
    const handle_b = try support.createTestTextSessionHandle();
    defer support.text.deinit(handle_b);
    const prepared_handle = try support.createPreparedHandle(handle_a);
    var submit_handle_b: c.HowlRenderRdrSfcHandle = null;
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_DECISION_IDLE, support.submit.takeSubmitHandle(handle_b, &submit_handle_b));
    var submit_handle: c.HowlRenderRdrSfcHandle = null;
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT, support.submit.takeSubmitHandle(handle_a, &submit_handle));
    try std.testing.expect(submit_handle == prepared_handle);
    const execution = support.validExecutionInput();
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_RENDERED, support.submit.submitHandle(handle_a, prepared_handle, &execution, null));
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_FAILED, support.submit.submitHandle(handle_a, prepared_handle, &execution, null));
}
