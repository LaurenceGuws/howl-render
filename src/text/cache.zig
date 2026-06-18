const std = @import("std");
const render = @import("../libhowl_render.zig");
const shape_run = @import("shape/run.zig");

pub const FaceTextKey = struct {
    face_id: u32,
    text_hash: u64,
};

pub const ShapeRunKey = struct {
    face_id: u32,
    run_hash: u64,
    cell_w_px: u16,
    cell_h_px: u16,
    baseline_px: i16,
};

pub const GlyphCellKey = struct {
    face_id: u32,
    codepoint: u32,
    cell_w_px: u16,
    cell_h_px: u16,
    baseline_px: i16,
};

pub const GlyphCellValue = struct {
    glyph_id: u32,
    advance_px: f32,
};

pub const CachedGlyph = struct {
    glyph_id: u32,
    cluster_offset: u32,
    x_offset_px: f32,
    y_offset_px: f32,
    x_advance_px: f32,
};

pub const CacheCapacityError = error{CacheFull};
pub const CachedRunCapacityError = CacheCapacityError || error{CachedRunTooLarge};

pub const FaceTextCache = struct {
    map: std.AutoHashMap(FaceTextKey, bool),
    capacity: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) FaceTextCache {
        return .{ .map = std.AutoHashMap(FaceTextKey, bool).init(allocator) };
    }

    pub fn configure(self: *FaceTextCache, capacity: u32) !void {
        if (self.capacity >= capacity) return;
        try self.map.ensureTotalCapacity(@intCast(capacity));
        self.capacity = capacity;
    }

    pub fn deinit(self: *FaceTextCache) void {
        self.map.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *FaceTextCache) void {
        self.map.clearRetainingCapacity();
    }

    pub fn put(self: *FaceTextCache, key: FaceTextKey, value: bool) !void {
        if (self.map.getPtr(key)) |stored| {
            stored.* = value;
            return;
        }
        if (self.map.count() >= self.capacity) return error.CacheFull;
        try self.map.put(key, value);
    }
};

