const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");
const windows = @import("windows.zig");

const log = std.log.scoped(.@"os-open");

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored.
///
/// This function is purposely simple for the sake of providing some portable
/// way to open URLs. If you are implementing an apprt for Ghostty, you should
/// consider doing something special-cased for your platform.
pub fn open(
    kind: apprt.action.OpenUrl.Kind,
    url: []const u8,
) !void {
    // On macOS, the apprt handles OSC 8 targets before this fallback. Ghostty's
    // native apprt applies its allowlist, confirmation, and file safety policy.
    // If a macOS embedder declines the action, fail closed rather than bypassing
    // that policy by handing producer-controlled terminal output to `open`.
    if (comptime builtin.os.tag == .macos) {
        if (kind == .osc8) return error.UnsafeOSC8Link;
    }

    var spawn_opts: std.process.SpawnOptions = switch (builtin.os.tag) {
        .linux, .freebsd => .{ .argv = &.{ "xdg-open", url } },
        .windows => return openWindows(kind, url),
        .macos => switch (kind) {
            .text => .{ .argv = &.{ "open", "-t", url } },
            .html, .unknown => .{ .argv = &.{ "open", url } },
            .osc8 => unreachable,
        },
        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };
    // Ignore anything from stdout. This must be set before spawning the
    // process.
    spawn_opts.stdout = .ignore;
    // Pipe stderr so we can log the stderr from the command. This must be set
    // before spawning the process.
    spawn_opts.stderr = .pipe;

    const exe = if (comptime build_config.snap) local_env: {
        // In the snap on Linux the launcher exports LD_LIBRARY_PATH
        // pointing at the snap's bundled libraries. Leaking this into
        // child process can can be problematic, so let's drop it from the
        // env.
        //
        // Note that `spawn` copies the passed in `Environ.Map` into a
        // fresh `Environ` block, so this is safe to release immediately
        // after spawn.
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        _ = environ_map.orderedRemove("LD_LIBRARY_PATH");
        spawn_opts.environ_map = &environ_map;
        break :local_env try std.process.spawn(global.io(), spawn_opts);
    } else
        // Non-snap releases don't need to alter the env.
        try std.process.spawn(global.io(), spawn_opts);

    const thread = try std.Thread.spawn(.{}, openThread, .{ global.io(), exe });
    thread.detach();
}

test "macOS OSC 8 links have no generic opener fallback" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    try std.testing.expectError(
        error.UnsafeOSC8Link,
        open(.osc8, "file:///tmp/payload.command"),
    );
}

const windows_path_max = 4096;

const WindowsOsc8Error = error{
    UnsafeCharacter,
    MalformedURL,
    UnsupportedScheme,
    RemoteFile,
    InaccessibleFile,
    UnsafeFile,
};

const windows_unsafe_extensions = [_][]const u8{
    "exe",  "bat",       "cmd",         "com",               "lnk",    "ps1",
    "psm1", "vbs",       "vbe",         "js",                "jse",    "wsf",
    "wsh",  "msi",       "msp",         "scr",               "pif",    "cpl",
    "hta",  "msc",       "reg",         "url",               "scf",    "inf",
    "jar",  "appref-ms", "application", "settingcontent-ms", "gadget",
};

fn openWindows(kind: apprt.action.OpenUrl.Kind, url: []const u8) !void {
    var path_buf: [windows_path_max:0]u16 = undefined;
    const path: ?[:0]const u16 = if (kind == .osc8)
        windowsOsc8Target(url, &path_buf) catch |err| {
            log.warn("refusing to open OSC 8 link err={} url={s}", .{ err, url });
            return error.UnsafeOSC8Link;
        }
    else
        null;

    const alloc = global.alloc();
    const target: [:0]u16 = if (path) |p|
        try alloc.dupeZ(u16, p)
    else
        try std.unicode.utf8ToUtf16LeAllocZ(alloc, url);
    errdefer alloc.free(target);

    // The core calls this with the renderer lock held, and ShellExecuteW
    // pumps messages until the handler starts, so it must not run here.
    const thread = try std.Thread.spawn(.{}, shellExecuteThread, .{target});
    thread.detach();
}

