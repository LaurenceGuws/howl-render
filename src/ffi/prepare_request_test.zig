const std = @import("std");
const support = @import("test_support.zig");
const c = support.c;

test "render ffi prepare seam reports initial idle contract" {
    const handle = support.text.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer support.text.deinit(handle);
    try std.testing.expect(handle != null);
    var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_IDLE, support.prepare.takePrepareRequest(handle, &request));
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
