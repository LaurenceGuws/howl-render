const std = @import("std");

const c = @import("../ffi.zig").c;

const DamageItem = c.HowlRenderV0DamageItem;
const ResourceId = c.HowlRenderV0ResourceId;
const Upload = c.HowlRenderV0Upload;
const Create = c.HowlRenderV0Create;
const GlyphRef = c.HowlRenderV0GlyphRef;
const Command = c.HowlRenderV0Command;
const Retire = c.HowlRenderV0Retire;
const Frame = c.HowlRenderV0Frame;

pub const Error = error{
    InvalidDamage,
    InvalidPixels,
    InvalidResource,
    InvalidSpan,
    InvalidUpload,
    MissingResource,
    RetiredResource,
    UnsupportedGlyphAtlas,
    UnsupportedGlyphRun,
    UnknownCommandKind,
    UnknownDamageKind,
    UnknownResourceKind,
    UnknownUploadFormat,
    WrongResourceGeneration,
};

pub fn realize(frame: *const Frame, pixels: []u8, base_pixels: ?[]const u8) Error!void {
    const pixels_len = try pixelsLen(frame.render_px);
    if (pixels.len != pixels_len) return error.InvalidPixels;
    try validateFrame(frame);

    if (base_pixels) |base| {
        if (base.len != pixels.len) return error.InvalidPixels;
        @memcpy(pixels, base);
    } else {
        clearSurfacePixels(pixels);
    }

    for (spanSlice(Command, frame.commands.ptr, frame.commands.count)) |command| {
        switch (command.kind) {
            c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
            => try drawSolidRect(pixels, frame.render_px, command.rect, command.color_rgba),
            c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN => return error.UnsupportedGlyphRun,
            c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE => try drawSprite(pixels, frame, command),
            else => return error.UnknownCommandKind,
        }
    }
}

fn validateFrame(frame: *const Frame) Error!void {
    if (frame.protocol_version != c.HOWL_RENDER_PROTOCOL_V0_VERSION) return error.InvalidDamage;
    try validateDamageSpan(frame);
    try validateCreateSpan(frame);
    try validateRetireSpan(frame);
    try validateUploadSpan(frame);
    try validateCommandSpan(frame);
}

fn validateDamageSpan(frame: *const Frame) Error!void {
    try validateSpan(
        frame.damage.ptr,
        frame.damage.count,
        frame.damage.count_max,
        c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX,
    );
    for (spanSlice(DamageItem, frame.damage.ptr, frame.damage.count)) |damage| {
        switch (damage.kind) {
            c.HOWL_RENDER_V0_DAMAGE_RECT => {},
            c.HOWL_RENDER_V0_DAMAGE_FULL => try validateFullDamage(frame, damage),
            else => return error.UnknownDamageKind,
        }
    }
}

fn validateFullDamage(frame: *const Frame, damage: DamageItem) Error!void {
    if (damage.rect.x_px != 0) return error.InvalidDamage;
    if (damage.rect.y_px != 0) return error.InvalidDamage;
    if (damage.rect.width_px != frame.render_px.width) return error.InvalidDamage;
    if (damage.rect.height_px != frame.render_px.height) return error.InvalidDamage;
}

fn validateCreateSpan(frame: *const Frame) Error!void {
    try validateSpan(
        frame.creates.ptr,
        frame.creates.count,
        frame.creates.count_max,
        c.HOWL_RENDER_V0_CREATES_MAX,
    );
    const creates = spanSlice(Create, frame.creates.ptr, frame.creates.count);
    for (creates, 0..) |create, create_index| {
        try validateResourceKind(create.resource.kind);
        if (isGlyphAtlas(create.resource.kind)) return error.UnsupportedGlyphAtlas;
        if (create.width_px == 0) return error.InvalidResource;
        if (create.height_px == 0) return error.InvalidResource;
        if (create.format != uploadFormatForResource(create.resource.kind)) {
            return error.InvalidUpload;
        }
        for (creates[create_index + 1 ..]) |next| {
            if (sameResource(create.resource, next.resource)) return error.InvalidResource;
            if (create.resource.value == next.resource.value) return error.InvalidResource;
        }
    }
}

fn validateRetireSpan(frame: *const Frame) Error!void {
    try validateSpan(
        frame.retires.ptr,
        frame.retires.count,
        frame.retires.count_max,
        c.HOWL_RENDER_V0_RETIRES_MAX,
    );
    const retires = spanSlice(Retire, frame.retires.ptr, frame.retires.count);
    for (retires, 0..) |retire, retire_index| {
        try validateResourceKind(retire.resource.kind);
        if (isGlyphAtlas(retire.resource.kind)) return error.UnsupportedGlyphAtlas;
        _ = findCreate(frame, retire.resource) orelse return error.MissingResource;
        for (retires[retire_index + 1 ..]) |next| {
            if (sameResource(retire.resource, next.resource)) return error.InvalidResource;
        }
    }
}

