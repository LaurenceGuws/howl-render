const std = @import("std");
const abi = @import("../ffi_types.zig");
const stb_image = @import("../stb_image.zig");
const queue = @import("queue.zig");
const surface = @import("surface.zig");

pub const invalid_graphics_raster_index = std.math.maxInt(u32);
pub const kitty_placeholder_codepoint: u21 = 0x10EEEE;
pub const kitty_placeholder_diacritics = [_]u21{
    0x0305,  0x030D,  0x030E,  0x0310,  0x0312,  0x033D,  0x033E,  0x033F,  0x0346,  0x034A,
    0x034B,  0x034C,  0x0350,  0x0351,  0x0352,  0x0357,  0x035B,  0x0363,  0x0364,  0x0365,
    0x0366,  0x0367,  0x0368,  0x0369,  0x036A,  0x036B,  0x036C,  0x036D,  0x036E,  0x036F,
    0x0483,  0x0484,  0x0485,  0x0486,  0x0487,  0x0592,  0x0593,  0x0594,  0x0595,  0x0597,
    0x0598,  0x0599,  0x059C,  0x059D,  0x059E,  0x059F,  0x05A0,  0x05A1,  0x05A8,  0x05A9,
    0x05AB,  0x05AC,  0x05AF,  0x05C4,  0x0610,  0x0611,  0x0612,  0x0613,  0x0614,  0x0615,
    0x0616,  0x0617,  0x0657,  0x0658,  0x0659,  0x065A,  0x065B,  0x065D,  0x065E,  0x06D6,
    0x06D7,  0x06D8,  0x06D9,  0x06DA,  0x06DB,  0x06DC,  0x06DF,  0x06E0,  0x06E1,  0x06E2,
    0x06E4,  0x06E7,  0x06E8,  0x06EB,  0x06EC,  0x0730,  0x0732,  0x0733,  0x0735,  0x0736,
    0x073A,  0x073D,  0x073F,  0x0740,  0x0741,  0x0743,  0x0745,  0x0747,  0x0749,  0x074A,
    0x07EB,  0x07EC,  0x07ED,  0x07EE,  0x07EF,  0x07F0,  0x07F1,  0x07F3,  0x0816,  0x0817,
    0x0818,  0x0819,  0x081B,  0x081C,  0x081D,  0x081E,  0x081F,  0x0820,  0x0821,  0x0822,
    0x0823,  0x0825,  0x0826,  0x0827,  0x0829,  0x082A,  0x082B,  0x082C,  0x082D,  0x0951,
    0x0953,  0x0954,  0x0F82,  0x0F83,  0x0F86,  0x0F87,  0x135D,  0x135E,  0x135F,  0x17DD,
    0x193A,  0x1A17,  0x1A75,  0x1A76,  0x1A77,  0x1A78,  0x1A79,  0x1A7A,  0x1A7B,  0x1A7C,
    0x1B6B,  0x1B6D,  0x1B6E,  0x1B6F,  0x1B70,  0x1B71,  0x1B72,  0x1B73,  0x1CD0,  0x1CD1,
    0x1CD2,  0x1CDA,  0x1CDB,  0x1CE0,  0x1DC0,  0x1DC1,  0x1DC3,  0x1DC4,  0x1DC5,  0x1DC6,
    0x1DC7,  0x1DC8,  0x1DC9,  0x1DCB,  0x1DCC,  0x1DD1,  0x1DD2,  0x1DD3,  0x1DD4,  0x1DD5,
    0x1DD6,  0x1DD7,  0x1DD8,  0x1DD9,  0x1DDA,  0x1DDB,  0x1DDC,  0x1DDD,  0x1DDE,  0x1DDF,
    0x1DE0,  0x1DE1,  0x1DE2,  0x1DE3,  0x1DE4,  0x1DE5,  0x1DE6,  0x1DFE,  0x20D0,  0x20D1,
    0x20D4,  0x20D5,  0x20D6,  0x20D7,  0x20DB,  0x20DC,  0x20E1,  0x20E7,  0x20E9,  0x20F0,
    0x2CEF,  0x2CF0,  0x2CF1,  0x2DE0,  0x2DE1,  0x2DE2,  0x2DE3,  0x2DE4,  0x2DE5,  0x2DE6,
    0x2DE7,  0x2DE8,  0x2DE9,  0x2DEA,  0x2DEB,  0x2DEC,  0x2DED,  0x2DEE,  0x2DEF,  0x2DF0,
    0x2DF1,  0x2DF2,  0x2DF3,  0x2DF4,  0x2DF5,  0x2DF6,  0x2DF7,  0x2DF8,  0x2DF9,  0x2DFA,
    0x2DFB,  0x2DFC,  0x2DFD,  0x2DFE,  0x2DFF,  0xA66F,  0xA67C,  0xA67D,  0xA6F0,  0xA6F1,
    0xA8E0,  0xA8E1,  0xA8E2,  0xA8E3,  0xA8E4,  0xA8E5,  0xA8E6,  0xA8E7,  0xA8E8,  0xA8E9,
    0xA8EA,  0xA8EB,  0xA8EC,  0xA8ED,  0xA8EE,  0xA8EF,  0xA8F0,  0xA8F1,  0xAAB0,  0xAAB2,
    0xAAB3,  0xAAB7,  0xAAB8,  0xAABE,  0xAABF,  0xAAC1,  0xFE20,  0xFE21,  0xFE22,  0xFE23,
    0xFE24,  0xFE25,  0xFE26,  0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187, 0x1D188, 0x1D189,
    0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
};

