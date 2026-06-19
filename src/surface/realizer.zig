const std = @import("std");

const c = @import("howl_render_c");

const DamageItem = c.HowlRenderSurfaceFrameDamageItem;
const ResourceId = c.HowlRenderResourceId;
const Upload = c.HowlRenderResourceUpload;
const Create = c.HowlRenderResourceCreate;
const GlyphRef = c.HowlRenderGlyphRef;
const Command = c.HowlRenderSurfaceFrameCommand;
const Retire = c.HowlRenderResourceRetire;
const Surface = c.HowlRenderSurfaceFrame;

const glyph_atlas_width_px = 1024;
const glyph_atlas_height_px = 1024;
const realizer_resource_store = @import("realizer_resource_store.zig");

pub const ResourceStore = realizer_resource_store.ResourceStore;

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

pub fn realize(surface: *const Surface, pixels: []u8, base_pixels: ?[]const u8) Error!void {
    try realizeWithStore(surface, pixels, base_pixels, null);
}

pub fn realizeRetained(surface: *const Surface, pixels: []u8, base_pixels: ?[]const u8, store: *ResourceStore) Error!void {
    try realizeWithStore(surface, pixels, base_pixels, store);
}

fn realizeWithStore(surface: *const Surface, pixels: []u8, base_pixels: ?[]const u8, store: ?*ResourceStore) Error!void {
    const pixels_len = try pixelsLen(surface.render_px);
    if (pixels.len != pixels_len) return error.InvalidPixels;
    if (base_pixels) |base| {
        if (base.len != pixels.len) return error.InvalidPixels;
    }

    if (store) |retained| {
        try retained.validateSurfaceTransition(Error, surface, error.InvalidResource, error.InvalidUpload, error.MissingResource);
        try validateSurface(surface, retained);
    } else {
        try validateSurface(surface, null);
    }

    if (base_pixels) |base| {
        @memcpy(pixels, base);
    } else {
        clearDrawablePixels(pixels);
    }

    for (spanSlice(Command, surface.commands.ptr, surface.commands.count), 0..) |command, command_index| {
        const command_index_u32: u32 = @intCast(command_index);
        switch (command.kind) {
            c.HOWL_RENDER_SURFACE_FRAME_COMMAND_CLEAR_RECT,
            c.HOWL_RENDER_SURFACE_FRAME_COMMAND_FILL_RECT,
            => try drawSolidRect(pixels, surface.render_px, command.rect, command.color_rgba),
            c.HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_GLYPH_RUN => {
                try drawGlyphRun(pixels, surface, command, command_index_u32, store);
            },
            c.HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_SPRITE => {
                try drawSprite(pixels, surface, command, command_index_u32, store);
            },
            else => return error.UnknownCommandKind,
        }
    }

    if (store) |retained| {
        retained.commitSurfaceResources(surface);
        retained.commitSurfaceRetires(surface);
    }
}

fn validateSurface(surface: *const Surface, store: ?*const ResourceStore) Error!void {
    if (surface.frame_version != c.HOWL_RENDER_SURFACE_FRAME_VERSION) return error.InvalidDamage;
    try validateDamageSpan(surface);
    try validateCreateSpan(surface);
    try validateRetireSpan(surface, store);
    try validateUploadSpan(surface, store);
    try validateCommandSpan(surface, store);
}

fn validateDamageSpan(surface: *const Surface) Error!void {
    try validateSpan(
        surface.damage.ptr,
        surface.damage.count,
        surface.damage.count_max,
        c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_ITEMS_MAX,
    );
    for (spanSlice(DamageItem, surface.damage.ptr, surface.damage.count)) |damage| {
        switch (damage.kind) {
            c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_RECT => {},
            c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_FULL => try validateFullDamage(surface, damage),
            else => return error.UnknownDamageKind,
        }
    }
}

fn validateFullDamage(surface: *const Surface, damage: DamageItem) Error!void {
    if (damage.rect.x_px != 0) return error.InvalidDamage;
    if (damage.rect.y_px != 0) return error.InvalidDamage;
    if (damage.rect.width_px != surface.render_px.width) return error.InvalidDamage;
    if (damage.rect.height_px != surface.render_px.height) return error.InvalidDamage;
}

