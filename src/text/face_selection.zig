const std = @import("std");

const render = @import("../grid/scene.zig");

pub const FaceId = render.FontFaceId;

pub const FaceRole = enum(u3) {
    primary,
    style,
    symbol,
    fallback,
    emoji,
    missing,
};

pub const FaceRecord = struct {
    id: FaceId,
    role: FaceRole,
    style: render.FontStyle = .regular,
    presentation: render.TextPresentation = .any,
    coverage: Coverage = .all,

    pub fn hasCellText(self: FaceRecord, text: render.CellText) bool {
        for (text.codepoints) |cp| {
            if (isNonRenderingCodepoint(cp)) continue;
            if (!covers(self.coverage, cp)) return false;
        }
        return true;
    }
};

pub const HasCellTextFn = *const fn (ctx: *anyopaque, face_id: FaceId, text: render.CellText) bool;

pub const FaceProvider = struct {
    ctx: *anyopaque,
    has_cell_text: HasCellTextFn,

    pub fn hasCellText(self: FaceProvider, face_id: FaceId, text: render.CellText) bool {
        return self.has_cell_text(self.ctx, face_id, text);
    }
};

pub const Coverage = union(enum) {
    all,
    range: CodepointRange,
};

pub const CodepointRange = struct {
    first: u32,
    last: u32,

    pub fn contains(self: CodepointRange, cp: u32) bool {
        return self.first <= cp and cp <= self.last;
    }
};

pub const FaceSelection = struct {
    primary_face: FaceId = .{ .value = 1 },
    faces: []const FaceRecord = &.{},
    provider: ?FaceProvider = null,
    cell_metrics: render.CellMetrics = .{ .cell_w_px = 1, .cell_h_px = 1, .baseline_px = 1 },

    pub fn primary(self: FaceSelection) FaceRecord {
        for (self.faces) |face| {
            if (face.role == .primary and face.id.value == self.primary_face.value) return face;
        }
        for (self.faces) |face| {
            if (face.role == .primary) return face;
        }
        return .{ .id = self.primary_face, .role = .primary };
    }

    pub fn findStyle(self: FaceSelection, style: render.FontStyle, presentation: render.TextPresentation, text: render.CellText) ?FaceRecord {
        if (self.findText(.style, style, presentation, text)) |face| return face;
        return validPrimary(self, self.primary(), text);
    }

    pub fn findSymbol(self: FaceSelection, cp: u32) ?FaceRecord {
        return self.find(.symbol, .regular, .any, cp);
    }

    pub fn findFallback(self: FaceSelection, style: render.FontStyle, presentation: render.TextPresentation, text: render.CellText) ?FaceRecord {
        return self.findText(.fallback, style, presentation, text) orelse self.findText(.fallback, .regular, .any, text);
    }

    fn find(self: FaceSelection, role: FaceRole, style: render.FontStyle, presentation: render.TextPresentation, cp: u32) ?FaceRecord {
        for (self.faces) |face| {
            if (face.role != role) continue;
            if (face.style != style and face.style != .regular) continue;
            if (face.presentation != presentation and face.presentation != .any) continue;
            if (!covers(face.coverage, cp)) continue;
            return face;
        }
        return null;
    }

    fn findText(self: FaceSelection, role: FaceRole, style: render.FontStyle, presentation: render.TextPresentation, text: render.CellText) ?FaceRecord {
        for (self.faces) |face| {
            if (face.role != role) continue;
            if (face.style != style and face.style != .regular) continue;
            if (face.presentation != presentation and face.presentation != .any) continue;
            if (!self.hasCellText(face, text)) continue;
            return face;
        }
        return null;
    }

    pub fn hasCellText(self: FaceSelection, face: FaceRecord, text: render.CellText) bool {
        if (self.provider) |provider| return provider.hasCellText(face.id, text);
        return face.hasCellText(text);
    }
};

