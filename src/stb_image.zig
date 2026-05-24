const std = @import("std");

const c = @cImport({
    @cInclude("stb_image.h");
});

pub const DecodedRgba = struct {
    pixels_rgba: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    ptr: [*]u8,

    pub fn deinit(self: DecodedRgba, allocator: std.mem.Allocator) void {
        _ = allocator;
        c.stbi_image_free(self.ptr);
    }
};

pub fn decodeRgba(data: []const u8) !DecodedRgba {
    if (data.len == 0) return error.DecodeFailed;

    var width: c_int = 0;
    var height: c_int = 0;
    var comp: c_int = 0;
    const ptr = c.stbi_load_from_memory(data.ptr, @intCast(data.len), &width, &height, &comp, 4);
    if (ptr == null) return error.DecodeFailed;
    if (width <= 0) {
        c.stbi_image_free(ptr);
        return error.DecodeFailed;
    }
    if (height <= 0) {
        c.stbi_image_free(ptr);
        return error.DecodeFailed;
    }

    const width_u32: u32 = @intCast(width);
    const height_u32: u32 = @intCast(height);
    const stride = std.math.mul(u64, width_u32, 4) catch {
        c.stbi_image_free(ptr);
        return error.DecodeFailed;
    };
    const len = std.math.mul(u64, stride, height_u32) catch {
        c.stbi_image_free(ptr);
        return error.DecodeFailed;
    };
    const len_usize = std.math.cast(usize, len) orelse {
        c.stbi_image_free(ptr);
        return error.DecodeFailed;
    };

    return .{
        .pixels_rgba = @as([*]const u8, @ptrCast(ptr))[0..len_usize],
        .width = width_u32,
        .height = height_u32,
        .stride = std.math.cast(usize, stride) orelse unreachable,
        .ptr = @ptrCast(ptr),
    };
}
