const std = @import("std");

const c = @import("../ffi.zig").c;

const DamageItem = c.HowlRenderSurfaceDamageItem;
const ResourceId = c.HowlRenderResourceId;
const Upload = c.HowlRenderResourceUpload;
const Create = c.HowlRenderResourceCreate;
const GlyphRef = c.HowlRenderGlyphRef;
const Command = c.HowlRenderSurfaceCommand;
const Retire = c.HowlRenderResourceRetire;
const Surface = c.HowlRenderSurface;

const glyph_atlas_width_px = 1024;
const glyph_atlas_height_px = 1024;

pub const ResourceStore = struct {
    entries: [c.HOWL_RENDER_SURFACE_RESOURCES_MAX]Entry = undefined,
    bytes: [c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX]u8 = undefined,
    count: u32 = 0,
    bytes_count: u32 = 0,

    const Entry = struct {
        resource: ResourceId,
        width_px: u32,
        height_px: u32,
        format: u32,
        upload_rect: c.HowlRenderSurfaceRect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
        upload_offset: u32 = 0,
        upload_count: u32 = 0,
        stride_bytes: u32 = 0,
        uploaded: bool = false,
        retired: bool = false,
    };

    pub fn init() ResourceStore {
        return .{};
    }

    fn commitSurfaceResources(self: *ResourceStore, surface: *const Surface) void {
        for (spanSlice(Create, surface.creates.ptr, surface.creates.count)) |create_value| {
            self.create(create_value);
        }
        for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count)) |upload_value| {
            self.upload(upload_value);
        }
    }

    fn commitSurfaceRetires(self: *ResourceStore, surface: *const Surface) void {
        for (spanSlice(Retire, surface.retires.ptr, surface.retires.count)) |retire_value| {
            self.retire(retire_value.resource);
        }
    }

    fn validateSurfaceTransition(self: *const ResourceStore, surface: *const Surface) Error!void {
        try validateSpan(
            surface.creates.ptr,
            surface.creates.count,
            surface.creates.count_max,
            c.HOWL_RENDER_SURFACE_CREATES_MAX,
        );
        try validateSpan(
            surface.uploads.ptr,
            surface.uploads.count,
            surface.uploads.count_max,
            c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
        );
        try validateSpan(
            surface.retires.ptr,
            surface.retires.count,
            surface.retires.count_max,
            c.HOWL_RENDER_SURFACE_RETIRES_MAX,
        );
        const creates = spanSlice(Create, surface.creates.ptr, surface.creates.count);
        const uploads = spanSlice(Upload, surface.uploads.ptr, surface.uploads.count);
        const retires = spanSlice(Retire, surface.retires.ptr, surface.retires.count);

        const resource_count = std.math.add(u32, self.count, surface.creates.count) catch {
            return error.InvalidResource;
        };
        if (resource_count > c.HOWL_RENDER_SURFACE_RESOURCES_MAX) return error.InvalidResource;
        for (creates, 0..) |create_value, create_index| {
            if (self.hasValue(create_value.resource.value)) return error.InvalidResource;
            for (creates[create_index + 1 ..]) |next| {
                if (create_value.resource.value == next.resource.value) return error.InvalidResource;
            }
        }

        var bytes_count = self.bytes_count;
        for (uploads) |upload_value| {
            if (upload_value.bytes_ptr == null) return error.InvalidUpload;
            if (!self.hasResourceOrCreate(creates, upload_value.resource)) {
                return error.MissingResource;
            }
            bytes_count = std.math.add(u32, bytes_count, upload_value.bytes_count) catch {
                return error.InvalidUpload;
            };
            if (bytes_count > c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) return error.InvalidUpload;
        }

        for (retires, 0..) |retire_value, retire_index| {
            if (!self.hasResourceOrCreate(creates, retire_value.resource)) {
                return error.MissingResource;
            }
            for (retires[retire_index + 1 ..]) |next| {
                if (sameResource(retire_value.resource, next.resource)) return error.InvalidResource;
            }
        }
    }

    fn hasResourceOrCreate(self: *const ResourceStore, creates: []const Create, resource: ResourceId) bool {
        if (self.find(resource)) |entry| return !entry.retired;
        for (creates) |create_value| {
            if (sameResource(create_value.resource, resource)) return true;
        }
        return false;
    }

    fn hasValue(self: *const ResourceStore, value: u64) bool {
        for (self.entries[0..@intCast(self.count)]) |entry| {
            if (entry.resource.value == value) return true;
        }
        return false;
    }

    fn create(self: *ResourceStore, create_value: Create) void {
        std.debug.assert(self.findIndex(create_value.resource) == null);
        std.debug.assert(!self.hasValue(create_value.resource.value));
        std.debug.assert(self.count < c.HOWL_RENDER_SURFACE_RESOURCES_MAX);
        self.entries[@intCast(self.count)] = .{
            .resource = create_value.resource,
            .width_px = create_value.width_px,
            .height_px = create_value.height_px,
            .format = create_value.format,
        };
        self.count += 1;
    }

    fn upload(self: *ResourceStore, upload_value: Upload) void {
        const index = self.findIndex(upload_value.resource) orelse unreachable;
        std.debug.assert(!self.entries[index].retired);
        const next_bytes_count = std.math.add(u32, self.bytes_count, upload_value.bytes_count) catch {
            unreachable;
        };
        std.debug.assert(next_bytes_count <= c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX);
        const bytes_ptr = upload_value.bytes_ptr orelse unreachable;
        @memcpy(self.bytes[self.bytes_count..next_bytes_count], bytes_ptr[0..upload_value.bytes_count]);
        self.entries[index].upload_rect = upload_value.rect;
        self.entries[index].upload_offset = self.bytes_count;
        self.entries[index].upload_count = upload_value.bytes_count;
        self.entries[index].stride_bytes = upload_value.stride_bytes;
        self.entries[index].uploaded = true;
        self.bytes_count = next_bytes_count;
    }

    fn retire(self: *ResourceStore, resource: ResourceId) void {
        const index = self.findIndex(resource) orelse unreachable;
        std.debug.assert(!self.entries[index].retired);
        self.entries[index].retired = true;
    }

    fn find(self: *const ResourceStore, resource: ResourceId) ?Entry {
        const index = self.findIndex(resource) orelse return null;
        return self.entries[index];
    }

    fn findIndex(self: *const ResourceStore, resource: ResourceId) ?usize {
        for (self.entries[0..@intCast(self.count)], 0..) |entry, index| {
            if (sameResource(entry.resource, resource)) return index;
        }
        return null;
    }
};

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
        try retained.validateSurfaceTransition(surface);
        try validateSurface(surface, retained);
    } else {
        try validateSurface(surface, null);
    }

    if (base_pixels) |base| {
        @memcpy(pixels, base);
    } else {
        clearSurfacePixels(pixels);
    }

    for (spanSlice(Command, surface.commands.ptr, surface.commands.count), 0..) |command, command_index| {
        const command_index_u32: u32 = @intCast(command_index);
        switch (command.kind) {
            c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            => try drawSolidRect(pixels, surface.render_px, command.rect, command.color_rgba),
            c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN => {
                try drawGlyphRun(pixels, surface, command, command_index_u32, store);
            },
            c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE => {
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
    if (surface.surface_version != c.HOWL_RENDER_SURFACE_VERSION) return error.InvalidDamage;
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
        c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX,
    );
    for (spanSlice(DamageItem, surface.damage.ptr, surface.damage.count)) |damage| {
        switch (damage.kind) {
            c.HOWL_RENDER_SURFACE_DAMAGE_RECT => {},
            c.HOWL_RENDER_SURFACE_DAMAGE_FULL => try validateFullDamage(surface, damage),
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
        c.HOWL_RENDER_SURFACE_CREATES_MAX,
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
        c.HOWL_RENDER_SURFACE_RETIRES_MAX,
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
        c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
    );
    if (surface.uploads.bytes_count_max != c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) {
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
        if (bytes_sum > c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) return error.InvalidSpan;
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
        c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
    );
    for (spanSlice(Command, surface.commands.ptr, surface.commands.count), 0..) |command, command_index| {
        const command_index_u32: u32 = @intCast(command_index);
        try validateSpan(
            command.glyphs.ptr,
            command.glyphs.count,
            command.glyphs.count_max,
            c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
        );
        switch (command.kind) {
            c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            => try validateFillCommand(command),
            c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN => {
                try validateGlyphRunCommand(surface, store, command, command_index_u32);
            },
            c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE => {
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
        if (isGlyphAtlas(command.resource.kind)) return error.InvalidResource;
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

fn isGlyphAtlas(kind: u32) bool {
    return kind == c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA or
        kind == c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR;
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

test "render surface constants match documented kind values" {
    try std.testing.expectEqual(@as(u8, 1), c.HOWL_RENDER_SURFACE_DAMAGE_RECT);
    try std.testing.expectEqual(@as(u8, 2), c.HOWL_RENDER_SURFACE_DAMAGE_FULL);
    try std.testing.expectEqual(@as(u32, 1), c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA);
    try std.testing.expectEqual(@as(u32, 2), c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR);
    try std.testing.expectEqual(@as(u32, 3), c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    try std.testing.expectEqual(@as(u32, 4), c.HOWL_RENDER_RESOURCE_SPRITE_COLOR);
    try std.testing.expectEqual(@as(u32, 1), c.HOWL_RENDER_UPLOAD_ALPHA8);
    try std.testing.expectEqual(@as(u32, 2), c.HOWL_RENDER_UPLOAD_RGBA8);
    try std.testing.expectEqual(@as(u8, 1), c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT);
    try std.testing.expectEqual(@as(u8, 2), c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
    try std.testing.expectEqual(@as(u8, 3), c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN);
    try std.testing.expectEqual(@as(u8, 4), c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE);
}

test "render-surface surface realizer clears and fills in command order" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 2, 1), 0xff0000ff),
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(1, 0, 1, 1), 0x0000ffff),
    };
    var pixels: [8]u8 = undefined;
    var surface = testSurface(2, 1);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 0, .g = 0, .b = 255, .a = 255 });
}

test "render-surface surface realizer preserves retained base outside commands" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0x010203ff),
    };
    var base = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 };
    var pixels: [8]u8 = undefined;
    var surface = testSurface(2, 1);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, &base);
    try expectPixel(&pixels, 0, .{ .r = 1, .g = 2, .b = 3, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 5, .g = 4, .b = 3, .a = 2 });
}

