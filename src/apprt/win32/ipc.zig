const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32_ipc);

pub const version: usize = 1;
const magic = "GIPC";
const max_payload = 1024 * 1024;
const max_args = 4096;

const WM_COPYDATA: c.UINT = 0x004A;
const WM_GHOSTTY_IPC = c.WM_APP + 1;
const SMTO_BLOCK: c.UINT = 0x0001;
const SMTO_ABORTIFHUNG: c.UINT = 0x0002;
const send_timeout_ms: c.UINT = 2000;
const STD_INPUT_HANDLE: c.DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: c.DWORD = @bitCast(@as(i32, -11));
const STD_ERROR_HANDLE: c.DWORD = @bitCast(@as(i32, -12));
const HANDLE_FLAG_INHERIT: c.DWORD = 0x1;

const COPYDATASTRUCT = extern struct {
    dwData: usize,
    cbData: c.DWORD,
    lpData: ?*const anyopaque,
};

extern "user32" fn FindWindowExW(
    parent: ?c.HWND,
    child_after: ?c.HWND,
    class: ?c.LPCWSTR,
    window: ?c.LPCWSTR,
) callconv(.winapi) ?c.HWND;
extern "user32" fn SendMessageTimeoutW(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
    flags: c.UINT,
    timeout: c.UINT,
    result: ?*usize,
) callconv(.winapi) c.LRESULT;
extern "user32" fn AllowSetForegroundWindow(pid: c.DWORD) callconv(.winapi) c.BOOL;
extern "user32" fn GetWindowThreadProcessId(hwnd: c.HWND, pid: ?*c.DWORD) callconv(.winapi) c.DWORD;
extern "kernel32" fn ProcessIdToSessionId(pid: c.DWORD, session: *c.DWORD) callconv(.winapi) c.BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) c.DWORD;
extern "kernel32" fn GetStdHandle(id: c.DWORD) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetHandleInformation(h: *anyopaque, mask: c.DWORD, flags: c.DWORD) callconv(.winapi) c.BOOL;

pub const Kind = enum(u8) {
    new_window = 0,
    new_tab = 1,
};

pub const Request = struct {
    kind: Kind,
    surface_id: u64,
    arguments: ?[]const [:0]const u8,
};

pub const DecodeError = error{ Malformed, OutOfMemory };

pub fn encode(alloc: Allocator, request: Request) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, magic);
    try buf.append(alloc, @intFromEnum(request.kind));
    try buf.append(alloc, @intFromBool(request.arguments != null));
    try appendInt(alloc, &buf, u64, request.surface_id);
    const args = request.arguments orelse &.{};
    try appendInt(alloc, &buf, u32, @intCast(args.len));
    for (args) |arg| {
        try appendInt(alloc, &buf, u32, @intCast(arg.len));
        try buf.appendSlice(alloc, arg);
    }
    return buf.toOwnedSlice(alloc);
}

fn appendInt(alloc: Allocator, buf: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, v, .little);
    try buf.appendSlice(alloc, &bytes);
}

