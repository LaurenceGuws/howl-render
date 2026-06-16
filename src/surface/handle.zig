const std = @import("std");
const tokens = @import("../tokens.zig");
const geometry_contract = @import("../geometry_contract.zig");
const prepared_surface = @import("prepared_surface.zig");
const render_surface_emitter = @import("emitter.zig");
const render_session = @import("../render_session.zig");

pub const PreparedSurfaceHandle = ?*anyopaque;

pub const PreparedHandle = struct {
    pub const State = enum { prepared, submit_ready, released, consumed };
    const RenderSurfacePayload = render_surface_emitter.Emitter(.{});

    session_owner: *render_session.TextSessionOwner,
    prepared: prepared_surface.PreparedSurface,
    render_surface_payload: ?*RenderSurfacePayload = null,
    state: State = .prepared,
    registered: bool = false,

    pub fn create(session_owner: *render_session.TextSessionOwner, value: *prepared_surface.PreparedSurface) !*PreparedHandle {
        var prepared_handle = try session_owner.allocator.create(PreparedHandle);
        const prepared_allocator = value.allocator;
        prepared_handle.* = .{
            .session_owner = session_owner,
            .prepared = value.*,
        };
        value.* = emptyPreparedSurface(prepared_allocator);
        errdefer prepared_handle.destroy();
        try session_owner.pending_prepared.registerHandle(session_owner.allocator, prepared_handle);
        prepared_handle.emitRenderSurfacePayload() catch |err| {
            prepared_handle.prepared.render_surface_emission_failure = switch (err) {
                error.OutOfMemory => .allocation_failed,
                else => render_surface_emitter.emissionFailureFromError(@errorCast(err)),
            };
        };
        return prepared_handle;
    }

    pub fn fromHandle(handle: PreparedSurfaceHandle) ?*PreparedHandle {
        const owned = handle orelse return null;
        return @ptrCast(@alignCast(owned));
    }

    pub fn destroy(self: *PreparedHandle) void {
        if (self == &destroyed_prepared_handle_sentinel) return;
        self.detachFromSessionTracking();
        self.deinitPayload();
        std.debug.assert(self.render_surface_payload == null);
        self.session_owner.allocator.destroy(self);
    }

    pub fn release(self: *PreparedHandle) void {
        switch (self.state) {
            .released, .consumed => return,
            .prepared, .submit_ready => {
                std.debug.assert(self.render_surface_payload == null or self.state == .prepared or self.state == .submit_ready);
                self.session_owner.pending_prepared.clearCachedHandle(self);
                self.deinitPayload();
                self.state = .released;
            },
        }
    }

    pub fn isLive(self: *const PreparedHandle) bool {
        return switch (self.state) {
            .prepared, .submit_ready => true,
            .released, .consumed => false,
        };
    }

    pub fn info(self: *const PreparedHandle) prepared_surface.PreparedInfo {
        return self.prepared.info();
    }

    pub fn buffer(self: *const PreparedHandle) prepared_surface.PreparedBuffer {
        return self.prepared.buffer();
    }

    pub fn renderSurface(self: *const PreparedHandle) ?*const render_surface_emitter.Surface {
        std.debug.assert(self.isLive());
        const payload = self.render_surface_payload orelse return null;
        return payload.surface();
    }

    pub fn renderSurfaceEmissionFailure(self: *const PreparedHandle) render_surface_emitter.RenderSurfaceEmissionFailure {
        std.debug.assert(self.isLive());
        return self.prepared.render_surface_emission_failure;
    }

    pub fn preparedSurfaceToken(self: *const PreparedHandle) tokens.PreparedSurfaceToken {
        std.debug.assert(self.isLive());
        return self.prepared.preparedSurfaceToken();
    }

    pub fn belongsToSession(self: *const PreparedHandle, session_owner: *render_session.TextSessionOwner) bool {
        return self.session_owner == session_owner;
    }

    pub fn consume(self: *PreparedHandle) void {
        std.debug.assert(self.state == .prepared or self.state == .submit_ready);
        self.session_owner.pending_prepared.clearCachedHandle(self);
        self.deinitPayload();
        self.state = .consumed;
    }

    fn deinitPayload(self: *PreparedHandle) void {
        switch (self.state) {
            .released, .consumed => return,
            .prepared, .submit_ready => {},
        }
        self.prepared.deinit();
        self.freeRenderSurfacePayload();
    }

    fn detachFromSessionTracking(self: *PreparedHandle) void {
        self.session_owner.pending_prepared.detachRegisteredHandle(self);
    }

    fn emitRenderSurfacePayload(self: *PreparedHandle) !void {
        std.debug.assert(self.render_surface_payload == null);
        const payload = try self.session_owner.allocator.create(RenderSurfacePayload);
        errdefer self.session_owner.allocator.destroy(payload);
        _ = try payload.emitPreparedFresh(
            &self.session_owner.render_surface_sprite_resources,
            &self.session_owner.session,
            &self.prepared,
        );
        self.render_surface_payload = payload;
    }

    fn freeRenderSurfacePayload(self: *PreparedHandle) void {
        const payload = self.render_surface_payload orelse return;
        self.render_surface_payload = null;
        self.session_owner.allocator.destroy(payload);
        std.debug.assert(self.render_surface_payload == null);
    }
};

var destroyed_prepared_handle_sentinel: PreparedHandle = undefined;

pub fn destroyedSentinel() *PreparedHandle {
    return &destroyed_prepared_handle_sentinel;
}

fn emptyPreparedSurface(allocator: std.mem.Allocator) prepared_surface.PreparedSurface {
    return .{
        .allocator = allocator,
        .request = .{ .token = .{
            .snapshot_seq = 0,
            .dirty_epoch = 0,
            .geometry_epoch = 0,
            .damage_base_seq = 0,
            .damage_kind = .full,
        } },
        .geometry_epoch = 0,
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .text_surface = .{
            .scene = .{
                .allocator = allocator,
                .owned = false,
                .scene = .{
                    .clear_draws = &.{},
                    .background_draws = &.{},
                    .sprite_draws = &.{},
                    .decoration_draws = &.{},
                    .cursor_draws = &.{},
                    .raster_requests = &.{},
                    .missing = &.{},
                    .full_redraw = true,
                },
            },
            .raster_plan = .{ .allocator = allocator, .outputs = &.{}, .owned = false },
        },
        .render_surface_emission_failure = .none,
    };
}

pub const testing = struct {
    pub fn executionMatchesPrepared(render_px: geometry_contract.PixelSize, execution: render_session.TextSession.SubmitExecution) bool {
        return execution.host_surface.width == render_px.width and execution.host_surface.height == render_px.height;
    }
};
