const prepared_buffer = @import("prepared/buffer.zig");
const protocol_emit = @import("protocol_v0/emit.zig");
const text_session = @import("session/text.zig");

test "protocol v0 prepared proof target imports owner oracle" {
    _ = prepared_buffer.compose;
    _ = text_session.TextSession;
    _ = protocol_emit.Emitter;
}
