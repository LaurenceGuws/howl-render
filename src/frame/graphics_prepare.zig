const std = @import("std");
const abi = @import("../ffi_types.zig");
const stb_image = @import("../stb_image.zig");
const queue = @import("queue.zig");
const surface = @import("surface.zig");

pub const invalid_graphics_raster_index = std.math.maxInt(u32);

pub const DecodedGraphicsKey = struct {
    format: u16,
    width: u32,
    height: u32,
    payload_len: u64,
    payload_hash64: u64,
};

pub const GraphicsPublicationImageKey = struct {
    image_id: u32,
    key: DecodedGraphicsKey,
};

pub const DecodedGraphicsRaster = struct {
    key: DecodedGraphicsKey,
    width: u32,
    height: u32,
    stride: u32,
    pixels_rgba: []u8,
};

pub const GraphicsRasterView = struct {
    width: u32,
    height: u32,
    stride: u32,
    pixels_rgba: []const u8,
};

pub const SourceGraphicsPayload = struct {
    image: abi.FfiVtGraphicsImage,
    payload: []const u8,
};

pub const GraphicsPreparer = struct {
    allocator: std.mem.Allocator,
    graphics_publication_image_keys: []GraphicsPublicationImageKey = &.{},
    decoded_graphics_rasters: []DecodedGraphicsRaster = &.{},

    pub fn init(allocator: std.mem.Allocator) GraphicsPreparer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GraphicsPreparer) void {
        self.clearGraphicsCache();
    }

    pub fn clearGraphicsCache(self: *GraphicsPreparer) void {
        if (self.graphics_publication_image_keys.len > 0) self.allocator.free(self.graphics_publication_image_keys);
        self.graphics_publication_image_keys = &.{};
        for (self.decoded_graphics_rasters) |decoded_raster| {
            self.allocator.free(decoded_raster.pixels_rgba);
        }
        if (self.decoded_graphics_rasters.len > 0) self.allocator.free(self.decoded_graphics_rasters);
        self.decoded_graphics_rasters = &.{};
    }

    pub fn prepare(
        self: *GraphicsPreparer,
        prepared: *surface.PreparedGraphics,
        source_images: []const abi.FfiVtGraphicsImage,
        payload_bytes: []const u8,
    ) !void {
        try self.ensureVirtualPlacementImageRefs(prepared, source_images);
        const source_payloads = try self.sourceGraphicsPayloads(source_images, payload_bytes);
        defer self.allocator.free(source_payloads);

        var publication_keys = try self.allocator.alloc(GraphicsPublicationImageKey, source_payloads.len);
        errdefer self.allocator.free(publication_keys);
        for (source_payloads, 0..) |source_payload, i| {
            const key = graphicsKey(source_payload.image, source_payload.payload);
            publication_keys[i] = .{ .image_id = source_payload.image.image_id, .key = key };
            _ = try self.ensureDecodedGraphicsRaster(source_payload, key);
        }
        self.replaceGraphicsPublicationImageKeys(publication_keys);
        self.sweepDecodedGraphicsRasters();
        try self.bindPreparedGraphicsRasters(prepared);
    }

    fn ensureVirtualPlacementImageRefs(
        self: *GraphicsPreparer,
        prepared: *surface.PreparedGraphics,
        source_images: []const abi.FfiVtGraphicsImage,
    ) !void {
        if (prepared.virtual_placements.len == 0) return;

        var images = std.ArrayList(surface.PreparedGraphicsImageRef).empty;
        defer images.deinit(self.allocator);
        try images.appendSlice(self.allocator, prepared.images);

        for (prepared.virtual_placements) |placement| {
            if (preparedImageIndex(images.items, placement.image_id) != null) continue;
            const image = findSourceImage(source_images, placement.image_id) orelse continue;
            try images.append(self.allocator, .{
                .image_id = image.image_id,
                .width = image.width,
                .height = image.height,
                .format = image.format,
                .raster_index = invalid_graphics_raster_index,
            });
        }

        if (images.items.len == prepared.images.len) return;
        if (prepared.images.len > 0) self.allocator.free(prepared.images);
        prepared.images = try images.toOwnedSlice(self.allocator);
    }

    fn preparedImageIndex(images: []const surface.PreparedGraphicsImageRef, image_id: u32) ?u32 {
        for (images, 0..) |image, idx| {
            if (image.image_id == image_id) return std.math.cast(u32, idx) orelse unreachable;
        }
        return null;
    }

    fn findSourceImage(images: []const abi.FfiVtGraphicsImage, image_id: u32) ?abi.FfiVtGraphicsImage {
        for (images) |image| {
            if (image.image_id == image_id) return image;
        }
        return null;
    }

    pub fn preparePlaceholderGraphics(
        self: *GraphicsPreparer,
        prepared: *surface.PreparedGraphics,
        source: queue.PublicationSource,
    ) !void {
        if (source.graphics_virtual_placements.len > 0) {
            prepared.virtual_placements = try self.allocator.alloc(surface.PreparedGraphicsVirtualPlacement, source.graphics_virtual_placements.len);
            for (source.graphics_virtual_placements, 0..) |placement, i| {
                prepared.virtual_placements[i] = .{
                    .image_id = placement.image_id,
                    .placement_id = placement.placement_id,
                    .source_x = placement.source_x,
                    .source_y = placement.source_y,
                    .source_width = placement.source_width,
                    .source_height = placement.source_height,
                    .columns = placement.columns,
                    .rows = placement.rows,
                };
            }
        }

        if (source.graphics_placeholder_runs.len == 0) return;
        prepared.placeholder_runs = try self.allocator.alloc(surface.PreparedGraphicsPlaceholderRun, source.graphics_placeholder_runs.len);
        for (source.graphics_placeholder_runs, 0..) |run, idx| {
            const virtual_placement_count = std.math.cast(u32, prepared.virtual_placements.len) orelse unreachable;
            std.debug.assert(run.virtual_placement_index < virtual_placement_count);
            const virtual_placement = prepared.virtual_placements[run.virtual_placement_index];
            std.debug.assert(run.image_id == virtual_placement.image_id);
            std.debug.assert(run.placement_id == virtual_placement.placement_id);
            std.debug.assert(run.run_order == std.math.cast(u32, idx) orelse unreachable);
            prepared.placeholder_runs[idx] = .{
                .virtual_placement_index = run.virtual_placement_index,
                .run_order = run.run_order,
                .cell_row = run.cell_row,
                .cell_col = run.cell_col,
                .image_row = run.image_row,
                .image_col = run.image_col,
                .columns = run.columns,
            };
        }
    }

    pub fn raster(self: *const GraphicsPreparer, raster_index: u32) ?GraphicsRasterView {
        if (raster_index >= self.decoded_graphics_rasters.len) return null;
        const raster_ = self.decoded_graphics_rasters[raster_index];
        return .{
            .width = raster_.width,
            .height = raster_.height,
            .stride = raster_.stride,
            .pixels_rgba = raster_.pixels_rgba,
        };
    }

    fn sourceGraphicsPayloads(
        self: *GraphicsPreparer,
        source_images: []const abi.FfiVtGraphicsImage,
        payload_bytes: []const u8,
    ) ![]SourceGraphicsPayload {
        var payloads = try self.allocator.alloc(SourceGraphicsPayload, source_images.len);
        errdefer self.allocator.free(payloads);
        var offset: usize = 0;
        for (source_images, 0..) |image, i| {
            const payload_len = std.math.cast(usize, image.payload_len) orelse return error.InvalidGraphicsPayload;
            const next_offset = std.math.add(usize, offset, payload_len) catch return error.InvalidGraphicsPayload;
            if (next_offset > payload_bytes.len) return error.InvalidGraphicsPayload;
            payloads[i] = .{ .image = image, .payload = payload_bytes[offset..next_offset] };
            offset = next_offset;
        }
        if (offset != payload_bytes.len) return error.InvalidGraphicsPayload;
        return payloads;
    }

    fn replaceGraphicsPublicationImageKeys(self: *GraphicsPreparer, next: []GraphicsPublicationImageKey) void {
        if (self.graphics_publication_image_keys.len > 0) self.allocator.free(self.graphics_publication_image_keys);
        self.graphics_publication_image_keys = next;
    }

    fn ensureDecodedGraphicsRaster(self: *GraphicsPreparer, source_payload: SourceGraphicsPayload, key: DecodedGraphicsKey) !?u32 {
        if (self.findDecodedGraphicsRasterIndex(key)) |index| return index;
        const decoded = try decodeGraphicsRaster(self.allocator, source_payload, key);
        if (decoded == null) return null;
        const raster_ = decoded.?;
        const next_len = std.math.add(usize, self.decoded_graphics_rasters.len, 1) catch return error.OutOfMemory;
        var next = try self.allocator.alloc(DecodedGraphicsRaster, next_len);
        errdefer self.allocator.free(next);
        @memcpy(next[0..self.decoded_graphics_rasters.len], self.decoded_graphics_rasters);
        next[self.decoded_graphics_rasters.len] = raster_;
        if (self.decoded_graphics_rasters.len > 0) self.allocator.free(self.decoded_graphics_rasters);
        self.decoded_graphics_rasters = next;
        return std.math.cast(u32, next_len - 1) orelse return error.OutOfMemory;
    }

    fn bindPreparedGraphicsRasters(self: *GraphicsPreparer, prepared: *surface.PreparedGraphics) !void {
        const old_images = prepared.images;
        const old_placements = prepared.placements;
        const image_remap = try self.allocator.alloc(u32, old_images.len);
        defer self.allocator.free(image_remap);
        @memset(image_remap, invalid_graphics_raster_index);

        var images = std.ArrayList(surface.PreparedGraphicsImageRef).empty;
        defer images.deinit(self.allocator);
        for (old_images, 0..) |image, old_index| {
            const raster_index = self.publicationRasterIndex(image.image_id) orelse continue;
            image_remap[old_index] = std.math.cast(u32, images.items.len) orelse return error.OutOfMemory;
            try images.append(self.allocator, .{
                .image_id = image.image_id,
                .width = image.width,
                .height = image.height,
                .format = image.format,
                .raster_index = raster_index,
            });
        }

        var placements = std.ArrayList(surface.PreparedGraphicsPlacement).empty;
        defer placements.deinit(self.allocator);
        var below_bg_count: u32 = 0;
        var below_text_count: u32 = 0;
        var above_text_count: u32 = 0;
        for (old_placements) |placement| {
            const next_image_index = image_remap[placement.image_index];
            if (next_image_index == invalid_graphics_raster_index) continue;
            var next = placement;
            next.image_index = next_image_index;
            try placements.append(self.allocator, next);
            switch (placement.layer) {
                .below_bg => below_bg_count +%= 1,
                .below_text => below_text_count +%= 1,
                .above_text => above_text_count +%= 1,
            }
        }

        if (old_images.len > 0) self.allocator.free(old_images);
        if (old_placements.len > 0) self.allocator.free(old_placements);
        prepared.images = try images.toOwnedSlice(self.allocator);
        prepared.placements = try placements.toOwnedSlice(self.allocator);
        prepared.below_bg_count = below_bg_count;
        prepared.below_text_count = below_text_count;
        prepared.above_text_count = above_text_count;
    }

    fn publicationRasterIndex(self: *const GraphicsPreparer, image_id: u32) ?u32 {
        const key = self.publicationKey(image_id) orelse return null;
        return self.findDecodedGraphicsRasterIndex(key);
    }

    fn publicationKey(self: *const GraphicsPreparer, image_id: u32) ?DecodedGraphicsKey {
        for (self.graphics_publication_image_keys) |entry| {
            if (entry.image_id == image_id) return entry.key;
        }
        return null;
    }

    fn findDecodedGraphicsRasterIndex(self: *const GraphicsPreparer, key: DecodedGraphicsKey) ?u32 {
        for (self.decoded_graphics_rasters, 0..) |raster_, i| {
            if (decodedGraphicsKeyEqual(raster_.key, key)) {
                return std.math.cast(u32, i) orelse unreachable;
            }
        }
        return null;
    }

    fn sweepDecodedGraphicsRasters(self: *GraphicsPreparer) void {
        var kept = std.ArrayList(DecodedGraphicsRaster).empty;
        defer kept.deinit(self.allocator);
        for (self.decoded_graphics_rasters) |raster_| {
            if (self.publicationReferencesKey(raster_.key)) {
                kept.append(self.allocator, raster_) catch unreachable;
            } else {
                self.allocator.free(raster_.pixels_rgba);
            }
        }
        if (self.decoded_graphics_rasters.len > 0) self.allocator.free(self.decoded_graphics_rasters);
        self.decoded_graphics_rasters = kept.toOwnedSlice(self.allocator) catch unreachable;
    }

    fn publicationReferencesKey(self: *const GraphicsPreparer, key: DecodedGraphicsKey) bool {
        for (self.graphics_publication_image_keys) |entry| {
            if (decodedGraphicsKeyEqual(entry.key, key)) return true;
        }
        return false;
    }
};

