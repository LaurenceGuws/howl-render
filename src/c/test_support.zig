const std = @import("std");

pub const c = @import("howl_render_c");
const prepare_request = @import("prepare_request.zig");
const prepared_surface = @import("prepared_surface.zig");
const submission = @import("submission.zig");
const surface_geometry = @import("surface_geometry.zig");
const text_session = @import("text_session.zig");
const work_state = @import("work_state.zig");
const prepared_buffer_model = @import("../surface/compositor.zig");
const prepared_handle_model = @import("../surface/handle.zig");
const prepared_surface_model = @import("../surface/prepared_surface.zig");
const render_surface_emitter_model = @import("../surface/emitter.zig");
const render_surface_realizer = @import("../surface/realizer.zig");
const surface = @import("../surface.zig");
const rasterizer = @import("../text/raster/rasterizer.zig");
const text_session_model = @import("../render_session.zig");

pub const prepare = prepare_request;
pub const prepared = prepared_surface;
pub const submit = submission;
pub const geometry = surface_geometry;
pub const text = text_session;
pub const work = work_state;
pub const prepared_buffer = prepared_buffer_model;
pub const prepared_handle_model_ns = prepared_handle_model;
pub const prepared_surface_model_ns = prepared_surface_model;
pub const render_surface_emitter_model_ns = render_surface_emitter_model;
pub const realizer = render_surface_realizer;
pub const surface_ns = surface;
pub const text_rasterizer = rasterizer;
pub const text_session_model_ns = text_session_model;

comptime {
    std.debug.assert(c.HOWL_RENDER_CALL_OK == 0);
    std.debug.assert(c.HOWL_RENDER_PREPARE_READY == 1);
    std.debug.assert(c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT == 1);
    std.debug.assert(c.HOWL_RENDER_MAX_FALLBACK_FONTS == 24);
}

pub fn validFullPrepareRequest() c.HowlRenderPrepareRequest {
    return .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = damageFull() };
}

pub fn validPartialPrepareRequest() c.HowlRenderPrepareRequest {
    return .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = damagePartial() };
}

pub fn preparedHandleWithFailure(failure: render_surface_emitter_model.RenderSurfaceEmissionFailure) prepared_handle_model.PreparedHandle {
    return .{
        .session_owner = undefined,
        .prepared = .{
            .allocator = std.testing.allocator,
            .request = .{ .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full } },
            .geometry_epoch = 1,
            .render_px = .{ .width = 1, .height = 1 },
            .cell_px = .{ .width = 1, .height = 1 },
            .grid = .{ .cols = 1, .rows = 1 },
            .text_surface = .{
                .scene = .{ .allocator = std.testing.allocator, .owned = false, .scene = .{ .clear_draws = &.{}, .background_draws = &.{}, .sprite_draws = &.{}, .decoration_draws = &.{}, .cursor_draws = &.{}, .raster_requests = &.{}, .missing = &.{}, .full_redraw = true } },
                .raster_plan = .{ .allocator = std.testing.allocator, .outputs = &.{}, .owned = false },
            },
            .render_surface_emission_failure = failure,
        },
        .state = .prepared,
    };
}

pub fn createPreparedHandle(handle: c.HowlRenderTextSessionHandle) !c.HowlRenderRdrSfcHandle {
    return createPreparedHandleWithSnapshot(handle, 1);
}

pub fn createPreparedHandleWithSnapshot(handle: c.HowlRenderTextSessionHandle, snapshot_seq: u64) !c.HowlRenderRdrSfcHandle {
    const geometry_response = surface_geometry.syncGeometry(handle, .{ .render_px = .{ .width = 16, .height = 16 }, .grid_px = .{ .width = 16, .height = 16 } });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, geometry_response.status);
    const cols = @divTrunc(geometry_response.grid_px.width, geometry_response.cell_px.width);
    const rows = @divTrunc(geometry_response.grid_px.height, geometry_response.cell_px.height);
    _ = snapshot_seq;
    const render_state = try createRenderState(rows, cols, "a");
    defer destroyRenderState(render_state);
    var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_READY, prepare_request.takePrepareRequest(handle, render_state, &request));
    var rdr_sfc_handle: c.HowlRenderRdrSfcHandle = null;
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_READY, prepared_surface.prepareHandle(handle, request, &rdr_sfc_handle));
    return rdr_sfc_handle;
}

pub fn createTestTextSessionHandle() !c.HowlRenderTextSessionHandle {
    const owner = @import("../render_session.zig").TextSessionOwner.create(std.testing.allocator, .{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 }) orelse return error.OutOfMemory;
    return @ptrCast(owner);
}

pub fn validExecutionInput() c.HowlRenderSubmitExecution {
    return .{ .host_surface = .{ .host_surface_id = 1, .width = 16, .height = 16 } };
}

