const std = @import("std");

const c = @import("../ffi.zig").c;
const realize = @import("realize.zig");

const ResourceId = c.HowlRenderV0ResourceId;
const Rect = c.HowlRenderV0Rect;
const Frame = c.HowlRenderV0Frame;

pub const Error = error{
    CommandBoundOverflow,
    CreateBoundOverflow,
    DamageBoundOverflow,
    RetireBoundOverflow,
    UploadBoundOverflow,
    UploadBytesOverflow,
};

pub const Limits = struct {
    damage_max: u32 = c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX,
    creates_max: u32 = c.HOWL_RENDER_V0_CREATES_MAX,
    uploads_max: u32 = c.HOWL_RENDER_V0_UPLOADS_MAX,
    commands_max: u32 = c.HOWL_RENDER_V0_COMMANDS_MAX,
    retires_max: u32 = c.HOWL_RENDER_V0_RETIRES_MAX,
    upload_bytes_max: u32 = c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX,

    pub fn assertValid(comptime limits: Limits) void {
        std.debug.assert(limits.damage_max <= c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX);
        std.debug.assert(limits.creates_max <= c.HOWL_RENDER_V0_CREATES_MAX);
        std.debug.assert(limits.uploads_max <= c.HOWL_RENDER_V0_UPLOADS_MAX);
        std.debug.assert(limits.commands_max <= c.HOWL_RENDER_V0_COMMANDS_MAX);
        std.debug.assert(limits.retires_max <= c.HOWL_RENDER_V0_RETIRES_MAX);
        std.debug.assert(limits.upload_bytes_max <= c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX);
    }
};

pub const Fill = struct {
    rect: Rect,
    color_rgba: u32,
};

pub const Sprite = struct {
    rect: Rect,
    color_rgba: u32,
    bytes: []const u8,
    width_px: u16,
    height_px: u16,
    stride_bytes: u32,
    color_mode: ColorMode,
};

pub const ColorMode = enum {
    alpha,
    color,
};

pub const Fixture = struct {
    render_px: c.HowlRenderPixelSize,
    cell_px: c.HowlRenderCellSize = .{ .width = 1, .height = 1 },
    grid: c.HowlRenderGridSize = .{ .cols = 1, .rows = 1 },
    token: c.HowlRenderV0Token = .{
        .snapshot_seq = 0,
        .frame_seq = 0,
        .geometry_epoch = 0,
        .resource_epoch = 0,
    },
    clear_fills: []const Fill = &.{},
    background_fills: []const Fill = &.{},
    decoration_fills: []const Fill = &.{},
    sprites: []const Sprite = &.{},
    cursor_fills: []const Fill = &.{},
};