pub fn graphicsKey(image: abi.FfiVtGraphicsImage, payload: []const u8) DecodedGraphicsKey {
    var hasher = std.hash.Wyhash.init(0x4752415048494353);
    hasher.update(payload);
    return .{
        .format = image.format,
        .width = image.width,
        .height = image.height,
        .payload_len = image.payload_len,
        .payload_hash64 = hasher.final(),
    };
}

pub fn decodedGraphicsKeyEqual(a: DecodedGraphicsKey, b: DecodedGraphicsKey) bool {
    return a.format == b.format and
        a.width == b.width and
        a.height == b.height and
        a.payload_len == b.payload_len and
        a.payload_hash64 == b.payload_hash64;
}

fn decodeGraphicsRaster(
    allocator: std.mem.Allocator,
    source_payload: SourceGraphicsPayload,
    key: DecodedGraphicsKey,
) !?DecodedGraphicsRaster {
    switch (source_payload.image.format) {
        24 => return try decodeRawGraphicsRaster(allocator, source_payload, key, 3),
        32 => return try decodeRawGraphicsRaster(allocator, source_payload, key, 4),
        100 => return try decodePngGraphicsRaster(allocator, source_payload, key),
        else => return null,
    }
}

fn decodePngGraphicsRaster(
    allocator: std.mem.Allocator,
    source_payload: SourceGraphicsPayload,
    key: DecodedGraphicsKey,
) !DecodedGraphicsRaster {
    const metadata_width = source_payload.image.width;
    const metadata_height = source_payload.image.height;
    const expected_stride = try graphicsBytesLen(metadata_width, 4);
    const expected_len = try graphicsBytesLen(try graphicsPixelCount(metadata_width, metadata_height), 4);
    const png_len = std.base64.standard.Decoder.calcSizeForSlice(source_payload.payload) catch return error.InvalidGraphicsPayload;
    const png_bytes = try allocator.alloc(u8, png_len);
    defer allocator.free(png_bytes);
    try std.base64.standard.Decoder.decode(png_bytes, source_payload.payload);

    const decoded = stb_image.decodeRgba(png_bytes) catch return error.InvalidGraphicsPayload;
    defer decoded.deinit(allocator);
    if (decoded.width != metadata_width) return error.InvalidGraphicsPayload;
    if (decoded.height != metadata_height) return error.InvalidGraphicsPayload;
    if (decoded.pixels_rgba.len != expected_len) return error.InvalidGraphicsPayload;
    if (decoded.stride != expected_stride) return error.InvalidGraphicsPayload;

    return .{
        .key = key,
        .width = decoded.width,
        .height = decoded.height,
        .stride = std.math.cast(u32, decoded.stride) orelse return error.InvalidGraphicsPayload,
        .pixels_rgba = try allocator.dupe(u8, decoded.pixels_rgba),
    };
}

