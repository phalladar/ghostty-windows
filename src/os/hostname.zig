const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const LocalHostnameValidationError = error{
    PermissionDenied,
    Unexpected,
};

/// Checks if a hostname is local to the current machine. This matches
/// both "localhost" and the current hostname of the machine (as returned
/// by `gethostname`).
pub fn isLocal(hostname: []const u8) LocalHostnameValidationError!bool {
    // A 'localhost' hostname is always considered local.
    if (std.mem.eql(u8, "localhost", hostname)) return true;

    // If hostname is not "localhost" it must match our hostname.
    switch (builtin.os.tag) {
        .windows => {
            var buf: [256]u8 = undefined;
            const ourHostname = windowsHostname(&buf) orelse return false;
            return std.ascii.eqlIgnoreCase(hostname, ourHostname);
        },
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const ourHostname = try posix.gethostname(&buf);
            return std.mem.eql(u8, hostname, ourHostname);
        },
    }
}

fn windowsHostname(buf: []u8) ?[]const u8 {
    const windows = @import("windows.zig");
    var wbuf: [64]u16 = undefined;
    var n: windows.DWORD = wbuf.len;
    if (windows.exp.kernel32.GetComputerNameExW(
        .DnsHostname,
        &wbuf,
        &n,
    ) == windows.FALSE) return null;
    const len = std.unicode.utf16LeToUtf8(buf, wbuf[0..n]) catch return null;
    return buf[0..len];
}

test "isLocal returns true when provided hostname is localhost" {
    try std.testing.expect(try isLocal("localhost"));
}

test "isLocal returns true when hostname is local" {
    switch (builtin.os.tag) {
        .windows => {
            var buf: [256]u8 = undefined;
            const localHostname = windowsHostname(&buf) orelse
                return error.GetComputerNameFailed;
            try std.testing.expect(try isLocal(localHostname));
        },
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const localHostname = try posix.gethostname(&buf);
            try std.testing.expect(try isLocal(localHostname));
        },
    }
}

test "isLocal returns false when hostname is not local" {
    try std.testing.expectEqual(
        false,
        try isLocal("not-the-local-hostname"),
    );
}