test "render-surface surface realizer draws alpha sprite bytes" {
    const resource = spriteAlphaResource(1, 1);
    var creates = [_]Create{createResource(resource, 2, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{ 255, 128 };
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 1), &bytes, 2)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 2, 1), 0xff000080)};
    var pixels: [8]u8 = undefined;
    var surface = testSurface(2, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 128, .g = 0, .b = 0, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 64, .g = 0, .b = 0, .a = 255 });
}

test "render-surface surface realizer draws color sprite bytes" {
    const resource = spriteColorResource(2, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_RGBA8)};
    var bytes = [_]u8{ 0, 255, 0, 128 };
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 4)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0)};
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 0, .g = 128, .b = 0, .a = 255 });
}

test "render-surface surface realizer draws alpha glyph atlas run" {
    const resource = glyphAtlasAlphaResource(1, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{ 255, 128, 64, 0 };
    var uploads = [_]Upload{uploadResource(resource, makeRect(2, 3, 2, 2), &bytes, 2)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(2, 3, 2, 2), 0, 0, 0xff000080)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var pixels: [16]u8 = undefined;
    var surface = testSurface(2, 2);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 128, .g = 0, .b = 0, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 64, .g = 0, .b = 0, .a = 255 });
    try expectPixel(&pixels, 2, .{ .r = 32, .g = 0, .b = 0, .a = 255 });
    try expectPixel(&pixels, 3, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

test "render-surface surface realizer clips alpha glyph atlas run" {
    const resource = glyphAtlasAlphaResource(2, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{ 10, 255, 20, 128 };
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 2), &bytes, 2)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 2, 2), -1, 0, 0x00ff00ff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var pixels: [8]u8 = undefined;
    var surface = testSurface(1, 2);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 0, .g = 255, .b = 0, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 0, .g = 128, .b = 0, .a = 255 });
}