fn validateUploadSpan(frame: *const Frame) Error!void {
    try validateSpan(
        frame.uploads.ptr,
        frame.uploads.count,
        frame.uploads.count_max,
        c.HOWL_RENDER_V0_UPLOADS_MAX,
    );
    if (frame.uploads.bytes_count_max != c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX) {
        return error.InvalidSpan;
    }

    var bytes_sum: u32 = 0;
    for (spanSlice(Upload, frame.uploads.ptr, frame.uploads.count)) |upload| {
        try validateUpload(frame, upload);
        bytes_sum = std.math.add(u32, bytes_sum, upload.bytes_count) catch {
            return error.InvalidSpan;
        };
        if (bytes_sum > c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX) return error.InvalidSpan;
    }
    if (frame.uploads.bytes_count_total != bytes_sum) return error.InvalidSpan;
}

fn validateUpload(frame: *const Frame, upload: Upload) Error!void {
    try validateResourceKind(upload.resource.kind);
    try validateUploadFormat(upload.format);
    if (isGlyphAtlas(upload.resource.kind)) return error.UnsupportedGlyphAtlas;
    if (upload.rect.x_px != 0) return error.InvalidUpload;
    if (upload.rect.y_px != 0) return error.InvalidUpload;
    const create = findCreate(frame, upload.resource) orelse return error.MissingResource;
    if (isRetired(frame, upload.resource)) return error.RetiredResource;
    if (upload.format != uploadFormatForResource(upload.resource.kind)) return error.InvalidUpload;
    if (upload.rect.width_px == 0) return error.InvalidUpload;
    if (upload.rect.height_px == 0) return error.InvalidUpload;
    if (upload.bytes_ptr == null) return error.InvalidUpload;
    if (!rectFitsResource(upload.rect, create.width_px, create.height_px)) {
        return error.InvalidUpload;
    }
    const bytes_min = try uploadBytesMin(upload.rect, upload.format, upload.stride_bytes);
    if (upload.bytes_count < bytes_min) return error.InvalidUpload;
}

fn validateCommandSpan(frame: *const Frame) Error!void {
    try validateSpan(
        frame.commands.ptr,
        frame.commands.count,
        frame.commands.count_max,
        c.HOWL_RENDER_V0_COMMANDS_MAX,
    );
    for (spanSlice(Command, frame.commands.ptr, frame.commands.count)) |command| {
        try validateSpan(
            command.glyphs.ptr,
            command.glyphs.count,
            command.glyphs.count_max,
            c.HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX,
        );
        switch (command.kind) {
            c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
            => try validateFillCommand(command),
            c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN => return error.UnsupportedGlyphRun,
            c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE => try validateSpriteCommand(frame, command),
            else => return error.UnknownCommandKind,
        }
    }
}

fn validateFillCommand(command: Command) Error!void {
    if (command.rect.width_px == 0) return error.InvalidDamage;
    if (command.rect.height_px == 0) return error.InvalidDamage;
    if (command.glyphs.count != 0) return error.InvalidDamage;
    if (!resourceIsZero(command.resource)) return error.InvalidResource;
}

fn validateSpriteCommand(frame: *const Frame, command: Command) Error!void {
    if (command.rect.width_px == 0) return error.InvalidDamage;
    if (command.rect.height_px == 0) return error.InvalidDamage;
    if (command.glyphs.count != 0) return error.InvalidDamage;
    if (command.resource.kind == c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA) {
        // Alpha sprites use command color and per-pixel upload alpha.
    } else if (command.resource.kind == c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR) {
        if (command.color_rgba != 0) return error.InvalidResource;
    } else {
        try validateResourceKind(command.resource.kind);
        if (isGlyphAtlas(command.resource.kind)) return error.UnsupportedGlyphAtlas;
        return error.InvalidResource;
    }
    _ = findCreate(frame, command.resource) orelse return error.MissingResource;
    if (isRetired(frame, command.resource)) return error.RetiredResource;
    _ = findUpload(frame, command.resource) orelse return error.MissingResource;
}

fn drawSprite(pixels: []u8, frame: *const Frame, command: Command) Error!void {
    const upload = findUpload(frame, command.resource) orelse return error.MissingResource;
    const bytes_ptr = upload.bytes_ptr orelse return error.InvalidUpload;
    var yy: u16 = 0;
    while (yy < command.rect.height_px) : (yy += 1) {
        var xx: u16 = 0;
        while (xx < command.rect.width_px) : (xx += 1) {
            try drawSpritePixel(pixels, frame, command, upload, bytes_ptr, xx, yy);
        }
    }
}

