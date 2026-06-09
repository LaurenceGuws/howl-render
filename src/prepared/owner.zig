const std = @import("std");
const tokens = @import("../render/tokens.zig");
const geometry_contract = @import("../render/geometry_contract.zig");
const prepared_buffer = @import("buffer.zig");
const prepared_surface = @import("surface.zig");
const prepared_submit_result = @import("submit_result.zig");
const render_surface_emitter = @import("render_surface_emitter.zig");
const render_surface_realizer = @import("../render/render_surface_realizer.zig");
const text_session = @import("../session/text.zig");
const contract = @import("../text/contract.zig");

pub const PreparedSurfaceHandle = ?*anyopaque;

fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const DebugOwnerCreateTiming = struct {
    enabled_known: bool = false,
    enabled: bool = false,
    count: u64 = 0,
    alloc_ns_total: u64 = 0,
    alloc_ns_max: u64 = 0,
    register_ns_total: u64 = 0,
    register_ns_max: u64 = 0,
    emit_ns_total: u64 = 0,
    emit_ns_max: u64 = 0,

    fn active(self: *DebugOwnerCreateTiming) bool {
        if (!self.enabled_known) {
            self.enabled = std.c.getenv("HOWL_RENDER_DEBUG_TIMING") != null;
            self.enabled_known = true;
        }
        return self.enabled;
    }

    fn record(self: *DebugOwnerCreateTiming, alloc_ns: u64, register_ns: u64, emit_ns: u64) void {
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
            "howl-render-debug owner_create count={} alloc_avg_us={} alloc_max_us={} register_avg_us={} register_max_us={} emit_avg_us={} emit_max_us={}\n",
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

var debug_owner_create_timing: DebugOwnerCreateTiming = .{};

pub const PreparedInfo = struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    render_px: geometry_contract.PixelSize,
    cell_px: geometry_contract.CellSize,
    grid: geometry_contract.GridSize,
    damage_kind: u8,
};

pub const PreparedBuffer = struct {
    uploads_required: u64,
};

pub const RenderSurfaceEmissionFailure = enum {
    none,
    allocation_failed,
    command_bound_overflow,
    create_bound_overflow,
    damage_bound_overflow,
    retire_bound_overflow,
    resource_bound_overflow,
    upload_bound_overflow,
    upload_bytes_overflow,
    invalid_prepared_sprite,
    missing_prepared_sprite,
};

pub const Owner = struct {
    pub const State = enum { prepared, published, submit_ready, released, consumed };
    const RenderSurfacePayload = render_surface_emitter.Emitter(.{});

    session_owner: *text_session.TextSessionOwner,
    prepared: prepared_surface.PreparedSurface,
    render_surface_payload: ?*RenderSurfacePayload = null,
    state: State = .prepared,
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    render_px: geometry_contract.PixelSize,
    cell_px: geometry_contract.CellSize,
    grid: geometry_contract.GridSize,
    damage_kind: u8,
    uploads_required: u64,
    render_surface_emission_failure: RenderSurfaceEmissionFailure = .none,

    pub const SubmitResult = union(enum) {
        rendered: prepared_submit_result.SubmitResult,
        needs_prepare,
        failed,
    };

    pub fn create(session_owner: *text_session.TextSessionOwner, value: *prepared_surface.PreparedSurface) !*Owner {
        const alloc_start_ns = monotonicNs();
        var owner = try session_owner.allocator.create(Owner);
        const alloc_ns = monotonicNs() -| alloc_start_ns;
        const prepared_allocator = value.allocator;
        owner.* = ownerBase(session_owner, value.*);
        value.* = emptyPreparedSurface(prepared_allocator);
        errdefer owner.destroy();
        const register_start_ns = monotonicNs();
        try session_owner.registerPreparedHandle(owner);
        const register_ns = monotonicNs() -| register_start_ns;
        const emit_start_ns = monotonicNs();
        owner.emitRenderSurfacePayload() catch |err| {
            owner.render_surface_emission_failure = switch (err) {
                error.OutOfMemory => .allocation_failed,
                else => renderSurfaceEmissionFailureFromError(@errorCast(err)),
            };
        };
        debug_owner_create_timing.record(alloc_ns, register_ns, monotonicNs() -| emit_start_ns);
        return owner;
    }

    pub fn fromHandle(handle: PreparedSurfaceHandle) ?*Owner {
        const owned = handle orelse return null;
        return @ptrCast(@alignCast(owned));
    }

    pub fn destroy(self: *Owner) void {
        self.deinitPayload();
        self.session_owner.allocator.destroy(self);
    }

    pub fn release(self: *Owner) void {
        switch (self.state) {
            .released, .consumed => return,
            .prepared, .published, .submit_ready => {
                self.session_owner.clearCachedPreparedHandle(self);
                self.deinitPayload();
                self.state = .released;
            },
        }
    }

    pub fn isLive(self: *const Owner) bool {
        return switch (self.state) {
            .prepared, .published, .submit_ready => true,
            .released, .consumed => false,
        };
    }

    pub fn markPublished(self: *Owner) bool {
        if (self.state != .prepared) return false;
        self.state = .published;
        return true;
    }

    pub fn markSubmitReady(self: *Owner) bool {
        if (self.state != .published) return false;
        self.state = .submit_ready;
        return true;
    }

    pub fn info(self: *Owner) PreparedInfo {
        return .{
            .snapshot_seq = self.snapshot_seq,
            .dirty_epoch = self.dirty_epoch,
            .geometry_epoch = self.geometry_epoch,
            .required_base_seq = self.required_base_seq,
            .render_px = self.render_px,
            .cell_px = self.cell_px,
            .grid = self.grid,
            .damage_kind = self.damage_kind,
        };
    }

    pub fn buffer(self: *Owner) PreparedBuffer {
        return .{
            .uploads_required = self.uploads_required,
        };
    }

    pub fn renderSurface(self: *const Owner) ?*const render_surface_emitter.Surface {
        std.debug.assert(self.isLive());
        const payload = self.render_surface_payload orelse return null;
        return payload.surface();
    }

    pub fn renderSurfaceEmissionFailure(self: *const Owner) RenderSurfaceEmissionFailure {
        std.debug.assert(self.isLive());
        return self.render_surface_emission_failure;
    }

    pub fn preparedSurfaceToken(self: *const Owner) tokens.PreparedSurfaceToken {
        std.debug.assert(self.isLive());
        return self.prepared.preparedSurfaceToken();
    }

    pub fn belongsToSession(self: *const Owner, session_owner: *text_session.TextSessionOwner) bool {
        return self.session_owner == session_owner;
    }

    pub fn submitOwned(self: *Owner, session_owner: *text_session.TextSessionOwner, execution: text_session.TextSession.SubmitExecution) SubmitResult {
        if (self.state != .submit_ready) return .failed;
        return self.performSubmit(session_owner, execution);
    }

    fn performSubmit(self: *Owner, session_owner: *text_session.TextSessionOwner, execution: text_session.TextSession.SubmitExecution) SubmitResult {
        if (!self.belongsToSession(session_owner)) return .failed;
        _ = self.uploads_required;
        if (!executionMatchesPrepared(self.render_px, execution)) return .failed;
        const result = session_owner.session.submitSurface(&self.prepared, execution) catch {
            return .failed;
        };
        self.consume();
        return .{ .rendered = result };
    }

    pub fn submit(
        self: *Owner,
        session_owner: *text_session.TextSessionOwner,
        prepared_token: tokens.PreparedSurfaceToken,
        execution: text_session.TextSession.SubmitExecution,
    ) SubmitResult {
        if (self.state != .prepared) return .failed;
        if (!self.belongsToSession(session_owner)) return .failed;
        if (!samePreparedSurfaceToken(self.prepared.preparedSurfaceToken(), prepared_token)) {
            return .needs_prepare;
        }
        return self.performSubmit(session_owner, execution);
    }

    fn consume(self: *Owner) void {
        std.debug.assert(self.state == .prepared or self.state == .submit_ready);
        self.session_owner.clearCachedPreparedHandle(self);
        self.deinitPayload();
        self.state = .consumed;
    }

    fn deinitPayload(self: *Owner) void {
        switch (self.state) {
            .released, .consumed => return,
            .prepared, .published, .submit_ready => {},
        }
        self.prepared.deinit();
        self.freeRenderSurfacePayload();
    }

    fn emitRenderSurfacePayload(self: *Owner) !void {
        std.debug.assert(self.render_surface_payload == null);
        const payload = try self.session_owner.allocator.create(RenderSurfacePayload);
        payload.* = .{};
        errdefer self.session_owner.allocator.destroy(payload);
        _ = try payload.emitPreparedFresh(
            &self.session_owner.render_surface_sprite_resources,
            &self.session_owner.session,
            &self.prepared,
        );
        self.render_surface_payload = payload;
    }

    fn freeRenderSurfacePayload(self: *Owner) void {
        const payload = self.render_surface_payload orelse return;
        self.render_surface_payload = null;
        self.session_owner.allocator.destroy(payload);
    }
};

fn ownerBase(session_owner: *text_session.TextSessionOwner, value: prepared_surface.PreparedSurface) Owner {
    return .{
        .session_owner = session_owner,
        .prepared = value,
        .snapshot_seq = value.request.token.snapshot_seq,
        .dirty_epoch = value.request.token.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .required_base_seq = value.preparedSurfaceToken().required_base_seq,
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .grid = .{ .cols = value.grid.cols, .rows = value.grid.rows },
        .damage_kind = @intFromEnum(value.damageKind()),
        .uploads_required = value.text_frame.raster_plan.outputs.len,
        .render_surface_emission_failure = .none,
    };
}

fn renderSurfaceEmissionFailureFromError(err: render_surface_emitter.Error) RenderSurfaceEmissionFailure {
    return switch (err) {
        error.CommandBoundOverflow => .command_bound_overflow,
        error.CreateBoundOverflow => .create_bound_overflow,
        error.DamageBoundOverflow => .damage_bound_overflow,
        error.RetireBoundOverflow => .retire_bound_overflow,
        error.ResourceBoundOverflow => .resource_bound_overflow,
        error.UploadBoundOverflow => .upload_bound_overflow,
        error.UploadBytesOverflow => .upload_bytes_overflow,
        error.InvalidPreparedSprite => .invalid_prepared_sprite,
        error.MissingPreparedSprite => .missing_prepared_sprite,
    };
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
        .text_frame = .{
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
    };
}

fn samePreparedSurfaceToken(a: tokens.PreparedSurfaceToken, b: tokens.PreparedSurfaceToken) bool {
    return a.token.snapshot_seq == b.token.snapshot_seq and
        a.token.dirty_epoch == b.token.dirty_epoch and
        a.token.geometry_epoch == b.token.geometry_epoch and
        a.token.damage_base_seq == b.token.damage_base_seq and
        a.token.damage_kind == b.token.damage_kind and
        a.required_base_seq == b.required_base_seq;
}

fn executionMatchesPrepared(render_px: geometry_contract.PixelSize, execution: text_session.TextSession.SubmitExecution) bool {
    if (execution.host_surface.width != render_px.width) return false;
    if (execution.host_surface.height != render_px.height) return false;
    return true;
}

pub const testing = struct {
    pub fn executionMatchesPrepared(render_px: geometry_contract.PixelSize, execution: text_session.TextSession.SubmitExecution) bool {
        return @import("owner.zig").executionMatchesPrepared(render_px, execution);
    }

    pub fn renderSurfaceEmissionFailureFromError(err: render_surface_emitter.Error) RenderSurfaceEmissionFailure {
        return @import("owner.zig").renderSurfaceEmissionFailureFromError(err);
    }
};