fn validateCreateSpan(surface: *const Surface) Error!void {
    try validateSpan(
        surface.creates.ptr,
        surface.creates.count,
        surface.creates.count_max,
        c.HOWL_RENDER_SURFACE_FRAME_CREATES_MAX,
    );
    const creates = spanSlice(Create, surface.creates.ptr, surface.creates.count);
    for (creates, 0..) |create, create_index| {
        try validateResourceKind(create.resource.kind);
        if (create.create_seq > surface.commands.count) return error.InvalidResource;
        if (create.resource.kind == c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR) {
            return error.UnsupportedGlyphAtlas;
        }
        if (create.resource.kind == c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA) {
            if (create.width_px != glyph_atlas_width_px) return error.InvalidResource;
            if (create.height_px != glyph_atlas_height_px) return error.InvalidResource;
        } else {
            if (create.width_px == 0) return error.InvalidResource;
            if (create.height_px == 0) return error.InvalidResource;
        }
        if (create.format != uploadFormatForResource(create.resource.kind)) {
            return error.InvalidUpload;
        }
        for (creates[create_index + 1 ..]) |next| {
            if (sameResource(create.resource, next.resource)) return error.InvalidResource;
            if (create.resource.value == next.resource.value) return error.InvalidResource;
        }
    }
}

fn validateRetireSpan(surface: *const Surface, store: ?*const ResourceStore) Error!void {
    try validateSpan(
        surface.retires.ptr,
        surface.retires.count,
        surface.retires.count_max,
        c.HOWL_RENDER_SURFACE_FRAME_RETIRES_MAX,
    );
    const retires = spanSlice(Retire, surface.retires.ptr, surface.retires.count);
    for (retires, 0..) |retire, retire_index| {
        try validateResourceKind(retire.resource.kind);
        if (retire.resource.kind == c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR) {
            return error.UnsupportedGlyphAtlas;
        }
        for (retires[retire_index + 1 ..]) |next| {
            if (sameResource(retire.resource, next.resource)) return error.InvalidResource;
        }
    }
    for (retires) |retire| {
        const create = try findCreateChecked(surface, store, retire.resource);
        if (retire.retire_seq > surface.commands.count) return error.RetiredResource;
        if (create) |same_surface_create| {
            if (same_surface_create.create_seq < retire.retire_seq) {
                // The resource exists for at least one command-boundary interval.
            } else {
                return error.RetiredResource;
            }
        } else {
            // The resource exists for at least one command-boundary interval.
        }
    }
}

fn validateUploadSpan(surface: *const Surface, store: ?*const ResourceStore) Error!void {
    try validateSpan(
        surface.uploads.ptr,
        surface.uploads.count,
        surface.uploads.count_max,
        c.HOWL_RENDER_SURFACE_FRAME_UPLOADS_MAX,
    );
    if (surface.uploads.bytes_count_max != c.HOWL_RENDER_SURFACE_FRAME_UPLOAD_BYTES_MAX) {
        return error.InvalidSpan;
    }

    var bytes_sum: u32 = 0;
    var previous_upload_seq: u32 = 0;
    for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count), 0..) |upload, upload_index| {
        if (upload_index > 0 and upload.upload_seq < previous_upload_seq) return error.InvalidUpload;
        previous_upload_seq = upload.upload_seq;
        try validateUpload(surface, store, upload);
        bytes_sum = std.math.add(u32, bytes_sum, upload.bytes_count) catch {
            return error.InvalidSpan;
        };
        if (bytes_sum > c.HOWL_RENDER_SURFACE_FRAME_UPLOAD_BYTES_MAX) return error.InvalidSpan;
    }
    if (surface.uploads.bytes_count_total != bytes_sum) return error.InvalidSpan;
}