pub fn nextPrepareRequest(handle: c.HowlRenderTextSessionHandle, snapshot_seq: u64) !c.HowlRenderPrepareRequest {
    _ = handle;
    return .{ .snapshot_seq = snapshot_seq, .dirty_epoch = snapshot_seq, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = damageFull() };
}

pub fn createRenderState(rows: u16, cols: u16, bytes: []const u8) !c.HowlVtRenderStateHandle {
    const terminal = c.howl_vt_terminal_init(rows, cols, 16) orelse return error.TestUnexpectedResult;
    defer c.howl_vt_terminal_deinit(terminal);
    if (bytes.len != 0) {
        const feed = c.howl_vt_terminal_feed(terminal, bytes.ptr, bytes.len);
        try std.testing.expectEqual(c.HOWL_VT_CALL_OK, feed.status);
    }
    var render_state: c.HowlVtRenderStateHandle = null;
    try std.testing.expectEqual(c.HOWL_VT_CALL_OK, c.howl_vt_render_state_init(&render_state));
    errdefer c.howl_vt_render_state_deinit(render_state);
    try std.testing.expectEqual(c.HOWL_VT_CALL_OK, c.howl_vt_render_state_update(render_state, terminal, 0));
    return render_state;
}

pub fn destroyRenderState(render_state: c.HowlVtRenderStateHandle) void {
    c.howl_vt_render_state_deinit(render_state);
}

pub fn rasterOutput(allocator: std.mem.Allocator, key: u64, width_px: u16, height_px: u16, color_mode: surface.SpriteColorMode, pixels: []u8, visual_bounds: rasterizer.SpriteBounds) rasterizer.RasterSpriteOutput {
    return .{ .allocator = allocator, .key = .{ .value = key }, .width_px = width_px, .height_px = height_px, .color_mode = color_mode, .visual_bounds = visual_bounds, .pixels = pixels };
}

pub fn damageNone() u8 {
    return @intCast(c.HOWL_RENDER_DAMAGE_NONE);
}
pub fn damagePartial() u8 {
    return @intCast(c.HOWL_RENDER_DAMAGE_PARTIAL);
}
pub fn damageFull() u8 {
    return @intCast(c.HOWL_RENDER_DAMAGE_FULL);
}

pub fn expectPrepareHandleFailedWithNullOutput(handle: c.HowlRenderTextSessionHandle, request: c.HowlRenderPrepareRequest) !void {
    var rdr_sfc_handle: c.HowlRenderRdrSfcHandle = null;
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_FAILED, prepared_surface.prepareHandle(handle, request, &rdr_sfc_handle));
    try std.testing.expect(rdr_sfc_handle == null);
}

pub const PreparedOptions = struct {
    clear_draws: []const surface.TextClearDraw = &.{},
    background_draws: []const surface.TextBackgroundDraw = &.{},
    sprite_draws: []const surface.TextSpriteDraw = &.{},
    decoration_draws: []const surface.TextDecorationDraw = &.{},
    cursor_draws: []const surface.TextCursorDraw = &.{},
    raster_outputs: []rasterizer.RasterSpriteOutput = &.{},
    width_px: u16,
    height_px: u16,
    full_redraw: bool = true,
};

pub fn preparedSurface(options: PreparedOptions) prepared_surface_model.PreparedSurface {
    return .{
        .allocator = std.testing.allocator,
        .request = .{ .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = if (options.full_redraw) 0 else 1, .damage_kind = if (options.full_redraw) .full else .partial } },
        .geometry_epoch = 1,
        .render_px = .{ .width = options.width_px, .height = options.height_px },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = options.width_px, .rows = options.height_px },
        .text_surface = .{
            .scene = .{ .allocator = std.testing.allocator, .owned = false, .scene = .{ .clear_draws = options.clear_draws, .background_draws = options.background_draws, .sprite_draws = options.sprite_draws, .decoration_draws = options.decoration_draws, .cursor_draws = options.cursor_draws, .raster_requests = &.{}, .missing = &.{}, .full_redraw = options.full_redraw } },
            .raster_plan = .{ .allocator = std.testing.allocator, .outputs = options.raster_outputs, .owned = false },
        },
        .render_surface_emission_failure = .none,
    };
}

pub fn rgba(r: u8, g: u8, b: u8, a: u8) surface.Rgba8 {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

pub fn backgroundDraw(x_px: i32, y_px: i32, width_px: u16, height_px: u16, color: surface.Rgba8) surface.TextBackgroundDraw {
    return .{ .x_px = x_px, .y_px = y_px, .width_px = width_px, .height_px = height_px, .color = color, .first_cell = 0, .cell_span = 1 };
}