test "render-surface surface realizer draws split alpha glyph runs in source order" {
    const resource = glyphAtlasAlphaResource(3, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var red_glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xff000080)};
    var blue_glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0x0000ff80)};
    var commands = [_]Command{ glyphCommand(&red_glyphs), glyphCommand(&blue_glyphs) };
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 63, .g = 0, .b = 128, .a = 255 });
}

test "render-surface surface rejects unknown command kind" {
    var commands = [_]Command{fillCommand(255, makeRect(0, 0, 0, 0), 0)};
    try expectRejectWithCommands(&commands, error.UnknownCommandKind);
}

test "render-surface surface rejects unknown damage kind" {
    var damage = [_]DamageItem{.{ .kind = 255, .rect = makeRect(0, 0, 1, 1) }};
    var surface = testSurface(1, 1);
    surface.damage = damageSpan(&damage, c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX);
    try expectReject(&surface, error.UnknownDamageKind);
}

test "render-surface surface rejects unknown resource kind" {
    const resource = ResourceId{ .value = 1, .generation = 1, .kind = 255 };
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_RGBA8)};
    try expectRejectWithCreates(&creates, error.UnknownResourceKind);
}

test "render-surface surface rejects unknown upload format" {
    const resource = spriteAlphaResource(1, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{
        uploadResourceWithFormat(resource, makeRect(0, 0, 1, 1), &bytes, 1, 255),
    };
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.UnknownUploadFormat);
}

test "render-surface surface rejects zero command width" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, makeRect(0, 0, 0, 1), 0),
    };
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "render-surface surface rejects zero command height" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 0), 0),
    };
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "render-surface surface rejects damage span overflow" {
    var surface = testSurface(1, 1);
    surface.damage.count = c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX + 1;
    try expectReject(&surface, error.InvalidSpan);
}

