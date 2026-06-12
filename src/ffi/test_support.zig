const std = @import("std");

const ffi_root = @import("../ffi.zig");
const prepare_request = @import("prepare_request.zig");
const prepared_surface = @import("prepared_surface.zig");
const submission = @import("submission.zig");
const surface_geometry = @import("surface_geometry.zig");
const text_session = @import("text_session.zig");
const vt_surface = @import("vt_surface.zig");
const work_state = @import("work_state.zig");
const prepared_buffer_model = @import("../prepared/buffer.zig");
const prepared_handle_model = @import("../prepared/handle.zig");
const prepared_surface_model = @import("../prepared/surface.zig");
const render_surface_emitter_model = @import("../prepared/render_surface_emitter.zig");
const render_surface_realizer = @import("../geometry/render_surface_realizer.zig");
const text_contract = @import("../text/contract.zig");
const rasterizer = @import("../text/raster/rasterizer.zig");
const text_session_model = @import("../session/text.zig");

pub const c = ffi_root.c;
pub const prepare = prepare_request;
pub const prepared = prepared_surface;
pub const submit = submission;
pub const geometry = surface_geometry;
pub const text = text_session;
pub const vt = vt_surface;
pub const work = work_state;
pub const prepared_buffer = prepared_buffer_model;
pub const prepared_handle_model_ns = prepared_handle_model;
pub const prepared_surface_model_ns = prepared_surface_model;
pub const render_surface_emitter_model_ns = render_surface_emitter_model;
pub const realizer = render_surface_realizer;
pub const text_contract_ns = text_contract;
pub const text_rasterizer = rasterizer;
pub const text_session_model_ns = text_session_model;

pub const RenderVtSurfaceSlot = @field(c, "Howl" ++ "RenderVtSurfaceSlot");
pub const RenderVtSurfaceCommit = @field(c, "Howl" ++ "RenderVtSurfaceCommit");
pub const RenderSourceCell = @field(c, "Howl" ++ "RenderSourceCell");
pub const RenderSourceCellAttrs = @field(c, "Howl" ++ "RenderSourceCellAttrs");

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

pub fn validFullPreparedSurfaceToken() c.HowlRenderPreparedSurfaceToken {
    return .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .required_base_seq = 0, .damage_kind = damageFull() };
}

pub fn validPartialPreparedSurfaceToken() c.HowlRenderPreparedSurfaceToken {
    return .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .required_base_seq = 1, .damage_kind = damagePartial() };
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

pub fn validVtSurfaceCommit(snapshot_seq: u64) RenderVtSurfaceCommit {
    return .{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = snapshot_seq,
        .is_alternate_screen = 0,
        .cursor = .{ .row = 0, .col = 0, .visible = 1, .shape = 0, .blink = 0 },
        .colors = std.mem.zeroes(c.HowlRenderSourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
    };
}

pub fn createPreparedHandle(handle: c.HowlRenderTextSessionHandle) !c.HowlRenderRdrSfcHandle {
    return createPreparedHandleWithSnapshot(handle, 1);
}

pub fn createPreparedHandleWithSnapshot(handle: c.HowlRenderTextSessionHandle, snapshot_seq: u64) !c.HowlRenderRdrSfcHandle {
    const request = try nextPrepareRequest(handle, snapshot_seq);
    var rdr_sfc_handle: c.HowlRenderRdrSfcHandle = null;
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_READY, prepared_surface.prepareHandle(handle, request, &rdr_sfc_handle));
    try std.testing.expect(rdr_sfc_handle != null);
    return rdr_sfc_handle;
}

pub fn createTestTextSessionHandle() !c.HowlRenderTextSessionHandle {
    const owner = @import("../session/text.zig").TextSessionOwner.create(std.testing.allocator, .{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 }) orelse return error.OutOfMemory;
    return @ptrCast(owner);
}

pub fn preparedSurfaceTokenFromHandle(rdr_sfc_handle: c.HowlRenderRdrSfcHandle) !c.HowlRenderPreparedSurfaceToken {
    var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, prepared_surface.describe(rdr_sfc_handle, &info));
    return .{
        .snapshot_seq = info.snapshot_seq,
        .dirty_epoch = info.dirty_epoch,
        .geometry_epoch = info.geometry_epoch,
        .damage_base_seq = if (info.damage_kind == damagePartial()) info.required_base_seq else 0,
        .required_base_seq = info.required_base_seq,
        .damage_kind = info.damage_kind,
    };
}

pub fn validExecutionInput() c.HowlRenderSubmitExecution {
    return .{ .host_surface = .{ .host_surface_id = 1, .width = 16, .height = 16 } };
}

