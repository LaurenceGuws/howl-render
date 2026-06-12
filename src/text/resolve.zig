const std = @import("std");
const contract = @import("contract.zig");

pub const ResolveStage = enum(u5) {
    blank,
    style_policy,
    codepoint_override,
    sprite_route,
    symbol_map,
    loaded_exact_match,
    regular_style_retry,
    configured_fallback,
    discovery_fallback,
    emoji_fallback,
    regular_any_presentation,
    missing_glyph,
};

pub const ResolveRequest = struct {
    codepoint: u32,
    style: contract.FontStyle,
    presentation: contract.TextPresentation,
    text_id: ?contract.CellTextId = null,
};

pub const ResolveHit = struct {
    stage: ResolveStage,
    face_id: u32,
    glyph_id: u32,
};

pub const ResolveMiss = struct {
    stage: ResolveStage,
    missing: contract.MissingGlyph,
};

pub const ResolveResult = union(enum) {
    hit: ResolveHit,
    miss: ResolveMiss,
};

pub const ResolveCounters = struct {
    missing_glyphs: u64 = 0,
    fallback_hits: u64 = 0,
    fallback_misses: u64 = 0,
    shaped_clusters: u64 = 0,
    resolved_runs: u64 = 0,
    sprite_routes: u64 = 0,
    face_checks: u64 = 0,
    face_cache_hits: u64 = 0,
    shape_requests: u64 = 0,
    shape_cache_hits: u64 = 0,
};

pub const ResolveObservability = struct {
    counters: ResolveCounters = .{},
    stage: ResolveStage = .style_policy,
};

pub const ResolveFallbackFaceFn = *const fn (ctx: *anyopaque, req: ResolveRequest) ResolveResult;

pub const ResolveFallbackFaceOp = struct {
    ctx: *anyopaque,
    call: ResolveFallbackFaceFn,

    pub fn resolve(self: ResolveFallbackFaceOp, req: ResolveRequest) ResolveResult {
        return self.call(self.ctx, req);
    }
};

test "resolve fallback face op dispatches" {
    const Stub = struct {
        hits: u8 = 0,
        last_request: ResolveRequest = undefined,

        fn resolve(ctx: *anyopaque, req: ResolveRequest) ResolveResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;
            self.last_request = req;
            return .{ .hit = .{
                .stage = if (req.style == .regular) .loaded_exact_match else .regular_style_retry,
                .face_id = 42,
                .glyph_id = req.codepoint,
            } };
        }
    };

    var stub = Stub{};
    const resolve_op = ResolveFallbackFaceOp{ .ctx = &stub, .call = Stub.resolve };
    const resolved = resolve_op.resolve(.{
        .codepoint = 'A',
        .style = .bold,
        .presentation = .any,
        .text_id = .{ .value = 7 },
    });
    try std.testing.expectEqual(@as(u8, 1), stub.hits);
    try std.testing.expectEqual(@as(u32, 'A'), stub.last_request.codepoint);
    try std.testing.expectEqual(contract.FontStyle.bold, stub.last_request.style);
    try std.testing.expectEqual(contract.TextPresentation.any, stub.last_request.presentation);
    try std.testing.expectEqual(@as(u32, 7), stub.last_request.text_id.?.value);
    switch (resolved) {
        .hit => |hit| {
            try std.testing.expectEqual(.regular_style_retry, hit.stage);
            try std.testing.expectEqual(@as(u32, 42), hit.face_id);
            try std.testing.expectEqual(@as(u32, 'A'), hit.glyph_id);
        },
        .miss => return error.UnexpectedResolveMiss,
    }
}
