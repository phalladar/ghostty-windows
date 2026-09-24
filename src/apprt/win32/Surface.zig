const Surface = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const CoreSurface = @import("../../Surface.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");
const clipboard = @import("clipboard.zig");
const key = @import("key.zig");
const dialogs = @import("dialogs.zig");
const ime = @import("ime.zig");

const log = std.log.scoped(.win32);

core_surface: CoreSurface,
app: *App,
window: *Window,
hwnd: ?c.HWND = null,
initialized: bool = false,
size: apprt.SurfaceSize = .{ .width = 800, .height = 600 },
content_scale: apprt.ContentScale = .{ .x = 1, .y = 1 },
cursor_pos: apprt.CursorPos = .{ .x = -1, .y = -1 },
title: ?[:0]const u8 = null,
title_override: ?[:0]const u8 = null,
key_utf8: [32]u8 = undefined,
sys_char_passthrough: bool = false,
dead_key_pending: bool = false,
preedit_utf8: [8]u8 = undefined,
key_down_pending: bool = false,
char_decoder: key.CharDecoder = .{},
ime_state: ime.State = .{},
focused: bool = false,
mouse_shape: terminal.MouseShape = .text,
mouse_hidden: bool = false,
mouse_tracking: bool = false,
mouse_buttons: u16 = 0,

const WM_GHOSTTY_FOCUS = c.WM_APP + 0x50;

pub fn create(
    window: *Window,
    rect: c.RECT,
    context: apprt.surface.NewSurfaceContext,
    parent_surface: ?*CoreSurface,
) !*Surface {
    const app = window.app;
    const alloc = app.core_app.alloc;
    const parent = window.hwnd orelse return error.WindowNotCreated;

    const self = try alloc.create(Surface);
    errdefer alloc.destroy(self);
    self.* = .{
        .core_surface = undefined,
        .app = app,
        .window = window,
    };

    const hwnd = c.CreateWindowExW(
        0,
        App.surface_class_name,
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPSIBLINGS,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        parent,
        null,
        app.instance,
        self,
    ) orelse return error.CreateWindowFailed;
    errdefer {
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(hwnd);
    }

    self.updateSize();
    self.updateContentScale();
    log.debug("surface hwnd created size={}x{} scale={d}", .{
        self.size.width,
        self.size.height,
        self.content_scale.x,
    });

    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);
    log.debug("surface added to core app", .{});

    var config = try apprt.surface.newConfig(app.core_app, &app.config, context);
    defer config.deinit();
    if (parent_surface) |p| {
        if (apprt.surface.shouldInheritWorkingDirectory(context, &app.config)) {
            if (try p.pwd(config._arena.?.allocator())) |pwd| config.@"working-directory" = .{ .path = pwd };
        }
    }
    try app.ipc.applyOverrides(&config);

    try self.core_surface.init(alloc, &config, app.core_app, app, self);
    self.initialized = true;
    log.debug("core surface initialized", .{});

    self.updateSize();
    self.core_surface.sizeCallback(self.size) catch |err| {
        log.warn("error in size callback err={}", .{err});
    };

    return self;
}

pub fn deinit(self: *Surface) void {
    if (!self.initialized) return;
    self.initialized = false;
    self.app.core_app.deleteSurface(self);
    self.core_surface.deinit();
    log.debug("core surface deinitialized", .{});
}

pub fn destroy(self: *Surface) void {
    const alloc = self.app.core_app.alloc;
    log.debug("surface destroy", .{});

    self.deinit();

    if (self.hwnd) |hwnd| {
        self.hwnd = null;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(hwnd);
    }

    if (self.title) |v| alloc.free(v);
    if (self.title_override) |v| alloc.free(v);
    alloc.destroy(self);
}

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn ref(self: *Surface) *Surface {
    return self;
}

pub fn unref(self: *Surface) void {
    _ = self;
}

pub fn rtApp(self: *const Surface) *App {
    return self.app;
}

pub fn close(self: *Surface, process_active: bool) void {
    if (process_active and !Window.confirmClose(self.window.hwnd)) return;
    self.window.closeSurface(self);
}

pub fn present(self: *Surface) void {
    self.window.selectSurface(self);
    if (self.window.hwnd) |hwnd| _ = c.SetForegroundWindow(hwnd);
    if (self.hwnd) |hwnd| _ = c.SetFocus(hwnd);
}

