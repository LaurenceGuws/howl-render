const std = @import("std");
const c = @import("../ffi.zig").c;

comptime {
    assertConstants();
    assertLayoutAll();
}

const Token = extern struct {
    snapshot_seq: u64,
    surface_seq: u64,
    geometry_epoch: u64,
    resource_epoch: u64,
};

const Rect = extern struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
};

const DamageItem = extern struct {
    kind: u8,
    reserved0: u8,
    reserved1: u16,
    rect: Rect,
};

const DamageSpan = extern struct {
    ptr: ?*const DamageItem,
    count: u32,
    count_max: u32,
};

const ResourceId = extern struct {
    value: u64,
    generation: u32,
    kind: u32,
};

const Upload = extern struct {
    resource: ResourceId,
    rect: Rect,
    bytes_ptr: ?*const u8,
    bytes_count: u32,
    stride_bytes: u32,
    format: u32,
    upload_seq: u32,
};

const UploadSpan = extern struct {
    ptr: ?*const Upload,
    count: u32,
    count_max: u32,
    bytes_count_total: u32,
    bytes_count_max: u32,
};

const Create = extern struct {
    resource: ResourceId,
    width_px: u32,
    height_px: u32,
    format: u32,
    create_seq: u64,
};

const CreateSpan = extern struct {
    ptr: ?*const Create,
    count: u32,
    count_max: u32,
};

const GlyphRef = extern struct {
    atlas_resource: ResourceId,
    atlas_rect: Rect,
    x_px: i32,
    y_px: i32,
    glyph_id: u32,
    color_rgba: u32,
};

const GlyphRunSpan = extern struct {
    ptr: ?*const GlyphRef,
    count: u32,
    count_max: u32,
};

const Command = extern struct {
    kind: u8,
    reserved0: u8,
    reserved1: u16,
    rect: Rect,
    color_rgba: u32,
    resource: ResourceId,
    glyphs: GlyphRunSpan,
};

const CommandSpan = extern struct {
    ptr: ?*const Command,
    count: u32,
    count_max: u32,
};

const Retire = extern struct {
    resource: ResourceId,
    retire_seq: u64,
};

const RetireSpan = extern struct {
    ptr: ?*const Retire,
    count: u32,
    count_max: u32,
};

const HostAck = extern struct {
    resource: ResourceId,
    ack_seq: u64,
};

const HostAckSpan = extern struct {
    ptr: ?*const HostAck,
    count: u32,
    count_max: u32,
};

const Surface = extern struct {
    surface_version: u32,
    reserved0: u32,
    token: Token,
    render_px: c.HowlRenderPixelSize,
    cell_px: c.HowlRenderCellSize,
    grid: c.HowlRenderGridSize,
    damage: DamageSpan,
    creates: CreateSpan,
    uploads: UploadSpan,
    commands: CommandSpan,
    retires: RetireSpan,
};

fn assertConstants() void {
    std.debug.assert(c.HOWL_RENDER_SURFACE_VERSION == 0);
    std.debug.assert(c.HOWL_RENDER_SURFACE_IN_FLIGHT_MAX == 2);
    std.debug.assert(c.HOWL_RENDER_SURFACE_SNAPSHOTS_IN_FLIGHT_MAX == 2);
    std.debug.assert(c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX == 1024);
    std.debug.assert(c.HOWL_RENDER_SURFACE_UPLOADS_MAX == 256);
    std.debug.assert(c.HOWL_RENDER_SURFACE_COMMANDS_MAX == 8192);
    std.debug.assert(c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX == 256);
    std.debug.assert(c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX == 8388608);
    std.debug.assert(c.HOWL_RENDER_SURFACE_ATLAS_PAGES_MAX == 64);
    std.debug.assert(c.HOWL_RENDER_SURFACE_RESOURCES_MAX == 4096);
    std.debug.assert(c.HOWL_RENDER_SURFACE_CREATES_MAX == 256);
    std.debug.assert(c.HOWL_RENDER_SURFACE_RETIRES_MAX == 256);
    std.debug.assert(c.HOWL_RENDER_SURFACE_HOST_ACKS_MAX == 256);
    std.debug.assert(c.HOWL_RENDER_SURFACE_DAMAGE_RECT == 1);
    std.debug.assert(c.HOWL_RENDER_SURFACE_DAMAGE_FULL == 2);
    std.debug.assert(c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA == 1);
    std.debug.assert(c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR == 2);
    std.debug.assert(c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA == 3);
    std.debug.assert(c.HOWL_RENDER_RESOURCE_SPRITE_COLOR == 4);
    std.debug.assert(c.HOWL_RENDER_UPLOAD_ALPHA8 == 1);
    std.debug.assert(c.HOWL_RENDER_UPLOAD_RGBA8 == 2);
    std.debug.assert(c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT == 1);
    std.debug.assert(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT == 2);
    std.debug.assert(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN == 3);
    std.debug.assert(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE == 4);
}

