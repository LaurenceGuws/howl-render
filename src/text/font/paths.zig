const std = @import("std");

pub const FallbackFontCount = u8;
pub const max_fallback_fonts: FallbackFontCount = 24;

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

pub const FontConfigError = error{ InvalidArgument, OutOfMemory };

pub const FontPaths = struct {
    allocator: std.mem.Allocator,
    primary: ?[:0]u8 = null,
    fallbacks: std.ArrayList([:0]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) FontPaths {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FontPaths) void {
        self.freePrimary();
        self.freeFallbacks(&self.fallbacks);
    }

    pub fn setPrimaryBytes(self: *FontPaths, bytes: ?[]const u8) FontConfigError!void {
        const owned = bytes orelse {
            self.setOwnedPrimary(null);
            return;
        };
        if (owned.len == 0) {
            self.setOwnedPrimary(null);
            return;
        }
        const copy = self.allocator.dupeZ(u8, owned) catch return error.OutOfMemory;
        self.setOwnedPrimary(copy);
    }

    pub fn setOwnedPrimary(self: *FontPaths, owned: ?[:0]u8) void {
        if (owned) |path| std.debug.assert(path.len > 0);
        if (self.primary) |old| {
            if (owned) |next| {
                if (old.ptr != next.ptr or old.len != next.len) self.allocator.free(old);
            } else {
                self.allocator.free(old);
            }
        }
        self.primary = owned;
    }

    pub fn setFallbackPathPtrs(self: *FontPaths, raw_paths: []const ?[*]const u8) FontConfigError!void {
        const path_count = fallbackFontCount(count32(raw_paths)) orelse return error.InvalidArgument;
        var staged = std.ArrayList([:0]u8).empty;
        defer self.freeFallbacks(&staged);
        if (path_count == 0) {
            self.adoptFallbacks(&staged);
            return;
        }
        staged.ensureTotalCapacity(self.allocator, @intCast(fallbackFontLen(path_count))) catch return error.OutOfMemory;
        var i: FallbackFontCount = 0;
        while (i < path_count) : (i += 1) {
            const raw = raw_paths[i] orelse return error.InvalidArgument;
            const owned = self.allocator.dupeZ(u8, std.mem.sliceTo(raw, 0)) catch {
                return error.OutOfMemory;
            };
            staged.appendAssumeCapacity(owned);
        }
        self.adoptFallbacks(&staged);
    }

    pub fn adoptFallbacks(self: *FontPaths, owned_paths: *std.ArrayList([:0]u8)) void {
        var old = self.fallbacks;
        self.fallbacks = owned_paths.*;
        owned_paths.* = .empty;
        self.freeFallbacks(&old);
    }

    pub fn syncPrimary(self: *const FontPaths, target: *?[:0]const u8) void {
        target.* = self.primary;
    }

    pub fn syncFallbacks(self: *const FontPaths, paths: *[max_fallback_fonts]?[:0]const u8, len: *FallbackFontCount) void {
        const count = fallbackFontCount(count32(self.fallbacks.items)) orelse unreachable;
        len.* = count;
        var slot: FallbackFontCount = 0;
        while (slot < count) : (slot += 1) {
            paths[@intCast(slot)] = self.fallbacks.items[@intCast(slot)];
        }
        while (slot < max_fallback_fonts) : (slot += 1) {
            paths[@intCast(slot)] = null;
        }
    }

    fn freePrimary(self: *FontPaths) void {
        if (self.primary) |path| self.allocator.free(path);
        self.primary = null;
    }

    fn freeFallbacks(self: *FontPaths, paths: *std.ArrayList([:0]u8)) void {
        for (paths.items) |path| self.allocator.free(path);
        paths.deinit(self.allocator);
        paths.* = .empty;
    }
};

pub fn fallbackFontCount(value: u32) ?FallbackFontCount {
    if (value > max_fallback_fonts) return null;
    return @intCast(value);
}

pub fn fallbackFontLen(value: FallbackFontCount) u32 {
    return value;
}

test "FontPaths syncPrimary keeps borrowed config pointer" {
    const primary = try std.testing.allocator.dupeZ(u8, "primary-font");
    var paths = FontPaths.init(std.testing.allocator);
    defer paths.deinit();

    var config_font: ?[:0]const u8 = null;

    paths.setOwnedPrimary(primary);
    paths.syncPrimary(&config_font);

    try std.testing.expectEqualStrings("primary-font", config_font.?);
}

test "FontPaths adoptFallbacks syncs fallback paths and clears stale slots" {
    var paths = FontPaths.init(std.testing.allocator);
    defer paths.deinit();

    var first = std.ArrayList([:0]u8).empty;
    defer first.deinit(std.testing.allocator);
    first.append(std.testing.allocator, try std.testing.allocator.dupeZ(u8, "mono")) catch return error.OutOfMemory;
    first.append(std.testing.allocator, try std.testing.allocator.dupeZ(u8, "emoji")) catch return error.OutOfMemory;
    paths.adoptFallbacks(&first);

    var sync = [_]?[:0]const u8{null} ** max_fallback_fonts;
    var sync_len: FallbackFontCount = 0;
    paths.syncFallbacks(&sync, &sync_len);

    try std.testing.expectEqual(@as(FallbackFontCount, 2), sync_len);
    try std.testing.expectEqualStrings("mono", sync[0].?);
    try std.testing.expectEqualStrings("emoji", sync[1].?);

    var second = std.ArrayList([:0]u8).empty;
    defer second.deinit(std.testing.allocator);
    second.append(std.testing.allocator, try std.testing.allocator.dupeZ(u8, "symbols")) catch return error.OutOfMemory;
    paths.adoptFallbacks(&second);

    paths.syncFallbacks(&sync, &sync_len);
    try std.testing.expectEqual(@as(FallbackFontCount, 1), sync_len);
    try std.testing.expectEqualStrings("symbols", sync[0].?);
    try std.testing.expect(sync[1] == null);
}

test "setFallbackPathPtrs rejects overflow and null entries" {
    var paths = FontPaths.init(std.testing.allocator);
    defer paths.deinit();

    var overflow_paths: [max_fallback_fonts + 1]?[*]const u8 = [_]?[*]const u8{"font".ptr} ** (max_fallback_fonts + 1);
    try std.testing.expectError(error.InvalidArgument, paths.setFallbackPathPtrs(&overflow_paths));

    const bad_paths = [_]?[*]const u8{null};
    try std.testing.expectError(error.InvalidArgument, paths.setFallbackPathPtrs(&bad_paths));
}