pub fn setTitle(self: *Surface, title: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy = try alloc.dupeZ(u8, title);
    if (self.title) |v| alloc.free(v);
    self.title = copy;
    self.window.surfaceTitleChanged(self);
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

pub fn getEffectiveTitle(self: *Surface) ?[:0]const u8 {
    return self.title_override orelse self.title;
}

pub fn setTitleOverride(self: *Surface, title: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy: ?[:0]const u8 = if (title.len == 0) null else try alloc.dupeZ(u8, title);
    if (self.title_override) |v| alloc.free(v);
    self.title_override = copy;
    self.window.surfaceTitleChanged(self);
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return self.content_scale;
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return self.size;
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    return self.cursor_pos;
}

fn updateSize(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    var rect: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &rect);
    self.size = .{
        .width = @intCast(@max(0, rect.right - rect.left)),
        .height = @intCast(@max(0, rect.bottom - rect.top)),
    };
}

fn updateContentScale(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    self.setDpi(c.GetDpiForWindow(hwnd));
}

fn setDpi(self: *Surface, dpi: c.UINT) void {
    if (dpi == 0) return;
    const scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
    self.content_scale = .{ .x = scale, .y = scale };
}

pub fn dpiChanged(self: *Surface, dpi: c.UINT) void {
    self.setDpi(dpi);
    if (!self.initialized) return;
    self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
        log.warn("error in content scale callback err={}", .{err});
    };
}

pub fn setVisible(self: *Surface, visible: bool) void {
    if (!self.initialized) return;
    self.core_surface.occlusionCallback(visible) catch |err| {
        log.warn("error in occlusion callback err={}", .{err});
    };
}

pub fn refresh(self: *Surface) void {
    if (!self.initialized) return;
    self.core_surface.refreshCallback() catch |err| {
        log.warn("error in refresh callback err={}", .{err});
    };
}

pub fn presentFresh(self: *Surface, timeout_ms: u32) bool {
    if (!self.initialized) return true;
    self.core_surface.renderer.api.provider.presented_size.store(0, .release);
    self.refresh();
    return self.waitPresented(timeout_ms);
}

pub fn waitPresented(self: *Surface, timeout_ms: u32) bool {
    if (!self.initialized or !self.core_surface.visible) return true;
    const hwnd = self.hwnd orelse return true;
    if (!c.IsWindowVisible(hwnd).toBool()) return true;
    if (self.size.width == 0 or self.size.height == 0) return true;
    return self.core_surface.renderer.api.provider.waitPresented(
        self.size.width,
        self.size.height,
        timeout_ms,
    );
}

fn focusChanged(self: *Surface, focused: bool) void {
    self.focused = focused;
    const hwnd = self.hwnd orelse return;
    _ = c.PostMessageW(hwnd, WM_GHOSTTY_FOCUS, 0, 0);
}

fn applyFocus(self: *Surface) void {
    if (!self.initialized) return;
    self.core_surface.focusCallback(self.focused) catch |err| {
        log.warn("error in focus callback err={}", .{err});
    };
    self.app.core_app.focusEvent(self.focused);
}

pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    self.mouse_shape = shape;
    if (self.mouse_tracking) _ = c.SetCursor(self.currentCursor());
}

pub fn setMouseVisibility(self: *Surface, visible: bool) void {
    self.mouse_hidden = !visible;
    if (self.mouse_tracking) _ = c.SetCursor(self.currentCursor());
}

fn currentCursor(self: *const Surface) ?c.HCURSOR {
    if (self.mouse_hidden) return null;
    return c.LoadCursorW(null, switch (self.mouse_shape) {
        .default, .context_menu, .alias, .copy, .zoom_in, .zoom_out => c.IDC_ARROW,
        .help => c.IDC_HELP,
        .pointer => c.IDC_HAND,
        .progress => c.IDC_APPSTARTING,
        .wait => c.IDC_WAIT,
        .cell, .crosshair => c.IDC_CROSS,
        .text, .vertical_text => c.IDC_IBEAM,
        .move, .grab, .grabbing, .all_scroll => c.IDC_SIZEALL,
        .no_drop, .not_allowed => c.IDC_NO,
        .col_resize, .e_resize, .w_resize, .ew_resize => c.IDC_SIZEWE,
        .row_resize, .n_resize, .s_resize, .ns_resize => c.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => c.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => c.IDC_SIZENWSE,
    });
}