pub const ShapeRunCache = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(ShapeRunKey, u32),
    slots: []ShapeRunSlot = &.{},
    glyph_storage: []CachedGlyph = &.{},
    capacity: u32 = 0,
    max_glyphs_per_run: u32 = 0,
    used_slots: u32 = 0,

    const ShapeRunSlot = struct {
        glyph_count: u32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) ShapeRunCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(ShapeRunKey, u32).init(allocator),
        };
    }

    pub fn configure(self: *ShapeRunCache, capacity: u32, max_glyphs_per_run: u32) !void {
        if (self.capacity >= capacity and self.max_glyphs_per_run >= max_glyphs_per_run) return;
        var next_map = std.AutoHashMap(ShapeRunKey, u32).init(self.allocator);
        errdefer next_map.deinit();
        const next_slots = try self.allocator.alloc(ShapeRunSlot, @intCast(capacity));
        errdefer self.allocator.free(next_slots);
        const next_glyph_storage = try self.allocator.alloc(CachedGlyph, glyphStorageLen(capacity, max_glyphs_per_run));
        errdefer self.allocator.free(next_glyph_storage);
        try next_map.ensureTotalCapacity(@intCast(capacity));

        self.map.deinit();
        if (self.slots.len > 0) self.allocator.free(self.slots);
        if (self.glyph_storage.len > 0) self.allocator.free(self.glyph_storage);
        self.map = next_map;
        self.slots = next_slots;
        self.glyph_storage = next_glyph_storage;
        self.capacity = capacity;
        self.max_glyphs_per_run = max_glyphs_per_run;
        self.used_slots = 0;
    }

    pub fn deinit(self: *ShapeRunCache) void {
        self.map.deinit();
        if (self.slots.len > 0) self.allocator.free(self.slots);
        if (self.glyph_storage.len > 0) self.allocator.free(self.glyph_storage);
        self.* = undefined;
    }

    pub fn clear(self: *ShapeRunCache) void {
        self.map.clearRetainingCapacity();
        self.used_slots = 0;
    }

    pub fn getOwnedRun(self: *const ShapeRunCache, allocator: std.mem.Allocator, key: ShapeRunKey, run: render.ResolvedRun) !?shape_run.OwnedShapedRun {
        const slot_index = self.map.get(key) orelse return null;
        const cached = self.slotGlyphs(slot_index);
        const glyphs = try allocator.alloc(render.GlyphInstance, cached.len);
        for (cached, 0..) |glyph, idx| {
            glyphs[idx] = .{
                .face_id = run.run.font.face_id,
                .glyph_id = glyph.glyph_id,
                .cluster_index = run.run.cluster_start + glyph.cluster_offset,
                .x_offset_px = glyph.x_offset_px,
                .y_offset_px = glyph.y_offset_px,
                .x_advance_px = glyph.x_advance_px,
            };
        }
        return .{ .allocator = allocator, .run = run, .glyphs = glyphs };
    }

    pub fn putRun(self: *ShapeRunCache, key: ShapeRunKey, run: shape_run.OwnedShapedRun) !void {
        if (run.glyphs.len > self.max_glyphs_per_run) return error.CachedRunTooLarge;

        const slot_index = if (self.map.get(key)) |existing|
            existing
        else blk: {
            if (self.map.count() >= self.capacity) return error.CacheFull;
            if (self.used_slots >= self.capacity) return error.CacheFull;
            const next_slot = self.used_slots;
            self.used_slots += 1;
            const entry = try self.map.getOrPut(key);
            std.debug.assert(!entry.found_existing);
            entry.value_ptr.* = next_slot;
            break :blk next_slot;
        };

        const slot = &self.slots[@intCast(slot_index)];
        const templates = self.slotGlyphsMut(slot_index)[0..run.glyphs.len];
        for (run.glyphs, 0..) |glyph, idx| {
            templates[idx] = .{
                .glyph_id = glyph.glyph_id,
                .cluster_offset = glyph.cluster_index - run.run.run.cluster_start,
                .x_offset_px = glyph.x_offset_px,
                .y_offset_px = glyph.y_offset_px,
                .x_advance_px = glyph.x_advance_px,
            };
        }
        slot.glyph_count = @intCast(run.glyphs.len);
    }

    fn slotGlyphs(self: *const ShapeRunCache, slot_index: u32) []const CachedGlyph {
        const slot = self.slots[@intCast(slot_index)];
        const start = @as(usize, @intCast(slot_index)) * @as(usize, @intCast(self.max_glyphs_per_run));
        const end = start + @as(usize, @intCast(slot.glyph_count));
        return self.glyph_storage[start..end];
    }

    fn slotGlyphsMut(self: *ShapeRunCache, slot_index: u32) []CachedGlyph {
        const start = @as(usize, @intCast(slot_index)) * @as(usize, @intCast(self.max_glyphs_per_run));
        const end = start + @as(usize, @intCast(self.max_glyphs_per_run));
        return self.glyph_storage[start..end];
    }
};

pub const GlyphCellCache = struct {
    map: std.AutoHashMap(GlyphCellKey, GlyphCellValue),
    capacity: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) GlyphCellCache {
        return .{ .map = std.AutoHashMap(GlyphCellKey, GlyphCellValue).init(allocator) };
    }

    pub fn configure(self: *GlyphCellCache, capacity: u32) !void {
        if (self.capacity >= capacity) return;
        try self.map.ensureTotalCapacity(@intCast(capacity));
        self.capacity = capacity;
    }

    pub fn deinit(self: *GlyphCellCache) void {
        self.map.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *GlyphCellCache) void {
        self.map.clearRetainingCapacity();
    }

    pub fn put(self: *GlyphCellCache, key: GlyphCellKey, value: GlyphCellValue) !void {
        if (self.map.getPtr(key)) |stored| {
            stored.* = value;
            return;
        }
        if (self.map.count() >= self.capacity) return error.CacheFull;
        try self.map.put(key, value);
    }
};

fn glyphStorageLen(capacity: u32, max_glyphs_per_run: u32) usize {
    const total = @as(u64, capacity) * @as(u64, max_glyphs_per_run);
    std.debug.assert(total <= std.math.maxInt(usize));
    return @intCast(total);
}

pub fn hashCellText(text: render.CellText) u64 {
    var hasher = std.hash.Wyhash.init(0x54455854);
    const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
    const len: u32 = @intCast(cps.len);
    hasher.update(std.mem.asBytes(&len));
    for (cps) |cp| hasher.update(std.mem.asBytes(&cp));
    return hasher.final();
}

