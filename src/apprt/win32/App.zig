const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const c = @import("c.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const TabBar = @import("TabBar.zig");
const taskbarpkg = @import("taskbar.zig");
const dialogs = @import("dialogs.zig");
const ipcpkg = @import("ipc.zig");

const log = std.log.scoped(.win32);

const L = std.unicode.utf8ToUtf16LeStringLiteral;
pub const message_class_name = L("GhosttyMessage");
pub const window_class_name = L("GhosttyWindow");
pub const surface_class_name = L("GhosttySurface");
pub const tab_bar_class_name = L("GhosttyTabBar");

const WM_GHOSTTY_TICK = c.WM_APP + 1;
const WM_GHOSTTY_COLOR_SCHEME = c.WM_APP + 2;
const WM_GHOSTTY_CONFIG_ERRORS = c.WM_APP + 3;
const WM_GHOSTTY_CONFIRM_QUIT = c.WM_APP + 4;
const WM_GHOSTTY_CLOSE_ALL = c.WM_APP + 5;
const quit_timer_id: c.UINT_PTR = 1;

core_app: *CoreApp,
config: Config,
instance: ?c.HINSTANCE,
msg_hwnd: ?c.HWND = null,
windows: std.ArrayList(*Window) = .empty,
last_active: ?*Window = null,
tick_pending: std.atomic.Value(bool) = .init(false),
quit_timer_active: bool = false,
quitting: bool = false,
color_scheme: apprt.ColorScheme = .light,
chrome: Window.Chrome = .{},
com_initialized: bool = false,
taskbar: taskbarpkg.State = .{},
ipc: ipcpkg.Server = .{},

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const alloc = core_app.alloc;
    var config = Config.load(alloc) catch |err| err: {
        var def: Config = try .default(alloc);
        errdefer def.deinit();
        try def.finalize();
        try def.addDiagnosticFmt(
            "error loading user configuration: {}",
            .{err},
        );
        break :err def;
    };
    errdefer config.deinit();

    const instance = c.GetModuleHandleW(null);
    self.* = .{
        .core_app = core_app,
        .config = config,
        .instance = instance,
    };

    self.com_initialized = c.CoInitializeEx(
        null,
        c.COINIT_APARTMENTTHREADED | c.COINIT_DISABLE_OLE1DDE,
    ) >= 0;
    errdefer if (self.com_initialized) c.CoUninitialize();
    _ = c.SetCurrentProcessExplicitAppUserModelID(L("com.mitchellh.ghostty"));

    try registerClasses(instance);
    errdefer unregisterClasses(instance);

    self.msg_hwnd = c.CreateWindowExW(
        0,
        message_class_name,
        null,
        0,
        0,
        0,
        0,
        0,
        c.HWND_MESSAGE,
        null,
        instance,
        self,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = c.DestroyWindow(self.msg_hwnd.?);

    self.color_scheme = readSystemColorScheme();
    core_app.colorSchemeEvent(self, self.color_scheme) catch |err| {
        log.warn("error setting initial color scheme err={}", .{err});
    };

    self.ipc.init(self) catch |err| log.warn("ipc unavailable err={}", .{err});
    errdefer self.ipc.deinit(self);

    try core_app.updateConfig(self, &self.config);

    _ = try Window.create(self);
    if (!self.config._diagnostics.empty()) self.postToSelf(WM_GHOSTTY_CONFIG_ERRORS);
}

fn registerClasses(instance: ?c.HINSTANCE) !void {
    const icon = c.LoadIconW(instance, c.makeIntResource(1));
    const cursor = c.LoadCursorW(null, c.IDC_ARROW);

    const msg_wc: c.WNDCLASSEXW = .{
        .lpfnWndProc = messageWndProc,
        .hInstance = instance,
        .lpszClassName = message_class_name,
    };
    if (c.RegisterClassExW(&msg_wc) == 0) return error.RegisterClassFailed;
    errdefer _ = c.UnregisterClassW(message_class_name, instance);

    const window_wc: c.WNDCLASSEXW = .{
        .style = c.CS_HREDRAW | c.CS_VREDRAW,
        .lpfnWndProc = Window.wndProc,
        .hInstance = instance,
        .hIcon = icon,
        .hIconSm = icon,
        .hCursor = cursor,
        .lpszClassName = window_class_name,
    };
    if (c.RegisterClassExW(&window_wc) == 0) return error.RegisterClassFailed;
    errdefer _ = c.UnregisterClassW(window_class_name, instance);

    const surface_wc: c.WNDCLASSEXW = .{
        .style = c.CS_OWNDC,
        .lpfnWndProc = Surface.wndProc,
        .hInstance = instance,
        .hCursor = cursor,
        .lpszClassName = surface_class_name,
    };
    if (c.RegisterClassExW(&surface_wc) == 0) return error.RegisterClassFailed;
    errdefer _ = c.UnregisterClassW(surface_class_name, instance);

    const tab_bar_wc: c.WNDCLASSEXW = .{
        .lpfnWndProc = TabBar.wndProc,
        .hInstance = instance,
        .hCursor = cursor,
        .lpszClassName = tab_bar_class_name,
    };
    if (c.RegisterClassExW(&tab_bar_wc) == 0) return error.RegisterClassFailed;
}

fn unregisterClasses(instance: ?c.HINSTANCE) void {
    _ = c.UnregisterClassW(tab_bar_class_name, instance);
    _ = c.UnregisterClassW(surface_class_name, instance);
    _ = c.UnregisterClassW(window_class_name, instance);
    _ = c.UnregisterClassW(message_class_name, instance);
}

pub fn run(self: *App) !void {
    log.debug("entering message loop", .{});
    defer log.debug("exiting message loop", .{});

    if (self.windows.items.len == 0) self.quit();

    var msg: c.MSG = .{};
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        if (!Surface.skipTranslate(&msg)) _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    self.quitting = true;
    self.destroyAllWindows();
    self.disarmQuitTimer();
    self.windows.deinit(self.core_app.alloc);
    taskbarpkg.deinit(self);
    self.ipc.deinit(self);
    if (self.msg_hwnd) |hwnd| {
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(hwnd);
    }
    self.msg_hwnd = null;
    unregisterClasses(self.instance);
    self.config.deinit();
    if (self.com_initialized) c.CoUninitialize();
}

pub fn wakeup(self: *App) void {
    if (self.tick_pending.swap(true, .acq_rel)) return;
    const hwnd = self.msg_hwnd orelse return;
    if (!c.PostMessageW(hwnd, WM_GHOSTTY_TICK, 0, 0).toBool()) {
        self.tick_pending.store(false, .release);
    }
}

fn tick(self: *App) void {
    self.tick_pending.store(false, .release);
    log.debug("tick", .{});
    self.core_app.tick(self) catch |err| {
        log.warn("error during app tick err={}", .{err});
    };
}

fn messageWndProc(
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
    const self: *App = @ptrFromInt(ptr);

    if (taskbarpkg.handleMessage(self, msg, wparam, lparam)) return 0;

    switch (msg) {
        WM_GHOSTTY_TICK => {
            self.tick();
            return 0;
        },
        WM_GHOSTTY_COLOR_SCHEME => {
            self.updateColorScheme();
            return 0;
        },
        WM_GHOSTTY_CONFIG_ERRORS => {
            self.showConfigErrors();
            return 0;
        },
        WM_GHOSTTY_CONFIRM_QUIT => {
            if (self.confirmTerminate(L("Quit Ghostty?"))) self.quit();
            return 0;
        },
        WM_GHOSTTY_CLOSE_ALL => {
            if (self.confirmTerminate(L("Close All Windows?"))) self.destroyAllWindows();
            return 0;
        },
        c.WM_TIMER => if (wparam == quit_timer_id) {
            log.debug("quit timer expired", .{});
            self.disarmQuitTimer();
            self.quit();
            return 0;
        },
        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn quit(self: *App) void {
    if (self.quitting) return;
    self.quitting = true;
    log.debug("quitting", .{});
    self.disarmQuitTimer();
    self.destroyAllWindows();
    c.PostQuitMessage(0);
}

fn destroyAllWindows(self: *App) void {
    while (self.windows.items.len > 0) {
        const window = self.windows.items[self.windows.items.len - 1];
        window.destroy();
    }
}

fn confirmTerminate(self: *App, title: [:0]const u16) bool {
    if (self.quitting) return false;
    if (!self.core_app.needsConfirmQuit()) return true;
    const owner: ?c.HWND = if (self.activeWindow()) |w| w.hwnd else null;
    const result = dialogs.confirm(owner, .{
        .main = title,
        .content = L("All terminal sessions will be terminated."),
        .yes = L("Close"),
    });
    return result and !self.quitting;
}

fn postToSelf(self: *App, msg: c.UINT) void {
    if (self.msg_hwnd) |hwnd| _ = c.PostMessageW(hwnd, msg, 0, 0);
}

pub fn activeWindow(self: *App) ?*Window {
    if (self.last_active) |w| return w;
    if (self.windows.items.len > 0) return self.windows.items[0];
    return null;
}

pub fn windowActivated(self: *App, window: *Window) void {
    self.last_active = window;
}

fn gotoWindow(self: *App, direction: apprt.action.GotoWindow) bool {
    const n = self.windows.items.len;
    if (n < 2) return false;
    const fg = c.GetForegroundWindow();
    const current = self.activeWindow();
    var start: usize = 0;
    for (self.windows.items, 0..) |w, i| {
        if (w.hwnd != null and w.hwnd == fg) {
            start = i;
            break;
        }
        if (w == current) start = i;
    }
    const idx = switch (direction) {
        .next => (start + 1) % n,
        .previous => (start + n - 1) % n,
    };
    const hwnd = self.windows.items[idx].hwnd orelse return false;
    presentWindow(hwnd);
    return true;
}

fn presentWindow(hwnd: c.HWND) void {
    if (c.IsIconic(hwnd).toBool()) _ = c.ShowWindow(hwnd, c.SW_RESTORE);
    _ = c.SetForegroundWindow(hwnd);
}

pub fn addWindow(self: *App, window: *Window) !void {
    try self.windows.append(self.core_app.alloc, window);
}

pub fn removeWindow(self: *App, window: *Window) void {
    if (self.last_active == window) self.last_active = null;
    for (self.windows.items, 0..) |w, i| {
        if (w == window) {
            _ = self.windows.orderedRemove(i);
            break;
        }
    }

    if (self.windows.items.len > 0 or self.quitting) return;
    if (self.config.@"quit-after-last-window-closed" and
        self.config.@"quit-after-last-window-closed-delay" != null) return;
    self.quit();
}

fn armQuitTimer(self: *App) void {
    self.disarmQuitTimer();
    if (self.quitting) return;
    if (!self.config.@"quit-after-last-window-closed") return;
    const delay = self.config.@"quit-after-last-window-closed-delay" orelse return;
    const hwnd = self.msg_hwnd orelse return;
    if (c.SetTimer(hwnd, quit_timer_id, delay.asMilliseconds(), null) != 0) self.quit_timer_active = true;
}

fn disarmQuitTimer(self: *App) void {
    if (!self.quit_timer_active) return;
    self.quit_timer_active = false;
    if (self.msg_hwnd) |hwnd| _ = c.KillTimer(hwnd, quit_timer_id);
}

fn reloadConfig(self: *App, target: apprt.Target, soft: bool) !void {
    if (!soft) {
        var config = try Config.load(self.core_app.alloc);
        errdefer config.deinit();
        var old = self.config;
        defer old.deinit();
        self.config = config;
        log.info("reloaded config diagnostics={}", .{self.config._diagnostics.items().len});
        if (!self.config._diagnostics.empty()) {
            if (self.msg_hwnd) |hwnd| _ = c.PostMessageW(hwnd, WM_GHOSTTY_CONFIG_ERRORS, 0, 0);
        }
    }

    switch (target) {
        .app => try self.core_app.updateConfig(self, &self.config),
        .surface => |core_surface| try core_surface.updateConfig(&self.config),
    }
}

fn showConfigErrors(self: *App) void {
    if (self.config._diagnostics.empty()) return;
    const alloc = self.core_app.alloc;
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    const writer = &text.writer;
    writer.writeAll("One or more configuration errors were found. Please review the errors below, and either reload your configuration or ignore these errors.\n\n") catch return;
    for (self.config._diagnostics.items()) |diag| {
        diag.format(writer) catch return;
        writer.writeAll("\n") catch return;
    }
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, text.written()) catch return;
    defer alloc.free(wide);
    const owner: ?c.HWND = if (self.activeWindow()) |w| w.hwnd else null;
    const reload = dialogs.confirm(owner, .{
        .main = L("Configuration Errors"),
        .content = wide,
        .yes = L("Reload Configuration"),
        .no = L("Ignore"),
    });
    if (!reload or self.quitting) return;
    self.reloadConfig(.app, false) catch |err| {
        log.warn("error reloading config err={}", .{err});
    };
}

fn readSystemColorScheme() apprt.ColorScheme {
    var value: c.DWORD = 1;
    var size: c.DWORD = @sizeOf(c.DWORD);
    const status = c.RegGetValueW(
        c.HKEY_CURRENT_USER,
        L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        L("AppsUseLightTheme"),
        c.RRF_RT_REG_DWORD,
        null,
        &value,
        &size,
    );
    if (status != 0) return .light;
    return if (value == 0) .dark else .light;
}

pub fn systemColorSchemeChanged(self: *App) void {
    const hwnd = self.msg_hwnd orelse return;
    _ = c.PostMessageW(hwnd, WM_GHOSTTY_COLOR_SCHEME, 0, 0);
}

fn updateColorScheme(self: *App) void {
    const scheme = readSystemColorScheme();
    log.debug("system color scheme setting changed scheme={} previous={}", .{ scheme, self.color_scheme });
    if (scheme == self.color_scheme) return;
    self.color_scheme = scheme;

    self.core_app.colorSchemeEvent(self, scheme) catch |err| {
        log.warn("error updating app color scheme err={}", .{err});
    };
    for (self.core_app.surfaces.items) |surface| {
        surface.core().colorSchemeCallback(scheme) catch |err| {
            log.warn("unable to tell surface about color scheme change err={}", .{err});
        };
    }
}

fn configChanged(self: *App, target: apprt.Target, config: *const Config) void {
    const chrome: Window.Chrome = .init(config, self.color_scheme);
    switch (target) {
        .app => {
            self.chrome = chrome;
            for (self.windows.items) |window| window.applyChrome(chrome);
        },
        .surface => |core_surface| core_surface.rt_surface.window.applyChrome(chrome),
    }
}

fn targetSurface(target: apprt.Target) ?*Surface {
    return switch (target) {
        .app => null,
        .surface => |v| v.rt_surface,
    };
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => self.postToSelf(WM_GHOSTTY_CONFIRM_QUIT),

        .close_all_windows => self.postToSelf(WM_GHOSTTY_CLOSE_ALL),

        .goto_window => return self.gotoWindow(value),

        .new_window => _ = try Window.create(self),

        .new_tab => switch (target) {
            .surface => |core| core.rt_surface.window.newTab(core),
            .app => if (self.activeWindow()) |window| window.newTab(null) else {
                _ = try Window.create(self);
            },
        },

        .close_tab => {
            const surface = targetSurface(target) orelse return false;
            surface.window.closeTabs(surface, value);
        },

        .goto_tab => {
            const surface = targetSurface(target) orelse return false;
            return surface.window.gotoTab(value);
        },

        .move_tab => {
            const surface = targetSurface(target) orelse return false;
            return surface.window.moveTab(surface, value.amount);
        },

        .move_tab_to_new_window => {
            const surface = targetSurface(target) orelse return false;
            return surface.window.moveTabToNewWindow(surface);
        },

        .new_split => {
            const surface = targetSurface(target) orelse return false;
            try surface.window.newSplit(surface, value);
        },

        .goto_split => {
            const surface = targetSurface(target) orelse return false;
            return surface.window.gotoSplit(surface, value);
        },

        .resize_split => {
            const surface = targetSurface(target) orelse return false;
            return surface.window.resizeSplit(surface, value);
        },

        .equalize_splits => {
            const surface = targetSurface(target) orelse return false;
            return surface.window.equalizeSplits(surface);
        },

        .toggle_split_zoom => {
            const surface = targetSurface(target) orelse return false;
            return surface.window.toggleSplitZoom(surface);
        },

        .set_tab_title => {
            const surface = targetSurface(target) orelse return false;
            try surface.window.setTabTitle(surface, value.title);
        },

        .close_window => {
            const surface = targetSurface(target) orelse return false;
            surface.window.requestClose();
        },

        .quit_timer => switch (value) {
            .start => self.armQuitTimer(),
            .stop => self.disarmQuitTimer(),
        },

        .set_title => {
            const surface = targetSurface(target) orelse return false;
            try surface.setTitle(value.title);
        },

        .size_limit => {
            const surface = targetSurface(target) orelse return false;
            surface.window.setSizeLimit(value);
        },

        .initial_size => {
            const surface = targetSurface(target) orelse return false;
            surface.window.setInitialSize(value.width, value.height);
        },

        .present_terminal => {
            const surface = targetSurface(target) orelse return false;
            if (surface.window.hwnd) |hwnd| presentWindow(hwnd);
            surface.present();
        },

        .reload_config => self.reloadConfig(target, value.soft) catch |err| {
            log.warn("error reloading config err={}", .{err});
        },

        .config_change => self.configChanged(target, value.config),

        .prompt_title => {
            const surface = targetSurface(target) orelse return false;
            return dialogs.requestPromptTitle(surface, value);
        },

        .open_config => dialogs.openConfig() catch |err| {
            log.warn("error opening config err={}", .{err});
            return false;
        },

        .set_window_title => {
            const surface = targetSurface(target) orelse return false;
            try surface.window.setTitleOverride(value.title);
        },

        .ring_bell => {
            const surface = targetSurface(target) orelse return false;
            surface.window.ringBell();
        },

        .toggle_maximize => {
            const surface = targetSurface(target) orelse return false;
            surface.window.toggleMaximize();
        },

        .toggle_fullscreen => {
            const surface = targetSurface(target) orelse return false;
            surface.window.toggleFullscreen();
        },

        .mouse_shape => {
            const surface = targetSurface(target) orelse return false;
            surface.setMouseShape(value);
        },

        .mouse_visibility => {
            const surface = targetSurface(target) orelse return false;
            surface.setMouseVisibility(value == .visible);
        },

        .mouse_over_link => {},

        .progress_report => {
            const surface = targetSurface(target) orelse return false;
            taskbarpkg.setProgress(self, surface.window, value);
        },

        .desktop_notification => taskbarpkg.notify(self, value.title, value.body),

        .command_finished => {
            const surface = targetSurface(target) orelse return false;
            taskbarpkg.commandFinished(surface.window, value);
        },

        .float_window => {
            const surface = targetSurface(target) orelse return false;
            taskbarpkg.setFloat(surface.window, value);
        },

        .toggle_visibility => taskbarpkg.toggleVisibility(self),

        .color_change,
        .renderer_health,
        .pwd,
        .selection_changed,
        .readonly,
        .key_sequence,
        .key_table,
        .secure_input,
        => log.debug("ignored action={t}", .{action}),

        else => return false,
    }

    return true;
}

pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) !bool {
    return ipcpkg.send(alloc, target, action, value);
}