fn mouseMods(wparam: c.WPARAM) input.Mods {
    return .{
        .shift = wparam & c.MK_SHIFT != 0,
        .ctrl = wparam & c.MK_CONTROL != 0,
        .alt = c.GetKeyState(c.VK_MENU) < 0,
        .super = c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0,
    };
}

fn trackMouseLeave(self: *Surface) void {
    if (self.mouse_tracking) return;
    var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = self.hwnd };
    if (c.TrackMouseEvent(&tme).toBool()) self.mouse_tracking = true;
}

fn mouseMove(self: *Surface, wparam: c.WPARAM, lparam: c.LPARAM) void {
    self.trackMouseLeave();
    const x: i16 = @bitCast(c.loword(lparam));
    const y: i16 = @bitCast(c.hiword(lparam));
    const pos: apprt.CursorPos = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    if (pos.x == self.cursor_pos.x and pos.y == self.cursor_pos.y) return;
    self.cursor_pos = pos;
    if (!self.initialized) return;
    self.core_surface.cursorPosCallback(pos, mouseMods(wparam)) catch |err| {
        log.warn("error in cursor pos callback err={}", .{err});
    };
}

fn mouseLeave(self: *Surface) void {
    self.mouse_tracking = false;
    if (self.mouse_buttons != 0) return;
    self.cursor_pos = .{ .x = -1, .y = -1 };
    if (!self.initialized) return;
    self.core_surface.cursorPosCallback(self.cursor_pos, null) catch |err| {
        log.warn("error in cursor pos callback err={}", .{err});
    };
}

fn mouseButton(
    self: *Surface,
    state: input.MouseButtonState,
    button: input.MouseButton,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) void {
    const hwnd = self.hwnd orelse return;
    if (state == .press and button == .left) _ = c.SetFocus(hwnd);
    self.mouseMove(wparam, lparam);

    const bit = @as(u16, 1) << @intCast(@intFromEnum(button));
    switch (state) {
        .press => {
            if (self.mouse_buttons == 0) _ = c.SetCapture(hwnd);
            self.mouse_buttons |= bit;
        },
        .release => {
            self.mouse_buttons &= ~bit;
            if (self.mouse_buttons == 0 and c.GetCapture() == hwnd) _ = c.ReleaseCapture();
        },
    }

    if (!self.initialized) return;
    _ = self.core_surface.mouseButtonCallback(state, button, mouseMods(wparam)) catch |err| {
        log.warn("error in mouse button callback err={}", .{err});
    };
}

fn captureLost(self: *Surface) void {
    const buttons = self.mouse_buttons;
    self.mouse_buttons = 0;
    self.mouse_tracking = false;
    self.trackMouseLeave();
    if (buttons == 0 or !self.initialized) return;

    var wparam: c.WPARAM = 0;
    if (c.GetKeyState(c.VK_SHIFT) < 0) wparam |= c.MK_SHIFT;
    if (c.GetKeyState(c.VK_CONTROL) < 0) wparam |= c.MK_CONTROL;
    const mods = mouseMods(wparam);
    for (std.enums.values(input.MouseButton)) |button| {
        const bit = @as(u16, 1) << @intCast(@intFromEnum(button));
        if (buttons & bit == 0) continue;
        _ = self.core_surface.mouseButtonCallback(.release, button, mods) catch |err| {
            log.warn("error in mouse button callback err={}", .{err});
        };
    }
}

fn wheelSetting(action: c.UINT, default: c.UINT) c.UINT {
    var value: c.UINT = default;
    if (!c.SystemParametersInfoW(action, 0, &value, 0).toBool()) return default;
    return value;
}