fn shellExecuteThread(target: [:0]u16) void {
    defer global.alloc().free(target);
    const hr = windows.exp.ole32.CoInitializeEx(
        null,
        windows.COINIT_APARTMENTTHREADED | windows.COINIT_DISABLE_OLE1DDE,
    );
    defer if (hr >= 0) windows.exp.ole32.CoUninitialize();

    const result = windows.exp.shell32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        target,
        null,
        null,
        windows.SW_SHOWNORMAL,
    );
    const code = @intFromPtr(result);
    if (code <= 32) {
        log.warn("ShellExecuteW failed code={} target={f}", .{ code, std.unicode.fmtUtf16Le(target) });
        return;
    }
    log.debug("opened target={f}", .{std.unicode.fmtUtf16Le(target)});
}

fn windowsOsc8Target(
    url: []const u8,
    buf: *[windows_path_max:0]u16,
) WindowsOsc8Error!?[:0]const u16 {
    for (url) |b| if (b < 0x20 or b == 0x7F) return error.UnsafeCharacter;

    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return error.MalformedURL;
    const scheme = url[0..colon];
    const rest = url[colon + 1 ..];
    if (scheme.len == 0) return error.MalformedURL;

    if (std.ascii.eqlIgnoreCase(scheme, "http") or
        std.ascii.eqlIgnoreCase(scheme, "https"))
    {
        if (!std.mem.startsWith(u8, rest, "//")) return error.MalformedURL;
        const authority = rest[2..];
        const end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
        if (end == 0) return error.MalformedURL;
        return null;
    }

    if (std.ascii.eqlIgnoreCase(scheme, "mailto")) {
        if (rest.len == 0) return error.MalformedURL;
        return null;
    }

    if (std.ascii.eqlIgnoreCase(scheme, "file")) return try windowsFileTarget(rest, buf);

    return error.UnsupportedScheme;
}

fn windowsFileTarget(
    rest: []const u8,
    buf: *[windows_path_max:0]u16,
) WindowsOsc8Error![:0]const u16 {
    if (!std.mem.startsWith(u8, rest, "//")) return error.MalformedURL;
    if (std.mem.indexOfAny(u8, rest, "?#") != null) return error.MalformedURL;
    const after = rest[2..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return error.MalformedURL;
    const host = after[0..slash];
    if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return error.RemoteFile;

    const encoded = after[slash..];
    if (encoded.len >= windows_path_max) return error.MalformedURL;
    var decoded_buf: [windows_path_max]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        var b = encoded[i];
        if (b == '%') {
            if (i + 2 >= encoded.len) return error.MalformedURL;
            b = std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16) catch return error.MalformedURL;
            i += 2;
        }
        if (b < 0x20 or b == 0x7F) return error.UnsafeCharacter;
        decoded_buf[len] = if (b == '/') '\\' else b;
        len += 1;
    }
    const decoded = decoded_buf[0..len];

    if (decoded.len < 3 or
        decoded[0] != '\\' or
        !std.ascii.isAlphabetic(decoded[1]) or
        decoded[2] != ':' or
        (decoded.len > 3 and decoded[3] != '\\'))
    {
        return error.MalformedURL;
    }
    const local = decoded[1..];
    if (std.mem.indexOfScalarPos(u8, local, 2, ':') != null) return error.UnsafeFile;

    const wlen = std.unicode.utf8ToUtf16Le(buf, local) catch return error.MalformedURL;
    var end = wlen;
    if (local.len == 2) {
        buf[end] = '\\';
        end += 1;
    }
    buf[end] = 0;
    const path = buf[0..end :0];

    const attrs = windows.exp.kernel32.GetFileAttributesW(path.ptr);
    if (attrs == windows.INVALID_FILE_ATTRIBUTES) return error.InaccessibleFile;
    if (attrs & windows.FILE_ATTRIBUTE_DIRECTORY == 0 and
        windowsUnsafeExtension(local)) return error.UnsafeFile;
    return path;
}

