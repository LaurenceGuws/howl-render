const std = @import("std");
const support = @import("test_support.zig");
const c = support.c;

test "render ffi vt surface slot translates vt cell ffi storage" {
    const handle = support.text.init(.{ .surface_px = .{ .width = 256, .height = 128 }, .font_size_px = 8 });
    defer support.text.deinit(handle);
    try std.testing.expect(handle != null);
    const geometry = support.geometry.syncGeometry(handle, .{ .render_px = .{ .width = 256, .height = 128 }, .grid_px = .{ .width = 256, .height = 128 } });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, geometry.status);
    var slot = std.mem.zeroes(support.RenderVtSurfaceSlot);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, support.vt.reserveVtSurfaceSlot(handle, 2, 2, &slot));
    try std.testing.expectEqual(@as(usize, 4), slot.cells.len);
    for (slot.cells.ptr[0..slot.cells.len], 0..) |*cell, index| {
        cell.* = support.testCell();
        cell.codepoint = @intCast('a' + index);
        cell.bg_color = .{ .kind = 2, .value = 0x112233 };
        cell.underline_style = 4;
    }
    @memcpy(slot.dirty_rows.ptr[0..slot.dirty_rows.len], &[_]u8{ 1, 1 });
    @memcpy(slot.dirty_cols_start.ptr[0..slot.dirty_cols_start.len], &[_]u16{ 0, 0 });
    @memcpy(slot.dirty_cols_end.ptr[0..slot.dirty_cols_end.len], &[_]u16{ 1, 1 });
    const publish = support.vt.commitVtSurface(handle, .{ .history_count = 0, .scroll_row = 0, .snapshot_seq = 9, .is_alternate_screen = 0, .cursor = .{ .row = 0, .col = 0, .visible = 1, .shape = 0, .blink = 0 }, .colors = std.mem.zeroes(c.HowlRenderSourceColors), .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } } });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, publish.status);
    try std.testing.expectEqual(@as(u64, 9), publish.snapshot_seq);
}

test "render ffi rejects invalid publish cell codepoint" {
    var cell = support.testCell();
    cell.codepoint = @as(u32, std.math.maxInt(u21)) + 1;
    try support.expectInvalidPublishedCell(cell);
}

test "render ffi rejects invalid publish underline style" {
    var cell = support.testCell();
    cell.underline_style = 5;
    try support.expectInvalidPublishedCell(cell);
}

test "render ffi rejects invalid publish color kind" {
    var cell = support.testCell();
    cell.fg_color = .{ .kind = 3, .value = 0 };
    try support.expectInvalidPublishedCell(cell);
}

test "render ffi reserve write commit and take prepare succeeds" {
    const handle = support.text.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer support.text.deinit(handle);
    try std.testing.expect(handle != null);
    _ = support.geometry.syncGeometry(handle, .{ .render_px = .{ .width = 16, .height = 16 }, .grid_px = .{ .width = 16, .height = 16 } });
    var slot = std.mem.zeroes(support.RenderVtSurfaceSlot);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, support.vt.reserveVtSurfaceSlot(handle, 1, 1, &slot));
    slot.cells.ptr[0] = support.testCell();
    slot.dirty_rows.ptr[0] = 1;
    slot.dirty_cols_start.ptr[0] = 0;
    slot.dirty_cols_end.ptr[0] = 0;
    const publish = support.vt.commitVtSurface(handle, support.validVtSurfaceCommit(11));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, publish.status);
    try std.testing.expectEqual(@as(u64, 11), publish.snapshot_seq);
    var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_READY, support.prepare.takePrepareRequest(handle, &request));
    try std.testing.expectEqual(@as(u64, 11), request.snapshot_seq);
}