fn mouseWheel(self: *Surface, wparam: c.WPARAM, horizontal: bool) void {
    if (!self.initialized) return;
    const delta: i16 = @bitCast(c.hiword(@bitCast(wparam)));
    const notches = @as(f64, @floatFromInt(delta)) / c.WHEEL_DELTA;
    const precision = @rem(delta, 120) != 0;
    const off: f64 = if (!precision) notches else off: {
        const size = self.core_surface.size;
        if (horizontal) {
            const chars = wheelSetting(c.SPI_GETWHEELSCROLLCHARS, 3);
            break :off notches * @as(f64, @floatFromInt(chars)) *
                @as(f64, @floatFromInt(size.cell.width));
        }
        const lines = switch (wheelSetting(c.SPI_GETWHEELSCROLLLINES, 3)) {
            c.WHEEL_PAGESCROLL => size.grid().rows,
            else => |v| v,
        };
        break :off notches * @as(f64, @floatFromInt(lines)) *
            @as(f64, @floatFromInt(size.cell.height));
    };
    self.core_surface.scrollCallback(
        if (horizontal) off else 0,
        if (horizontal) 0 else off,
        .{ .precision = precision },
    ) catch |err| {
        log.warn("error in scroll callback err={}", .{err});
    };
}

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    if (!self.supportsClipboard(clipboard_type)) return .unsupported;

    switch (state) {
        .osc_52_write => unreachable,
        .kitty_write => |kitty| {
            const text = textContent(kitty.contents);
            if (kitty.contents.len > 0 and text == null) return .unsupported;
            self.completeClipboard(state, .{}, text orelse "");
            return .started;
        },
        .list => {
            const available: []const []const u8 = if (clipboard.hasText()) &.{"text/plain"} else &.{};
            self.completeClipboard(state, .{ .available = available }, "");
            return .started;
        },
        .paste, .osc_52_read, .kitty_read => {},
    }

    const alloc = self.app.core_app.alloc;
    const text = clipboard.readText(alloc, self.hwnd) catch |err| switch (err) {
        error.ClipboardBusy => {
            log.warn("clipboard is held by another application", .{});
            return .unavailable;
        },
        else => |e| return e,
    } orelse return .unavailable;
    defer alloc.free(text);

    const contents = [_]terminal.clipboard.Content{.{ .mime = "text/plain", .data = text }};
    self.completeClipboard(state, .{
        .contents = &contents,
        .available = &.{"text/plain"},
    }, text);
    return .started;
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    if (!self.supportsClipboard(clipboard_type)) return;
    const text = textContent(contents) orelse return;
    if (confirm and !self.confirmClipboard(.write, text)) return;
    try clipboard.writeText(self.app.core_app.alloc, self.hwnd, text);
}

fn textContent(contents: []const apprt.ClipboardContent) ?[:0]const u8 {
    for (contents) |content| {
        if (terminal.clipboard.isTextMime(content.mime)) return content.data;
    }
    return null;
}

fn completeClipboard(
    self: *Surface,
    req: apprt.ClipboardRequest,
    complete: CoreSurface.CompleteClipboard,
    preview: []const u8,
) void {
    self.core_surface.completeClipboardRequest(req, complete) catch |err| switch (err) {
        error.UnsafePaste, error.UnauthorizedPaste => {
            const prompt: ClipboardPrompt = switch (req) {
                .paste, .list => .paste,
                .osc_52_read, .kitty_read => .read,
                .osc_52_write, .kitty_write => .write,
            };
            if (!self.confirmClipboard(prompt, preview)) {
                self.core_surface.denyClipboardRequest(req);
                return;
            }
            var confirmed = complete;
            confirmed.confirmed = true;
            self.core_surface.completeClipboardRequest(req, confirmed) catch |err2| {
                log.warn("error completing clipboard request err={}", .{err2});
            };
        },
        else => log.warn("error completing clipboard request err={}", .{err}),
    };
}

const ClipboardPrompt = enum { paste, read, write };

fn confirmClipboard(self: *Surface, prompt: ClipboardPrompt, text: []const u8) bool {
    const alloc = self.app.core_app.alloc;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const title: [:0]const u16, const body: []const u8 = switch (prompt) {
        .paste => .{
            L("Warning: Potentially Unsafe Paste"),
            "Pasting this text into the terminal may be dangerous as it looks like some commands may be executed.",
        },
        .read => .{
            L("Authorize Clipboard Access"),
            "An application is attempting to read from the clipboard. The current clipboard contents are shown below.",
        },
        .write => .{
            L("Authorize Clipboard Access"),
            "An application is attempting to write to the clipboard. The current clipboard contents are shown below.",
        },
    };

    var end = @min(text.len, 1024);
    while (end < text.len and end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    const ellipsis = if (end < text.len) "\n…" else "";
    const message = std.fmt.allocPrint(alloc, "{s}\n\n{s}{s}", .{ body, text[0..end], ellipsis }) catch return false;
    defer alloc.free(message);
    const wide = clipboard.utf16FromUtf8(alloc, message) catch return false;
    defer alloc.free(wide);

    return dialogs.confirm(self.window.hwnd, .{
        .main = title,
        .content = wide,
        .yes = L("Allow"),
        .no = L("Deny"),
        .default_yes = false,
    });
}

pub fn defaultTermioEnv(self: *Surface) !std.process.Environ.Map {
    _ = self;
    return try global.environMap();
}

pub fn skipTranslate(msg: *const c.MSG) bool {
    switch (msg.message) {
        c.WM_KEYDOWN, c.WM_KEYUP, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP => {},
        else => return false,
    }
    const vk: c.UINT = @truncate(msg.wParam & 0xFFFF);
    if (vk == c.VK_PACKET or vk == c.VK_PROCESSKEY) return false;
    const hwnd = msg.hwnd orelse return false;
    const proc: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_WNDPROC));
    return proc == @intFromPtr(&wndProc);
}