pub fn decode(alloc: Allocator, data: []const u8) DecodeError!Request {
    if (data.len > max_payload) return error.Malformed;
    var r: Reader = .{ .data = data };
    if (!std.mem.eql(u8, try r.bytes(magic.len), magic)) return error.Malformed;
    const kind = std.enums.fromInt(Kind, try r.int(u8)) orelse return error.Malformed;
    const has_args = switch (try r.int(u8)) {
        0 => false,
        1 => true,
        else => return error.Malformed,
    };
    const surface_id = try r.int(u64);
    const argc = try r.int(u32);
    if (argc > max_args) return error.Malformed;
    if (!has_args and argc != 0) return error.Malformed;
    const args = try alloc.alloc([:0]const u8, argc);
    for (args) |*arg| {
        const len = try r.int(u32);
        const s = try r.bytes(len);
        if (std.mem.indexOfScalar(u8, s, 0) != null) return error.Malformed;
        if (!std.unicode.utf8ValidateSlice(s)) return error.Malformed;
        arg.* = try alloc.dupeZ(u8, s);
    }
    if (r.pos != data.len) return error.Malformed;
    return .{
        .kind = kind,
        .surface_id = surface_id,
        .arguments = if (has_args) args else null,
    };
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn bytes(self: *Reader, n: usize) error{Malformed}![]const u8 {
        if (self.data.len - self.pos < n) return error.Malformed;
        defer self.pos += n;
        return self.data[self.pos..][0..n];
    }

    fn int(self: *Reader, comptime T: type) error{Malformed}!T {
        const b = try self.bytes(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
    }
};

pub const Overrides = struct {
    command: ?configpkg.Command = null,
    shell_integration: ?configpkg.Config.ShellIntegration = null,
    working_directory: ?[]const u8 = null,
    title: ?[:0]const u8 = null,

    pub fn parse(alloc: Allocator, arguments: []const [:0]const u8) !Overrides {
        var result: Overrides = .{};
        for (arguments, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "-e")) {
                const rest = arguments[i + 1 ..];
                if (rest.len > 0) result.command = .{ .direct = try alloc.dupe([:0]const u8, rest) };
                break;
            }
            if (std.mem.cutPrefix(u8, arg, "--command=")) |v| {
                var cmd: configpkg.Command = undefined;
                cmd.parseCLI(alloc, v) catch |err| {
                    log.warn("ignoring invalid command err={}", .{err});
                    continue;
                };
                result.command = cmd;
            } else if (std.mem.cutPrefix(u8, arg, "--shell-integration=")) |v| {
                const trimmed = std.mem.trim(u8, v, &std.ascii.whitespace);
                result.shell_integration = std.meta.stringToEnum(configpkg.Config.ShellIntegration, trimmed) orelse {
                    log.warn("ignoring invalid shell-integration value={s}", .{trimmed});
                    continue;
                };
            } else if (std.mem.cutPrefix(u8, arg, "--working-directory=")) |v| {
                result.working_directory = v;
            } else if (std.mem.cutPrefix(u8, arg, "--title=")) |v| {
                result.title = try alloc.dupeZ(u8, std.mem.trim(u8, v, &std.ascii.whitespace));
            }
        }
        return result;
    }

    pub fn apply(self: *const Overrides, config: *configpkg.Config) !void {
        const alloc = config.arenaAlloc();
        if (self.command) |cmd| {
            config.command = try cmd.clone(alloc);
            if (self.shell_integration) |v| {
                config.@"shell-integration" = v;
            } else if (config.@"shell-integration" != .none) {
                config.@"shell-integration" = .detect;
            }
        } else if (self.shell_integration) |v| {
            config.@"shell-integration" = v;
        }
        if (self.working_directory) |v| {
            var wd: configpkg.WorkingDirectory = undefined;
            if (wd.parseCLI(alloc, v)) {
                try wd.finalize(alloc);
                config.@"working-directory" = wd;
            } else |err| log.warn("ignoring invalid working-directory err={}", .{err});
        }
        if (self.title) |v| config.title = try alloc.dupeZ(u8, v);
    }
};

const Pending = struct {
    arena: std.heap.ArenaAllocator,
    request: Request,
};

pub const Server = struct {
    hwnd: ?c.HWND = null,
    class_name: [64:0]u16 = undefined,
    registered: bool = false,
    pending: std.ArrayList(*Pending) = .empty,
    overrides: ?*const Overrides = null,

    pub fn init(self: *Server, app: *App) !void {
        const alloc = app.core_app.alloc;
        _ = try className(&self.class_name);

        const wc: c.WNDCLASSEXW = .{
            .lpfnWndProc = wndProc,
            .hInstance = app.instance,
            .lpszClassName = &self.class_name,
        };
        if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
        self.registered = true;

        const text = try std.unicode.utf8ToUtf16LeAllocZ(alloc, app.config.class orelse build_config.bundle_id);
        defer alloc.free(text);

        self.hwnd = c.CreateWindowExW(
            0,
            &self.class_name,
            text,
            0,
            0,
            0,
            0,
            0,
            c.HWND_MESSAGE,
            null,
            app.instance,
            app,
        ) orelse return error.CreateWindowFailed;
    }

    pub fn deinit(self: *Server, app: *App) void {
        if (self.hwnd) |hwnd| {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            _ = c.DestroyWindow(hwnd);
        }
        self.hwnd = null;
        if (self.registered) _ = c.UnregisterClassW(&self.class_name, app.instance);
        self.registered = false;
        for (self.pending.items) |p| freePending(app.core_app.alloc, p);
        self.pending.deinit(app.core_app.alloc);
    }

    pub fn applyOverrides(self: *const Server, config: *configpkg.Config) !void {
        if (self.overrides) |o| try o.apply(config);
    }

    fn receive(self: *Server, app: *App, cds: *const COPYDATASTRUCT) bool {
        if (app.quitting) return false;
        if (cds.dwData != version) {
            log.warn("ignoring ipc message with unknown version={}", .{cds.dwData});
            return false;
        }
        const len: usize = cds.cbData;
        const data: []const u8 = if (len == 0) &.{} else if (cds.lpData) |p|
            @as([*]const u8, @ptrCast(p))[0..len]
        else
            return false;

        const alloc = app.core_app.alloc;
        const pending = alloc.create(Pending) catch return false;
        pending.arena = .init(alloc);
        pending.request = decode(pending.arena.allocator(), data) catch |err| {
            log.warn("ignoring malformed ipc message err={}", .{err});
            freePending(alloc, pending);
            return false;
        };
        self.pending.append(alloc, pending) catch {
            freePending(alloc, pending);
            return false;
        };
        const hwnd = self.hwnd orelse return false;
        _ = c.PostMessageW(hwnd, WM_GHOSTTY_IPC, 0, 0);
        return true;
    }

    fn drain(self: *Server, app: *App) void {
        const alloc = app.core_app.alloc;
        while (self.pending.items.len > 0) {
            const pending = self.pending.orderedRemove(0);
            defer freePending(alloc, pending);
            if (app.quitting) continue;
            self.execute(app, pending) catch |err| {
                log.warn("error handling ipc request err={}", .{err});
            };
        }
    }

    fn execute(self: *Server, app: *App, pending: *Pending) !void {
        const request = pending.request;
        const overrides: Overrides = if (request.arguments) |args|
            try .parse(pending.arena.allocator(), args)
        else
            .{};
        self.overrides = &overrides;
        defer self.overrides = null;

        log.info("ipc request kind={t} surface_id={x}", .{ request.kind, request.surface_id });
        const window: *Window = switch (request.kind) {
            .new_window => try Window.create(app),
            .new_tab => tab: {
                const target = if (request.surface_id != 0)
                    app.core_app.findSurfaceByID(request.surface_id)
                else
                    null;
                if (target) |core| {
                    core.rt_surface.window.newTab(core);
                    break :tab core.rt_surface.window;
                }
                if (app.activeWindow()) |w| {
                    w.newTab(null);
                    break :tab w;
                }
                break :tab try Window.create(app);
            },
        };
        if (window.hwnd) |hwnd| {
            if (c.IsIconic(hwnd).toBool()) _ = c.ShowWindow(hwnd, c.SW_RESTORE);
            _ = c.SetForegroundWindow(hwnd);
        }
    }
};