fn validPrimary(self: FaceSelection, face: FaceRecord, text: render.CellText) ?FaceRecord {
    return if (self.hasCellText(face, text)) face else null;
}

fn covers(coverage: Coverage, cp: u32) bool {
    return switch (coverage) {
        .all => true,
        .range => |range| range.contains(cp),
    };
}

fn isNonRenderingCodepoint(cp: u32) bool {
    return cp == 0xfe0e or cp == 0xfe0f;
}

test "face selection has deterministic defaults" {
    const selection = FaceSelection{};
    try std.testing.expectEqual(@as(u32, 1), selection.primary_face.value);
    try std.testing.expectEqual(@as(u32, 1), selection.primary().id.value);
}

test "face selection resolves symbol and fallback records by coverage" {
    const faces = [_]FaceRecord{
        .{ .id = .{ .value = 2 }, .role = .symbol, .coverage = .{ .range = .{ .first = 0xe000, .last = 0xf8ff } } },
        .{ .id = .{ .value = 3 }, .role = .fallback, .coverage = .{ .range = .{ .first = 0x2600, .last = 0x26ff } } },
    };
    const selection = FaceSelection{ .faces = &faces };
    try std.testing.expectEqual(@as(u32, 2), selection.findSymbol(0xe0b0).?.id.value);
    const snowman = render.CellText{ .id = .{ .value = 1 }, .first_cp = 0x2603, .codepoints = &.{0x2603} };
    try std.testing.expectEqual(@as(u32, 3), selection.findFallback(.regular, .any, snowman).?.id.value);
}

test "face selection validates all rendering codepoints in cell text" {
    const faces = [_]FaceRecord{
        .{ .id = .{ .value = 2 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
        .{ .id = .{ .value = 3 }, .role = .fallback, .coverage = .all },
    };
    const selection = FaceSelection{ .faces = &faces };
    const combining = render.CellText{ .id = .{ .value = 1 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } };
    const emoji_presentation = render.CellText{ .id = .{ .value = 2 }, .first_cp = 'x', .codepoints = &.{ 'x', 0xfe0f } };
    try std.testing.expect(selection.findStyle(.regular, .any, combining) == null);
    try std.testing.expectEqual(@as(u32, 3), selection.findFallback(.regular, .any, combining).?.id.value);
    try std.testing.expectEqual(@as(u32, 2), selection.findStyle(.regular, .any, emoji_presentation).?.id.value);
}

test "face selection primary lookup preserves configured face without synthetic coverage" {
    const faces = [_]FaceRecord{
        .{ .id = .{ .value = 2 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
        .{ .id = .{ .value = 4 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 3 }, .role = .fallback, .coverage = .all },
    };
    const selection = FaceSelection{ .primary_face = .{ .value = 2 }, .faces = &faces };
    const combining = render.CellText{ .id = .{ .value = 1 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } };
    try std.testing.expectEqual(@as(u32, 2), selection.primary().id.value);
    try std.testing.expect(selection.findStyle(.regular, .any, combining) == null);
    try std.testing.expectEqual(@as(u32, 3), selection.findFallback(.regular, .any, combining).?.id.value);
}

test "face selection provider can reject static coverage hits" {
    const Provider = struct {
        fn has(ctx: *anyopaque, face_id: FaceId, text: render.CellText) bool {
            _ = ctx;
            if (face_id.value == 1 and text.codepoints.len > 1) return false;
            return true;
        }
    };
    const faces = [_]FaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    var dummy: u8 = 0;
    const selection = FaceSelection{ .faces = &faces, .provider = .{ .ctx = &dummy, .has_cell_text = Provider.has } };
    const sequence = render.CellText{ .id = .{ .value = 1 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } };
    try std.testing.expect(selection.findStyle(.regular, .any, sequence) == null);
    try std.testing.expectEqual(@as(u32, 2), selection.findFallback(.regular, .any, sequence).?.id.value);
}
