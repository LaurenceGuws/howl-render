const std = @import("std");
const render = @import("../../libhowl_render.zig");
const rasterizer = @import("rasterizer.zig");

pub const StoredRaster = struct {
    pixels: []u8 = &.{},
    width_px: u16 = 0,
    height_px: u16 = 0,
    color_mode: render.SpriteColorMode = .alpha,
    visual_bounds: rasterizer.SpriteBounds = .{},

    fn deinit(self: *StoredRaster, allocator: std.mem.Allocator) void {
        if (self.pixels.len > 0) allocator.free(self.pixels);
        self.* = .{};
    }
};

pub const AtlasCapacity = u32;

pub const Entry = struct {
    key: render.SpriteKey,
    position: render.SpritePosition,
    raster: StoredRaster = .{},
};

pub const ReserveResult = struct {
    position: render.SpritePosition,
    pending: bool,
};

pub const OwnedAtlasCache = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    len: u32 = 0,
    next_slot: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: AtlasCapacity) !OwnedAtlasCache {
        return .{ .allocator = allocator, .entries = try allocator.alloc(Entry, @intCast(capacity)) };
    }

    pub fn deinit(self: *OwnedAtlasCache) void {
        for (self.entries[0..@intCast(liveLen(self))]) |*entry| entry.raster.deinit(self.allocator);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn get(self: *const OwnedAtlasCache, key: render.SpriteKey) ?render.SpritePosition {
        for (self.entries[0..@intCast(liveLen(self))]) |entry| {
            if (entry.key.value == key.value) return entry.position;
        }
        return null;
    }

    pub fn reserve(self: *OwnedAtlasCache, key: render.SpriteKey, colored: bool) ReserveResult {
        if (self.get(key)) |pos| return .{ .position = pos, .pending = !pos.rendered };
        if (self.entries.len == 0) return .{ .position = .{ .slot = 0, .key = key, .rendered = false, .colored = colored }, .pending = true };
        const len = liveLen(self);
        const idx = if (len < entryCap(self)) len else self.next_slot % entryCap(self);
        const slot = idx;
        const pos = render.SpritePosition{ .slot = slot, .key = key, .rendered = false, .colored = colored };
        if (idx < len) self.entries[@intCast(idx)].raster.deinit(self.allocator);
        self.entries[@intCast(idx)] = .{ .key = key, .position = pos };
        if (len < entryCap(self)) self.len += 1;
        self.next_slot = (slot + 1) % entryCap(self);
        return .{ .position = pos, .pending = true };
    }

    pub fn reserveRequest(self: *OwnedAtlasCache, req: render.SpriteRasterRequest) ReserveResult {
        return self.reserve(req.key, req.color_mode == .color);
    }

    pub fn markRendered(self: *OwnedAtlasCache, key: render.SpriteKey) bool {
        for (self.entries[0..@intCast(liveLen(self))]) |*entry| {
            if (entry.key.value != key.value) continue;
            entry.position.rendered = true;
            return true;
        }
        return false;
    }

    pub fn storeRendered(self: *OwnedAtlasCache, output: rasterizer.RasterSpriteOutput) !bool {
        for (self.entries[0..@intCast(liveLen(self))]) |*entry| {
            if (entry.key.value != output.key.value) continue;
            entry.raster.deinit(self.allocator);
            entry.raster.pixels = try self.allocator.dupe(u8, output.pixels);
            entry.raster.width_px = output.width_px;
            entry.raster.height_px = output.height_px;
            entry.raster.color_mode = output.color_mode;
            entry.raster.visual_bounds = output.visualBounds();
            entry.position.rendered = true;
            entry.position.colored = output.color_mode == .color;
            return true;
        }
        return false;
    }

    pub fn rasterForKey(self: *const OwnedAtlasCache, key: render.SpriteKey) ?StoredRaster {
        for (self.entries[0..@intCast(liveLen(self))]) |entry| {
            if (entry.key.value == key.value) return entry.raster;
        }
        return null;
    }

    fn liveLen(self: *const OwnedAtlasCache) u32 {
        return self.len;
    }

    fn entryCap(self: *const OwnedAtlasCache) u32 {
        return @intCast(self.entries.len);
    }
};

test "atlas cache reuses slots by sprite key" {
    var cache = try OwnedAtlasCache.init(std.testing.allocator, 4);
    defer cache.deinit();
    const first = cache.reserve(.{ .value = 11 }, false);
    const second = cache.reserve(.{ .value = 11 }, false);
    const third = cache.reserve(.{ .value = 12 }, true);
    try std.testing.expectEqual(first.position.slot, second.position.slot);
    try std.testing.expectEqual(@as(u32, 1), third.position.slot);
    try std.testing.expect(third.position.colored);
}

test "atlas cache marks entries rendered after raster" {
    var cache = try OwnedAtlasCache.init(std.testing.allocator, 4);
    defer cache.deinit();
    const pos = cache.reserve(.{ .value = 99 }, false);
    try std.testing.expect(!pos.position.rendered);
    try std.testing.expect(cache.markRendered(.{ .value = 99 }));
    try std.testing.expect(cache.get(.{ .value = 99 }).?.rendered);
}

test "atlas cache requests pending sprites until marked rendered" {
    var cache = try OwnedAtlasCache.init(std.testing.allocator, 4);
    defer cache.deinit();
    const first = cache.reserve(.{ .value = 99 }, false);
    const pending = cache.reserve(.{ .value = 99 }, false);
    try std.testing.expect(first.pending);
    try std.testing.expect(pending.pending);
    try std.testing.expectEqual(first.position.slot, pending.position.slot);
    try std.testing.expect(cache.markRendered(.{ .value = 99 }));
    const committed = cache.reserve(.{ .value = 99 }, false);
    try std.testing.expect(!committed.pending);
}

test "atlas cache stores rendered raster payload" {
    var cache = try OwnedAtlasCache.init(std.testing.allocator, 2);
    defer cache.deinit();
    _ = cache.reserve(.{ .value = 7 }, true);
    var output = rasterizer.RasterSpriteOutput{
        .allocator = std.testing.allocator,
        .key = .{ .value = 7 },
        .width_px = 2,
        .height_px = 2,
        .color_mode = .color,
        .pixels = try std.testing.allocator.dupe(u8, &[_]u8{ 1, 2, 3, 4 }),
    };
    defer output.deinit();
    try std.testing.expect(try cache.storeRendered(output));
    const stored = cache.rasterForKey(.{ .value = 7 }).?;
    try std.testing.expectEqual(@as(u32, 4), count32(stored.pixels));
    try std.testing.expect(cache.get(.{ .value = 7 }).?.rendered);
    try std.testing.expect(cache.get(.{ .value = 7 }).?.colored);
}

test "atlas cache reserve and store stay in bounds" {
    var zero = try OwnedAtlasCache.init(std.testing.allocator, 0);
    defer zero.deinit();
    const reserve = zero.reserve(.{ .value = 1 }, false);
    try std.testing.expectEqual(@as(u32, 0), reserve.position.slot);
    try std.testing.expect(reserve.pending);

    var cache = try OwnedAtlasCache.init(std.testing.allocator, 1);
    defer cache.deinit();
    var output = rasterizer.RasterSpriteOutput{
        .allocator = std.testing.allocator,
        .key = .{ .value = 404 },
        .width_px = 1,
        .height_px = 1,
        .pixels = try std.testing.allocator.dupe(u8, &[_]u8{255}),
    };
    defer output.deinit();
    try std.testing.expect(!(try cache.storeRendered(output)));
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}
