const geometry_contract = @import("../render/geometry_contract.zig");
const render_surface_emitter = @import("render_surface_emitter.zig");
const prepared_handle = @import("handle.zig");
const prepared_surface = @import("surface.zig");
const text_session = @import("../session/text.zig");

pub const PreparedSurfaceHandle = prepared_handle.PreparedSurfaceHandle;
pub const PreparedInfo = prepared_surface.PreparedInfo;
pub const PreparedBuffer = prepared_surface.PreparedBuffer;
pub const RenderSurfaceEmissionFailure = render_surface_emitter.RenderSurfaceEmissionFailure;
pub const Owner = prepared_handle.PreparedHandle;

pub const testing = struct {
    pub fn executionMatchesPrepared(render_px: geometry_contract.PixelSize, execution: text_session.TextSession.SubmitExecution) bool {
        return prepared_handle.testing.executionMatchesPrepared(render_px, execution);
    }

    pub fn renderSurfaceEmissionFailureFromError(err: render_surface_emitter.Error) RenderSurfaceEmissionFailure {
        return render_surface_emitter.emissionFailureFromError(err);
    }
};