fn drawSpritePixel(
    pixels: []u8,
    frame: *const Frame,
    command: Command,
    upload: Upload,
    bytes_ptr: anytype,
    xx: u16,
    yy: u16,
) Error!void {
    const dst_x = destinationCoordinate(command.rect.x_px, xx) orelse return;
    const dst_y = destinationCoordinate(command.rect.y_px, yy) orelse return;
    if (dst_x < 0) return;
    if (dst_y < 0) return;
    if (dst_x >= frame.render_px.width) return;
    if (dst_y >= frame.render_px.height) return;
    const source_index = try spriteIndex(upload, xx, yy);
    const source_end = std.math.add(u32, source_index, bytesPerPixel(upload.format)) catch {
        return error.InvalidUpload;
    };
    if (source_end > upload.bytes_count) return;
    const dst_index = try pixelIndex(frame.render_px.width, @intCast(dst_x), @intCast(dst_y));
    if (command.resource.kind == c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA) {
        const rgba = unpackRgba(command.color_rgba);
        const alpha = bytes_ptr[source_index];
        const out_alpha: u8 = @intCast((@as(u16, rgba.a) * @as(u16, alpha)) / 255);
        blendPixel(pixels, dst_index, rgba.r, rgba.g, rgba.b, out_alpha);
    } else {
        blendPixel(
            pixels,
            dst_index,
            bytes_ptr[source_index],
            bytes_ptr[source_index + 1],
            bytes_ptr[source_index + 2],
            bytes_ptr[source_index + 3],
        );
    }
}

fn drawSolidRect(
    pixels: []u8,
    render_px: c.HowlRenderPixelSize,
    command_rect: c.HowlRenderV0Rect,
    color_rgba: u32,
) Error!void {
    const color = unpackRgba(color_rgba);
    var yy: u16 = 0;
    while (yy < command_rect.height_px) : (yy += 1) {
        const dst_y = destinationCoordinate(command_rect.y_px, yy) orelse continue;
        if (dst_y < 0) continue;
        if (dst_y >= render_px.height) continue;
        var xx: u16 = 0;
        while (xx < command_rect.width_px) : (xx += 1) {
            const dst_x = destinationCoordinate(command_rect.x_px, xx) orelse continue;
            if (dst_x < 0) continue;
            if (dst_x >= render_px.width) continue;
            const index = try pixelIndex(render_px.width, @intCast(dst_x), @intCast(dst_y));
            blendPixel(pixels, index, color.r, color.g, color.b, color.a);
        }
    }
}

fn clearSurfacePixels(pixels: []u8) void {
    var index: u32 = 0;
    while (index + 3 < pixels.len) : (index += 4) {
        pixels[index] = 0;
        pixels[index + 1] = 0;
        pixels[index + 2] = 0;
        pixels[index + 3] = 255;
    }
}

fn blendPixel(pixels: []u8, dst_index: u32, r: u8, g: u8, b: u8, a: u8) void {
    std.debug.assert(dst_index + 3 < pixels.len);
    const source_alpha: u32 = a;
    const inverse_alpha: u32 = 255 - source_alpha;
    pixels[dst_index] = @intCast(
        (@as(u32, r) * source_alpha + @as(u32, pixels[dst_index]) * inverse_alpha) / 255,
    );
    pixels[dst_index + 1] = @intCast(
        (@as(u32, g) * source_alpha + @as(u32, pixels[dst_index + 1]) * inverse_alpha) / 255,
    );
    pixels[dst_index + 2] = @intCast(
        (@as(u32, b) * source_alpha + @as(u32, pixels[dst_index + 2]) * inverse_alpha) / 255,
    );
    pixels[dst_index + 3] = @intCast(@min(
        255,
        source_alpha + (@as(u32, pixels[dst_index + 3]) * inverse_alpha) / 255,
    ));
}

fn validateSpan(ptr: anytype, count: u32, count_max: u32, expected_max: u32) Error!void {
    if (count_max != expected_max) return error.InvalidSpan;
    if (count > expected_max) return error.InvalidSpan;
    if (count > 0 and ptr == null) return error.InvalidSpan;
}

fn spanSlice(comptime T: type, ptr: anytype, count: u32) []const T {
    if (count == 0) return &.{};
    return ptr[0..count];
}

