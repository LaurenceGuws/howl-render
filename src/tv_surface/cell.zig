// Temporary compatibility input until Slice 2 moves renderable content owners out of `tv_surface`.
pub const Color = struct {
    pub const Kind = enum {
        default,
        indexed,
        rgb,
    };

    kind: Kind = .default,
    value: u24 = 0,
};

pub const CellFlags = packed struct {
    continuation: bool = false,
    _pad: u7 = 0,
};

pub const CellAttrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    underline_color_set: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    selected: bool = false,
};

pub const UnderlineStyle = enum {
    straight,
    double,
    curly,
    dotted,
    dashed,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    combining_len: u8 = 0,
    combining: [3]u32 = [_]u32{0} ** 3,
    flags: CellFlags = .{},
    fg_color: Color = .{ .kind = .default, .value = 0 },
    bg_color: Color = .{ .kind = .default, .value = 0 },
    underline_color: Color = .{ .kind = .default, .value = 0 },
    underline_style: UnderlineStyle = .straight,
    attrs: CellAttrs = .{},
    link_id: u32 = 0,
};

pub const GridModel = struct {
    cells: []const Cell,
    cols: u16,
    rows: u16,
};

pub const DamageInfo = struct {
    full: bool = true,
    dirty_rows: []const bool = &.{},
    dirty_cols_start: []const u16 = &.{},
    dirty_cols_end: []const u16 = &.{},
};

pub const ViewportInfo = struct {
    cols: u16,
    rows: u16,
    scroll_row: u64 = 0,
    is_alternate_screen: bool = false,
};

pub const CursorShape = enum {
    block,
    underline,
    beam,
    hollow_block,
};

pub const CursorInfo = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
    shape: CursorShape = .block,
    // Cursor blink stores VT truth only.
    blink: bool = false,
};

pub const SurfaceData = struct {
    viewport: ViewportInfo,
    grid: GridModel,
    cursor: CursorInfo,
    damage: DamageInfo = .{},
};