pub fn Emitter(comptime limits: Limits) type {
    comptime limits.assertValid();

    return struct {
        damage: [limits.damage_max]c.HowlRenderV0DamageItem = undefined,
        creates: [limits.creates_max]c.HowlRenderV0Create = undefined,
        uploads: [limits.uploads_max]c.HowlRenderV0Upload = undefined,
        upload_byte_offsets: [limits.uploads_max]u32 = undefined,
        commands: [limits.commands_max]c.HowlRenderV0Command = undefined,
        retires: [limits.retires_max]c.HowlRenderV0Retire = undefined,
        upload_bytes: [limits.upload_bytes_max]u8 = undefined,
        damage_count: u32 = 0,
        create_count: u32 = 0,
        upload_count: u32 = 0,
        command_count: u32 = 0,
        retire_count: u32 = 0,
        upload_bytes_count: u32 = 0,
        frame_storage: Frame = emptyFrame(),

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn frame(self: *const Self) *const Frame {
            return &self.frame_storage;
        }

        pub fn emit(self: *Self, fixture: *const Fixture) Error!*const Frame {
            var next = self.*;
            next.reset(fixture);
            try next.appendFullDamage(fixture.render_px);
            try next.appendFillPass(fixture.clear_fills, c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT);
            try next.appendFillPass(fixture.background_fills, c.HOWL_RENDER_V0_COMMAND_FILL_RECT);
            try next.appendFillPass(fixture.decoration_fills, c.HOWL_RENDER_V0_COMMAND_FILL_RECT);
            try next.appendSprites(fixture.sprites);
            try next.appendFillPass(fixture.cursor_fills, c.HOWL_RENDER_V0_COMMAND_FILL_RECT);
            self.* = next;
            self.publishFrame();
            return &self.frame_storage;
        }

        fn reset(self: *Self, fixture: *const Fixture) void {
            self.damage_count = 0;
            self.create_count = 0;
            self.upload_count = 0;
            self.command_count = 0;
            self.retire_count = 0;
            self.upload_bytes_count = 0;
            self.frame_storage = emptyFrame();
            self.frame_storage.token = fixture.token;
            self.frame_storage.render_px = fixture.render_px;
            self.frame_storage.cell_px = fixture.cell_px;
            self.frame_storage.grid = fixture.grid;
        }

        fn appendFullDamage(self: *Self, render_px: c.HowlRenderPixelSize) Error!void {
            if (self.damage_count >= limits.damage_max) return error.DamageBoundOverflow;
            self.damage[self.damage_count] = .{
                .kind = c.HOWL_RENDER_V0_DAMAGE_FULL,
                .reserved0 = 0,
                .reserved1 = 0,
                .rect = .{
                    .x_px = 0,
                    .y_px = 0,
                    .width_px = render_px.width,
                    .height_px = render_px.height,
                },
            };
            self.damage_count += 1;
        }

        fn appendFillPass(self: *Self, fills: []const Fill, kind: u8) Error!void {
            for (fills) |fill| try self.appendCommand(.{
                .kind = kind,
                .reserved0 = 0,
                .reserved1 = 0,
                .rect = fill.rect,
                .color_rgba = fill.color_rgba,
                .resource = zeroResource(),
                .glyphs = emptyGlyphs(),
            });
        }

        fn appendSprites(self: *Self, sprites: []const Sprite) Error!void {
            for (sprites, 0..) |sprite, sprite_index| {
                const resource = spriteResource(sprite, @intCast(sprite_index + 1));
                try self.appendCreate(resource, sprite);
                try self.appendUpload(resource, sprite);
                try self.appendCommand(.{
                    .kind = c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE,
                    .reserved0 = 0,
                    .reserved1 = 0,
                    .rect = sprite.rect,
                    .color_rgba = if (sprite.color_mode == .alpha) sprite.color_rgba else 0,
                    .resource = resource,
                    .glyphs = emptyGlyphs(),
                });
                try self.appendRetire(resource, self.command_count);
            }
        }

        fn appendCreate(self: *Self, resource: ResourceId, sprite: Sprite) Error!void {
            if (self.create_count >= limits.creates_max) return error.CreateBoundOverflow;
            self.creates[self.create_count] = .{
                .resource = resource,
                .width_px = sprite.width_px,
                .height_px = sprite.height_px,
                .format = uploadFormat(sprite.color_mode),
                .create_seq = 0,
            };
            self.create_count += 1;
        }

        fn appendUpload(self: *Self, resource: ResourceId, sprite: Sprite) Error!void {
            if (self.upload_count >= limits.uploads_max) return error.UploadBoundOverflow;
            const bytes_count: u32 = std.math.cast(u32, sprite.bytes.len) orelse {
                return error.UploadBytesOverflow;
            };
            const next_bytes_count = std.math.add(u32, self.upload_bytes_count, bytes_count) catch {
                return error.UploadBytesOverflow;
            };
            if (next_bytes_count > limits.upload_bytes_max) return error.UploadBytesOverflow;
            @memcpy(self.upload_bytes[self.upload_bytes_count..next_bytes_count], sprite.bytes);
            self.uploads[self.upload_count] = .{
                .resource = resource,
                .rect = .{
                    .x_px = 0,
                    .y_px = 0,
                    .width_px = sprite.width_px,
                    .height_px = sprite.height_px,
                },
                .bytes_ptr = &self.upload_bytes[self.upload_bytes_count],
                .bytes_count = bytes_count,
                .stride_bytes = sprite.stride_bytes,
                .format = uploadFormat(sprite.color_mode),
                .upload_seq = 0,
            };
            self.upload_byte_offsets[self.upload_count] = self.upload_bytes_count;
            self.upload_bytes_count = next_bytes_count;
            self.upload_count += 1;
        }

        fn appendCommand(self: *Self, command: c.HowlRenderV0Command) Error!void {
            if (self.command_count >= limits.commands_max) return error.CommandBoundOverflow;
            self.commands[self.command_count] = command;
            self.command_count += 1;
        }

        fn appendRetire(self: *Self, resource: ResourceId, retire_seq: u32) Error!void {
            if (self.retire_count >= limits.retires_max) return error.RetireBoundOverflow;
            self.retires[self.retire_count] = .{
                .resource = resource,
                .retire_seq = retire_seq,
            };
            self.retire_count += 1;
        }

        fn publishFrame(self: *Self) void {
            var upload_index: u32 = 0;
            while (upload_index < self.upload_count) : (upload_index += 1) {
                const byte_offset = self.upload_byte_offsets[upload_index];
                std.debug.assert(byte_offset < self.upload_bytes_count);
                self.uploads[upload_index].bytes_ptr = &self.upload_bytes[byte_offset];
            }
            self.frame_storage.damage = .{
                .ptr = if (self.damage_count == 0) null else &self.damage[0],
                .count = self.damage_count,
                .count_max = c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX,
            };
            self.frame_storage.creates = .{
                .ptr = if (self.create_count == 0) null else &self.creates[0],
                .count = self.create_count,
                .count_max = c.HOWL_RENDER_V0_CREATES_MAX,
            };
            self.frame_storage.uploads = .{
                .ptr = if (self.upload_count == 0) null else &self.uploads[0],
                .count = self.upload_count,
                .count_max = c.HOWL_RENDER_V0_UPLOADS_MAX,
                .bytes_count_total = self.upload_bytes_count,
                .bytes_count_max = c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX,
            };
            self.frame_storage.commands = .{
                .ptr = if (self.command_count == 0) null else &self.commands[0],
                .count = self.command_count,
                .count_max = c.HOWL_RENDER_V0_COMMANDS_MAX,
            };
            self.frame_storage.retires = .{
                .ptr = if (self.retire_count == 0) null else &self.retires[0],
                .count = self.retire_count,
                .count_max = c.HOWL_RENDER_V0_RETIRES_MAX,
            };
        }
    };
}