test "render-surface surface rejects upload span overflow" {
    var surface = testSurface(1, 1);
    surface.uploads.count = c.HOWL_RENDER_SURFACE_UPLOADS_MAX + 1;
    try expectReject(&surface, error.InvalidSpan);
}

test "render-surface surface rejects command span overflow" {
    var surface = testSurface(1, 1);
    surface.commands.count = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    try expectReject(&surface, error.InvalidSpan);
}

test "render-surface surface rejects glyph span overflow" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0),
    };
    commands[0].glyphs.count = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX + 1;
    try expectRejectWithCommands(&commands, error.InvalidSpan);
}

test "render-surface surface rejects alpha upload to color sprite" {
    const resource = spriteColorResource(1, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_RGBA8)};
    var uploads = [_]Upload{
        uploadResourceWithFormat(
            resource,
            makeRect(0, 0, 1, 1),
            &bytes,
            1,
            c.HOWL_RENDER_UPLOAD_ALPHA8,
        ),
    };
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface rejects rgba upload to alpha sprite" {
    const resource = spriteAlphaResource(1, 1);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{
        uploadResourceWithFormat(
            resource,
            makeRect(0, 0, 1, 1),
            &bytes,
            4,
            c.HOWL_RENDER_UPLOAD_RGBA8,
        ),
    };
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface rejects upload before create" {
    const resource = spriteAlphaResource(77, 1);
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var surface = testSurface(1, 1);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    try expectReject(&surface, error.MissingResource);
}

test "render-surface surface rejects missing sprite command resource" {
    const resource = spriteAlphaResource(78, 1);
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    try expectRejectWithCommands(&commands, error.MissingResource);
}

test "render-surface surface rejects wrong generation sprite use" {
    const created = spriteAlphaResource(79, 1);
    const used = spriteAlphaResource(79, 2);
    var creates = [_]Create{createResource(created, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var commands = [_]Command{spriteCommand(used, makeRect(0, 0, 1, 1), 0xffffffff)};
    try expectRejectWithCreatesCommands(&creates, &commands, error.WrongResourceGeneration);
}

test "render-surface surface rejects retired sprite use" {
    const resource = spriteAlphaResource(80, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var retires = [_]Retire{.{ .resource = resource }};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.retires = retireSpan(&retires);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface rejects color sprite command color" {
    const resource = spriteColorResource(1, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_RGBA8)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0x01020304)};
    try expectRejectWithCreatesCommands(&creates, &commands, error.InvalidResource);
}

test "render-surface surface rejects sprite command glyph span" {
    const resource = spriteAlphaResource(1, 1);
    var glyphs = [_]GlyphRef{.{}};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    commands[0].glyphs = .{
        .ptr = &glyphs,
        .count = 1,
        .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
    };
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "render-surface surface rejects fill command resource" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0),
    };
    commands[0].resource.value = 1;
    try expectRejectWithCommands(&commands, error.InvalidResource);
}

test "render-surface surface realizer rejects alpha atlas wrong size" {
    const resource = glyphAtlasAlphaResource(1, 1);
    var creates = [_]Create{createResource(resource, 1023, 1024, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    try expectRejectWithCreates(&creates, error.InvalidResource);
}

test "render-surface surface realizer rejects color atlas create" {
    const resource = glyphAtlasColorResource(1, 1);
    var creates = [_]Create{createResource(resource, 1024, 1024, c.HOWL_RENDER_UPLOAD_RGBA8)};
    try expectRejectWithCreates(&creates, error.UnsupportedGlyphAtlas);
}

test "render-surface surface realizer rejects color atlas upload" {
    const resource = glyphAtlasColorResource(1, 1);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var uploads = [_]Upload{
        uploadResourceWithFormat(
            resource,
            makeRect(0, 0, 1, 1),
            &bytes,
            4,
            c.HOWL_RENDER_UPLOAD_RGBA8,
        ),
    };
    var surface = testSurface(1, 1);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    try expectReject(&surface, error.UnsupportedGlyphAtlas);
}

test "render-surface surface realizer rejects rgba upload to alpha atlas" {
    const resource = glyphAtlasAlphaResource(2, 1);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var uploads = [_]Upload{
        uploadResourceWithFormat(
            resource,
            makeRect(0, 0, 1, 1),
            &bytes,
            4,
            c.HOWL_RENDER_UPLOAD_RGBA8,
        ),
    };
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface realizer rejects alpha upload stride too small" {
    const resource = glyphAtlasAlphaResource(3, 1);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 1), &bytes, 1)};
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface realizer rejects alpha upload byte count too small" {
    const resource = glyphAtlasAlphaResource(4, 1);
    var bytes = [_]u8{1};
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 1), &bytes, 2)};
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface realizer rejects alpha atlas upload outside page" {
    const resource = glyphAtlasAlphaResource(5, 1);
    var bytes = [_]u8{ 1, 2 };
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(1023, 0, 2, 1), &bytes, 2)};
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface realizer rejects missing glyph atlas resource" {
    const resource = glyphAtlasAlphaResource(81, 1);
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    try expectRejectWithCommands(&commands, error.MissingResource);
}

