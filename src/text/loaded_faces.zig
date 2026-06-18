const std = @import("std");
const render = @import("../libhowl_render.zig");
const font_paths = @import("font_paths.zig");
const c_api = @import("c_api.zig");

pub const c = c_api.c;
pub const FtLibrary = c_api.FtLibrary;
pub const FtFace = c_api.FtFace;
pub const HbFont = c_api.HbFont;
pub const primary_face_id: u32 = 1;
pub const FallbackFontCount = font_paths.FallbackFontCount;
pub const max_fallback_fonts: FallbackFontCount = font_paths.max_fallback_fonts;
pub const fallbackFontCount = font_paths.fallbackFontCount;

pub const ShapingFace = struct {
    face: FtFace,
    hb_font: ?HbFont,
    owns_face: bool,
};

pub const LoadedFaces = struct {
    ft_lib: ?FtLibrary = null,
    ft_face: ?FtFace = null,
    hb_font: ?HbFont = null,
    fallback_faces: [max_fallback_fonts]?FtFace = [_]?FtFace{null} ** max_fallback_fonts,
    fallback_hb_fonts: [max_fallback_fonts]?HbFont = [_]?HbFont{null} ** max_fallback_fonts,

    pub fn ensurePrimaryFontLocked(self: *LoadedFaces, font_path: ?[:0]const u8, font_size_px: u16) bool {
        if (self.ft_face != null) return true;
        if (!self.ensureFreeTypeLibraryLocked()) return false;
        if (font_path == null) return false;
        var face: FtFace = undefined;
        const lib = self.ft_lib.?;
        if (c.FT_New_Face(lib, font_path.?, 0, &face) != 0) return false;
        if (!selectUnicodeCharmap(face)) {
            _ = c.FT_Done_Face(face);
            return false;
        }
        if (!setFacePixelHeight(face, font_size_px)) {
            _ = c.FT_Done_Face(face);
            return false;
        }
        self.ft_face = face;
        self.hb_font = c_api.createHbFont(face);
        return true;
    }

    pub fn ensureFallbackFaceLocked(
        self: *LoadedFaces,
        fallback_index: FallbackFontCount,
        fallback_font_paths: *const [max_fallback_fonts]?[:0]const u8,
        fallback_font_paths_len: u8,
        font_size_px: u16,
    ) ?FtFace {
        const slot = fallbackSlot(fallback_index, fallback_font_paths_len) orelse return null;
        if (self.fallback_faces[slot]) |face| return face;
        if (!self.ensureFreeTypeLibraryLocked()) return null;
        const font_path = fallback_font_paths[slot] orelse return null;
        const lib = self.ft_lib orelse return null;
        var face: FtFace = undefined;
        if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) return null;
        if (!selectUnicodeCharmap(face)) {
            _ = c.FT_Done_Face(face);
            return null;
        }
        if (!setFacePixelHeight(face, font_size_px)) {
            _ = c.FT_Done_Face(face);
            return null;
        }
        self.fallback_faces[slot] = face;
        self.fallback_hb_fonts[slot] = c_api.createHbFont(face);
        return face;
    }

    pub fn ensureFaceForIdLocked(
        self: *LoadedFaces,
        face_id: render.FontFaceId,
        font_path: ?[:0]const u8,
        font_size_px: u16,
        fallback_font_paths: *const [max_fallback_fonts]?[:0]const u8,
        fallback_font_paths_len: u8,
    ) bool {
        if (face_id.value == primary_face_id) return self.ensurePrimaryFontLocked(font_path, font_size_px);
        if (face_id.value < 2) return false;
        const fallback_index = fallbackFontCount(face_id.value - 2) orelse return false;
        return self.ensureFallbackFaceLocked(fallback_index, fallback_font_paths, fallback_font_paths_len, font_size_px) != null;
    }

    pub fn acquireShapingFaceLocked(self: *LoadedFaces, face_id: render.FontFaceId, fallback_font_paths_len: u8) ?ShapingFace {
        if (face_id.value == primary_face_id) {
            const face = self.ft_face orelse return null;
            return .{ .face = face, .hb_font = self.hb_font, .owns_face = false };
        }
        const fallback_index = if (face_id.value >= 2)
            fallbackFontCount(face_id.value - 2) orelse return null
        else
            return null;
        const slot = fallbackSlot(fallback_index, fallback_font_paths_len) orelse return null;
        const face = self.fallback_faces[slot] orelse return null;
        return .{ .face = face, .hb_font = self.fallback_hb_fonts[slot], .owns_face = false };
    }

    pub fn resizeLocked(self: *LoadedFaces, font_size_px: u16) void {
        if (self.ft_face) |face| _ = setFacePixelHeight(face, font_size_px);
        for (self.fallback_faces) |face_opt| {
            if (face_opt) |face| _ = setFacePixelHeight(face, font_size_px);
        }
    }

    pub fn resetLocked(self: *LoadedFaces) void {
        self.resetFallbackFacesLocked();
        if (self.ft_face != null) {
            c_api.destroyHbFont(self.hb_font);
            self.hb_font = null;
            _ = c.FT_Done_Face(self.ft_face.?);
            self.ft_face = null;
        }
        if (self.ft_lib != null) {
            _ = c.FT_Done_FreeType(self.ft_lib.?);
            self.ft_lib = null;
        }
    }

    pub fn ensureFreeTypeLibraryLocked(self: *LoadedFaces) bool {
        if (self.ft_lib != null) return true;
        var lib: FtLibrary = undefined;
        if (c.FT_Init_FreeType(&lib) != 0) return false;
        self.ft_lib = lib;
        return true;
    }

    fn resetFallbackFacesLocked(self: *LoadedFaces) void {
        for (self.fallback_faces, 0..) |face_opt, i| {
            c_api.destroyHbFont(self.fallback_hb_fonts[i]);
            self.fallback_hb_fonts[i] = null;
            if (face_opt != null) {
                _ = c.FT_Done_Face(face_opt.?);
                self.fallback_faces[i] = null;
            }
        }
    }
};

fn selectUnicodeCharmap(face: FtFace) bool {
    return c.FT_Select_Charmap(face, c.FT_ENCODING_UNICODE) == 0;
}

fn setFacePixelHeight(face: FtFace, font_size_px: u16) bool {
    return c.FT_Set_Pixel_Sizes(face, 0, @max(font_size_px, 1)) == 0;
}

fn fallbackSlot(fallback_index: FallbackFontCount, fallback_font_paths_len: u8) ?FallbackFontCount {
    if (fallback_index >= fallback_font_paths_len) return null;
    return fallback_index;
}