fn validateResourceKind(kind: u32) Error!void {
    switch (kind) {
        c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_ALPHA,
        c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_COLOR,
        c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA,
        c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR,
        c.HOWL_RENDER_V0_RESOURCE_FALLBACK_RGBA,
        => {},
        else => return error.UnknownResourceKind,
    }
}

fn validateUploadFormat(format: u32) Error!void {
    switch (format) {
        c.HOWL_RENDER_V0_UPLOAD_ALPHA8, c.HOWL_RENDER_V0_UPLOAD_RGBA8 => {},
        else => return error.UnknownUploadFormat,
    }
}

fn uploadFormatForResource(kind: u32) u32 {
    return switch (kind) {
        c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA => c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR => c.HOWL_RENDER_V0_UPLOAD_RGBA8,
        c.HOWL_RENDER_V0_RESOURCE_FALLBACK_RGBA => c.HOWL_RENDER_V0_UPLOAD_RGBA8,
        else => 0,
    };
}

fn findCreate(frame: *const Frame, resource: ResourceId) ?Create {
    var wrong_generation = false;
    for (spanSlice(Create, frame.creates.ptr, frame.creates.count)) |create| {
        if (sameResource(create.resource, resource)) return create;
        if (create.resource.value == resource.value) wrong_generation = true;
    }
    if (wrong_generation) return null;
    return null;
}

fn findUpload(frame: *const Frame, resource: ResourceId) ?Upload {
    for (spanSlice(Upload, frame.uploads.ptr, frame.uploads.count)) |upload| {
        if (sameResource(upload.resource, resource)) return upload;
    }
    return null;
}

fn isRetired(frame: *const Frame, resource: ResourceId) bool {
    for (spanSlice(Retire, frame.retires.ptr, frame.retires.count)) |retire| {
        if (sameResource(retire.resource, resource)) return true;
    }
    return false;
}

fn sameResource(a: ResourceId, b: ResourceId) bool {
    return a.value == b.value and a.generation == b.generation and a.kind == b.kind;
}

fn resourceIsZero(resource: ResourceId) bool {
    return resource.value == 0 and resource.generation == 0 and resource.kind == 0;
}

fn isGlyphAtlas(kind: u32) bool {
    return kind == c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_ALPHA or
        kind == c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_COLOR;
}

fn rectFitsResource(upload_rect: c.HowlRenderV0Rect, width_px: u32, height_px: u32) bool {
    if (upload_rect.x_px < 0) return false;
    if (upload_rect.y_px < 0) return false;
    const rect_right = std.math.add(u32, @intCast(upload_rect.x_px), upload_rect.width_px) catch {
        return false;
    };
    const rect_bottom = std.math.add(u32, @intCast(upload_rect.y_px), upload_rect.height_px) catch {
        return false;
    };
    return rect_right <= width_px and rect_bottom <= height_px;
}

fn uploadBytesMin(upload_rect: c.HowlRenderV0Rect, format: u32, stride_bytes: u32) Error!u32 {
    const row_bytes = std.math.mul(u32, upload_rect.width_px, bytesPerPixel(format)) catch {
        return error.InvalidUpload;
    };
    if (stride_bytes < row_bytes) return error.InvalidUpload;
    return std.math.mul(u32, stride_bytes, upload_rect.height_px) catch error.InvalidUpload;
}

fn spriteIndex(upload: Upload, x: u16, y: u16) Error!u32 {
    const row_offset = std.math.mul(u32, y, upload.stride_bytes) catch {
        return error.InvalidUpload;
    };
    const column_offset = std.math.mul(u32, x, bytesPerPixel(upload.format)) catch {
        return error.InvalidUpload;
    };
    return std.math.add(u32, row_offset, column_offset) catch error.InvalidUpload;
}

fn destinationCoordinate(origin: i32, offset: u16) ?i32 {
    return std.math.add(i32, origin, offset) catch null;
}

fn bytesPerPixel(format: u32) u32 {
    return if (format == c.HOWL_RENDER_V0_UPLOAD_ALPHA8) 1 else 4;
}

fn pixelsLen(render_px: c.HowlRenderPixelSize) Error!usize {
    if (render_px.width == 0) return error.InvalidPixels;
    if (render_px.height == 0) return error.InvalidPixels;
    const pixels = std.math.mul(usize, render_px.width, render_px.height) catch {
        return error.InvalidPixels;
    };
    return std.math.mul(usize, pixels, 4) catch error.InvalidPixels;
}

fn pixelIndex(width: u16, x: u16, y: u16) Error!u32 {
    const row = std.math.mul(u32, y, width) catch return error.InvalidPixels;
    const pixel = std.math.add(u32, row, x) catch return error.InvalidPixels;
    return std.math.mul(u32, pixel, 4) catch error.InvalidPixels;
}