fn decodeRawGraphicsRaster(
    allocator: std.mem.Allocator,
    source_payload: SourceGraphicsPayload,
    key: DecodedGraphicsKey,
    channels: u32,
) !DecodedGraphicsRaster {
    const pixel_count = try graphicsPixelCount(source_payload.image.width, source_payload.image.height);
    const expected_len = try graphicsBytesLen(pixel_count, channels);
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(source_payload.payload) catch return error.InvalidGraphicsPayload;
    if (decoded_len != expected_len) return error.InvalidGraphicsPayload;
    const stride = try graphicsBytesLen(source_payload.image.width, 4);
    const pixels_rgba = try allocator.alloc(u8, try graphicsBytesLen(pixel_count, 4));
    errdefer allocator.free(pixels_rgba);

    if (channels == 4) {
        try std.base64.standard.Decoder.decode(pixels_rgba, source_payload.payload);
    } else {
        const rgb = try allocator.alloc(u8, expected_len);
        defer allocator.free(rgb);
        try std.base64.standard.Decoder.decode(rgb, source_payload.payload);
        var src_index: usize = 0;
        var dst_index: usize = 0;
        while (src_index < rgb.len) : (src_index += 3) {
            pixels_rgba[dst_index] = rgb[src_index];
            pixels_rgba[dst_index + 1] = rgb[src_index + 1];
            pixels_rgba[dst_index + 2] = rgb[src_index + 2];
            pixels_rgba[dst_index + 3] = 255;
            dst_index += 4;
        }
    }

    return .{
        .key = key,
        .width = source_payload.image.width,
        .height = source_payload.image.height,
        .stride = std.math.cast(u32, stride) orelse return error.InvalidGraphicsPayload,
        .pixels_rgba = pixels_rgba,
    };
}