test "render-surface surface realizer rejects wrong generation glyph atlas use" {
    const created = glyphAtlasAlphaResource(82, 1);
    const used = glyphAtlasAlphaResource(82, 2);
    var creates = [_]Create{createGlyphAtlasAlpha(created)};
    var glyphs = [_]GlyphRef{glyphRef(used, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    try expectRejectWithCreatesCommands(&creates, &commands, error.WrongResourceGeneration);
}

test "render-surface surface realizer rejects retired glyph atlas use" {
    const resource = glyphAtlasAlphaResource(83, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var retires = [_]Retire{.{ .resource = resource }};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.retires = retireSpan(&retires);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface realizer rejects empty glyph run" {
    var commands = [_]Command{glyphCommand(&.{})};
    try expectRejectWithCommands(&commands, error.UnsupportedGlyphRun);
}

test "render-surface surface realizer rejects zero alpha glyph ref" {
    const resource = glyphAtlasAlphaResource(84, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xffffff00)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.InvalidDamage);
}

test "render-surface surface realizer rejects glyph rect outside page" {
    const resource = glyphAtlasAlphaResource(85, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(1023, 0, 2, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    try expectRejectWithCreatesCommands(&creates, &commands, error.InvalidDamage);
}

test "render-surface surface realizer rejects color glyph run" {
    const resource = glyphAtlasColorResource(86, 1);
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    try expectRejectWithCommands(&commands, error.UnsupportedGlyphAtlas);
}

test "render-surface surface realizer rejects glyph destination outside render" {
    const resource = glyphAtlasAlphaResource(87, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 1, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.InvalidDamage);
}

test "render-surface surface realizer rejects glyph without upload coverage" {
    const resource = glyphAtlasAlphaResource(88, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(1, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.MissingResource);
}

test "render-surface surface realizer rejects glyph run command rect" {
    var commands = [_]Command{glyphCommand(&.{})};
    commands[0].rect.width_px = 1;
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "render-surface surface realizer rejects glyph run command resource" {
    var commands = [_]Command{glyphCommand(&.{})};
    commands[0].resource.value = 1;
    try expectRejectWithCommands(&commands, error.InvalidResource);
}

test "render-surface surface realizer rejects glyph run command color" {
    var commands = [_]Command{glyphCommand(&.{})};
    commands[0].color_rgba = 0xffffffff;
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "render-surface surface rejects duplicate creates" {
    const resource = spriteAlphaResource(81, 1);
    var creates = [_]Create{
        createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8),
        createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8),
    };
    try expectRejectWithCreates(&creates, error.InvalidResource);
}

test "render-surface surface rejects duplicate retires" {
    const resource = spriteAlphaResource(82, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var retires = [_]Retire{ .{ .resource = resource }, .{ .resource = resource } };
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.retires = retireSpan(&retires);
    try expectReject(&surface, error.InvalidResource);
}

test "render-surface surface rejects upload to retired resource" {
    const resource = spriteAlphaResource(83, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var retires = [_]Retire{.{ .resource = resource }};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.retires = retireSpan(&retires);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface rejects wrong generation uploads" {
    const created = spriteAlphaResource(84, 1);
    const uploaded = spriteAlphaResource(84, 2);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(created, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(uploaded, makeRect(0, 0, 1, 1), &bytes, 1)};
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.WrongResourceGeneration);
}

test "render-surface surface realizer accepts sprite use before same surface retire" {
    const resource = spriteAlphaResource(89, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
}

test "render-surface surface realizer accepts late sprite create upload use retire" {
    const resource = spriteAlphaResource(90, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    creates[0].create_seq = 1;
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].upload_seq = 1;
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0x00000000),
        spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff),
    };
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 2 }};
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
}

test "render-surface surface realizer rejects upload after same surface retire" {
    const resource = spriteAlphaResource(91, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].upload_seq = 1;
    var commands = [_]Command{fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface realizer rejects upload before same surface create" {
    const resource = spriteAlphaResource(92, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    creates[0].create_seq = 1;
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.InvalidUpload);
}

test "render-surface surface realizer rejects sprite use before same surface create" {
    const resource = spriteAlphaResource(93, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    creates[0].create_seq = 1;
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].upload_seq = 1;
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.MissingResource);
}

test "render-surface surface realizer rejects sprite use before same surface upload" {
    const resource = spriteAlphaResource(94, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].upload_seq = 1;
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.MissingResource);
}

test "render-surface surface realizer rejects sprite command outside visible upload before mutation" {
    const resource = spriteAlphaResource(94, 2);
    var creates = [_]Create{createResource(resource, 2, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 2, 1), 0xffffffff)};
    var base = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 };
    var pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const pixels_before = pixels;
    var surface = testSurface(2, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try std.testing.expectError(error.InvalidUpload, realize(&surface, &pixels, &base));
    try std.testing.expectEqualSlices(u8, &pixels_before, &pixels);
}