const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

fn unpackRgba(color_rgba: u32) Rgba {
    return .{
        .r = @intCast((color_rgba >> 24) & 0xff),
        .g = @intCast((color_rgba >> 16) & 0xff),
        .b = @intCast((color_rgba >> 8) & 0xff),
        .a = @intCast(color_rgba & 0xff),
    };
}

test "protocol v0 constants match documented kind values" {
    try std.testing.expectEqual(@as(u8, 1), c.HOWL_RENDER_V0_DAMAGE_RECT);
    try std.testing.expectEqual(@as(u8, 2), c.HOWL_RENDER_V0_DAMAGE_FULL);
    try std.testing.expectEqual(@as(u32, 1), c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_ALPHA);
    try std.testing.expectEqual(@as(u32, 2), c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_COLOR);
    try std.testing.expectEqual(@as(u32, 3), c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    try std.testing.expectEqual(@as(u32, 4), c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR);
    try std.testing.expectEqual(@as(u32, 5), c.HOWL_RENDER_V0_RESOURCE_FALLBACK_RGBA);
    try std.testing.expectEqual(@as(u32, 1), c.HOWL_RENDER_V0_UPLOAD_ALPHA8);
    try std.testing.expectEqual(@as(u32, 2), c.HOWL_RENDER_V0_UPLOAD_RGBA8);
    try std.testing.expectEqual(@as(u8, 1), c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT);
    try std.testing.expectEqual(@as(u8, 2), c.HOWL_RENDER_V0_COMMAND_FILL_RECT);
    try std.testing.expectEqual(@as(u8, 3), c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN);
    try std.testing.expectEqual(@as(u8, 4), c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE);
}

test "protocol v0 realizer clears and fills in command order" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_V0_COMMAND_FILL_RECT, makeRect(0, 0, 2, 1), 0xff0000ff),
        fillCommand(c.HOWL_RENDER_V0_COMMAND_FILL_RECT, makeRect(1, 0, 1, 1), 0x0000ffff),
    };
    var pixels: [8]u8 = undefined;
    var frame = testFrame(2, 1);
    frame.commands = commandSpan(&commands);
    try realize(&frame, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 0, .g = 0, .b = 255, .a = 255 });
}

test "protocol v0 realizer preserves retained base outside commands" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_V0_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0x010203ff),
    };
    var base = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 };
    var pixels: [8]u8 = undefined;
    var frame = testFrame(2, 1);
    frame.commands = commandSpan(&commands);
    try realize(&frame, &pixels, &base);
    try expectPixel(&pixels, 0, .{ .r = 1, .g = 2, .b = 3, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 5, .g = 4, .b = 3, .a = 2 });
}

test "protocol v0 realizer draws alpha sprite bytes" {
    const resource = spriteAlphaResource(1, 1);
    var creates = [_]Create{createResource(resource, 2, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    var bytes = [_]u8{ 255, 128 };
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 1), &bytes, 2)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 2, 1), 0xff000080)};
    var pixels: [8]u8 = undefined;
    var frame = testFrame(2, 1);
    frame.creates = createSpan(&creates);
    frame.uploads = uploadSpan(&uploads, bytes.len);
    frame.commands = commandSpan(&commands);
    try realize(&frame, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 128, .g = 0, .b = 0, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 64, .g = 0, .b = 0, .a = 255 });
}

test "protocol v0 realizer draws color sprite bytes" {
    const resource = spriteColorResource(2, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_RGBA8)};
    var bytes = [_]u8{ 0, 255, 0, 128 };
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 4)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0)};
    var pixels: [4]u8 = undefined;
    var frame = testFrame(1, 1);
    frame.creates = createSpan(&creates);
    frame.uploads = uploadSpan(&uploads, bytes.len);
    frame.commands = commandSpan(&commands);
    try realize(&frame, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 0, .g = 128, .b = 0, .a = 255 });
}

test "protocol v0 realizer rejects glyph run command" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN, makeRect(0, 0, 0, 0), 0),
    };
    try expectRejectWithCommands(&commands, error.UnsupportedGlyphRun);
}

test "protocol v0 realizer rejects glyph atlas resources" {
    const resource = glyphAtlasAlphaResource(1, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    try expectRejectWithCreates(&creates, error.UnsupportedGlyphAtlas);
}

test "protocol v0 rejects unknown command kind" {
    var commands = [_]Command{fillCommand(255, makeRect(0, 0, 0, 0), 0)};
    try expectRejectWithCommands(&commands, error.UnknownCommandKind);
}

test "protocol v0 rejects unknown damage kind" {
    var damage = [_]DamageItem{.{ .kind = 255, .rect = makeRect(0, 0, 1, 1) }};
    var frame = testFrame(1, 1);
    frame.damage = damageSpan(&damage, c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX);
    try expectReject(&frame, error.UnknownDamageKind);
}

test "protocol v0 rejects unknown resource kind" {
    const resource = ResourceId{ .value = 1, .generation = 1, .kind = 255 };
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_RGBA8)};
    try expectRejectWithCreates(&creates, error.UnknownResourceKind);
}

