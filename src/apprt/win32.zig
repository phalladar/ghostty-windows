const internal_os = @import("../os/main.zig");

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = internal_os.resourcesDir;

pub const c = @import("win32/c.zig");
pub const clipboard = @import("win32/clipboard.zig");
pub const ime = @import("win32/ime.zig");
pub const ipc = @import("win32/ipc.zig");
pub const key = @import("win32/key.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
