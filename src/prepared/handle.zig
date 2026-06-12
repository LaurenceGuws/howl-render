const std = @import("std");
const tokens = @import("../geometry/tokens.zig");
const geometry_contract = @import("../geometry/geometry_contract.zig");
const prepared_surface = @import("surface.zig");
const render_surface_emitter = @import("render_surface_emitter.zig");
const text_session = @import("../session/text.zig");

pub const PreparedSurfaceHandle = ?*anyopaque;

fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const DebugPreparedHandleCreateTiming = struct {
    enabled_known: bool = false,
    enabled: bool = false,
    count: u64 = 0,
    alloc_ns_total: u64 = 0,
    alloc_ns_max: u64 = 0,
    register_ns_total: u64 = 0,
    register_ns_max: u64 = 0,
    emit_ns_total: u64 = 0,
    emit_ns_max: u64 = 0,

    fn active(self: *DebugPreparedHandleCreateTiming) bool {
        if (!self.enabled_known) {
            self.enabled = std.c.getenv("HOWL_RENDER_DEBUG_TIMING") != null;
            self.enabled_known = true;
        }
        return self.enabled;
    }

    fn record(self: *DebugPreparedHandleCreateTiming, alloc_ns: u64, register_ns: u64, emit_ns: u64) void {
        if (!self.active()) return;
        self.count += 1;
        self.alloc_ns_total += alloc_ns;
        self.alloc_ns_max = @max(self.alloc_ns_max, alloc_ns);
        self.register_ns_total += register_ns;
        self.register_ns_max = @max(self.register_ns_max, register_ns);
        self.emit_ns_total += emit_ns;
        self.emit_ns_max = @max(self.emit_ns_max, emit_ns);
        if (self.count % 128 != 0) return;
        std.debug.print(
            "howl-render-debug prepared_handle_create count={} alloc_avg_us={} alloc_max_us={} register_avg_us={} register_max_us={} emit_avg_us={} emit_max_us={}\n",
            .{
                self.count,
                self.alloc_ns_total / self.count / std.time.ns_per_us,
                self.alloc_ns_max / std.time.ns_per_us,
                self.register_ns_total / self.count / std.time.ns_per_us,
                self.register_ns_max / std.time.ns_per_us,
                self.emit_ns_total / self.count / std.time.ns_per_us,
                self.emit_ns_max / std.time.ns_per_us,
            },
        );
    }
};

var debug_prepared_handle_create_timing: DebugPreparedHandleCreateTiming = .{};

pub const PreparedHandle = struct {
    pub const State = enum { prepared, submit_ready, released, consumed };
    const RenderSurfacePayload = render_surface_emitter.Emitter(.{});

    session_owner: *text_session.TextSessionOwner,
    prepared: prepared_surface.PreparedSurface,
    render_surface_payload: ?*RenderSurfacePayload = null,
    state: State = .prepared,
    registered: bool = false,

    pub fn create(session_owner: *text_session.TextSessionOwner, value: *prepared_surface.PreparedSurface) !*PreparedHandle {
        const alloc_start_ns = monotonicNs();
        var prepared_handle = try session_owner.allocator.create(PreparedHandle);
        const alloc_ns = monotonicNs() -| alloc_start_ns;
        const prepared_allocator = value.allocator;
        prepared_handle.* = .{
            .session_owner = session_owner,
            .prepared = value.*,
        };
        value.* = emptyPreparedSurface(prepared_allocator);
        errdefer prepared_handle.destroy();
        const register_start_ns = monotonicNs();
        try session_owner.registerPreparedHandle(prepared_handle);
        prepared_handle.registered = true;
        const register_ns = monotonicNs() -| register_start_ns;
        const emit_start_ns = monotonicNs();
        prepared_handle.emitRenderSurfacePayload() catch |err| {
            prepared_handle.prepared.render_surface_emission_failure = switch (err) {
                error.OutOfMemory => .allocation_failed,
                else => render_surface_emitter.emissionFailureFromError(@errorCast(err)),
            };
        };
        debug_prepared_handle_create_timing.record(alloc_ns, register_ns, monotonicNs() -| emit_start_ns);
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
        self.session_owner.allocator.destroy(self);
    }

    pub fn release(self: *PreparedHandle) void {
        switch (self.state) {
            .released, .consumed => return,
            .prepared, .submit_ready => {
                self.session_owner.clearCachedPreparedHandle(self);
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

    pub fn belongsToSession(self: *const PreparedHandle, session_owner: *text_session.TextSessionOwner) bool {
        return self.session_owner == session_owner;
    }

    pub fn consume(self: *PreparedHandle) void {
        std.debug.assert(self.state == .prepared or self.state == .submit_ready);
        self.session_owner.clearCachedPreparedHandle(self);
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
        if (!self.registered) return;
        self.session_owner.clearCachedPreparedHandle(self);
        for (self.session_owner.prepared_handles.items, 0..) |prepared, index| {
            if (prepared != self) continue;
            self.session_owner.prepared_handles.items[index] = &destroyed_prepared_handle_sentinel;
            self.registered = false;
            return;
        }
        std.debug.panic("prepared handle registration missing during destroy", .{});
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
    }
};

var destroyed_prepared_handle_sentinel: PreparedHandle = undefined;

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
    pub fn executionMatchesPrepared(render_px: geometry_contract.PixelSize, execution: text_session.TextSession.SubmitExecution) bool {
        return execution.host_surface.width == render_px.width and execution.host_surface.height == render_px.height;
    }
};
