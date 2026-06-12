const tokens = @import("../geometry/tokens.zig");

pub const HostSurface = struct {
    host_surface_id: u64,
    width: u16,
    height: u16,
};

pub const SubmitResult = struct {
    damage_kind: tokens.DamageKind,
    host_surface: HostSurface,

    pub fn damageKind(self: SubmitResult) tokens.DamageKind {
        return self.damage_kind;
    }
};