pub fn nextPrepareRequest(handle: c.HowlRenderTextSessionHandle, snapshot_seq: u64) !c.HowlRenderPrepareRequest {
    const render_px = c.HowlRenderPixelSize{ .width = 16, .height = 16 };
    const grid_px = c.HowlRenderPixelSize{ .width = 16, .height = 16 };
    const layout = surface_geometry.deriveLayout(handle, render_px, grid_px);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, layout.status);
    const sync = surface_geometry.syncGeometry(handle, .{ .render_px = render_px, .grid_px = grid_px });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, sync.status);
    var slot = std.mem.zeroes(RenderVtSurfaceSlot);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, vt_surface.reserveVtSurfaceSlot(handle, 1, 1, &slot));
    slot.cells.ptr[0] = testCell();
    slot.dirty_rows.ptr[0] = 1;
    slot.dirty_cols_start.ptr[0] = 0;
    slot.dirty_cols_end.ptr[0] = 0;
    const publish = vt_surface.commitVtSurface(handle, .{
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = snapshot_seq,
        .is_alternate_screen = 0,
        .cursor = .{ .row = 0, .col = 0, .visible = 1, .shape = 0, .blink = 0 },
        .colors = std.mem.zeroes(c.HowlRenderSourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
    });
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, publish.status);
    var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_READY, prepare_request.takePrepareRequest(handle, &request));
    return request;
}

pub fn testCell() RenderSourceCell {
    return .{ .codepoint = 'a', .flags = .{ .continuation = 0 }, .fg_color = .{ .kind = 0, .value = 0 }, .bg_color = .{ .kind = 0, .value = 0 }, .underline_color = .{ .kind = 0, .value = 0 }, .underline_style = 0, .attrs = std.mem.zeroes(RenderSourceCellAttrs), .link_id = 0 };
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

pub fn expectInvalidPreparedSurfaceTokenRejected(handle: c.HowlRenderTextSessionHandle, rdr_sfc_handle: c.HowlRenderRdrSfcHandle, prepared_token: c.HowlRenderPreparedSurfaceToken) !void {
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, submission.acceptSubmitted(handle, prepared_token));
    const execution = c.HowlRenderSubmitExecution{ .host_surface = .{ .host_surface_id = 1, .width = 1, .height = 1 } };
    try std.testing.expectEqual(c.HOWL_RENDER_SUBMIT_FAILED, submission.submit(handle, rdr_sfc_handle, prepared_token, &execution, null));
}

pub fn expectPrepareHandleFailedWithNullOutput(handle: c.HowlRenderTextSessionHandle, request: c.HowlRenderPrepareRequest) !void {
    var rdr_sfc_handle: c.HowlRenderRdrSfcHandle = null;
    try std.testing.expectEqual(c.HOWL_RENDER_PREPARE_FAILED, prepared_surface.prepareHandle(handle, request, &rdr_sfc_handle));
    try std.testing.expect(rdr_sfc_handle == null);
}

pub fn expectInvalidPublishedCell(cell: RenderSourceCell) !void {
    const handle = text_session.init(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 });
    defer text_session.deinit(handle);
    try std.testing.expect(handle != null);
    _ = surface_geometry.syncGeometry(handle, .{ .render_px = .{ .width = 16, .height = 16 }, .grid_px = .{ .width = 16, .height = 16 } });
    var slot = std.mem.zeroes(RenderVtSurfaceSlot);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, vt_surface.reserveVtSurfaceSlot(handle, 1, 1, &slot));
    slot.cells.ptr[0] = cell;
    slot.dirty_rows.ptr[0] = 1;
    slot.dirty_cols_start.ptr[0] = 0;
    slot.dirty_cols_end.ptr[0] = 0;
    const publish = vt_surface.commitVtSurface(handle, validVtSurfaceCommit(7));
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, publish.status);
    var next_slot = std.mem.zeroes(RenderVtSurfaceSlot);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, vt_surface.reserveVtSurfaceSlot(handle, 1, 1, &next_slot));
}

pub const PreparedOptions = struct {
    clear_draws: []const text_contract.TextClearDraw = &.{},
    background_draws: []const text_contract.TextBackgroundDraw = &.{},
    sprite_draws: []const text_contract.TextSpriteDraw = &.{},
    decoration_draws: []const text_contract.TextDecorationDraw = &.{},
    cursor_draws: []const text_contract.TextCursorDraw = &.{},
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

pub fn backgroundDraw(x: i32, y: i32, width: u16, height: u16, color: text_contract.Rgba8) text_contract.TextBackgroundDraw {
    return .{ .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = 0, .cell_span = 1 };
}

pub fn rgba(r: u8, g: u8, b: u8, a: u8) text_contract.Rgba8 {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