fn freePending(alloc: Allocator, pending: *Pending) void {
    pending.arena.deinit();
    alloc.destroy(pending);
}

fn className(buf: *[64:0]u16) ![:0]const u16 {
    var session: c.DWORD = 0;
    if (!ProcessIdToSessionId(GetCurrentProcessId(), &session).toBool()) session = 0;
    var utf8: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&utf8, "GhosttyIpc_{d}", .{session});
    const n = try std.unicode.utf8ToUtf16Le(buf, name);
    buf[n] = 0;
    return buf[0..n :0];
}

fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(cs.lpCreateParams)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const app: *App = @ptrFromInt(ptr);

    switch (msg) {
        WM_COPYDATA => {
            if (lparam == 0) return 0;
            const cds: *const COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            return @intFromBool(app.ipc.receive(app, cds));
        },
        WM_GHOSTTY_IPC => {
            app.ipc.drain(app);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn send(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) (Allocator.Error || apprt.ipc.Errors)!bool {
    const request: Request = switch (action) {
        .new_window => .{ .kind = .new_window, .surface_id = 0, .arguments = value.arguments },
        .new_tab => .{ .kind = .new_tab, .surface_id = value.surface_id, .arguments = value.arguments },
        .toggle_quick_terminal => return false,
    };

    var class_buf: [64:0]u16 = undefined;
    const class = className(&class_buf) catch return error.IPCFailed;
    const text_utf8: []const u8 = switch (target) {
        .class => |v| v,
        .detect => build_config.bundle_id,
    };
    const text = std.unicode.utf8ToUtf16LeAllocZ(alloc, text_utf8) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => {
            printError("The class name is not valid UTF-8.\n");
            return error.IPCFailed;
        },
    };
    defer alloc.free(text);

    const hwnd = FindWindowExW(c.HWND_MESSAGE, null, class.ptr, text.ptr) orelse {
        log.info("no running instance found, launching a new one", .{});
        return launch(alloc, target, request.arguments);
    };

    const payload = try encode(alloc, request);
    defer alloc.free(payload);

    var pid: c.DWORD = 0;
    _ = GetWindowThreadProcessId(hwnd, &pid);
    if (pid != 0) _ = AllowSetForegroundWindow(pid);

    const cds: COPYDATASTRUCT = .{
        .dwData = version,
        .cbData = @intCast(payload.len),
        .lpData = payload.ptr,
    };
    var result: usize = 0;
    const ok = SendMessageTimeoutW(
        hwnd,
        WM_COPYDATA,
        0,
        @bitCast(@intFromPtr(&cds)),
        SMTO_BLOCK | SMTO_ABORTIFHUNG,
        send_timeout_ms,
        &result,
    );
    if (ok == 0 or result != 1) {
        printError("The running Ghostty instance did not accept the request.\n");
        return error.IPCFailed;
    }
    return true;
}

fn launch(
    alloc: Allocator,
    target: apprt.ipc.Target,
    arguments: ?[]const [:0]const u8,
) (Allocator.Error || apprt.ipc.Errors)!bool {
    const io = global.io();
    const exe = std.process.executablePathAlloc(io, alloc) catch {
        printError("Unable to determine the Ghostty executable path.\n");
        return error.IPCFailed;
    };
    defer alloc.free(exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, exe);
    var class_arg: ?[]u8 = null;
    defer if (class_arg) |v| alloc.free(v);
    switch (target) {
        .class => |v| {
            class_arg = try std.fmt.allocPrint(alloc, "--class={s}", .{v});
            try argv.append(alloc, class_arg.?);
        },
        .detect => {},
    }
    if (arguments) |args| for (args) |arg| try argv.append(alloc, arg);

    for ([_]c.DWORD{ STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE }) |id| {
        const h = GetStdHandle(id) orelse continue;
        if (@intFromPtr(h) == std.math.maxInt(usize)) continue;
        _ = SetHandleInformation(h, HANDLE_FLAG_INHERIT, 0);
    }

    _ = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        log.warn("unable to launch ghostty err={}", .{err});
        printError("Unable to launch a new Ghostty instance.\n");
        return error.IPCFailed;
    };
    return true;
}