test "retained render-surface surface realizer rejects invalid surface without store mutation" {
    const accepted = spriteAlphaResource(200, 1);
    var accepted_creates = [_]Create{createResource(accepted, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var accepted_bytes = [_]u8{255};
    var accepted_uploads = [_]Upload{uploadResource(accepted, makeRect(0, 0, 1, 1), &accepted_bytes, 1)};
    var accepted_commands = [_]Command{spriteCommand(accepted, makeRect(0, 0, 1, 1), 0xffffffff)};
    var accepted_surface = testSurface(1, 1);
    accepted_surface.creates = createSpan(&accepted_creates);
    accepted_surface.uploads = uploadSpan(&accepted_uploads, accepted_bytes.len);
    accepted_surface.commands = commandSpan(&accepted_commands);

    var store = ResourceStore.init();
    var pixels: [4]u8 = undefined;
    try realizeRetained(&accepted_surface, &pixels, null, &store);
    try std.testing.expectEqual(@as(u32, 1), store.count);

    const rejected = spriteAlphaResource(201, 1);
    var rejected_creates = [_]Create{createResource(rejected, 2, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var rejected_bytes = [_]u8{255};
    var rejected_uploads = [_]Upload{uploadResource(rejected, makeRect(0, 0, 1, 1), &rejected_bytes, 1)};
    var rejected_commands = [_]Command{spriteCommand(rejected, makeRect(0, 0, 2, 1), 0xffffffff)};
    var rejected_surface = testSurface(2, 1);
    rejected_surface.creates = createSpan(&rejected_creates);
    rejected_surface.uploads = uploadSpan(&rejected_uploads, rejected_bytes.len);
    rejected_surface.commands = commandSpan(&rejected_commands);

    var rejected_pixels: [8]u8 = undefined;
    try std.testing.expectError(
        error.InvalidUpload,
        realizeRetained(&rejected_surface, &rejected_pixels, null, &store),
    );
    try std.testing.expectEqual(@as(u32, 1), store.count);
    try std.testing.expect(store.find(rejected) == null);

    var later_commands = [_]Command{spriteCommand(rejected, makeRect(0, 0, 1, 1), 0xffffffff)};
    var later_surface = testSurface(1, 1);
    later_surface.commands = commandSpan(&later_commands);
    try std.testing.expectError(
        error.MissingResource,
        realizeRetained(&later_surface, &pixels, null, &store),
    );
}

test "render-surface surface realizer rejects sprite use after same surface retire" {
    const resource = spriteAlphaResource(95, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 0 }};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try expectReject(&surface, error.RetiredResource);
}

test "retained render-surface surface realizer accepts existing sprite use before same surface retire" {
    const resource = spriteAlphaResource(97, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var init_surface = testSurface(1, 1);
    init_surface.creates = createSpan(&creates);
    init_surface.uploads = uploadSpan(&uploads, bytes.len);

    var store = ResourceStore.init();
    var pixels: [4]u8 = undefined;
    try realizeRetained(&init_surface, &pixels, null, &store);
    try std.testing.expect(!store.find(resource).?.retired);

    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var retire_surface = testSurface(1, 1);
    retire_surface.commands = commandSpan(&commands);
    retire_surface.retires = retireSpan(&retires);
    try realizeRetained(&retire_surface, &pixels, null, &store);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    try std.testing.expect(store.find(resource).?.retired);
}

test "retained render-surface surface realizer uses old upload before future upload" {
    const resource = spriteAlphaResource(99, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var old_bytes = [_]u8{64};
    var init_uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &old_bytes, 1)};
    var init_surface = testSurface(1, 1);
    init_surface.creates = createSpan(&creates);
    init_surface.uploads = uploadSpan(&init_uploads, old_bytes.len);

    var store = ResourceStore.init();
    var pixels: [4]u8 = undefined;
    try realizeRetained(&init_surface, &pixels, null, &store);

    var new_bytes = [_]u8{255};
    var future_uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &new_bytes, 1)};
    future_uploads[0].upload_seq = 1;
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var surface = testSurface(1, 1);
    surface.uploads = uploadSpan(&future_uploads, new_bytes.len);
    surface.commands = commandSpan(&commands);
    try realizeRetained(&surface, &pixels, null, &store);
    try expectPixel(&pixels, 0, .{ .r = 64, .g = 64, .b = 64, .a = 255 });
}

test "render-surface surface realizer uses latest visible same surface upload" {
    const resource = spriteAlphaResource(100, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var old_bytes = [_]u8{64};
    var new_bytes = [_]u8{255};
    var uploads = [_]Upload{
        uploadResource(resource, makeRect(0, 0, 1, 1), &old_bytes, 1),
        uploadResource(resource, makeRect(0, 0, 1, 1), &new_bytes, 1),
    };
    uploads[0].upload_seq = 0;
    uploads[1].upload_seq = 1;
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0),
        spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff),
    };
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, old_bytes.len + new_bytes.len);
    surface.commands = commandSpan(&commands);
    var pixels: [4]u8 = undefined;

    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
}