fn graphicsPixelCount(width: u32, height: u32) !u32 {
    return std.math.mul(u32, width, height) catch return error.InvalidGraphicsPayload;
}

fn graphicsBytesLen(left: u32, right: u32) !usize {
    const total = std.math.mul(u64, left, right) catch return error.InvalidGraphicsPayload;
    return std.math.cast(usize, total) orelse return error.InvalidGraphicsPayload;
}

test "sourceGraphicsPayloads binds exact payload slices across multiple images" {
    var preparer = GraphicsPreparer.init(std.testing.allocator);
    defer preparer.deinit();

    const images = [_]abi.FfiVtGraphicsImage{
        .{ .image_id = 1, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 2 },
        .{ .image_id = 2, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 3 },
        .{ .image_id = 3, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 1 },
    };

    const payloads = try preparer.sourceGraphicsPayloads(images[0..], "ABCDEF");
    defer std.testing.allocator.free(payloads);

    try std.testing.expectEqual(@as(usize, 3), payloads.len);
    try std.testing.expectEqual(@as(u32, 1), payloads[0].image.image_id);
    try std.testing.expectEqual(@as(u32, 2), payloads[1].image.image_id);
    try std.testing.expectEqual(@as(u32, 3), payloads[2].image.image_id);
    try std.testing.expectEqualStrings("AB", payloads[0].payload);
    try std.testing.expectEqualStrings("CDE", payloads[1].payload);
    try std.testing.expectEqualStrings("F", payloads[2].payload);
}

