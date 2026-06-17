pub const max_extra_cursors = 256;
pub const max_cursor_trail_rects = 16;

pub const ColorKind = enum(u8) {
    default = 0,
    indexed = 1,
    rgb = 2,
};

pub const CursorColor = struct {
    kind: ColorKind,
    value: u32,
};

pub const Rgb8 = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const CellExtent = struct {
    row: u16,
    col: u16,
    rows: u16,
    cols: u16,
};

pub const CursorShape = enum(u8) {
    none = 0,
    block = 1,
    beam = 2,
    underline = 3,
    hollow = 4,
};

pub const ExtraCursorMode = enum(u8) {
    point = 0,
    rectangle = 1,
};

pub const ExtraCursorPresentation = struct {
    extent: CellExtent,
    shape: CursorShape,
    mode: ExtraCursorMode,
    shape_follows_main: bool,
    color_follows_main: bool,
    cursor_color: CursorColor,
    text_color: CursorColor,
};

pub const CursorTrailRect = struct {
    extent: CellExtent,
    opacity: u8,
    color: Rgb8,
    pixel_rect: bool = false,
    x_px: i32 = 0,
    y_px: i32 = 0,
    width_px: u16 = 0,
    height_px: u16 = 0,
};

pub const CursorTrailSource = struct {
    rects: [max_cursor_trail_rects]CursorTrailRect,
    count: u16,
};

pub const CursorPresentation = struct {
    focused: bool,
    visible: bool,
    blink: bool,
    shape: CursorShape,
    beam_thickness: f32 = 1.5,
    underline_thickness: f32 = 2.0,
    cursor_opacity: u8,
    text_blink_opacity: u8,
    cursor_color: CursorColor,
    cursor_text_color: CursorColor,
    cursor_trail_color: CursorColor = .{ .kind = .default, .value = 0 },
    default_foreground: Rgb8,
    default_background: Rgb8,
    primary_extent: CellExtent,
    extra_cursors: [max_extra_cursors]ExtraCursorPresentation,
    extra_cursor_count: u16,
    trail: CursorTrailSource,
};
