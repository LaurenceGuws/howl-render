const c = @import("abi.zig").c;
const prepared_submit_result = @import("prepared/submit_result.zig");
const text_session = @import("session/text.zig");

pub fn submitResultOut(value: prepared_submit_result.SubmitResult) c.HowlRenderSubmitResult {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .damage_kind = @intFromEnum(value.damageKind()),
        .host_surface = .{
            .host_surface_id = value.host_surface.host_surface_id,
            .width = value.host_surface.width,
            .height = value.host_surface.height,
        },
    };
}

pub fn failedSubmitResult() c.HowlRenderSubmitResult {
    return .{
        .status = c.HOWL_RENDER_CALL_FAILED,
        .damage_kind = 0,
        .host_surface = .{ .host_surface_id = 0, .width = 0, .height = 0 },
    };
}

pub fn submitExecutionIn(value: c.HowlRenderSubmitExecution) text_session.TextSession.SubmitExecution {
    return .{
        .host_surface = .{
            .host_surface_id = value.host_surface.host_surface_id,
            .width = value.host_surface.width,
            .height = value.host_surface.height,
        },
    };
}