fn keyMessage(
    self: *Surface,
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) c.LRESULT {
    const sys_down = msg == c.WM_SYSKEYDOWN;
    if (sys_down) self.sys_char_passthrough = false;
    if (!self.initialized) return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    const vk: c.UINT = @truncate(wparam & 0xFFFF);
    const ime_composing = self.ime_state.onKey(hwnd, msg, vk);
    switch (vk) {
        c.VK_PACKET => {
            self.key_down_pending = false;
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.VK_PROCESSKEY => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
        c.VK_SHIFT, c.VK_CONTROL, c.VK_MENU, c.VK_LWIN, c.VK_RWIN, c.VK_CAPITAL => {},
        else => self.key_down_pending = msg == c.WM_KEYDOWN or sys_down,
    }
    if (key.isSyntheticAltGrCtrl(vk, lparam)) return 0;

    var event = key.translate(
        msg,
        wparam,
        lparam,
        c.GetKeyboardLayout(0),
        &self.key_utf8,
    ) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    var preedit: ?[]const u8 = null;
    if (ime_composing) {
        event.composing = true;
        event.utf8 = "";
    } else if (event.composing) {
        const len = @min(event.utf8.len, self.preedit_utf8.len);
        @memcpy(self.preedit_utf8[0..len], event.utf8[0..len]);
        preedit = self.preedit_utf8[0..len];
        event.utf8 = "";
    } else if (self.dead_key_pending and event.utf8.len > 0) {
        self.dead_key_pending = false;
        self.core_surface.preeditCallback(null) catch |err| {
            log.warn("error in preedit callback err={}", .{err});
        };
    }

    const effect = self.core_surface.keyCallback(event) catch |err| err: {
        log.warn("error in key callback err={}", .{err});
        break :err .ignored;
    };
    if (effect == .closed) return 0;

    if (preedit) |text| {
        self.dead_key_pending = true;
        self.core_surface.preeditCallback(text) catch |err| {
            log.warn("error in preedit callback err={}", .{err});
        };
    }

    if (vk == c.VK_LWIN or vk == c.VK_RWIN) return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (effect) {
        .closed, .consumed => return 0,
        .ignored => {
            if (!sys_down) return 0;
            self.sys_char_passthrough = true;
            const translate_msg: c.MSG = .{
                .hwnd = hwnd,
                .message = msg,
                .wParam = wparam,
                .lParam = lparam,
                .time = @bitCast(c.GetMessageTime()),
            };
            _ = c.TranslateMessage(&translate_msg);
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
    }
}

fn charMessage(self: *Surface, unit: u16) void {
    if (!self.initialized) return;
    const cp = self.char_decoder.push(unit) orelse return;
    var buf: [4]u8 = undefined;
    const event = key.charEvent(cp, &buf) orelse return;
    _ = self.core_surface.keyCallback(event) catch |err| {
        log.warn("error in key callback err={}", .{err});
    };
}

pub fn imePreedit(self: *Surface, text: ?[]const u8) void {
    if (!self.initialized) return;
    self.dead_key_pending = false;
    self.core_surface.preeditCallback(text) catch |err| {
        log.warn("error in preedit callback err={}", .{err});
    };
}

pub fn imeCommit(self: *Surface, text: []const u8) void {
    if (!self.initialized) return;
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .utf8 = text,
    }) catch |err| {
        log.warn("error in key callback err={}", .{err});
    };
}

