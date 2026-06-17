const std = @import("std");
const scene = @import("../text/scene.zig");

pub const PrepareOptions = struct {
    scene: scene.BuildOptions = .{},
};

test "prepare options default to scene build defaults" {
    const options: PrepareOptions = .{};
    try std.testing.expect(options.scene.cursor == null);
}