fn validateUpload(surface: *const Surface, store: ?*const ResourceStore, upload: Upload) Error!void {
    try validateResourceKind(upload.resource.kind);
    try validateUploadFormat(upload.format);
    if (upload.upload_seq > surface.commands.count) return error.InvalidUpload;
    if (upload.resource.kind == c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR) {
        return error.UnsupportedGlyphAtlas;
    }
    if (upload.resource.kind != c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA) {
        if (upload.rect.x_px != 0) return error.InvalidUpload;
        if (upload.rect.y_px != 0) return error.InvalidUpload;
    }
    const create = try findCreateChecked(surface, store, upload.resource);
    if (create) |same_surface_create| {
        if (same_surface_create.create_seq <= upload.upload_seq) {
            // The upload becomes visible only after the resource exists.
        } else {
            return error.InvalidUpload;
        }
    } else {
        // Earlier-surface retained resources already exist before command boundary 0.
    }
    if (retireForResource(surface, upload.resource)) |retire| {
        if (upload.upload_seq < retire.retire_seq) {
            // The upload is visible before same-surface retirement.
        } else {
            return error.RetiredResource;
        }
    }
    if (upload.format != uploadFormatForResource(upload.resource.kind)) return error.InvalidUpload;
    if (upload.rect.width_px == 0) return error.InvalidUpload;
    if (upload.rect.height_px == 0) return error.InvalidUpload;
    if (upload.bytes_ptr == null) return error.InvalidUpload;
    const facts = try resourceDimensions(surface, store, upload.resource);
    if (!rectFitsResource(upload.rect, facts.width_px, facts.height_px)) {
        return error.InvalidUpload;
    }
    const bytes_min = try uploadBytesMin(upload.rect, upload.format, upload.stride_bytes);
    if (upload.bytes_count < bytes_min) return error.InvalidUpload;
}