test "protocol v0 rejects unknown upload format" {
    const resource = spriteAlphaResource(1, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{
        uploadResourceWithFormat(resource, makeRect(0, 0, 1, 1), &bytes, 1, 255),
    };
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.UnknownUploadFormat);
}

test "protocol v0 rejects zero command width" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT, makeRect(0, 0, 0, 1), 0),
    };
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "protocol v0 rejects zero command height" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_V0_COMMAND_FILL_RECT, makeRect(0, 0, 1, 0), 0),
    };
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "protocol v0 rejects damage span overflow" {
    var frame = testFrame(1, 1);
    frame.damage.count = c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX + 1;
    try expectReject(&frame, error.InvalidSpan);
}

test "protocol v0 rejects upload span overflow" {
    var frame = testFrame(1, 1);
    frame.uploads.count = c.HOWL_RENDER_V0_UPLOADS_MAX + 1;
    try expectReject(&frame, error.InvalidSpan);
}

test "protocol v0 rejects command span overflow" {
    var frame = testFrame(1, 1);
    frame.commands.count = c.HOWL_RENDER_V0_COMMANDS_MAX + 1;
    try expectReject(&frame, error.InvalidSpan);
}

test "protocol v0 rejects glyph span overflow" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_V0_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0),
    };
    commands[0].glyphs.count = c.HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX + 1;
    try expectRejectWithCommands(&commands, error.InvalidSpan);
}

test "protocol v0 rejects alpha upload to color sprite" {
    const resource = spriteColorResource(1, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_RGBA8)};
    var uploads = [_]Upload{
        uploadResourceWithFormat(
            resource,
            makeRect(0, 0, 1, 1),
            &bytes,
            1,
            c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        ),
    };
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "protocol v0 rejects rgba upload to alpha sprite" {
    const resource = spriteAlphaResource(1, 1);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{
        uploadResourceWithFormat(
            resource,
            makeRect(0, 0, 1, 1),
            &bytes,
            4,
            c.HOWL_RENDER_V0_UPLOAD_RGBA8,
        ),
    };
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "protocol v0 rejects upload before create" {
    const resource = spriteAlphaResource(77, 1);
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var frame = testFrame(1, 1);
    frame.uploads = uploadSpan(&uploads, bytes.len);
    try expectReject(&frame, error.MissingResource);
}

test "protocol v0 rejects missing sprite command resource" {
    const resource = spriteAlphaResource(78, 1);
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    try expectRejectWithCommands(&commands, error.MissingResource);
}

test "protocol v0 rejects wrong generation sprite use" {
    const created = spriteAlphaResource(79, 1);
    const used = spriteAlphaResource(79, 2);
    var creates = [_]Create{createResource(created, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    var commands = [_]Command{spriteCommand(used, makeRect(0, 0, 1, 1), 0xffffffff)};
    try expectRejectWithCreatesCommands(&creates, &commands, error.MissingResource);
}

test "protocol v0 rejects retired sprite use" {
    const resource = spriteAlphaResource(80, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    var retires = [_]Retire{.{ .resource = resource }};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var frame = testFrame(1, 1);
    frame.creates = createSpan(&creates);
    frame.retires = retireSpan(&retires);
    frame.commands = commandSpan(&commands);
    try expectReject(&frame, error.RetiredResource);
}

test "protocol v0 rejects color sprite command color" {
    const resource = spriteColorResource(1, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_RGBA8)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0x01020304)};
    try expectRejectWithCreatesCommands(&creates, &commands, error.InvalidResource);
}

test "protocol v0 rejects sprite command glyph span" {
    const resource = spriteAlphaResource(1, 1);
    var glyphs = [_]GlyphRef{.{}};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    commands[0].glyphs = .{
        .ptr = &glyphs,
        .count = 1,
        .count_max = c.HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX,
    };
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "protocol v0 rejects fill command resource" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_V0_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0),
    };
    commands[0].resource.value = 1;
    try expectRejectWithCommands(&commands, error.InvalidResource);
}