fn assertLayoutAll() void {
    assertTokenLayout();
    assertRectLayout();
    assertDamageItemLayout();
    assertDamageSpanLayout();
    assertResourceIdLayout();
    assertUploadLayout();
    assertUploadSpanLayout();
    assertCreateLayout();
    assertCreateSpanLayout();
    assertGlyphRefLayout();
    assertGlyphRunSpanLayout();
    assertCommandLayout();
    assertCommandSpanLayout();
    assertRetireLayout();
    assertRetireSpanLayout();
    assertHostAckLayout();
    assertHostAckSpanLayout();
    assertSurfaceLayout();
}

fn assertTokenLayout() void {
    assertLayout(Token, c.HowlRenderSurfaceToken);
    assertOffset(Token, c.HowlRenderSurfaceToken, "snapshot_seq");
    assertOffset(Token, c.HowlRenderSurfaceToken, "surface_seq");
    assertOffset(Token, c.HowlRenderSurfaceToken, "geometry_epoch");
    assertOffset(Token, c.HowlRenderSurfaceToken, "resource_epoch");
}

fn assertRectLayout() void {
    assertLayout(Rect, c.HowlRenderSurfaceRect);
    assertOffset(Rect, c.HowlRenderSurfaceRect, "x_px");
    assertOffset(Rect, c.HowlRenderSurfaceRect, "y_px");
    assertOffset(Rect, c.HowlRenderSurfaceRect, "width_px");
    assertOffset(Rect, c.HowlRenderSurfaceRect, "height_px");
}

fn assertDamageItemLayout() void {
    assertLayout(DamageItem, c.HowlRenderSurfaceDamageItem);
    assertOffset(DamageItem, c.HowlRenderSurfaceDamageItem, "kind");
    assertOffset(DamageItem, c.HowlRenderSurfaceDamageItem, "reserved0");
    assertOffset(DamageItem, c.HowlRenderSurfaceDamageItem, "reserved1");
    assertOffset(DamageItem, c.HowlRenderSurfaceDamageItem, "rect");
}

fn assertDamageSpanLayout() void {
    assertLayout(DamageSpan, c.HowlRenderSurfaceDamageSpan);
    assertOffset(DamageSpan, c.HowlRenderSurfaceDamageSpan, "ptr");
    assertOffset(DamageSpan, c.HowlRenderSurfaceDamageSpan, "count");
    assertOffset(DamageSpan, c.HowlRenderSurfaceDamageSpan, "count_max");
}

fn assertResourceIdLayout() void {
    assertLayout(ResourceId, c.HowlRenderResourceId);
    assertOffset(ResourceId, c.HowlRenderResourceId, "value");
    assertOffset(ResourceId, c.HowlRenderResourceId, "generation");
    assertOffset(ResourceId, c.HowlRenderResourceId, "kind");
}

fn assertUploadLayout() void {
    assertLayout(Upload, c.HowlRenderResourceUpload);
    assertOffset(Upload, c.HowlRenderResourceUpload, "resource");
    assertOffset(Upload, c.HowlRenderResourceUpload, "rect");
    assertOffset(Upload, c.HowlRenderResourceUpload, "bytes_ptr");
    assertOffset(Upload, c.HowlRenderResourceUpload, "bytes_count");
    assertOffset(Upload, c.HowlRenderResourceUpload, "stride_bytes");
    assertOffset(Upload, c.HowlRenderResourceUpload, "format");
    assertOffset(Upload, c.HowlRenderResourceUpload, "upload_seq");
}

fn assertUploadSpanLayout() void {
    assertLayout(UploadSpan, c.HowlRenderResourceUploadSpan);
    assertOffset(UploadSpan, c.HowlRenderResourceUploadSpan, "ptr");
    assertOffset(UploadSpan, c.HowlRenderResourceUploadSpan, "count");
    assertOffset(UploadSpan, c.HowlRenderResourceUploadSpan, "count_max");
    assertOffset(UploadSpan, c.HowlRenderResourceUploadSpan, "bytes_count_total");
    assertOffset(UploadSpan, c.HowlRenderResourceUploadSpan, "bytes_count_max");
}

fn assertCreateLayout() void {
    assertLayout(Create, c.HowlRenderResourceCreate);
    assertOffset(Create, c.HowlRenderResourceCreate, "resource");
    assertOffset(Create, c.HowlRenderResourceCreate, "width_px");
    assertOffset(Create, c.HowlRenderResourceCreate, "height_px");
    assertOffset(Create, c.HowlRenderResourceCreate, "format");
    assertOffset(Create, c.HowlRenderResourceCreate, "create_seq");
}

fn assertCreateSpanLayout() void {
    assertLayout(CreateSpan, c.HowlRenderResourceCreateSpan);
    assertOffset(CreateSpan, c.HowlRenderResourceCreateSpan, "ptr");
    assertOffset(CreateSpan, c.HowlRenderResourceCreateSpan, "count");
    assertOffset(CreateSpan, c.HowlRenderResourceCreateSpan, "count_max");
}

