const std = @import("std");

const c = @import("howl_render_c");

const ResourceId = c.HowlRenderResourceId;
const Upload = c.HowlRenderResourceUpload;
const Create = c.HowlRenderResourceCreate;
const Retire = c.HowlRenderResourceRetire;
const Surface = c.HowlRenderSurfaceFrame;

pub const ResourceStore = struct {
    entries: [c.HOWL_RENDER_SURFACE_RESOURCES_MAX]Entry = undefined,
    bytes: [c.HOWL_RENDER_SURFACE_FRAME_UPLOAD_BYTES_MAX]u8 = undefined,
    count: u32 = 0,
    bytes_count: u32 = 0,

    pub const Entry = struct {
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

    pub fn commitSurfaceResources(self: *ResourceStore, surface: *const Surface) void {
        for (spanSlice(Create, surface.creates.ptr, surface.creates.count)) |create_value| {
            self.create(create_value);
        }
        for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count)) |upload_value| {
            self.upload(upload_value);
        }
    }

    pub fn commitSurfaceRetires(self: *ResourceStore, surface: *const Surface) void {
        for (spanSlice(Retire, surface.retires.ptr, surface.retires.count)) |retire_value| {
            self.retire(retire_value.resource);
        }
    }

    pub fn validateSurfaceTransition(self: *const ResourceStore, comptime Error: type, surface: *const Surface, invalid_resource: Error, invalid_upload: Error, missing_resource: Error) Error!void {
        try validateSpan(
            surface.creates.ptr,
            surface.creates.count,
            surface.creates.count_max,
            c.HOWL_RENDER_SURFACE_FRAME_CREATES_MAX,
        );
        try validateSpan(
            surface.uploads.ptr,
            surface.uploads.count,
            surface.uploads.count_max,
            c.HOWL_RENDER_SURFACE_FRAME_UPLOADS_MAX,
        );
        try validateSpan(
            surface.retires.ptr,
            surface.retires.count,
            surface.retires.count_max,
            c.HOWL_RENDER_SURFACE_FRAME_RETIRES_MAX,
        );
        const creates = spanSlice(Create, surface.creates.ptr, surface.creates.count);
        const uploads = spanSlice(Upload, surface.uploads.ptr, surface.uploads.count);
        const retires = spanSlice(Retire, surface.retires.ptr, surface.retires.count);

        const resource_count = std.math.add(u32, self.count, surface.creates.count) catch return invalid_resource;
        if (resource_count > c.HOWL_RENDER_SURFACE_RESOURCES_MAX) return invalid_resource;
        for (creates, 0..) |create_value, create_index| {
            if (self.hasValue(create_value.resource.value)) return invalid_resource;
            for (creates[create_index + 1 ..]) |next| {
                if (create_value.resource.value == next.resource.value) return invalid_resource;
            }
        }

        var bytes_count = self.bytes_count;
        for (uploads) |upload_value| {
            if (upload_value.bytes_ptr == null) return invalid_upload;
            if (!self.hasResourceOrCreate(creates, upload_value.resource)) {
                return missing_resource;
            }
            bytes_count = std.math.add(u32, bytes_count, upload_value.bytes_count) catch return invalid_upload;
            if (bytes_count > c.HOWL_RENDER_SURFACE_FRAME_UPLOAD_BYTES_MAX) return invalid_upload;
        }

        for (retires, 0..) |retire_value, retire_index| {
            if (!self.hasResourceOrCreate(creates, retire_value.resource)) {
                return missing_resource;
            }
            for (retires[retire_index + 1 ..]) |next| {
                if (sameResource(retire_value.resource, next.resource)) return invalid_resource;
            }
        }
    }

    pub fn find(self: *const ResourceStore, resource: ResourceId) ?Entry {
        const index = self.findIndex(resource) orelse return null;
        return self.entries[index];
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
        const next_bytes_count = std.math.add(u32, self.bytes_count, upload_value.bytes_count) catch unreachable;
        std.debug.assert(next_bytes_count <= c.HOWL_RENDER_SURFACE_FRAME_UPLOAD_BYTES_MAX);
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

    fn findIndex(self: *const ResourceStore, resource: ResourceId) ?usize {
        for (self.entries[0..@intCast(self.count)], 0..) |entry, index| {
            if (entry.resource.value == resource.value and entry.resource.generation == resource.generation and entry.resource.kind == resource.kind) return index;
        }
        return null;
    }
};

fn validateSpan(ptr: anytype, count: u32, count_max: u32, expected_max: u32) error{InvalidSpan}!void {
    if (count_max != expected_max) return error.InvalidSpan;
    if (count > expected_max) return error.InvalidSpan;
    if (count > 0 and ptr == null) return error.InvalidSpan;
}

fn sameResource(a: ResourceId, b: ResourceId) bool {
    return a.value == b.value and a.generation == b.generation and a.kind == b.kind;
}

fn spanSlice(comptime T: type, ptr: anytype, count: u32) []const T {
    if (count == 0) return &.{};
    return ptr[0..count];
}