test "protocol v0 rejects glyph atlas create" {
    const resource = glyphAtlasAlphaResource(1, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    try expectRejectWithCreates(&creates, error.UnsupportedGlyphAtlas);
}

test "protocol v0 rejects glyph atlas upload" {
    const resource = glyphAtlasColorResource(1, 1);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var uploads = [_]Upload{
        uploadResourceWithFormat(
            resource,
            makeRect(0, 0, 1, 1),
            &bytes,
            4,
            c.HOWL_RENDER_V0_UPLOAD_RGBA8,
        ),
    };
    var frame = testFrame(1, 1);
    frame.uploads = uploadSpan(&uploads, bytes.len);
    try expectReject(&frame, error.UnsupportedGlyphAtlas);
}

test "protocol v0 rejects blocked glyph run" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN, makeRect(0, 0, 0, 0), 0),
    };
    try expectRejectWithCommands(&commands, error.UnsupportedGlyphRun);
}

test "protocol v0 rejects duplicate creates" {
    const resource = spriteAlphaResource(81, 1);
    var creates = [_]Create{
        createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8),
        createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8),
    };
    try expectRejectWithCreates(&creates, error.InvalidResource);
}

test "protocol v0 rejects duplicate retires" {
    const resource = spriteAlphaResource(82, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    var retires = [_]Retire{ .{ .resource = resource }, .{ .resource = resource } };
    var frame = testFrame(1, 1);
    frame.creates = createSpan(&creates);
    frame.retires = retireSpan(&retires);
    try expectReject(&frame, error.InvalidResource);
}

test "protocol v0 rejects upload to retired resource" {
    const resource = spriteAlphaResource(83, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    var retires = [_]Retire{.{ .resource = resource }};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var frame = testFrame(1, 1);
    frame.creates = createSpan(&creates);
    frame.retires = retireSpan(&retires);
    frame.uploads = uploadSpan(&uploads, bytes.len);
    try expectReject(&frame, error.RetiredResource);
}

test "protocol v0 rejects wrong generation uploads" {
    const created = spriteAlphaResource(84, 1);
    const uploaded = spriteAlphaResource(84, 2);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(created, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(uploaded, makeRect(0, 0, 1, 1), &bytes, 1)};
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.MissingResource);
}

test "protocol v0 rejects upload byte total mismatch" {
    const resource = spriteAlphaResource(85, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var frame = testFrame(1, 1);
    frame.creates = createSpan(&creates);
    frame.uploads = uploadSpan(&uploads, bytes.len + 1);
    try expectReject(&frame, error.InvalidSpan);
}

test "protocol v0 rejects upload byte total overflow" {
    const resource = spriteAlphaResource(86, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].bytes_count = c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX + 1;
    var frame = testFrame(1, 1);
    frame.creates = createSpan(&creates);
    frame.uploads = uploadSpan(&uploads, uploads[0].bytes_count);
    try expectReject(&frame, error.InvalidSpan);
}

test "protocol v0 rejects nonzero sprite upload origin" {
    const resource = spriteAlphaResource(87, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(1, 0, 1, 1), &bytes, 1)};
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "protocol v0 realizer clips fill coordinate overflow" {
    var commands = [_]Command{
        fillCommand(
            c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
            makeRect(std.math.maxInt(i32), std.math.maxInt(i32), 2, 2),
            0xffffffff,
        ),
    };
    var pixels: [4]u8 = undefined;
    var frame = testFrame(1, 1);
    frame.commands = commandSpan(&commands);
    try realize(&frame, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

test "protocol v0 realizer clips sprite coordinate overflow" {
    const resource = spriteAlphaResource(88, 1);
    var bytes = [_]u8{ 255, 255, 255, 255 };
    var creates = [_]Create{createResource(resource, 2, 2, c.HOWL_RENDER_V0_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 2), &bytes, 2)};
    var commands = [_]Command{
        spriteCommand(resource, makeRect(std.math.maxInt(i32), 0, 2, 2), 0xffffffff),
    };
    var pixels: [4]u8 = undefined;
    var frame = testFrame(1, 1);
    frame.creates = createSpan(&creates);
    frame.uploads = uploadSpan(&uploads, bytes.len);
    frame.commands = commandSpan(&commands);
    try realize(&frame, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

fn testFrame(width: u16, height: u16) Frame {
    return .{
        .protocol_version = c.HOWL_RENDER_PROTOCOL_V0_VERSION,
        .reserved0 = 0,
        .token = .{ .snapshot_seq = 0, .frame_seq = 0, .geometry_epoch = 0, .resource_epoch = 0 },
        .render_px = .{ .width = width, .height = height },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .damage = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX },
        .creates = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_V0_CREATES_MAX },
        .uploads = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_V0_UPLOADS_MAX,
            .bytes_count_total = 0,
            .bytes_count_max = c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX,
        },
        .commands = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_V0_COMMANDS_MAX },
        .retires = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_V0_RETIRES_MAX },
    };
}