const PlaceholderCell = struct {
    image_id_low: u32,
    image_id_high: ?u8,
    placement_id: u32,
    row: ?u32,
    col: ?u32,
    cell_row: u16,
    cell_col: u16,

    fn imageId(self: PlaceholderCell) u32 {
        return self.image_id_low | (@as(u32, self.image_id_high orelse 0) << 24);
    }
};

const PlaceholderRun = struct {
    cell: PlaceholderCell,
    width: u32 = 1,

    fn canAppend(self: PlaceholderRun, other: PlaceholderCell) bool {
        if (self.cell.image_id_low != other.image_id_low) return false;
        if (self.cell.placement_id != other.placement_id) return false;
        if (other.row) |row| {
            if (self.cell.row == null) return false;
            if (row != self.cell.row.?) return false;
        }
        if (other.col) |col| {
            if (self.cell.col == null) return false;
            if (col != self.cell.col.? + self.width) return false;
        }
        if (other.image_id_high) |high| {
            if (self.cell.image_id_high == null) return false;
            if (high != self.cell.image_id_high.?) return false;
        }
        return true;
    }

    fn append(self: *PlaceholderRun) void {
        self.width += 1;
    }
};

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

        var runs = std.ArrayList(surface.PreparedGraphicsPlaceholderRun).empty;
        defer runs.deinit(self.allocator);

        var row: u16 = 0;
        while (row < source.rows) : (row += 1) {
            var pending: ?PlaceholderRun = null;
            var col: u16 = 0;
            while (col < source.cols) : (col += 1) {
                const cell_index = @as(usize, row) * @as(usize, source.cols) + @as(usize, col);
                const current = placeholderCellFromVtCell(source.cells[cell_index], row, col);
                if (current == null) {
                    if (pending) |run| {
                        try appendPreparedPlaceholderRun(self.allocator, prepared.virtual_placements, &runs, run);
                        pending = null;
                    }
                    continue;
                }

                var next = current.?;
                if (pending) |*run| {
                    if (run.canAppend(next)) {
                        run.append();
                        continue;
                    }
                    try appendPreparedPlaceholderRun(self.allocator, prepared.virtual_placements, &runs, run.*);
                }

                if (next.row == null) continue;
                if (next.col == null) next.col = 0;
                if (next.image_id_high == null) next.image_id_high = 0;
                pending = .{ .cell = next };
            }
            if (pending) |run| try appendPreparedPlaceholderRun(self.allocator, prepared.virtual_placements, &runs, run);
        }

        prepared.placeholder_runs = try runs.toOwnedSlice(self.allocator);
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

    fn appendPreparedPlaceholderRun(
        allocator: std.mem.Allocator,
        virtual_placements: []const surface.PreparedGraphicsVirtualPlacement,
        runs: *std.ArrayList(surface.PreparedGraphicsPlaceholderRun),
        run: PlaceholderRun,
    ) !void {
        const image_row = run.cell.row orelse return;
        const image_col = run.cell.col orelse return;
        const virtual_placement_index = findPreparedVirtualPlacementIndex(virtual_placements, run.cell.imageId(), run.cell.placement_id) orelse return;
        const virtual_placement = virtual_placements[virtual_placement_index];
        if (image_row >= virtual_placement.rows) return;
        if (image_col >= virtual_placement.columns) return;
        const remaining_columns = virtual_placement.columns - image_col;
        const columns = @min(run.width, remaining_columns);
        if (columns == 0) return;
        try runs.append(allocator, .{
            .virtual_placement_index = virtual_placement_index,
            .cell_row = run.cell.cell_row,
            .cell_col = run.cell.cell_col,
            .image_row = image_row,
            .image_col = image_col,
            .columns = columns,
        });
    }

    fn findPreparedVirtualPlacementIndex(
        virtual_placements: []const surface.PreparedGraphicsVirtualPlacement,
        image_id: u32,
        placement_id: u32,
    ) ?u32 {
        if (placement_id != 0) {
            for (virtual_placements, 0..) |placement, idx| {
                if (placement.image_id != image_id) continue;
                if (placement.placement_id != placement_id) continue;
                return std.math.cast(u32, idx) orelse unreachable;
            }
            return null;
        }
        for (virtual_placements, 0..) |placement, idx| {
            if (placement.image_id != image_id) continue;
            return std.math.cast(u32, idx) orelse unreachable;
        }
        return null;
    }

    fn placeholderCellFromVtCell(cell: abi.FfiVtCell, row: u16, col: u16) ?PlaceholderCell {
        if (cell.flags.continuation != 0) return null;
        if (cell.codepoint != kitty_placeholder_codepoint) return null;
        return .{
            .image_id_low = placeholderColorId(cell.fg_color),
            .image_id_high = placeholderHighByte(cell),
            .placement_id = placeholderColorId(cell.underline_color),
            .row = placeholderIndex(cell, 0),
            .col = placeholderIndex(cell, 1),
            .cell_row = row,
            .cell_col = col,
        };
    }

    fn placeholderHighByte(cell: abi.FfiVtCell) ?u8 {
        const value = placeholderIndex(cell, 2) orelse return null;
        return std.math.cast(u8, value);
    }

    fn placeholderIndex(cell: abi.FfiVtCell, idx: usize) ?u32 {
        if (idx >= cell.combining_len) return null;
        return placeholderDiacriticIndex(@intCast(cell.combining[idx]));
    }

    fn placeholderDiacriticIndex(cp: u21) ?u32 {
        for (kitty_placeholder_diacritics, 0..) |candidate, idx| {
            if (candidate == cp) return std.math.cast(u32, idx) orelse unreachable;
        }
        return null;
    }

    fn placeholderColorId(color: abi.FfiVtColor) u32 {
        return switch (color.kind) {
            0 => 0,
            1 => color.value & 0xFF,
            2 => color.value & 0xFFFFFF,
            else => 0,
        };
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