fn emptyFrame() Frame {
    return .{
        .protocol_version = c.HOWL_RENDER_PROTOCOL_V0_VERSION,
        .reserved0 = 0,
        .token = .{ .snapshot_seq = 0, .frame_seq = 0, .geometry_epoch = 0, .resource_epoch = 0 },
        .render_px = .{ .width = 1, .height = 1 },
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

fn emptyGlyphs() c.HowlRenderV0GlyphRunSpan {
    return .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX };
}

fn zeroResource() ResourceId {
    return .{ .value = 0, .generation = 0, .kind = 0 };
}

fn spriteResource(sprite: Sprite, value: u64) ResourceId {
    return .{
        .value = value,
        .generation = 1,
        .kind = switch (sprite.color_mode) {
            .alpha => c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA,
            .color => c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR,
        },
    };
}

fn uploadFormat(color_mode: ColorMode) u32 {
    return switch (color_mode) {
        .alpha => c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .color => c.HOWL_RENDER_V0_UPLOAD_RGBA8,
    };
}

fn rect(x_px: i32, y_px: i32, width_px: u16, height_px: u16) Rect {
    return .{ .x_px = x_px, .y_px = y_px, .width_px = width_px, .height_px = height_px };
}

fn realizeFixture(comptime limits: Limits, fixture: Fixture, pixels: []u8) !void {
    var emitter = Emitter(limits).init();
    const frame = try emitter.emit(&fixture);
    try realize.realize(frame, pixels, null);
}

test "protocol v0 emitter realizes fill pass order equal to oracle" {
    const limits = Limits{ .commands_max = 5 };
    const clear = [_]Fill{.{ .rect = rect(0, 0, 2, 1), .color_rgba = 0x000000ff }};
    const background = [_]Fill{.{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xff0000ff }};
    const decoration = [_]Fill{.{ .rect = rect(1, 0, 1, 1), .color_rgba = 0x00ff00ff }};
    const cursor = [_]Fill{.{ .rect = rect(0, 0, 2, 1), .color_rgba = 0x0000ff80 }};
    var pixels: [8]u8 = undefined;
    try realizeFixture(limits, .{
        .render_px = .{ .width = 2, .height = 1 },
        .clear_fills = &clear,
        .background_fills = &background,
        .decoration_fills = &decoration,
        .cursor_fills = &cursor,
    }, &pixels);
    const oracle = [_]u8{ 127, 0, 128, 255, 0, 127, 128, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "protocol v0 emitter realizes alpha sprite equal to oracle" {
    const limits = Limits{ .creates_max = 1, .uploads_max = 1, .commands_max = 1, .retires_max = 1, .upload_bytes_max = 2 };
    const sprite_bytes = [_]u8{ 255, 128 };
    const sprites = [_]Sprite{.{
        .rect = rect(0, 0, 2, 1),
        .color_rgba = 0xff000080,
        .bytes = &sprite_bytes,
        .width_px = 2,
        .height_px = 1,
        .stride_bytes = 2,
        .color_mode = .alpha,
    }};
    var pixels: [8]u8 = undefined;
    try realizeFixture(limits, .{
        .render_px = .{ .width = 2, .height = 1 },
        .sprites = &sprites,
    }, &pixels);
    const oracle = [_]u8{ 128, 0, 0, 255, 64, 0, 0, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "protocol v0 emitter realizes color sprite equal to oracle" {
    const limits = Limits{ .creates_max = 1, .uploads_max = 1, .commands_max = 1, .retires_max = 1, .upload_bytes_max = 4 };
    const sprite_bytes = [_]u8{ 0, 255, 0, 128 };
    const sprites = [_]Sprite{.{
        .rect = rect(0, 0, 1, 1),
        .color_rgba = 0,
        .bytes = &sprite_bytes,
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 4,
        .color_mode = .color,
    }};
    var pixels: [4]u8 = undefined;
    try realizeFixture(limits, .{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    }, &pixels);
    const oracle = [_]u8{ 0, 128, 0, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "protocol v0 emitter emits sprite retires after final use" {
    const limits = Limits{ .creates_max = 1, .uploads_max = 1, .commands_max = 1, .retires_max = 1, .upload_bytes_max = 1 };
    const sprite_bytes = [_]u8{255};
    const sprites = [_]Sprite{.{
        .rect = rect(0, 0, 1, 1),
        .color_rgba = 0xffffffff,
        .bytes = &sprite_bytes,
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 1,
        .color_mode = .alpha,
    }};
    var emitter = Emitter(limits).init();
    const frame = try emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    });
    try std.testing.expectEqual(@as(u32, 1), frame.retires.count);
    try std.testing.expectEqual(@as(u64, 1), frame.retires.ptr[0].retire_seq);
    var pixels: [4]u8 = undefined;
    try realize.realize(frame, &pixels, null);
    const oracle = [_]u8{ 255, 255, 255, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "protocol v0 emitter rejects command bound overflow" {
    const limits = Limits{ .commands_max = 1 };
    const fills = [_]Fill{
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff },
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff },
    };
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.CommandBoundOverflow, emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .background_fills = &fills,
    }));
}

test "protocol v0 emitter rejects upload bound overflow" {
    const limits = Limits{ .creates_max = 2, .uploads_max = 1, .commands_max = 2, .retires_max = 2, .upload_bytes_max = 2 };
    const one = [_]u8{255};
    const sprites = [_]Sprite{
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff, .bytes = &one, .width_px = 1, .height_px = 1, .stride_bytes = 1, .color_mode = .alpha },
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff, .bytes = &one, .width_px = 1, .height_px = 1, .stride_bytes = 1, .color_mode = .alpha },
    };
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.UploadBoundOverflow, emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    }));
}