fn validateCommandSpan(surface: *const Surface, store: ?*const ResourceStore) Error!void {
    try validateSpan(
        surface.commands.ptr,
        surface.commands.count,
        surface.commands.count_max,
        c.HOWL_RENDER_SURFACE_FRAME_COMMANDS_MAX,
    );
    for (spanSlice(Command, surface.commands.ptr, surface.commands.count), 0..) |command, command_index| {
        const command_index_u32: u32 = @intCast(command_index);
        try validateSpan(
            command.glyphs.ptr,
            command.glyphs.count,
            command.glyphs.count_max,
            c.HOWL_RENDER_SURFACE_FRAME_GLYPHS_PER_RUN_MAX,
        );
        switch (command.kind) {
            c.HOWL_RENDER_SURFACE_FRAME_COMMAND_CLEAR_RECT,
            c.HOWL_RENDER_SURFACE_FRAME_COMMAND_FILL_RECT,
            => try validateFillCommand(command),
            c.HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_GLYPH_RUN => {
                try validateGlyphRunCommand(surface, store, command, command_index_u32);
            },
            c.HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_SPRITE => {
                try validateSpriteCommand(surface, store, command, command_index_u32);
            },
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

fn validateSpriteCommand(surface: *const Surface, store: ?*const ResourceStore, command: Command, command_index: u32) Error!void {
    if (command.rect.width_px == 0) return error.InvalidDamage;
    if (command.rect.height_px == 0) return error.InvalidDamage;
    if (command.glyphs.count != 0) return error.InvalidDamage;
    if (command.resource.kind == c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA) {
        // Alpha sprites use command color and per-pixel upload alpha.
    } else if (command.resource.kind == c.HOWL_RENDER_RESOURCE_SPRITE_COLOR) {
        if (command.color_rgba != 0) return error.InvalidResource;
    } else {
        try validateResourceKind(command.resource.kind);
        return error.InvalidResource;
    }
    try validateResourceVisibleAtCommand(surface, store, command.resource, command_index);
    _ = try findSpriteUploadVisible(surface, store, command, command_index);
}

fn validateGlyphRunCommand(surface: *const Surface, store: ?*const ResourceStore, command: Command, command_index: u32) Error!void {
    if (command.rect.x_px != 0) return error.InvalidDamage;
    if (command.rect.y_px != 0) return error.InvalidDamage;
    if (command.rect.width_px != 0) return error.InvalidDamage;
    if (command.rect.height_px != 0) return error.InvalidDamage;
    if (command.color_rgba != 0) return error.InvalidDamage;
    if (!resourceIsZero(command.resource)) return error.InvalidResource;
    if (command.glyphs.count == 0) return error.UnsupportedGlyphRun;
    for (spanSlice(GlyphRef, command.glyphs.ptr, command.glyphs.count)) |glyph| {
        try validateGlyphRef(surface, store, glyph, command_index);
    }
}

fn validateGlyphRef(surface: *const Surface, store: ?*const ResourceStore, glyph: GlyphRef, command_index: u32) Error!void {
    try validateResourceKind(glyph.atlas_resource.kind);
    if (glyph.atlas_resource.kind == c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR) {
        return error.UnsupportedGlyphAtlas;
    }
    if (glyph.atlas_resource.kind != c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA) {
        return error.InvalidResource;
    }
    try validateResourceVisibleAtCommand(surface, store, glyph.atlas_resource, command_index);
    if (unpackRgba(glyph.color_rgba).a == 0) return error.InvalidDamage;
    if (glyph.atlas_rect.width_px == 0) return error.InvalidDamage;
    if (glyph.atlas_rect.height_px == 0) return error.InvalidDamage;
    if (!rectFitsResource(glyph.atlas_rect, glyph_atlas_width_px, glyph_atlas_height_px)) {
        return error.InvalidDamage;
    }
    if (!destinationOverlaps(surface.render_px, glyph.x_px, glyph.y_px, glyph.atlas_rect)) {
        return error.InvalidDamage;
    }
    _ = findGlyphUploadVisible(surface, store, glyph, command_index) orelse {
        return error.MissingResource;
    };
}

fn drawGlyphRun(pixels: []u8, surface: *const Surface, command: Command, command_index: u32, store: ?*const ResourceStore) Error!void {
    for (spanSlice(GlyphRef, command.glyphs.ptr, command.glyphs.count)) |glyph| {
        const upload = findGlyphUploadVisible(surface, store, glyph, command_index) orelse {
            return error.MissingResource;
        };
        const bytes_ptr = upload.bytes_ptr orelse return error.InvalidUpload;
        var yy: u16 = 0;
        while (yy < glyph.atlas_rect.height_px) : (yy += 1) {
            var xx: u16 = 0;
            while (xx < glyph.atlas_rect.width_px) : (xx += 1) {
                try drawGlyphPixel(pixels, surface, glyph, upload, bytes_ptr, xx, yy);
            }
        }
    }
}

fn drawGlyphPixel(pixels: []u8, surface: *const Surface, glyph: GlyphRef, upload: Upload, bytes_ptr: anytype, xx: u16, yy: u16) Error!void {
    const dst_x = destinationCoordinate(glyph.x_px, xx) orelse return;
    const dst_y = destinationCoordinate(glyph.y_px, yy) orelse return;
    if (dst_x < 0) return;
    if (dst_y < 0) return;
    if (dst_x >= surface.render_px.width) return;
    if (dst_y >= surface.render_px.height) return;
    const source_x = std.math.add(u32, @intCast(glyph.atlas_rect.x_px), xx) catch {
        return error.InvalidDamage;
    };
    const source_y = std.math.add(u32, @intCast(glyph.atlas_rect.y_px), yy) catch {
        return error.InvalidDamage;
    };
    const source_index = try atlasIndex(upload, source_x, source_y);
    if (source_index >= upload.bytes_count) return error.InvalidUpload;
    const rgba = unpackRgba(glyph.color_rgba);
    const alpha = bytes_ptr[source_index];
    const out_alpha: u8 = @intCast((@as(u16, rgba.a) * @as(u16, alpha)) / 255);
    const dst_index = try pixelIndex(surface.render_px.width, @intCast(dst_x), @intCast(dst_y));
    blendPixel(pixels, dst_index, rgba.r, rgba.g, rgba.b, out_alpha);
}

fn drawSprite(pixels: []u8, surface: *const Surface, command: Command, command_index: u32, store: ?*const ResourceStore) Error!void {
    const upload = try findSpriteUploadVisible(surface, store, command, command_index);
    const bytes_ptr = upload.bytes_ptr orelse return error.InvalidUpload;
    var yy: u16 = 0;
    while (yy < command.rect.height_px) : (yy += 1) {
        var xx: u16 = 0;
        while (xx < command.rect.width_px) : (xx += 1) {
            try drawSpritePixel(pixels, surface, command, upload, bytes_ptr, xx, yy);
        }
    }
}

fn drawSpritePixel(pixels: []u8, surface: *const Surface, command: Command, upload: Upload, bytes_ptr: anytype, xx: u16, yy: u16) Error!void {
    const dst_x = destinationCoordinate(command.rect.x_px, xx) orelse return;
    const dst_y = destinationCoordinate(command.rect.y_px, yy) orelse return;
    if (dst_x < 0) return;
    if (dst_y < 0) return;
    if (dst_x >= surface.render_px.width) return;
    if (dst_y >= surface.render_px.height) return;
    const source_index = try spriteIndex(upload, xx, yy);
    const source_end = std.math.add(u32, source_index, bytesPerPixel(upload.format)) catch {
        return error.InvalidUpload;
    };
    if (source_end > upload.bytes_count) return;
    const dst_index = try pixelIndex(surface.render_px.width, @intCast(dst_x), @intCast(dst_y));
    if (command.resource.kind == c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA) {
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

fn drawSolidRect(pixels: []u8, render_px: c.HowlRenderPixelSize, command_rect: c.HowlRenderSurfaceRect, color_rgba: u32) Error!void {
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

fn clearDrawablePixels(pixels: []u8) void {
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
        c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA,
        c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR,
        c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
        c.HOWL_RENDER_RESOURCE_SPRITE_COLOR,
        => {},
        else => return error.UnknownResourceKind,
    }
}

fn validateUploadFormat(format: u32) Error!void {
    switch (format) {
        c.HOWL_RENDER_UPLOAD_ALPHA8, c.HOWL_RENDER_UPLOAD_RGBA8 => {},
        else => return error.UnknownUploadFormat,
    }
}

fn uploadFormatForResource(kind: u32) u32 {
    return switch (kind) {
        c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA => c.HOWL_RENDER_UPLOAD_ALPHA8,
        c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA => c.HOWL_RENDER_UPLOAD_ALPHA8,
        c.HOWL_RENDER_RESOURCE_SPRITE_COLOR => c.HOWL_RENDER_UPLOAD_RGBA8,
        else => 0,
    };
}

fn findCreate(surface: *const Surface, resource: ResourceId) ?Create {
    for (spanSlice(Create, surface.creates.ptr, surface.creates.count)) |create| {
        if (sameResource(create.resource, resource)) return create;
    }
    return null;
}

fn findCreateChecked(surface: *const Surface, store: ?*const ResourceStore, resource: ResourceId) Error!?Create {
    for (spanSlice(Create, surface.creates.ptr, surface.creates.count)) |create| {
        if (sameResource(create.resource, resource)) return create;
        if (create.resource.value == resource.value) return error.WrongResourceGeneration;
    }
    if (store) |retained| {
        if (retained.find(resource)) |entry| {
            if (entry.retired) return error.RetiredResource;
            return null;
        }
        for (retained.entries[0..@intCast(retained.count)]) |entry| {
            if (entry.resource.value == resource.value) return error.WrongResourceGeneration;
        }
    }
    return error.MissingResource;
}

const ResourceDimensions = struct {
    width_px: u32,
    height_px: u32,
};

fn resourceDimensions(surface: *const Surface, store: ?*const ResourceStore, resource: ResourceId) Error!ResourceDimensions {
    if (findCreate(surface, resource)) |create| {
        return .{ .width_px = create.width_px, .height_px = create.height_px };
    }
    if (store) |retained| {
        if (retained.find(resource)) |entry| {
            if (entry.retired) return error.RetiredResource;
            return .{ .width_px = entry.width_px, .height_px = entry.height_px };
        }
    }
    return error.MissingResource;
}

fn validateResourceVisibleAtCommand(surface: *const Surface, store: ?*const ResourceStore, resource: ResourceId, command_index: u32) Error!void {
    const create = try findCreateChecked(surface, store, resource);
    if (create) |same_surface_create| {
        if (same_surface_create.create_seq <= command_index) {
            // Same-surface create is visible at command indexes at or after create_seq.
        } else {
            return error.MissingResource;
        }
    } else {
        // Earlier-surface retained resources are visible at command boundary 0.
    }
    if (retireForResource(surface, resource)) |retire| {
        if (command_index < retire.retire_seq) {
            // Same-surface retire invalidates the resource at retire_seq and later.
        } else {
            return error.RetiredResource;
        }
    }
}

fn findUploadVisible(surface: *const Surface, store: ?*const ResourceStore, resource: ResourceId, command_index: u32) ?Upload {
    var selected: ?Upload = null;
    for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count)) |upload| {
        if (!sameResource(upload.resource, resource)) continue;
        if (upload.upload_seq > command_index) continue;
        if (selected) |current| {
            if (upload.upload_seq < current.upload_seq) continue;
        }
        selected = upload;
    }
    if (selected) |upload| return upload;
    if (store) |retained| {
        if (retained.find(resource)) |entry| {
            if (entry.retired) return null;
            if (!entry.uploaded) return null;
            return .{
                .resource = entry.resource,
                .rect = entry.upload_rect,
                .bytes_ptr = &retained.bytes[entry.upload_offset],
                .bytes_count = entry.upload_count,
                .stride_bytes = entry.stride_bytes,
                .format = entry.format,
                .upload_seq = 0,
            };
        }
    }
    return null;
}

fn findSpriteUploadVisible(surface: *const Surface, store: ?*const ResourceStore, command: Command, command_index: u32) Error!Upload {
    const upload = findUploadVisible(surface, store, command.resource, command_index) orelse {
        return error.MissingResource;
    };
    try validateSpriteUploadCoverage(upload, command.rect);
    return upload;
}

fn validateSpriteUploadCoverage(upload: Upload, command_rect: c.HowlRenderSurfaceRect) Error!void {
    if (upload.rect.x_px != 0) return error.InvalidUpload;
    if (upload.rect.y_px != 0) return error.InvalidUpload;
    if (command_rect.width_px <= upload.rect.width_px) {
        // Limited visual-resource sprites read from resource-local x = 0.
    } else {
        return error.InvalidUpload;
    }
    if (command_rect.height_px <= upload.rect.height_px) {
        // Limited visual-resource sprites read from resource-local y = 0.
    } else {
        return error.InvalidUpload;
    }

    const bytes_per_pixel = bytesPerPixel(upload.format);
    const row_bytes = std.math.mul(u32, command_rect.width_px, bytes_per_pixel) catch {
        return error.InvalidUpload;
    };
    if (row_bytes <= upload.stride_bytes) {
        // The selected upload has enough bytes per row for every sprite source pixel.
    } else {
        return error.InvalidUpload;
    }
    if (command_rect.height_px == 0) return error.InvalidUpload;
    const final_row: u32 = command_rect.height_px - 1;
    const final_row_offset = std.math.mul(u32, final_row, upload.stride_bytes) catch {
        return error.InvalidUpload;
    };
    const bytes_required = std.math.add(u32, final_row_offset, row_bytes) catch {
        return error.InvalidUpload;
    };
    if (bytes_required <= upload.bytes_count) {
        // The draw loop cannot read beyond the selected visible upload.
    } else {
        return error.InvalidUpload;
    }
}

fn findGlyphUploadVisible(surface: *const Surface, store: ?*const ResourceStore, glyph: GlyphRef, command_index: u32) ?Upload {
    var selected: ?Upload = null;
    for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count)) |upload| {
        if (!sameResource(upload.resource, glyph.atlas_resource)) continue;
        if (upload.upload_seq > command_index) continue;
        if (upload.format != c.HOWL_RENDER_UPLOAD_ALPHA8) continue;
        if (!rectContains(upload.rect, glyph.atlas_rect)) continue;
        if (selected) |current| {
            if (upload.upload_seq < current.upload_seq) continue;
        }
        selected = upload;
    }
    if (selected) |upload| return upload;
    if (store) |retained| {
        const upload = findUploadVisible(surface, retained, glyph.atlas_resource, command_index) orelse {
            return null;
        };
        if (upload.format != c.HOWL_RENDER_UPLOAD_ALPHA8) return null;
        if (!rectContains(upload.rect, glyph.atlas_rect)) return null;
        return upload;
    }
    return null;
}

fn retireForResource(surface: *const Surface, resource: ResourceId) ?Retire {
    for (spanSlice(Retire, surface.retires.ptr, surface.retires.count)) |retire| {
        if (sameResource(retire.resource, resource)) return retire;
    }
    return null;
}

fn sameResource(a: ResourceId, b: ResourceId) bool {
    return a.value == b.value and a.generation == b.generation and a.kind == b.kind;
}

fn resourceIsZero(resource: ResourceId) bool {
    return resource.value == 0 and resource.generation == 0 and resource.kind == 0;
}

fn rectFitsResource(upload_rect: c.HowlRenderSurfaceRect, width_px: u32, height_px: u32) bool {
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

fn rectContains(container: c.HowlRenderSurfaceRect, child: c.HowlRenderSurfaceRect) bool {
    if (!rectFitsResource(child, glyph_atlas_width_px, glyph_atlas_height_px)) return false;
    if (container.x_px < 0) return false;
    if (container.y_px < 0) return false;
    if (child.x_px < container.x_px) return false;
    if (child.y_px < container.y_px) return false;
    const container_right = std.math.add(u32, @intCast(container.x_px), container.width_px) catch {
        return false;
    };
    const container_bottom = std.math.add(u32, @intCast(container.y_px), container.height_px) catch {
        return false;
    };
    const child_right = std.math.add(u32, @intCast(child.x_px), child.width_px) catch {
        return false;
    };
    const child_bottom = std.math.add(u32, @intCast(child.y_px), child.height_px) catch {
        return false;
    };
    return child_right <= container_right and child_bottom <= container_bottom;
}

fn destinationOverlaps(render_px: c.HowlRenderPixelSize, x_px: i32, y_px: i32, rect: c.HowlRenderSurfaceRect) bool {
    var yy: u16 = 0;
    while (yy < rect.height_px) : (yy += 1) {
        const dst_y = destinationCoordinate(y_px, yy) orelse continue;
        if (dst_y < 0) continue;
        if (dst_y >= render_px.height) continue;
        var xx: u16 = 0;
        while (xx < rect.width_px) : (xx += 1) {
            const dst_x = destinationCoordinate(x_px, xx) orelse continue;
            if (dst_x < 0) continue;
            if (dst_x >= render_px.width) continue;
            return true;
        }
    }
    return false;
}

fn uploadBytesMin(upload_rect: c.HowlRenderSurfaceRect, format: u32, stride_bytes: u32) Error!u32 {
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

fn atlasIndex(upload: Upload, source_x: u32, source_y: u32) Error!u32 {
    if (source_x < @as(u32, @intCast(upload.rect.x_px))) return error.InvalidUpload;
    if (source_y < @as(u32, @intCast(upload.rect.y_px))) return error.InvalidUpload;
    const local_x = source_x - @as(u32, @intCast(upload.rect.x_px));
    const local_y = source_y - @as(u32, @intCast(upload.rect.y_px));
    const row_offset = std.math.mul(u32, local_y, upload.stride_bytes) catch {
        return error.InvalidUpload;
    };
    return std.math.add(u32, row_offset, local_x) catch error.InvalidUpload;
}

fn destinationCoordinate(origin: i32, offset: u16) ?i32 {
    return std.math.add(i32, origin, offset) catch null;
}

fn bytesPerPixel(format: u32) u32 {
    return if (format == c.HOWL_RENDER_UPLOAD_ALPHA8) 1 else 4;
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
