const std = @import("std");
const abi = @import("../ffi_types.zig");
const stb_image = @import("../stb_image.zig");
const queue = @import("queue.zig");
const surface = @import("surface.zig");

pub const invalid_graphics_raster_index = std.math.maxInt(u32);

pub const DecodedGraphicsKey = struct {
    payload_kind: queue.GraphicsPayloadKind,
    format: u16,
    width: u32,
    height: u32,
    payload_len: u64,
    payload_hash64: u64,
};

pub const GraphicsPublicationImageKey = struct {
    image_ref_id: u32,
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
    payload_kind: queue.GraphicsPayloadKind,
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
        payload_kind: queue.GraphicsPayloadKind,
    ) !void {
        const source_payloads = try self.sourceGraphicsPayloads(source_images, payload_bytes, payload_kind);
        defer self.allocator.free(source_payloads);

        var publication_keys = try self.allocator.alloc(GraphicsPublicationImageKey, source_payloads.len);
        errdefer self.allocator.free(publication_keys);
        for (source_payloads, 0..) |source_payload, i| {
            const key = graphicsKeyForPayload(source_payload.payload_kind, source_payload.image, source_payload.payload);
            publication_keys[i] = .{ .image_ref_id = source_payload.image.image_ref_id, .key = key };
            _ = try self.ensureDecodedGraphicsRaster(source_payload, key);
        }
        self.replaceGraphicsPublicationImageKeys(publication_keys);
        self.sweepDecodedGraphicsRasters();
        try self.bindPreparedGraphicsRasters(prepared);
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
        payload_kind: queue.GraphicsPayloadKind,
    ) ![]SourceGraphicsPayload {
        var payloads = try self.allocator.alloc(SourceGraphicsPayload, source_images.len);
        errdefer self.allocator.free(payloads);
        var offset: usize = 0;
        for (source_images, 0..) |image, i| {
            const payload_len = std.math.cast(usize, image.payload_len) orelse return error.InvalidGraphicsPayload;
            const next_offset = std.math.add(usize, offset, payload_len) catch return error.InvalidGraphicsPayload;
            if (next_offset > payload_bytes.len) return error.InvalidGraphicsPayload;
            payloads[i] = .{
                .image = image,
                .payload = payload_bytes[offset..next_offset],
                .payload_kind = payload_kind,
            };
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
            const raster_index = self.publicationRasterIndex(image.image_ref_id) orelse continue;
            image_remap[old_index] = std.math.cast(u32, images.items.len) orelse return error.OutOfMemory;
            try images.append(self.allocator, .{
                .image_id = image.image_id,
                .image_ref_id = image.image_ref_id,
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

    fn publicationRasterIndex(self: *const GraphicsPreparer, image_ref_id: u32) ?u32 {
        const key = self.publicationKey(image_ref_id) orelse return null;
        return self.findDecodedGraphicsRasterIndex(key);
    }

    fn publicationKey(self: *const GraphicsPreparer, image_ref_id: u32) ?DecodedGraphicsKey {
        for (self.graphics_publication_image_keys) |entry| {
            if (entry.image_ref_id == image_ref_id) return entry.key;
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
    return graphicsKeyForPayload(.legacy_protocol, image, payload);
}

pub fn graphicsKeyForPayload(
    payload_kind: queue.GraphicsPayloadKind,
    image: abi.FfiVtGraphicsImage,
    payload: []const u8,
) DecodedGraphicsKey {
    var hasher = std.hash.Wyhash.init(0x4752415048494353);
    hasher.update(payload);
    return .{
        .payload_kind = payload_kind,
        .format = image.format,
        .width = image.width,
        .height = image.height,
        .payload_len = image.payload_len,
        .payload_hash64 = hasher.final(),
    };
}

pub fn decodedGraphicsKeyEqual(a: DecodedGraphicsKey, b: DecodedGraphicsKey) bool {
    return a.payload_kind == b.payload_kind and
        a.format == b.format and
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
    switch (source_payload.payload_kind) {
        .legacy_protocol => switch (source_payload.image.format) {
            24 => return try decodeBase64RawGraphicsRaster(allocator, source_payload, key, 3),
            32 => return try decodeBase64RawGraphicsRaster(allocator, source_payload, key, 4),
            100 => return try decodePngGraphicsRaster(allocator, source_payload, key),
            else => return null,
        },
        .decoded_pixels => switch (source_payload.image.format) {
            24 => return try decodeDecodedRawGraphicsRaster(allocator, source_payload, key, 3),
            32 => return try decodeDecodedRawGraphicsRaster(allocator, source_payload, key, 4),
            else => return error.InvalidGraphicsPayload,
        },
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

fn decodeBase64RawGraphicsRaster(
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

fn decodeDecodedRawGraphicsRaster(
    allocator: std.mem.Allocator,
    source_payload: SourceGraphicsPayload,
    key: DecodedGraphicsKey,
    channels: u32,
) !DecodedGraphicsRaster {
    const pixel_count = try graphicsPixelCount(source_payload.image.width, source_payload.image.height);
    const expected_len = try graphicsBytesLen(pixel_count, channels);
    if (source_payload.payload.len != expected_len) return error.InvalidGraphicsPayload;
    const stride = try graphicsBytesLen(source_payload.image.width, 4);
    const pixels_rgba = try allocator.alloc(u8, try graphicsBytesLen(pixel_count, 4));
    errdefer allocator.free(pixels_rgba);

    if (channels == 4) {
        @memcpy(pixels_rgba, source_payload.payload);
    } else {
        var source_index: usize = 0;
        var target_index: usize = 0;
        while (source_index < source_payload.payload.len) : (source_index += 3) {
            pixels_rgba[target_index] = source_payload.payload[source_index];
            pixels_rgba[target_index + 1] = source_payload.payload[source_index + 1];
            pixels_rgba[target_index + 2] = source_payload.payload[source_index + 2];
            pixels_rgba[target_index + 3] = 255;
            target_index += 4;
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
        .{ .image_id = 1, .image_ref_id = 10, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 2 },
        .{ .image_id = 2, .image_ref_id = 20, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 3 },
        .{ .image_id = 3, .image_ref_id = 30, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 1 },
    };

    const payloads = try preparer.sourceGraphicsPayloads(images[0..], "ABCDEF", .legacy_protocol);
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
        .{ .image_id = 1, .image_ref_id = 10, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 2 },
        .{ .image_id = 2, .image_ref_id = 20, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 2 },
    };

    try std.testing.expectError(error.InvalidGraphicsPayload, preparer.sourceGraphicsPayloads(images[0..], "ABCDE", .legacy_protocol));
    try std.testing.expectError(error.InvalidGraphicsPayload, preparer.sourceGraphicsPayloads(images[0..], "ABC", .legacy_protocol));
}

test "decoded graphics key distinguishes payload kind" {
    const image = abi.FfiVtGraphicsImage{
        .image_id = 1,
        .image_ref_id = 10,
        .image_number = 0,
        .format = 24,
        .width = 1,
        .height = 1,
        .payload_len = 3,
    };
    const legacy_key = graphicsKeyForPayload(.legacy_protocol, image, "ABC");
    const decoded_key = graphicsKeyForPayload(.decoded_pixels, image, "ABC");
    try std.testing.expect(!decodedGraphicsKeyEqual(legacy_key, decoded_key));
}

test "decoded graphics prepares raw rgb and rgba payloads" {
    var preparer = GraphicsPreparer.init(std.testing.allocator);
    defer preparer.deinit();

    var rgb_graphics = surface.PreparedGraphics{
        .publication_seq = 1,
        .images = try std.testing.allocator.dupe(surface.PreparedGraphicsImageRef, &.{.{ .image_id = 1, .image_ref_id = 10, .width = 1, .height = 1, .format = 24, .raster_index = invalid_graphics_raster_index }}),
        .placements = &.{},
    };
    defer rgb_graphics.deinit(std.testing.allocator);
    const rgb_images = [_]abi.FfiVtGraphicsImage{.{ .image_id = 1, .image_ref_id = 10, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 3 }};
    try preparer.prepare(&rgb_graphics, rgb_images[0..], &.{ 1, 2, 3 }, .decoded_pixels);
    try std.testing.expectEqual(@as(usize, 1), rgb_graphics.images.len);
    try std.testing.expectEqual(@as(u32, 10), rgb_graphics.images[0].image_ref_id);
    try std.testing.expectEqual(@as(u32, 0), rgb_graphics.images[0].raster_index);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, preparer.raster(0).?.pixels_rgba);

    var rgba_graphics = surface.PreparedGraphics{
        .publication_seq = 2,
        .images = try std.testing.allocator.dupe(surface.PreparedGraphicsImageRef, &.{.{ .image_id = 2, .image_ref_id = 20, .width = 1, .height = 1, .format = 32, .raster_index = invalid_graphics_raster_index }}),
        .placements = &.{},
    };
    defer rgba_graphics.deinit(std.testing.allocator);
    const rgba_images = [_]abi.FfiVtGraphicsImage{.{ .image_id = 2, .image_ref_id = 20, .image_number = 0, .format = 32, .width = 1, .height = 1, .payload_len = 4 }};
    try preparer.prepare(&rgba_graphics, rgba_images[0..], &.{ 4, 5, 6, 7 }, .decoded_pixels);
    try std.testing.expectEqual(@as(u32, 0), rgba_graphics.images[0].raster_index);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6, 7 }, preparer.raster(0).?.pixels_rgba);
}

test "decoded graphics rejects exact byte and format violations" {
    var preparer = GraphicsPreparer.init(std.testing.allocator);
    defer preparer.deinit();

    const images = [_]abi.FfiVtGraphicsImage{.{ .image_id = 1, .image_ref_id = 10, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 3 }};
    try std.testing.expectError(error.InvalidGraphicsPayload, preparer.sourceGraphicsPayloads(images[0..], &.{ 1, 2 }, .decoded_pixels));
    try std.testing.expectError(error.InvalidGraphicsPayload, preparer.sourceGraphicsPayloads(images[0..], &.{ 1, 2, 3, 4 }, .decoded_pixels));

    var graphics = surface.PreparedGraphics{
        .publication_seq = 1,
        .images = try std.testing.allocator.dupe(surface.PreparedGraphicsImageRef, &.{.{ .image_id = 2, .image_ref_id = 20, .width = 1, .height = 1, .format = 100, .raster_index = invalid_graphics_raster_index }}),
        .placements = &.{},
    };
    defer graphics.deinit(std.testing.allocator);
    const unsupported = [_]abi.FfiVtGraphicsImage{.{ .image_id = 2, .image_ref_id = 20, .image_number = 0, .format = 100, .width = 1, .height = 1, .payload_len = 4 }};
    try std.testing.expectError(error.InvalidGraphicsPayload, preparer.prepare(&graphics, unsupported[0..], &.{ 1, 2, 3, 4 }, .decoded_pixels));
}