test "render-surface surface rejects out of order upload sequence" {
    const resource = spriteAlphaResource(101, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var first_bytes = [_]u8{64};
    var second_bytes = [_]u8{255};
    var uploads = [_]Upload{
        uploadResource(resource, makeRect(0, 0, 1, 1), &first_bytes, 1),
        uploadResource(resource, makeRect(0, 0, 1, 1), &second_bytes, 1),
    };
    uploads[0].upload_seq = 1;
    uploads[1].upload_seq = 0;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, first_bytes.len + second_bytes.len);

    try expectReject(&surface, error.InvalidUpload);
}

test "render-surface surface realizer rejects retire before final sprite use" {
    const resource = spriteAlphaResource(96, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{
        spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff),
        spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff),
    };
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface realizer rejects create sequence outside surface" {
    const resource = spriteAlphaResource(98, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    creates[0].create_seq = 2;
    var commands = [_]Command{fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.InvalidResource);
}

test "render-surface surface realizer rejects upload sequence outside surface" {
    const resource = spriteAlphaResource(99, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].upload_seq = 2;
    var commands = [_]Command{fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.InvalidUpload);
}

test "render-surface surface realizer rejects retire sequence outside surface" {
    const resource = spriteAlphaResource(100, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var commands = [_]Command{fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 2 }};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface realizer accepts glyph atlas use before same surface retire" {
    const resource = glyphAtlasAlphaResource(101, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
}

test "render-surface surface realizer rejects glyph atlas use after same surface retire" {
    const resource = glyphAtlasAlphaResource(102, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 0 }};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface rejects upload byte total mismatch" {
    const resource = spriteAlphaResource(85, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len + 1);
    try expectReject(&surface, error.InvalidSpan);
}

test "render-surface surface rejects upload byte total overflow" {
    const resource = spriteAlphaResource(86, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].bytes_count = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX + 1;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, uploads[0].bytes_count);
    try expectReject(&surface, error.InvalidSpan);
}

test "render-surface surface rejects nonzero sprite upload origin" {
    const resource = spriteAlphaResource(87, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(1, 0, 1, 1), &bytes, 1)};
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface realizer clips fill coordinate overflow" {
    var commands = [_]Command{
        fillCommand(
            c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            makeRect(std.math.maxInt(i32), std.math.maxInt(i32), 2, 2),
            0xffffffff,
        ),
    };
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

test "render-surface surface realizer clips sprite coordinate overflow" {
    const resource = spriteAlphaResource(88, 1);
    var bytes = [_]u8{ 255, 255, 255, 255 };
    var creates = [_]Create{createResource(resource, 2, 2, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 2), &bytes, 2)};
    var commands = [_]Command{
        spriteCommand(resource, makeRect(std.math.maxInt(i32), 0, 2, 2), 0xffffffff),
    };
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

fn testSurface(width: u16, height: u16) Surface {
    return .{
        .surface_version = c.HOWL_RENDER_SURFACE_VERSION,
        .reserved0 = 0,
        .token = .{ .snapshot_seq = 0, .surface_seq = 0, .geometry_epoch = 0, .resource_epoch = 0 },
        .render_px = .{ .width = width, .height = height },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .damage = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX },
        .creates = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_CREATES_MAX },
        .uploads = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
            .bytes_count_total = 0,
            .bytes_count_max = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX,
        },
        .commands = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_COMMANDS_MAX },
        .retires = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_RETIRES_MAX },
    };
}