fn windowsUnsafeExtension(path: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, path, ". ");
    const base_start = if (std.mem.lastIndexOfAny(u8, trimmed, "\\/")) |idx| idx + 1 else 0;
    const base = trimmed[base_start..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return false;
    const ext = base[dot + 1 ..];
    for (windows_unsafe_extensions) |unsafe| {
        if (std.ascii.eqlIgnoreCase(ext, unsafe)) return true;
    }
    return false;
}

test "windows OSC 8 link safety" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    var buf: [windows_path_max:0]u16 = undefined;

    try testing.expectEqual(null, try windowsOsc8Target("https://example.com/a", &buf));
    try testing.expectEqual(null, try windowsOsc8Target("mailto:a@example.com", &buf));
    try testing.expectError(error.MalformedURL, windowsOsc8Target("https:relative", &buf));
    try testing.expectError(error.UnsafeCharacter, windowsOsc8Target("https://a\x1b.com", &buf));
    try testing.expectError(error.UnsupportedScheme, windowsOsc8Target("ms-msdt:/id", &buf));
    try testing.expectError(error.UnsupportedScheme, windowsOsc8Target("C:\\Windows", &buf));
    try testing.expectError(error.RemoteFile, windowsOsc8Target("file://server/share/a.txt", &buf));
    try testing.expectError(error.MalformedURL, windowsOsc8Target("file:///C:/Windows?x", &buf));
    try testing.expectError(error.UnsafeFile, windowsOsc8Target("file:///C:/Windows/System32/cmd.exe", &buf));
    try testing.expectError(error.UnsafeFile, windowsOsc8Target("file:///C:/Windows/System32/cmd%2EEXE", &buf));
    try testing.expectError(error.UnsafeFile, windowsOsc8Target("file:///C:/a.txt:b.exe", &buf));
    try testing.expectError(error.InaccessibleFile, windowsOsc8Target("file:///C:/definitely-not-here.txt", &buf));
    try testing.expect((try windowsOsc8Target("file:///C:/Windows", &buf)) != null);
    try testing.expect((try windowsOsc8Target("file://localhost/C:/Windows/", &buf)) != null);

    try testing.expect(windowsUnsafeExtension("C:\\x\\run.Bat. "));
    try testing.expect(!windowsUnsafeExtension("C:\\x.exe\\notes.txt"));
    try testing.expect(!windowsUnsafeExtension("C:\\x\\README"));
}

fn openThread(io: std.Io, exe_: std.process.Child) void {
    // Copy the exe so it is non-const. This is necessary because wait()
    // requires a mutable reference and we can't have one as a thread
    // param.
    var exe = exe_;
    if (exe.stderr) |stderr| {
        var buffer: [256]u8 = undefined;
        var stream = stderr.readerStreaming(io, &buffer);
        const reader = &stream.interface;
        while (true) {
            // Read inclusively so the delimiter is consumed:
            // takeDelimiterExclusive leaves the '\n' buffered, so once the
            // child writes a line this loop would receive an empty slice
            // forever, pinning a core and spamming empty warnings.
            const line = reader.takeDelimiterInclusive('\n') catch |outer| switch (outer) {
                error.EndOfStream => break,
                error.ReadFailed => break,
                error.StreamTooLong => reader.take(buffer.len) catch |inner| switch (inner) {
                    error.ReadFailed => break,
                    error.EndOfStream => break,
                },
            };
            log.warn("open stderr={s}", .{std.mem.trimEnd(u8, line, "\n")});
        }
    }
    _ = exe.wait(io) catch {};
}