test "sourceGraphicsPayloads rejects trailing or truncated multi-image payload bytes" {
    var preparer = GraphicsPreparer.init(std.testing.allocator);
    defer preparer.deinit();

    const images = [_]abi.FfiVtGraphicsImage{
        .{ .image_id = 1, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 2 },
        .{ .image_id = 2, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 2 },
    };

    try std.testing.expectError(error.InvalidGraphicsPayload, preparer.sourceGraphicsPayloads(images[0..], "ABCDE"));
    try std.testing.expectError(error.InvalidGraphicsPayload, preparer.sourceGraphicsPayloads(images[0..], "ABC"));
}

test "preparePlaceholderGraphics preserves yazi-like multi-row pane-offset runs" {
    const allocator = std.testing.allocator;
    const rows: u16 = 3;
    const cols: u16 = 8;
    const cells = try allocator.alloc(abi.FfiVtCell, @as(usize, rows) * @as(usize, cols));
    defer allocator.free(cells);
    @memset(cells, std.mem.zeroes(abi.FfiVtCell));

    const dirty_rows = try allocator.dupe(u8, &.{ 1, 1, 1 });
    defer allocator.free(dirty_rows);
    const dirty_cols_start = try allocator.dupe(u16, &.{ 0, 0, 0 });
    defer allocator.free(dirty_cols_start);
    const dirty_cols_end = try allocator.dupe(u16, &.{ cols - 1, cols - 1, cols - 1 });
    defer allocator.free(dirty_cols_end);
    const virtual_placements = try allocator.dupe(abi.FfiVtGraphicsVirtualPlacement, &.{.{
        .image_id = 42 + (@as(u32, 2) << 24),
        .placement_id = 9,
        .source_x = 0,
        .source_y = 0,
        .source_width = 80,
        .source_height = 40,
        .columns = 24,
        .rows = 13,
    }});
    defer allocator.free(virtual_placements);
    const placeholder_runs = try allocator.dupe(abi.FfiVtGraphicsPlaceholderRun, &.{
        .{ .image_id = 42 + (@as(u32, 2) << 24), .placement_id = 9, .virtual_placement_index = 0, .run_order = 0, .cell_row = 0, .cell_col = 4, .image_row = 10, .image_col = 20, .columns = 3 },
        .{ .image_id = 42 + (@as(u32, 2) << 24), .placement_id = 9, .virtual_placement_index = 0, .run_order = 1, .cell_row = 1, .cell_col = 4, .image_row = 11, .image_col = 20, .columns = 3 },
        .{ .image_id = 42 + (@as(u32, 2) << 24), .placement_id = 9, .virtual_placement_index = 0, .run_order = 2, .cell_row = 2, .cell_col = 4, .image_row = 12, .image_col = 20, .columns = 3 },
    });
    defer allocator.free(placeholder_runs);

    const source: queue.PublicationSource = .{
        .cols = cols,
        .rows = rows,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells,
        .cursor = std.mem.zeroes(surface.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = std.mem.zeroes(abi.FfiVtSelection),
        .graphics = .{ .image_count = 0, .placement_count = 0, .virtual_placement_count = 1, .placeholder_run_count = 3, .is_alternate_screen = 0, .publication_seq = 0, .dirty_generation = 0 },
        .graphics_virtual_placements = virtual_placements,
        .graphics_placeholder_runs = placeholder_runs,
        .graphics_payload_bytes = &.{},
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };

    var prepared = surface.PreparedGraphics{};
    defer prepared.deinit(allocator);
    var preparer = GraphicsPreparer.init(allocator);
    defer preparer.deinit();
    try preparer.preparePlaceholderGraphics(&prepared, source);

    try std.testing.expectEqual(@as(usize, 1), prepared.virtual_placements.len);
    try std.testing.expectEqual(@as(usize, 3), prepared.placeholder_runs.len);
    try std.testing.expectEqual(@as(u32, 20), prepared.placeholder_runs[0].image_col);
    try std.testing.expectEqual(@as(u16, 4), prepared.placeholder_runs[0].cell_col);
    try std.testing.expectEqual(@as(u32, 10), prepared.placeholder_runs[0].image_row);
    try std.testing.expectEqual(@as(u32, 11), prepared.placeholder_runs[1].image_row);
    try std.testing.expectEqual(@as(u32, 12), prepared.placeholder_runs[2].image_row);
    try std.testing.expectEqual(@as(u32, 3), prepared.placeholder_runs[0].columns);
    try std.testing.expectEqual(@as(u32, 2), prepared.placeholder_runs[2].run_order);
    try std.testing.expectEqual(@as(u32, 24), prepared.virtual_placements[0].columns);
    try std.testing.expectEqual(@as(u32, 13), prepared.virtual_placements[0].rows);
}

test "preparePlaceholderGraphics consumes exported runs without cell reconstruction" {
    const allocator = std.testing.allocator;
    const cells = try allocator.alloc(abi.FfiVtCell, 3);
    defer allocator.free(cells);
    @memset(cells, std.mem.zeroes(abi.FfiVtCell));

    const dirty_rows = try allocator.dupe(u8, &.{1});
    defer allocator.free(dirty_rows);
    const dirty_cols_start = try allocator.dupe(u16, &.{0});
    defer allocator.free(dirty_cols_start);
    const dirty_cols_end = try allocator.dupe(u16, &.{2});
    defer allocator.free(dirty_cols_end);
    const virtual_placements = try allocator.dupe(abi.FfiVtGraphicsVirtualPlacement, &.{.{
        .image_id = 42 + (@as(u32, 1) << 24),
        .placement_id = 9,
        .source_x = 0,
        .source_y = 0,
        .source_width = 200,
        .source_height = 100,
        .columns = 124,
        .rows = 100,
    }});
    defer allocator.free(virtual_placements);
    const placeholder_runs = try allocator.dupe(abi.FfiVtGraphicsPlaceholderRun, &.{
        .{ .image_id = 42 + (@as(u32, 1) << 24), .placement_id = 9, .virtual_placement_index = 0, .run_order = 0, .cell_row = 0, .cell_col = 0, .image_row = 3, .image_col = 7, .columns = 1 },
        .{ .image_id = 42 + (@as(u32, 1) << 24), .placement_id = 9, .virtual_placement_index = 0, .run_order = 1, .cell_row = 0, .cell_col = 2, .image_row = 99, .image_col = 123, .columns = 1 },
    });
    defer allocator.free(placeholder_runs);

    const source: queue.PublicationSource = .{
        .cols = 3,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells,
        .cursor = std.mem.zeroes(surface.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = std.mem.zeroes(abi.FfiVtSelection),
        .graphics = .{ .image_count = 0, .placement_count = 0, .virtual_placement_count = 1, .placeholder_run_count = 2, .is_alternate_screen = 0, .publication_seq = 0, .dirty_generation = 0 },
        .graphics_virtual_placements = virtual_placements,
        .graphics_placeholder_runs = placeholder_runs,
        .graphics_payload_bytes = &.{},
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };

    var prepared = surface.PreparedGraphics{};
    defer prepared.deinit(allocator);
    var preparer = GraphicsPreparer.init(allocator);
    defer preparer.deinit();
    try preparer.preparePlaceholderGraphics(&prepared, source);

    try std.testing.expectEqual(@as(usize, 2), prepared.placeholder_runs.len);
    try std.testing.expectEqual(@as(u16, 0), prepared.placeholder_runs[0].cell_col);
    try std.testing.expectEqual(@as(u16, 2), prepared.placeholder_runs[1].cell_col);
    try std.testing.expectEqual(@as(u32, 99), prepared.placeholder_runs[1].image_row);
    try std.testing.expectEqual(@as(u32, 123), prepared.placeholder_runs[1].image_col);
    try std.testing.expectEqual(@as(u32, 1), prepared.placeholder_runs[0].columns);
    try std.testing.expectEqual(@as(u32, 1), prepared.placeholder_runs[1].columns);
}

test "preparePlaceholderGraphics preserves virtual placement binding from exported runs" {
    const allocator = std.testing.allocator;
    const cells = try allocator.alloc(abi.FfiVtCell, 3);
    defer allocator.free(cells);
    @memset(cells, std.mem.zeroes(abi.FfiVtCell));

    const dirty_rows = try allocator.dupe(u8, &.{1});
    defer allocator.free(dirty_rows);
    const dirty_cols_start = try allocator.dupe(u16, &.{0});
    defer allocator.free(dirty_cols_start);
    const dirty_cols_end = try allocator.dupe(u16, &.{2});
    defer allocator.free(dirty_cols_end);
    const virtual_placements = try allocator.dupe(abi.FfiVtGraphicsVirtualPlacement, &.{
        .{ .image_id = 42, .placement_id = 9, .source_x = 0, .source_y = 0, .source_width = 1, .source_height = 1, .columns = 1, .rows = 1 },
        .{ .image_id = 42 + (@as(u32, 2) << 24), .placement_id = 9, .source_x = 0, .source_y = 0, .source_width = 1, .source_height = 1, .columns = 1, .rows = 1 },
    });
    defer allocator.free(virtual_placements);
    const placeholder_runs = try allocator.dupe(abi.FfiVtGraphicsPlaceholderRun, &.{
        .{ .image_id = 42, .placement_id = 9, .virtual_placement_index = 0, .run_order = 0, .cell_row = 0, .cell_col = 0, .image_row = 0, .image_col = 0, .columns = 1 },
        .{ .image_id = 42 + (@as(u32, 2) << 24), .placement_id = 9, .virtual_placement_index = 1, .run_order = 1, .cell_row = 0, .cell_col = 2, .image_row = 0, .image_col = 0, .columns = 1 },
    });
    defer allocator.free(placeholder_runs);

    const source: queue.PublicationSource = .{
        .cols = 3,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells,
        .cursor = std.mem.zeroes(surface.CursorInfo),
        .colors = std.mem.zeroes(abi.FfiVtRenderColorState),
        .selection = std.mem.zeroes(abi.FfiVtSelection),
        .graphics = .{ .image_count = 0, .placement_count = 0, .virtual_placement_count = 2, .placeholder_run_count = 2, .is_alternate_screen = 0, .publication_seq = 0, .dirty_generation = 0 },
        .graphics_virtual_placements = virtual_placements,
        .graphics_placeholder_runs = placeholder_runs,
        .graphics_payload_bytes = &.{},
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };

    var prepared = surface.PreparedGraphics{};
    defer prepared.deinit(allocator);
    var preparer = GraphicsPreparer.init(allocator);
    defer preparer.deinit();
    try preparer.preparePlaceholderGraphics(&prepared, source);

    try std.testing.expectEqual(@as(usize, 2), prepared.placeholder_runs.len);
    try std.testing.expectEqual(@as(u32, 0), prepared.placeholder_runs[0].virtual_placement_index);
    try std.testing.expectEqual(@as(u32, 1), prepared.placeholder_runs[1].virtual_placement_index);
}
