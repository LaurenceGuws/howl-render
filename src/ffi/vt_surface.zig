const std = @import("std");
const c = @import("../ffi.zig").c;
const handle_owner = @import("handle.zig");
const source_vt = @import("../tv_surface/vt.zig");
const tokens = @import("../geometry/tokens.zig");

pub fn publishVtSurface(value: c.HowlRenderTextSessionHandle, vt_surface: ?*const c.HowlVtSurfaceResult) callconv(.c) c.HowlRenderVtSurfacePublishResult {
    const source = vt_surface orelse return vtSurfacePublishFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
    const owner = handle_owner.textSessionOwner(value) orelse return vtSurfacePublishFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
    const result = owner.publishVtSurface(source.*) catch {
        return vtSurfacePublishFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
    };
    return vtSurfacePublishResultOut(result);
}

fn vtSurfacePublishFailure(status: c_int) c.HowlRenderVtSurfacePublishResult {
    return .{
        .status = status,
        .published = 0,
        .queued = 0,
        .damage_kind = @intFromEnum(tokens.DamageKind.none),
        .reserved0 = 0,
        .snapshot_seq = 0,
        .geometry_epoch = 0,
    };
}

pub fn vtSurfacePublishResultOut(value: source_vt.VtSurfacePublishResult) c.HowlRenderVtSurfacePublishResult {
    return vtSurfacePublishResultWithStatus(value, c.HOWL_RENDER_CALL_OK);
}

pub fn vtSurfacePublishResultWithStatus(value: source_vt.VtSurfacePublishResult, status: c_int) c.HowlRenderVtSurfacePublishResult {
    return .{
        .status = status,
        .published = @intFromBool(value.published),
        .queued = @intFromBool(value.queued),
        .damage_kind = @intFromEnum(value.damage_kind),
        .reserved0 = 0,
        .snapshot_seq = value.snapshot_seq,
        .geometry_epoch = value.geometry_epoch,
    };
}