fn makeRect(x_px: i32, y_px: i32, width_px: u16, height_px: u16) c.HowlRenderV0Rect {
    return .{ .x_px = x_px, .y_px = y_px, .width_px = width_px, .height_px = height_px };
}

fn spriteAlphaResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA,
    };
}

fn spriteColorResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR,
    };
}

fn glyphAtlasAlphaResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_ALPHA,
    };
}

fn glyphAtlasColorResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_COLOR,
    };
}

fn fillCommand(kind: u8, command_rect: c.HowlRenderV0Rect, color_rgba: u32) Command {
    return .{
        .kind = kind,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = command_rect,
        .color_rgba = color_rgba,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX },
    };
}

fn spriteCommand(resource: ResourceId, command_rect: c.HowlRenderV0Rect, color_rgba: u32) Command {
    var command = fillCommand(c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE, command_rect, color_rgba);
    command.resource = resource;
    return command;
}

fn createResource(resource: ResourceId, width_px: u32, height_px: u32, format: u32) Create {
    return .{
        .resource = resource,
        .width_px = width_px,
        .height_px = height_px,
        .format = format,
        .create_seq = 0,
    };
}

fn uploadResource(
    resource: ResourceId,
    upload_rect: c.HowlRenderV0Rect,
    bytes: []const u8,
    stride_bytes: u32,
) Upload {
    return uploadResourceWithFormat(
        resource,
        upload_rect,
        bytes,
        stride_bytes,
        uploadFormatForResource(resource.kind),
    );
}

fn uploadResourceWithFormat(
    resource: ResourceId,
    upload_rect: c.HowlRenderV0Rect,
    bytes: []const u8,
    stride_bytes: u32,
    format: u32,
) Upload {
    return .{
        .resource = resource,
        .rect = upload_rect,
        .bytes_ptr = bytes.ptr,
        .bytes_count = @intCast(bytes.len),
        .stride_bytes = stride_bytes,
        .format = format,
        .upload_seq = 0,
    };
}

fn damageSpan(items: []const DamageItem, count_max: u32) c.HowlRenderV0DamageSpan {
    return .{ .ptr = items.ptr, .count = @intCast(items.len), .count_max = count_max };
}

fn createSpan(items: []const Create) c.HowlRenderV0CreateSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_V0_CREATES_MAX,
    };
}

fn uploadSpan(items: []const Upload, bytes_count_total: usize) c.HowlRenderV0UploadSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_V0_UPLOADS_MAX,
        .bytes_count_total = @intCast(bytes_count_total),
        .bytes_count_max = c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX,
    };
}

fn commandSpan(items: []const Command) c.HowlRenderV0CommandSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_V0_COMMANDS_MAX,
    };
}

fn retireSpan(items: []const Retire) c.HowlRenderV0RetireSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_V0_RETIRES_MAX,
    };
}

fn expectReject(frame: *const Frame, expected: Error) !void {
    var pixels: [4]u8 = undefined;
    try std.testing.expectError(expected, realize(frame, &pixels, null));
}

fn expectRejectWithCommands(commands: []const Command, expected: Error) !void {
    var frame = testFrame(1, 1);
    frame.commands = commandSpan(commands);
    try expectReject(&frame, expected);
}

fn expectRejectWithCreates(creates: []const Create, expected: Error) !void {
    var frame = testFrame(1, 1);
    frame.creates = createSpan(creates);
    try expectReject(&frame, expected);
}

fn expectRejectWithCreatesCommands(
    creates: []const Create,
    commands: []const Command,
    expected: Error,
) !void {
    var frame = testFrame(1, 1);
    frame.creates = createSpan(creates);
    frame.commands = commandSpan(commands);
    try expectReject(&frame, expected);
}

fn expectRejectWithCreatesUploads(
    creates: []const Create,
    uploads: []const Upload,
    bytes_count_total: usize,
    expected: Error,
) !void {
    var frame = testFrame(1, 1);
    frame.creates = createSpan(creates);
    frame.uploads = uploadSpan(uploads, bytes_count_total);
    try expectReject(&frame, expected);
}

fn expectPixel(pixels: []const u8, pixel: u32, rgba: Rgba) !void {
    const index = pixel * 4;
    try std.testing.expectEqual(rgba.r, pixels[index]);
    try std.testing.expectEqual(rgba.g, pixels[index + 1]);
    try std.testing.expectEqual(rgba.b, pixels[index + 2]);
    try std.testing.expectEqual(rgba.a, pixels[index + 3]);
}
