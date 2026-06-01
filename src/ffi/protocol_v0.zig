const std = @import("std");
const c = @import("../ffi.zig").c;

comptime {
    assertConstants();
    assertLayoutAll();
}

const Token = extern struct {
    snapshot_seq: u64,
    frame_seq: u64,
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

const Frame = extern struct {
    protocol_version: u32,
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
    std.debug.assert(c.HOWL_RENDER_PROTOCOL_V0_VERSION == 0);
    std.debug.assert(c.HOWL_RENDER_V0_FRAMES_IN_FLIGHT_MAX == 2);
    std.debug.assert(c.HOWL_RENDER_V0_SNAPSHOTS_IN_FLIGHT_MAX == 2);
    std.debug.assert(c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX == 1024);
    std.debug.assert(c.HOWL_RENDER_V0_UPLOADS_MAX == 256);
    std.debug.assert(c.HOWL_RENDER_V0_COMMANDS_MAX == 8192);
    std.debug.assert(c.HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX == 256);
    std.debug.assert(c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX == 8388608);
    std.debug.assert(c.HOWL_RENDER_V0_ATLAS_PAGES_MAX == 64);
    std.debug.assert(c.HOWL_RENDER_V0_RESOURCES_MAX == 4096);
    std.debug.assert(c.HOWL_RENDER_V0_CREATES_MAX == 256);
    std.debug.assert(c.HOWL_RENDER_V0_RETIRES_MAX == 256);
    std.debug.assert(c.HOWL_RENDER_V0_HOST_ACKS_MAX == 256);
    std.debug.assert(c.HOWL_RENDER_V0_DAMAGE_RECT == 1);
    std.debug.assert(c.HOWL_RENDER_V0_DAMAGE_FULL == 2);
    std.debug.assert(c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_ALPHA == 1);
    std.debug.assert(c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_COLOR == 2);
    std.debug.assert(c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA == 3);
    std.debug.assert(c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR == 4);
    std.debug.assert(c.HOWL_RENDER_V0_UPLOAD_ALPHA8 == 1);
    std.debug.assert(c.HOWL_RENDER_V0_UPLOAD_RGBA8 == 2);
    std.debug.assert(c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT == 1);
    std.debug.assert(c.HOWL_RENDER_V0_COMMAND_FILL_RECT == 2);
    std.debug.assert(c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN == 3);
    std.debug.assert(c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE == 4);
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
    assertFrameLayout();
}

fn assertTokenLayout() void {
    assertLayout(Token, c.HowlRenderV0Token);
    assertOffset(Token, c.HowlRenderV0Token, "snapshot_seq");
    assertOffset(Token, c.HowlRenderV0Token, "frame_seq");
    assertOffset(Token, c.HowlRenderV0Token, "geometry_epoch");
    assertOffset(Token, c.HowlRenderV0Token, "resource_epoch");
}

fn assertRectLayout() void {
    assertLayout(Rect, c.HowlRenderV0Rect);
    assertOffset(Rect, c.HowlRenderV0Rect, "x_px");
    assertOffset(Rect, c.HowlRenderV0Rect, "y_px");
    assertOffset(Rect, c.HowlRenderV0Rect, "width_px");
    assertOffset(Rect, c.HowlRenderV0Rect, "height_px");
}

fn assertDamageItemLayout() void {
    assertLayout(DamageItem, c.HowlRenderV0DamageItem);
    assertOffset(DamageItem, c.HowlRenderV0DamageItem, "kind");
    assertOffset(DamageItem, c.HowlRenderV0DamageItem, "reserved0");
    assertOffset(DamageItem, c.HowlRenderV0DamageItem, "reserved1");
    assertOffset(DamageItem, c.HowlRenderV0DamageItem, "rect");
}

fn assertDamageSpanLayout() void {
    assertLayout(DamageSpan, c.HowlRenderV0DamageSpan);
    assertOffset(DamageSpan, c.HowlRenderV0DamageSpan, "ptr");
    assertOffset(DamageSpan, c.HowlRenderV0DamageSpan, "count");
    assertOffset(DamageSpan, c.HowlRenderV0DamageSpan, "count_max");
}

fn assertResourceIdLayout() void {
    assertLayout(ResourceId, c.HowlRenderV0ResourceId);
    assertOffset(ResourceId, c.HowlRenderV0ResourceId, "value");
    assertOffset(ResourceId, c.HowlRenderV0ResourceId, "generation");
    assertOffset(ResourceId, c.HowlRenderV0ResourceId, "kind");
}

fn assertUploadLayout() void {
    assertLayout(Upload, c.HowlRenderV0Upload);
    assertOffset(Upload, c.HowlRenderV0Upload, "resource");
    assertOffset(Upload, c.HowlRenderV0Upload, "rect");
    assertOffset(Upload, c.HowlRenderV0Upload, "bytes_ptr");
    assertOffset(Upload, c.HowlRenderV0Upload, "bytes_count");
    assertOffset(Upload, c.HowlRenderV0Upload, "stride_bytes");
    assertOffset(Upload, c.HowlRenderV0Upload, "format");
    assertOffset(Upload, c.HowlRenderV0Upload, "upload_seq");
}

fn assertUploadSpanLayout() void {
    assertLayout(UploadSpan, c.HowlRenderV0UploadSpan);
    assertOffset(UploadSpan, c.HowlRenderV0UploadSpan, "ptr");
    assertOffset(UploadSpan, c.HowlRenderV0UploadSpan, "count");
    assertOffset(UploadSpan, c.HowlRenderV0UploadSpan, "count_max");
    assertOffset(UploadSpan, c.HowlRenderV0UploadSpan, "bytes_count_total");
    assertOffset(UploadSpan, c.HowlRenderV0UploadSpan, "bytes_count_max");
}

fn assertCreateLayout() void {
    assertLayout(Create, c.HowlRenderV0Create);
    assertOffset(Create, c.HowlRenderV0Create, "resource");
    assertOffset(Create, c.HowlRenderV0Create, "width_px");
    assertOffset(Create, c.HowlRenderV0Create, "height_px");
    assertOffset(Create, c.HowlRenderV0Create, "format");
    assertOffset(Create, c.HowlRenderV0Create, "create_seq");
}

fn assertCreateSpanLayout() void {
    assertLayout(CreateSpan, c.HowlRenderV0CreateSpan);
    assertOffset(CreateSpan, c.HowlRenderV0CreateSpan, "ptr");
    assertOffset(CreateSpan, c.HowlRenderV0CreateSpan, "count");
    assertOffset(CreateSpan, c.HowlRenderV0CreateSpan, "count_max");
}

fn assertGlyphRefLayout() void {
    assertLayout(GlyphRef, c.HowlRenderV0GlyphRef);
    assertOffset(GlyphRef, c.HowlRenderV0GlyphRef, "atlas_resource");
    assertOffset(GlyphRef, c.HowlRenderV0GlyphRef, "atlas_rect");
    assertOffset(GlyphRef, c.HowlRenderV0GlyphRef, "x_px");
    assertOffset(GlyphRef, c.HowlRenderV0GlyphRef, "y_px");
    assertOffset(GlyphRef, c.HowlRenderV0GlyphRef, "glyph_id");
    assertOffset(GlyphRef, c.HowlRenderV0GlyphRef, "color_rgba");
}

fn assertGlyphRunSpanLayout() void {
    assertLayout(GlyphRunSpan, c.HowlRenderV0GlyphRunSpan);
    assertOffset(GlyphRunSpan, c.HowlRenderV0GlyphRunSpan, "ptr");
    assertOffset(GlyphRunSpan, c.HowlRenderV0GlyphRunSpan, "count");
    assertOffset(GlyphRunSpan, c.HowlRenderV0GlyphRunSpan, "count_max");
}

fn assertCommandLayout() void {
    assertLayout(Command, c.HowlRenderV0Command);
    assertOffset(Command, c.HowlRenderV0Command, "kind");
    assertOffset(Command, c.HowlRenderV0Command, "reserved0");
    assertOffset(Command, c.HowlRenderV0Command, "reserved1");
    assertOffset(Command, c.HowlRenderV0Command, "rect");
    assertOffset(Command, c.HowlRenderV0Command, "color_rgba");
    assertOffset(Command, c.HowlRenderV0Command, "resource");
    assertOffset(Command, c.HowlRenderV0Command, "glyphs");
}

fn assertCommandSpanLayout() void {
    assertLayout(CommandSpan, c.HowlRenderV0CommandSpan);
    assertOffset(CommandSpan, c.HowlRenderV0CommandSpan, "ptr");
    assertOffset(CommandSpan, c.HowlRenderV0CommandSpan, "count");
    assertOffset(CommandSpan, c.HowlRenderV0CommandSpan, "count_max");
}

fn assertRetireLayout() void {
    assertLayout(Retire, c.HowlRenderV0Retire);
    assertOffset(Retire, c.HowlRenderV0Retire, "resource");
    assertOffset(Retire, c.HowlRenderV0Retire, "retire_seq");
}

fn assertRetireSpanLayout() void {
    assertLayout(RetireSpan, c.HowlRenderV0RetireSpan);
    assertOffset(RetireSpan, c.HowlRenderV0RetireSpan, "ptr");
    assertOffset(RetireSpan, c.HowlRenderV0RetireSpan, "count");
    assertOffset(RetireSpan, c.HowlRenderV0RetireSpan, "count_max");
}

fn assertHostAckLayout() void {
    assertLayout(HostAck, c.HowlRenderV0HostAck);
    assertOffset(HostAck, c.HowlRenderV0HostAck, "resource");
    assertOffset(HostAck, c.HowlRenderV0HostAck, "ack_seq");
}

fn assertHostAckSpanLayout() void {
    assertLayout(HostAckSpan, c.HowlRenderV0HostAckSpan);
    assertOffset(HostAckSpan, c.HowlRenderV0HostAckSpan, "ptr");
    assertOffset(HostAckSpan, c.HowlRenderV0HostAckSpan, "count");
    assertOffset(HostAckSpan, c.HowlRenderV0HostAckSpan, "count_max");
}

fn assertFrameLayout() void {
    assertLayout(Frame, c.HowlRenderV0Frame);
    assertOffset(Frame, c.HowlRenderV0Frame, "protocol_version");
    assertOffset(Frame, c.HowlRenderV0Frame, "reserved0");
    assertOffset(Frame, c.HowlRenderV0Frame, "token");
    assertOffset(Frame, c.HowlRenderV0Frame, "render_px");
    assertOffset(Frame, c.HowlRenderV0Frame, "cell_px");
    assertOffset(Frame, c.HowlRenderV0Frame, "grid");
    assertOffset(Frame, c.HowlRenderV0Frame, "damage");
    assertOffset(Frame, c.HowlRenderV0Frame, "creates");
    assertOffset(Frame, c.HowlRenderV0Frame, "uploads");
    assertOffset(Frame, c.HowlRenderV0Frame, "commands");
    assertOffset(Frame, c.HowlRenderV0Frame, "retires");
}

fn assertLayout(comptime Mirror: type, comptime Abi: type) void {
    std.debug.assert(@sizeOf(Mirror) == @sizeOf(Abi));
    std.debug.assert(@alignOf(Mirror) == @alignOf(Abi));
}

fn assertOffset(comptime Mirror: type, comptime Abi: type, comptime field: []const u8) void {
    std.debug.assert(@offsetOf(Mirror, field) == @offsetOf(Abi, field));
}

test {
    _ = @import("../protocol_v0/realize.zig");
}
