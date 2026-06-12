const std = @import("std");
const support = @import("test_support.zig");
const c = support.c;

test "render ffi publishes vt abi surface result" {
    const handle = support.text.init(.{ .surface_px = .{ .width = 256, .height = 128 }, .font_size_px = 8 });
    defer support.text.deinit(handle);
    try std.testing.expect(handle != null);
    const geometry = support.geometry.syncGeometry(handle, .{ .render_px = .{ .width = 256, .height = 128 }, .grid_px = .{ .width = 256, .height = 128 } });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, geometry.status);
    var cells: [4]support.VtSurfaceCell = undefined;
    for (&cells, 0..) |*cell, index| {
        cell.* = support.testCell();
        cell.codepoint = @intCast('a' + index);
        cell.bg_color = .{ .kind = 2, .value = 0x112233 };
        cell.underline_style = 4;
    }
    var dirty_rows = [_]u8{ 1, 1 };
    var dirty_cols_start = [_]u16{ 0, 0 };
    var dirty_cols_end = [_]u16{ 1, 1 };
    var surface = support.validVtSurfaceResult(9, 2, 2, &cells, &dirty_rows, &dirty_cols_start, &dirty_cols_end);
    const publish = support.vt.publishVtSurface(handle, &surface);
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
    var cells = [_]support.VtSurfaceCell{support.testCell()};
    var dirty_rows = [_]u8{1};
    var dirty_cols_start = [_]u16{0};
    var dirty_cols_end = [_]u16{0};
    var surface = support.validVtSurfaceResult(11, 1, 1, &cells, &dirty_rows, &dirty_cols_start, &dirty_cols_end);
    const publish = support.vt.publishVtSurface(handle, &surface);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, publish.status);
    try std.testing.expectEqual(@as(u64, 11), publish.snapshot_seq);
    var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_READY, support.prepare.takePrepareRequest(handle, &request));
    try std.testing.expectEqual(@as(u64, 11), request.snapshot_seq);
}

test "render ffi rejects invalid vt surface inputs" {
    const handle = support.text.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer support.text.deinit(handle);
    try std.testing.expect(handle != null);

    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.vt.publishVtSurface(handle, null).status);

    var cells = [_]support.VtSurfaceCell{support.testCell()};
    var dirty_rows = [_]u8{1};
    var dirty_cols_start = [_]u16{0};
    var dirty_cols_end = [_]u16{0};
    var surface = support.validVtSurfaceResult(13, 1, 1, &cells, &dirty_rows, &dirty_cols_start, &dirty_cols_end);

    surface.status = c.HOWL_VT_CALL_FAILED;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.vt.publishVtSurface(handle, &surface).status);
    surface.status = c.HOWL_VT_CALL_OK;

    surface.snapshot_seq = 0;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.vt.publishVtSurface(handle, &surface).status);
    surface.snapshot_seq = 13;

    surface.dirty_generation = 0;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.vt.publishVtSurface(handle, &surface).status);
    surface.dirty_generation = 13;

    surface.source.surface_cells.len = 2;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.vt.publishVtSurface(handle, &surface).status);
    surface.source.surface_cells.len = 1;

    dirty_rows[0] = 2;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.vt.publishVtSurface(handle, &surface).status);
    dirty_rows[0] = 1;

    dirty_cols_end[0] = 1;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, support.vt.publishVtSurface(handle, &surface).status);
    dirty_cols_end[0] = 0;
}