pub fn hashRunText(text_cache: render.LineTextCache, clusters: []const render.CellCluster) u64 {
    var hasher = std.hash.Wyhash.init(0x52554e54);
    const len: u32 = @intCast(clusters.len);
    hasher.update(std.mem.asBytes(&len));
    for (clusters) |cluster| {
        const text = textForCluster(text_cache, cluster);
        const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
        const cp_len: u32 = @intCast(cps.len);
        hasher.update(std.mem.asBytes(&cp_len));
        for (cps) |cp| hasher.update(std.mem.asBytes(&cp));
        hasher.update(std.mem.asBytes(&cluster.cell_span));
    }
    return hasher.final();
}

fn textForCluster(text_cache: render.LineTextCache, cluster: render.CellCluster) render.CellText {
    const idx = cluster.text_id.value;
    if (idx < count32(text_cache.texts)) return text_cache.texts[@intCast(idx)];
    return .{ .id = cluster.text_id, .first_cp = cluster.first_cp, .codepoints = &.{cluster.first_cp} };
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

test "shape run cache keeps retained bounded storage" {
    var cache = ShapeRunCache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.configure(2, 3);
    try std.testing.expectEqual(@as(usize, 2), cache.slots.len);
    try std.testing.expectEqual(@as(usize, 6), cache.glyph_storage.len);

    const run_a = render.ResolvedRun{ .run = .{ .cluster_start = 4, .cluster_count = 2, .font = .{ .face_id = .{ .value = 7 }, .style = .regular, .presentation = .any } } };
    const glyphs_a = try std.testing.allocator.alloc(render.GlyphInstance, 2);
    defer std.testing.allocator.free(glyphs_a);
    glyphs_a[0] = .{ .face_id = .{ .value = 7 }, .glyph_id = 11, .cluster_index = 4, .x_advance_px = 8 };
    glyphs_a[1] = .{ .face_id = .{ .value = 7 }, .glyph_id = 12, .cluster_index = 5, .x_advance_px = 8 };
    try cache.putRun(.{ .face_id = 7, .run_hash = 1, .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .allocator = std.testing.allocator, .run = run_a, .glyphs = glyphs_a });

    const glyphs_b = try std.testing.allocator.alloc(render.GlyphInstance, 4);
    defer std.testing.allocator.free(glyphs_b);
    try std.testing.expectError(
        error.CachedRunTooLarge,
        cache.putRun(.{ .face_id = 7, .run_hash = 2, .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .allocator = std.testing.allocator, .run = run_a, .glyphs = glyphs_b }),
    );

    const glyphs_c = try std.testing.allocator.alloc(render.GlyphInstance, 1);
    defer std.testing.allocator.free(glyphs_c);
    glyphs_c[0] = .{ .face_id = .{ .value = 7 }, .glyph_id = 13, .cluster_index = 4, .x_advance_px = 8 };
    try cache.putRun(.{ .face_id = 7, .run_hash = 3, .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .allocator = std.testing.allocator, .run = run_a, .glyphs = glyphs_c });

    try std.testing.expectError(
        error.CacheFull,
        cache.putRun(.{ .face_id = 7, .run_hash = 4, .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .allocator = std.testing.allocator, .run = run_a, .glyphs = glyphs_c }),
    );
}

test "ft hb caches report capacity errors" {
    var face_cache = FaceTextCache.init(std.testing.allocator);
    defer face_cache.deinit();
    try face_cache.configure(1);
    try face_cache.put(.{ .face_id = 1, .text_hash = 11 }, true);
    try std.testing.expectError(error.CacheFull, face_cache.put(.{ .face_id = 2, .text_hash = 22 }, false));

    var glyph_cache = GlyphCellCache.init(std.testing.allocator);
    defer glyph_cache.deinit();
    try glyph_cache.configure(1);
    try glyph_cache.put(.{ .face_id = 1, .codepoint = 'a', .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .glyph_id = 33, .advance_px = 8 });
    try std.testing.expectError(
        error.CacheFull,
        glyph_cache.put(.{ .face_id = 2, .codepoint = 'b', .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .glyph_id = 34, .advance_px = 8 }),
    );
}