pub fn imeCaret(self: *Surface) ?ime.Caret {
    if (!self.initialized) return null;
    const pos = self.core_surface.imePoint();
    const sx: f64 = self.content_scale.x;
    const sy: f64 = self.content_scale.y;
    const cell_w: f64 = @floatFromInt(self.core_surface.size.cell.width);
    const height = pos.height * sy;
    return .{
        .x = @intFromFloat(@max(0, pos.x * sx - cell_w / 2)),
        .y = @intFromFloat(@max(0, pos.y * sy - height)),
        .width = @intFromFloat(@max(1, pos.width * sx)),
        .height = @intFromFloat(@max(1, height)),
    };
}

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *Surface = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.hwnd = hwnd;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Surface = @ptrFromInt(ptr);

    if (self.ime_state.handle(self, self.app.core_app.alloc, hwnd, msg, wparam, lparam)) |result| return result;

    switch (msg) {
        c.WM_SIZE => {
            self.size = .{ .width = c.loword(lparam), .height = c.hiword(lparam) };
            if (self.initialized and self.size.width > 0 and self.size.height > 0) {
                self.core_surface.sizeCallback(self.size) catch |err| {
                    log.warn("error in size callback err={}", .{err});
                };
            }
            return 0;
        },

        c.WM_DPICHANGED_AFTERPARENT => {
            self.dpiChanged(c.GetDpiForWindow(hwnd));
            return 0;
        },

        c.WM_PAINT => {
            _ = c.ValidateRect(hwnd, null);
            return 0;
        },

        c.WM_ERASEBKGND => return 1,

        c.WM_SETFOCUS => {
            self.focusChanged(true);
            self.window.surfaceFocused(self);
            return 0;
        },

        c.WM_KILLFOCUS => {
            self.focusChanged(false);
            return 0;
        },

        WM_GHOSTTY_FOCUS => {
            self.applyFocus();
            return 0;
        },
        dialogs.WM_GHOSTTY_PROMPT_TITLE => {
            dialogs.promptTitle(self, std.enums.fromInt(apprt.action.PromptTitle, wparam) orelse return 0);
            return 0;
        },

        c.WM_SETCURSOR => if (c.loword(lparam) == c.HTCLIENT) {
            _ = c.SetCursor(self.currentCursor());
            return 1;
        },

        c.WM_MOUSEMOVE => {
            self.mouseMove(wparam, lparam);
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.mouseLeave();
            return 0;
        },

        c.WM_LBUTTONDOWN => {
            self.mouseButton(.press, .left, wparam, lparam);
            return 0;
        },

        c.WM_LBUTTONUP => {
            self.mouseButton(.release, .left, wparam, lparam);
            return 0;
        },

        c.WM_RBUTTONDOWN => {
            self.mouseButton(.press, .right, wparam, lparam);
            return 0;
        },

        c.WM_RBUTTONUP => {
            self.mouseButton(.release, .right, wparam, lparam);
            return 0;
        },

        c.WM_MBUTTONDOWN => {
            self.mouseButton(.press, .middle, wparam, lparam);
            return 0;
        },

        c.WM_MBUTTONUP => {
            self.mouseButton(.release, .middle, wparam, lparam);
            return 0;
        },

        c.WM_XBUTTONDOWN, c.WM_XBUTTONUP => {
            const button: input.MouseButton = switch (c.hiword(@bitCast(wparam))) {
                c.XBUTTON1 => .eight,
                c.XBUTTON2 => .nine,
                else => .unknown,
            };
            const state: input.MouseButtonState = if (msg == c.WM_XBUTTONDOWN) .press else .release;
            self.mouseButton(state, button, wparam, lparam);
            return 1;
        },

        c.WM_CAPTURECHANGED => {
            if (@as(usize, @bitCast(lparam)) != @intFromPtr(hwnd)) self.captureLost();
            return 0;
        },

        c.WM_MOUSEWHEEL => {
            self.mouseWheel(wparam, false);
            return 0;
        },

        c.WM_MOUSEHWHEEL => {
            self.mouseWheel(wparam, true);
            return 0;
        },

        c.WM_KEYDOWN,
        c.WM_KEYUP,
        c.WM_SYSKEYDOWN,
        c.WM_SYSKEYUP,
        => return self.keyMessage(hwnd, msg, wparam, lparam),

        c.WM_CHAR => {
            if (!self.key_down_pending and !self.ime_state.dedup.skip(@truncate(wparam), c.GetMessageTime())) self.charMessage(@truncate(wparam));
            return 0;
        },

        c.WM_INPUTLANGCHANGE => log.debug("keyboard layout changed hkl=0x{x}", .{@as(usize, @bitCast(lparam))}),

        c.WM_SYSCHAR => {
            if (self.sys_char_passthrough) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