fn makeRect(x_px: i32, y_px: i32, width_px: u16, height_px: u16) c.HowlRenderSurfaceRect {
    return .{ .x_px = x_px, .y_px = y_px, .width_px = width_px, .height_px = height_px };
}

fn spriteAlphaResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
    };
}

fn spriteColorResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_RESOURCE_SPRITE_COLOR,
    };
}

fn glyphAtlasAlphaResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA,
    };
}

fn glyphAtlasColorResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR,
    };
}

fn fillCommand(kind: u8, command_rect: c.HowlRenderSurfaceRect, color_rgba: u32) Command {
    return .{
        .kind = kind,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = command_rect,
        .color_rgba = color_rgba,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX },
    };
}

fn spriteCommand(resource: ResourceId, command_rect: c.HowlRenderSurfaceRect, color_rgba: u32) Command {
    var command = fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE, command_rect, color_rgba);
    command.resource = resource;
    return command;
}

fn glyphCommand(glyphs: []const GlyphRef) Command {
    var command = fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, makeRect(0, 0, 0, 0), 0);
    command.glyphs = .{
        .ptr = glyphs.ptr,
        .count = @intCast(glyphs.len),
        .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
    };
    return command;
}

fn glyphRef(resource: ResourceId, atlas_rect: c.HowlRenderSurfaceRect, x_px: i32, y_px: i32, color_rgba: u32) GlyphRef {
    return .{
        .atlas_resource = resource,
        .atlas_rect = atlas_rect,
        .x_px = x_px,
        .y_px = y_px,
        .glyph_id = 1,
        .color_rgba = color_rgba,
    };
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

fn createGlyphAtlasAlpha(resource: ResourceId) Create {
    return createResource(
        resource,
        glyph_atlas_width_px,
        glyph_atlas_height_px,
        c.HOWL_RENDER_UPLOAD_ALPHA8,
    );
}

fn uploadResource(resource: ResourceId, upload_rect: c.HowlRenderSurfaceRect, bytes: []const u8, stride_bytes: u32) Upload {
    return uploadResourceWithFormat(
        resource,
        upload_rect,
        bytes,
        stride_bytes,
        uploadFormatForResource(resource.kind),
    );
}

fn uploadResourceWithFormat(resource: ResourceId, upload_rect: c.HowlRenderSurfaceRect, bytes: []const u8, stride_bytes: u32, format: u32) Upload {
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

fn damageSpan(items: []const DamageItem, count_max: u32) c.HowlRenderSurfaceDamageSpan {
    return .{ .ptr = items.ptr, .count = @intCast(items.len), .count_max = count_max };
}

fn createSpan(items: []const Create) c.HowlRenderResourceCreateSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_CREATES_MAX,
    };
}

fn uploadSpan(items: []const Upload, bytes_count_total: usize) c.HowlRenderResourceUploadSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
        .bytes_count_total = @intCast(bytes_count_total),
        .bytes_count_max = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX,
    };
}

fn commandSpan(items: []const Command) c.HowlRenderSurfaceCommandSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
    };
}

fn retireSpan(items: []const Retire) c.HowlRenderResourceRetireSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_RETIRES_MAX,
    };
}

fn expectReject(surface: *const Surface, expected: Error) !void {
    var pixels: [4]u8 = undefined;
    try std.testing.expectError(expected, realize(surface, &pixels, null));
}

fn expectRejectWithCommands(commands: []const Command, expected: Error) !void {
    var surface = testSurface(1, 1);
    surface.commands = commandSpan(commands);
    try expectReject(&surface, expected);
}

fn expectRejectWithCreates(creates: []const Create, expected: Error) !void {
    var surface = testSurface(1, 1);
    surface.creates = createSpan(creates);
    try expectReject(&surface, expected);
}

fn expectRejectWithCreatesCommands(creates: []const Create, commands: []const Command, expected: Error) !void {
    var surface = testSurface(1, 1);
    surface.creates = createSpan(creates);
    surface.commands = commandSpan(commands);
    try expectReject(&surface, expected);
}

fn expectRejectWithCreatesUploads(creates: []const Create, uploads: []const Upload, bytes_count_total: usize, expected: Error) !void {
    var surface = testSurface(1, 1);
    surface.creates = createSpan(creates);
    surface.uploads = uploadSpan(uploads, bytes_count_total);
    try expectReject(&surface, expected);
}

fn expectPixel(pixels: []const u8, pixel: u32, rgba: Rgba) !void {
    const index = pixel * 4;
    try std.testing.expectEqual(rgba.r, pixels[index]);
    try std.testing.expectEqual(rgba.g, pixels[index + 1]);
    try std.testing.expectEqual(rgba.b, pixels[index + 2]);
    try std.testing.expectEqual(rgba.a, pixels[index + 3]);
}
