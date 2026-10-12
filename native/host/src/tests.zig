//! Test root for the native host: pulls in every module's `test` blocks.
//! `zig build test` (or `mix live_cimgui.native_test`) runs these without a
//! display; GUI acceptance is a separate, explicitly display-requiring suite.

test {
    _ = @import("protocol.zig");
    _ = @import("scene.zig");
    _ = @import("transport.zig");
}