test "protocol v0 emitter rejects retire bound overflow" {
    const limits = Limits{ .creates_max = 2, .uploads_max = 2, .commands_max = 2, .retires_max = 1, .upload_bytes_max = 2 };
    const one = [_]u8{255};
    const sprites = [_]Sprite{
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff, .bytes = &one, .width_px = 1, .height_px = 1, .stride_bytes = 1, .color_mode = .alpha },
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff, .bytes = &one, .width_px = 1, .height_px = 1, .stride_bytes = 1, .color_mode = .alpha },
    };
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.RetireBoundOverflow, emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    }));
}

test "protocol v0 emitter rejects upload byte total overflow" {
    const limits = Limits{ .creates_max = 1, .uploads_max = 1, .commands_max = 1, .retires_max = 1, .upload_bytes_max = 1 };
    const two = [_]u8{ 255, 255 };
    const sprites = [_]Sprite{.{
        .rect = rect(0, 0, 2, 1),
        .color_rgba = 0xffffffff,
        .bytes = &two,
        .width_px = 2,
        .height_px = 1,
        .stride_bytes = 2,
        .color_mode = .alpha,
    }};
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.UploadBytesOverflow, emitter.emit(&.{
        .render_px = .{ .width = 2, .height = 1 },
        .sprites = &sprites,
    }));
}

test "protocol v0 emitter leaves oracle path independent after emission failure" {
    const limits = Limits{ .commands_max = 1 };
    const fill = [_]Fill{.{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xff0000ff }};
    const too_many = [_]Fill{
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0x00ff00ff },
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0x0000ffff },
    };
    var emitter = Emitter(limits).init();
    const accepted = try emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .background_fills = &fill,
    });
    try std.testing.expectError(error.CommandBoundOverflow, emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .background_fills = &too_many,
    }));
    try std.testing.expectEqual(@as(*const Frame, accepted), emitter.frame());
    var pixels: [4]u8 = undefined;
    try realize.realize(emitter.frame(), &pixels, null);
    const oracle = [_]u8{ 255, 0, 0, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}
