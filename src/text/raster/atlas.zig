const std = @import("std");

/// Text-atlas layout contract shared by surface execution owners.
pub const AtlasLayout = struct {
    cell_w: u16,
    cell_h: u16,
    slot_stride: u64,
    max_slots: u32,
};

/// Return the atlas slice for one slot when it is in bounds.
pub fn slotSlice(layout: AtlasLayout, atlas: []u8, slot: u32) ?[]u8 {
    if (slot >= layout.max_slots) return null;
    const slot_index = std.math.mul(u64, slot, layout.slot_stride) catch return null;
    const slot_end = std.math.add(u64, slot_index, layout.slot_stride) catch return null;
    if (slot_end > atlas.len) return null;
    return atlas[@intCast(slot_index)..@intCast(slot_end)];
}