fn printError(msg: []const u8) void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(global.io(), &buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

test "ipc encode/decode round trip" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = [_][:0]const u8{ "--working-directory=C:\\", "-e", "cmd.exe", "/c", "echo hi" };
    const payload = try encode(alloc, .{ .kind = .new_tab, .surface_id = 0xdeadbeef, .arguments = &args });
    const req = try decode(alloc, payload);
    try testing.expectEqual(Kind.new_tab, req.kind);
    try testing.expectEqual(@as(u64, 0xdeadbeef), req.surface_id);
    try testing.expectEqual(args.len, req.arguments.?.len);
    for (args, req.arguments.?) |a, b| try testing.expectEqualStrings(a, b);

    const empty = try encode(alloc, .{ .kind = .new_window, .surface_id = 0, .arguments = null });
    const req2 = try decode(alloc, empty);
    try testing.expectEqual(Kind.new_window, req2.kind);
    try testing.expect(req2.arguments == null);
}

test "ipc decode rejects malformed payloads" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = [_][:0]const u8{ "--title=x", "abc" };
    const good = try encode(alloc, .{ .kind = .new_window, .surface_id = 1, .arguments = &args });

    for (0..good.len) |n| try testing.expectError(error.Malformed, decode(alloc, good[0..n]));

    const extra = try std.mem.concat(alloc, u8, &.{ good, "x" });
    try testing.expectError(error.Malformed, decode(alloc, extra));

    var bad_magic = try alloc.dupe(u8, good);
    bad_magic[0] = 'X';
    try testing.expectError(error.Malformed, decode(alloc, bad_magic));

    var bad_kind = try alloc.dupe(u8, good);
    bad_kind[4] = 9;
    try testing.expectError(error.Malformed, decode(alloc, bad_kind));

    var huge_argc = try alloc.dupe(u8, good);
    std.mem.writeInt(u32, huge_argc[14..18], 0xffffffff, .little);
    try testing.expectError(error.Malformed, decode(alloc, huge_argc));

    var huge_len = try alloc.dupe(u8, good);
    std.mem.writeInt(u32, huge_len[18..22], 0xfffffff0, .little);
    try testing.expectError(error.Malformed, decode(alloc, huge_len));

    var nul = try alloc.dupe(u8, good);
    nul[22] = 0;
    try testing.expectError(error.Malformed, decode(alloc, nul));
}

test "ipc overrides parse" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = [_][:0]const u8{ "--working-directory=C:\\", "--title= T ", "--shell-integration=none", "-e", "ping", "-n", "1" };
    const o = try Overrides.parse(alloc, &args);
    try testing.expectEqualStrings("C:\\", o.working_directory.?);
    try testing.expectEqualStrings("T", o.title.?);
    try testing.expectEqual(configpkg.Config.ShellIntegration.none, o.shell_integration.?);
    try testing.expectEqual(@as(usize, 3), o.command.?.direct.len);
    try testing.expectEqualStrings("ping", o.command.?.direct[0]);

    var config: configpkg.Config = try .default(testing.allocator);
    defer config.deinit();
    try o.apply(&config);
    try testing.expectEqualStrings("C:\\", config.@"working-directory".?.path);
    try testing.expectEqualStrings("T", config.title.?);
    try testing.expectEqual(configpkg.Config.ShellIntegration.none, config.@"shell-integration");
}