fn assertGlyphRefLayout() void {
    assertLayout(GlyphRef, c.HowlRenderGlyphRef);
    assertOffset(GlyphRef, c.HowlRenderGlyphRef, "atlas_resource");
    assertOffset(GlyphRef, c.HowlRenderGlyphRef, "atlas_rect");
    assertOffset(GlyphRef, c.HowlRenderGlyphRef, "x_px");
    assertOffset(GlyphRef, c.HowlRenderGlyphRef, "y_px");
    assertOffset(GlyphRef, c.HowlRenderGlyphRef, "glyph_id");
    assertOffset(GlyphRef, c.HowlRenderGlyphRef, "color_rgba");
}

fn assertGlyphRunSpanLayout() void {
    assertLayout(GlyphRunSpan, c.HowlRenderGlyphRunSpan);
    assertOffset(GlyphRunSpan, c.HowlRenderGlyphRunSpan, "ptr");
    assertOffset(GlyphRunSpan, c.HowlRenderGlyphRunSpan, "count");
    assertOffset(GlyphRunSpan, c.HowlRenderGlyphRunSpan, "count_max");
}

fn assertCommandLayout() void {
    assertLayout(Command, c.HowlRenderSurfaceCommand);
    assertOffset(Command, c.HowlRenderSurfaceCommand, "kind");
    assertOffset(Command, c.HowlRenderSurfaceCommand, "reserved0");
    assertOffset(Command, c.HowlRenderSurfaceCommand, "reserved1");
    assertOffset(Command, c.HowlRenderSurfaceCommand, "rect");
    assertOffset(Command, c.HowlRenderSurfaceCommand, "color_rgba");
    assertOffset(Command, c.HowlRenderSurfaceCommand, "resource");
    assertOffset(Command, c.HowlRenderSurfaceCommand, "glyphs");
}

fn assertCommandSpanLayout() void {
    assertLayout(CommandSpan, c.HowlRenderSurfaceCommandSpan);
    assertOffset(CommandSpan, c.HowlRenderSurfaceCommandSpan, "ptr");
    assertOffset(CommandSpan, c.HowlRenderSurfaceCommandSpan, "count");
    assertOffset(CommandSpan, c.HowlRenderSurfaceCommandSpan, "count_max");
}

fn assertRetireLayout() void {
    assertLayout(Retire, c.HowlRenderResourceRetire);
    assertOffset(Retire, c.HowlRenderResourceRetire, "resource");
    assertOffset(Retire, c.HowlRenderResourceRetire, "retire_seq");
}

fn assertRetireSpanLayout() void {
    assertLayout(RetireSpan, c.HowlRenderResourceRetireSpan);
    assertOffset(RetireSpan, c.HowlRenderResourceRetireSpan, "ptr");
    assertOffset(RetireSpan, c.HowlRenderResourceRetireSpan, "count");
    assertOffset(RetireSpan, c.HowlRenderResourceRetireSpan, "count_max");
}

fn assertHostAckLayout() void {
    assertLayout(HostAck, c.HowlRenderResourceAck);
    assertOffset(HostAck, c.HowlRenderResourceAck, "resource");
    assertOffset(HostAck, c.HowlRenderResourceAck, "ack_seq");
}

fn assertHostAckSpanLayout() void {
    assertLayout(HostAckSpan, c.HowlRenderResourceAckSpan);
    assertOffset(HostAckSpan, c.HowlRenderResourceAckSpan, "ptr");
    assertOffset(HostAckSpan, c.HowlRenderResourceAckSpan, "count");
    assertOffset(HostAckSpan, c.HowlRenderResourceAckSpan, "count_max");
}

fn assertSurfaceLayout() void {
    assertLayout(Surface, c.HowlRenderSurface);
    assertOffset(Surface, c.HowlRenderSurface, "surface_version");
    assertOffset(Surface, c.HowlRenderSurface, "reserved0");
    assertOffset(Surface, c.HowlRenderSurface, "token");
    assertOffset(Surface, c.HowlRenderSurface, "render_px");
    assertOffset(Surface, c.HowlRenderSurface, "cell_px");
    assertOffset(Surface, c.HowlRenderSurface, "grid");
    assertOffset(Surface, c.HowlRenderSurface, "damage");
    assertOffset(Surface, c.HowlRenderSurface, "creates");
    assertOffset(Surface, c.HowlRenderSurface, "uploads");
    assertOffset(Surface, c.HowlRenderSurface, "commands");
    assertOffset(Surface, c.HowlRenderSurface, "retires");
}

fn assertLayout(comptime Mirror: type, comptime Abi: type) void {
    std.debug.assert(@sizeOf(Mirror) == @sizeOf(Abi));
    std.debug.assert(@alignOf(Mirror) == @alignOf(Abi));
}

fn assertOffset(comptime Mirror: type, comptime Abi: type, comptime field: []const u8) void {
    std.debug.assert(@offsetOf(Mirror, field) == @offsetOf(Abi, field));
}

test {
    _ = @import("../render/render_surface_realizer.zig");
}
