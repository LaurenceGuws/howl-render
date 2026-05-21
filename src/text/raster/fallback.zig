
const PixelIndex = @TypeOf(@as([]const u8, &.{}).len);

pub fn rasterAsciiOrPlaceholder(dst: []u8, cell_w: u16, codepoint: u21, gw: u16, gh: u16) void {
    _ = codepoint;
    rasterPlaceholder(dst, cell_w, gw, gh);
}

fn rasterPlaceholder(dst: []u8, cell_w: u16, gw: u16, gh: u16) void {
    const w = @max(gw, 1);
    const h = @max(gh, 1);
    for (0..h) |yy| {
        for (0..w) |xx| {
            const border = xx == 0 or yy == 0 or xx + 1 == w or yy + 1 == h;
            const diagonal = xx == yy or xx + yy + 1 == w;
            const idx = @as(PixelIndex, yy) * @as(PixelIndex, cell_w) + @as(PixelIndex, xx);
            dst[idx] = if (border or diagonal) 255 else 0;
        }
    }
}
