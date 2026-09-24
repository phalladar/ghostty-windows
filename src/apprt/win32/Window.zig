const Window = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");
const CoreSurface = @import("../../Surface.zig");
const Surface = @import("Surface.zig");
const TabBar = @import("TabBar.zig");
const SplitView = @import("SplitView.zig");
const c = @import("c.zig");
const dialogs = @import("dialogs.zig");

const log = std.log.scoped(.win32);

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const style = c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN;
const ex_style: c.DWORD = 0;
const default_columns = 80;
const default_rows = 24;
const cascade_step = 32;

app: *App,
hwnd: ?c.HWND = null,
tabs: std.ArrayList(Tab) = .empty,
active: usize = 0,
tab_bar: TabBar = .{},
split_view: SplitView = .{},
drag: ?SplitView.Handle = null,
sizing: bool = false,
size_limit: apprt.action.SizeLimit = .{
    .min_width = 0,
    .min_height = 0,
    .max_width = 0,
    .max_height = 0,
},
title_override: ?[:0]const u8 = null,
bell_ringing: bool = false,
fullscreen_saved: ?FullscreenSaved = null,

const Tab = struct {
    tree: SplitView.Tree,
    focused: *Surface,
    title_override: ?[:0]const u8 = null,
};

const FullscreenSaved = struct {
    style: c.LONG_PTR,
    placement: c.WINDOWPLACEMENT,
};

pub const Chrome = struct {
    dark: bool = true,
    caption: ?c.COLORREF = null,
    text: ?c.COLORREF = null,

    pub fn init(config: *const configpkg.Config, scheme: apprt.ColorScheme) Chrome {
        return switch (config.@"window-theme") {
            .auto => .{ .dark = isDark(config.background) },
            .system => .{ .dark = scheme == .dark },
            .light => .{ .dark = false },
            .dark => .{ .dark = true },
            .ghostty => ghostty: {
                const bg = config.@"window-titlebar-background" orelse config.background;
                const fg = config.@"window-titlebar-foreground" orelse config.foreground;
                break :ghostty .{
                    .dark = isDark(bg),
                    .caption = colorRef(bg),
                    .text = colorRef(fg),
                };
            },
        };
    }

    pub fn isDark(color: configpkg.Config.Color) bool {
        return color.toTerminalRGB().perceivedLuminance() <= 0.5;
    }

    pub fn colorRef(color: configpkg.Config.Color) c.COLORREF {
        return @as(c.COLORREF, color.r) |
            (@as(c.COLORREF, color.g) << 8) |
            (@as(c.COLORREF, color.b) << 16);
    }
};

pub fn create(app: *App) !*Window {
    const prev = app.activeWindow();
    const self = try createHost(app);
    const hwnd = self.hwnd.?;
    errdefer _ = c.DestroyWindow(hwnd);

    _ = try self.addTab(null, .window);
    self.place(prev);

    self.applyChrome(app.chrome);
    _ = c.ShowWindow(hwnd, if (app.config.maximize) c.SW_MAXIMIZE else c.SW_SHOWNORMAL);
    if (app.config.fullscreen != .false) self.toggleFullscreen();
    _ = c.UpdateWindow(hwnd);
    log.debug("window created hwnd={x}", .{@intFromPtr(hwnd)});
    return self;
}

fn createHost(app: *App) !*Window {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Window);
    self.* = .{ .app = app };

    const hwnd = c.CreateWindowExW(
        ex_style,
        App.window_class_name,
        L("Ghostty"),
        style,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        null,
        null,
        app.instance,
        self,
    ) orelse {
        alloc.destroy(self);
        return error.CreateWindowFailed;
    };
    errdefer _ = c.DestroyWindow(hwnd);

    try app.addWindow(self);
    try self.tab_bar.create(hwnd, app.instance);
    return self;
}

pub fn destroy(self: *Window) void {
    self.destroyTabs();
    if (self.hwnd) |hwnd| _ = c.DestroyWindow(hwnd);
}

fn destroyTabs(self: *Window) void {
    self.cancelDrag();
    self.split_view.clear();
    while (self.tabs.pop()) |tab| self.destroyTab(tab);
    self.active = 0;
}

fn destroyTab(self: *Window, tab: Tab) void {
    const alloc = self.app.core_app.alloc;
    var tree = tab.tree;
    if (tab.title_override) |v| alloc.free(v);
    var it = tree.iterator();
    while (it.next()) |entry| entry.view.destroy();
    tree.deinit();
}

pub fn requestClose(self: *Window) void {
    if (self.hwnd) |hwnd| _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0);
}

pub fn activeSurface(self: *const Window) ?*Surface {
    if (self.active >= self.tabs.items.len) return null;
    return self.tabs.items[self.active].focused;
}

pub fn tabIndex(self: *const Window, surface: *const Surface) ?usize {
    for (self.tabs.items, 0..) |*tab, i| {
        if (tab.tree.locate(surface) != null) return i;
    }
    return null;
}

pub fn tabTitle(self: *const Window, index: usize) []const u8 {
    const tab = self.tabs.items[index];
    return tab.title_override orelse tab.focused.getEffectiveTitle() orelse "Ghostty";
}

fn tabBarVisible(self: *const Window, count: usize) bool {
    return switch (self.app.config.@"window-show-tab-bar") {
        .always => true,
        .auto => count > 1,
        .never => false,
    };
}

fn contentRect(self: *const Window, count: usize) c.RECT {
    var rect: c.RECT = .{};
    const hwnd = self.hwnd orelse return rect;
    _ = c.GetClientRect(hwnd, &rect);
    if (self.tabBarVisible(count)) rect.top = @min(rect.bottom, rect.top + self.tab_bar.height());
    return rect;
}

pub fn newTab(self: *Window, parent: ?*CoreSurface) void {
    const p = parent orelse if (self.activeSurface()) |s| s.core() else null;
    _ = self.addTab(p, .tab) catch |err| {
        log.warn("error creating tab err={}", .{err});
    };
}

fn addTab(
    self: *Window,
    parent: ?*CoreSurface,
    context: apprt.surface.NewSurfaceContext,
) !*Surface {
    const alloc = self.app.core_app.alloc;
    try self.tabs.ensureUnusedCapacity(alloc, 1);
    const count = self.tabs.items.len;
    const index = switch (self.app.config.@"window-new-tab-position") {
        .current => if (count == 0) 0 else @min(self.active + 1, count),
        .end => count,
    };
    const prev = self.activeSurface();
    const surface = try Surface.create(self, self.contentRect(count + 1), context, parent);
    errdefer surface.destroy();
    const tree = try SplitView.Tree.init(alloc, surface);
    self.tabs.insertAssumeCapacity(index, .{ .tree = tree, .focused = surface });
    self.activate(index, prev);
    return surface;
}

fn activate(self: *Window, index: usize, prev: ?*Surface) void {
    if (index >= self.tabs.items.len) return;
    const focus = self.shouldFocus(prev);
    if (index != self.active) self.cancelDrag();
    self.active = index;
    self.layout();
    if (focus) self.focusActive();
    self.tab_bar.invalidate();
    self.refreshTitle();
}

fn shouldFocus(self: *const Window, prev: ?*Surface) bool {
    const hwnd = self.hwnd orelse return false;
    if (prev) |p| if (p.hwnd) |h| if (c.GetFocus() == h) return true;
    return c.GetForegroundWindow() == hwnd and !c.IsIconic(hwnd).toBool();
}

fn focusActive(self: *Window) void {
    const surface = self.activeSurface() orelse return;
    if (surface.hwnd) |h| _ = c.SetFocus(h);
}

pub fn selectSurface(self: *Window, surface: *Surface) void {
    const index = self.tabIndex(surface) orelse return;
    if (index == self.active) return self.focusSplit(index, surface);
    self.retarget(&self.tabs.items[index], surface);
    self.selectTab(index);
}

pub fn selectTab(self: *Window, index: usize) void {
    if (index == self.active) return;
    self.activate(index, self.activeSurface());
}

pub fn gotoTab(self: *Window, tab: apprt.action.GotoTab) bool {
    const total = self.tabs.items.len;
    if (total == 0) return false;
    const current = @min(self.active, total - 1);
    const target: usize = switch (tab) {
        .previous => if (current > 0) current - 1 else total - 1,
        .next => if (current < total - 1) current + 1 else 0,
        .last => total - 1,
        _ => n: {
            const n = std.math.cast(usize, @intFromEnum(tab)) orelse return false;
            if (n == 0) return false;
            break :n @min(n - 1, total - 1);
        },
    };
    if (target == current) return false;
    self.selectTab(target);
    return true;
}

pub fn moveTab(self: *Window, surface: *Surface, amount: isize) bool {
    const total = self.tabs.items.len;
    if (total <= 1) return false;
    const pos = self.tabIndex(surface) orelse return false;
    const max: isize = @intCast(total - 1);
    const initial: isize = @as(isize, @intCast(pos)) + amount;
    const desired: usize = @intCast(if (initial < 0)
        @max(0, max + initial + 1)
    else if (initial > max)
        @min(max, initial - max - 1)
    else
        initial);
    if (desired == pos) return false;
    const active = self.activeSurface();
    const tab = self.tabs.orderedRemove(pos);
    self.tabs.insertAssumeCapacity(desired, tab);
    if (active) |a| self.active = self.tabIndex(a) orelse self.active;
    self.tab_bar.invalidate();
    return true;
}

pub fn moveTabToNewWindow(self: *Window, surface: *Surface) bool {
    const index = self.tabIndex(surface) orelse return false;
    if (self.tabs.items.len <= 1) return false;
    return self.tearOffTab(index, null, 0);
}

pub fn detachTab(self: *Window, index: usize, pt: c.POINT, grab: i32) ?*Window {
    if (self.tabs.items.len <= 1) return null;
    return self.spawnWindow(index, pt, grab, true);
}

pub fn dropTab(self: *Window, index: usize, pt: c.POINT, grab: i32) void {
    const root = if (c.WindowFromPoint(pt)) |h| c.GetAncestor(h, c.GA_ROOT) else null;
    if (root) |r| for (self.app.windows.items) |target| {
        if (target == self or target.hwnd != r) continue;
        const at = target.tab_bar.dropIndex(pt) orelse break;
        if (!self.transferTab(index, target, at)) return;
        if (target.hwnd) |h| _ = c.SetForegroundWindow(h);
        return;
    };
    _ = self.tearOffTab(index, pt, grab);
}

fn tearOffTab(self: *Window, index: usize, drop: ?c.POINT, grab: i32) bool {
    const hwnd = self.hwnd orelse return false;
    if (index >= self.tabs.items.len) return false;
    const dpi = c.GetDpiForWindow(hwnd);
    var frame: c.RECT = .{};
    _ = c.AdjustWindowRectExForDpi(&frame, style, .FALSE, ex_style, dpi);

    if (self.tabs.items.len == 1) {
        const pt = drop orelse return false;
        const bar = self.tabBarHeight();
        const x = pt.x - grab + frame.left;
        const y = pt.y - @divTrunc(bar, 2) + frame.top;
        _ = c.SetWindowPos(hwnd, null, x, y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        return true;
    }
    return self.spawnWindow(index, drop, grab, false) != null;
}

fn spawnWindow(self: *Window, index: usize, drop: ?c.POINT, grab: i32, live: bool) ?*Window {
    const hwnd = self.hwnd orelse return null;
    if (index >= self.tabs.items.len) return null;
    const dpi = c.GetDpiForWindow(hwnd);
    var frame: c.RECT = .{};
    _ = c.AdjustWindowRectExForDpi(&frame, style, .FALSE, ex_style, dpi);

    const content = self.contentRect(self.tabs.items.len);
    const target = createHost(self.app) catch |err| {
        log.warn("error creating window for tab err={}", .{err});
        return null;
    };
    const target_hwnd = target.hwnd.?;
    const bar = if (target.tabBarVisible(1)) target.tab_bar.height() else 0;
    const size = outerSize(
        target_hwnd,
        @intCast(@max(1, content.right - content.left)),
        @intCast(@max(1, content.bottom - content.top + bar)),
    );

    var x: i32 = 0;
    var y: i32 = 0;
    if (drop) |pt| {
        x = pt.x - grab + frame.left;
        y = if (bar > 0) pt.y - @divTrunc(bar, 2) + frame.top else pt.y + @divTrunc(frame.top, 2);
    } else {
        var rect: c.RECT = .{};
        _ = c.GetWindowRect(hwnd, &rect);
        const step: i32 = @intCast(@divTrunc(cascade_step * dpi, 96));
        x = rect.left + step;
        y = rect.top + step;
    }
    const monitor = c.MonitorFromPoint(drop orelse .{ .x = x, .y = y }, c.MONITOR_DEFAULTTONEAREST);
    var info: c.MONITORINFO = .{};
    if (!live and monitor != null and c.GetMonitorInfoW(monitor.?, &info).toBool()) {
        const work = info.rcWork;
        x = @max(work.left, @min(x, work.right - size.x));
        y = @max(work.top, @min(y, work.bottom - size.y));
    }
    const on: c.BOOL = .TRUE;
    _ = c.DwmSetWindowAttribute(target_hwnd, c.DWMWA_CLOAK, &on, @sizeOf(c.BOOL));
    if (live) target.setTransitions(false);
    target.applyChrome(self.app.chrome);
    _ = c.SetWindowPos(target_hwnd, null, x, y, size.x, size.y, c.SWP_NOACTIVATE);

    if (!self.transferTab(index, target, 0)) {
        _ = c.DestroyWindow(target_hwnd);
        return null;
    }
    _ = c.ShowWindow(target_hwnd, if (live) c.SW_SHOWNA else c.SW_SHOWNORMAL);
    _ = c.UpdateWindow(target_hwnd);
    target.presentActive(reveal_timeout_ms);
    const off: c.BOOL = .FALSE;
    _ = c.DwmSetWindowAttribute(target_hwnd, c.DWMWA_CLOAK, &off, @sizeOf(c.BOOL));
    return target;
}

const reveal_timeout_ms = 80;

pub fn setTransitions(self: *Window, enabled: bool) void {
    const hwnd = self.hwnd orelse return;
    const disabled: c.BOOL = if (enabled) .FALSE else .TRUE;
    _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_TRANSITIONS_FORCEDISABLED, &disabled, @sizeOf(c.BOOL));
}

fn presentActive(self: *Window, timeout_ms: u32) void {
    if (self.active >= self.tabs.items.len) return;
    const tab = &self.tabs.items[self.active];
    const n: u32 = @intCast(@max(1, tab.tree.nodes.len));
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        if (!entry.view.presentFresh(@max(10, timeout_ms / n))) {
            log.debug("reveal present timed out", .{});
        }
    }
}

pub fn transferTab(self: *Window, index: usize, target: *Window, at: usize) bool {
    const target_hwnd = target.hwnd orelse return false;
    if (index >= self.tabs.items.len) return false;
    target.tabs.ensureUnusedCapacity(self.app.core_app.alloc, 1) catch return false;
    self.cancelDrag();
    target.cancelDrag();
    const tab = self.tabs.orderedRemove(index);

    const dpi = c.GetDpiForWindow(target_hwnd);
    const scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    var tree = tab.tree;
    var it = tree.iterator();
    while (it.next()) |entry| {
        const surface = entry.view;
        surface.window = target;
        if (surface.hwnd) |h| _ = c.SetParent(h, target_hwnd);
        if (surface.content_scale.x != scale) surface.dpiChanged(dpi);
        surface.refresh();
    }
    const prev = target.activeSurface();
    const pos = @min(at, target.tabs.items.len);
    target.tabs.insertAssumeCapacity(pos, tab);
    target.activate(pos, prev);

    const remaining = self.tabs.items.len;
    if (remaining == 0) {
        self.active = 0;
        self.split_view.clear();
        if (self.hwnd) |h| _ = c.DestroyWindow(h);
        return true;
    }
    if (index < self.active) {
        self.active -= 1;
    } else if (index == self.active) {
        self.activate(@min(index, remaining - 1), null);
    }
    self.layout();
    self.tab_bar.invalidate();
    self.refreshTitle();
    return true;
}

pub fn setTabTitle(self: *Window, surface: *Surface, title: [:0]const u8) !void {
    const index = self.tabIndex(surface) orelse return;
    const alloc = self.app.core_app.alloc;
    const copy: ?[:0]const u8 = if (title.len == 0) null else try alloc.dupeZ(u8, title);
    const tab = &self.tabs.items[index];
    if (tab.title_override) |v| alloc.free(v);
    tab.title_override = copy;
    self.tab_bar.invalidate();
    if (index == self.active) self.refreshTitle();
}

pub fn surfaceTitleChanged(self: *Window, surface: *Surface) void {
    self.tab_bar.invalidate();
    if (self.activeSurface() == surface) self.refreshTitle();
}

pub fn surfaceFocused(self: *Window, surface: *Surface) void {
    const index = self.tabIndex(surface) orelse return;
    const tab = &self.tabs.items[index];
    if (tab.focused == surface) return;
    tab.focused = surface;
    self.tab_bar.invalidate();
    if (index == self.active) self.refreshTitle();
}

fn tabNeedsConfirm(self: *Window, index: usize) bool {
    var it = self.tabs.items[index].tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.core().needsConfirmQuit()) return true;
    }
    return false;
}

pub fn closeTabAt(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len) return;
    const surface = self.tabs.items[index].focused;
    if (self.tabNeedsConfirm(index) and !dialogs.confirmClose(self.hwnd, .tab)) return;
    const i = self.tabIndex(surface) orelse return;
    self.removeTab(i);
}

pub fn closeTabs(self: *Window, surface: *Surface, mode: apprt.action.CloseTabMode) void {
    const pos = self.tabIndex(surface) orelse return;
    if (mode == .this) return self.closeTabAt(pos);

    const alloc = self.app.core_app.alloc;
    var targets: std.ArrayList(*Surface) = .empty;
    defer targets.deinit(alloc);
    var confirm = false;
    for (self.tabs.items, 0..) |tab, i| {
        const close = switch (mode) {
            .this => unreachable,
            .other => i != pos,
            .right => i > pos,
        };
        if (!close) continue;
        targets.append(alloc, tab.focused) catch return;
        if (!confirm) confirm = self.tabNeedsConfirm(i);
    }
    if (targets.items.len == 0) return;
    if (confirm and !dialogs.confirmClose(self.hwnd, .tab)) return;
    for (targets.items) |s| {
        if (self.tabIndex(s)) |i| self.removeTab(i);
    }
}

fn removeTab(self: *Window, index: usize) void {
    self.cancelDrag();
    const tab = self.tabs.orderedRemove(index);
    const remaining = self.tabs.items.len;
    if (remaining == 0) {
        self.active = 0;
        self.split_view.clear();
        self.destroyTab(tab);
        if (self.hwnd) |hwnd| _ = c.DestroyWindow(hwnd);
        return;
    }

    if (index < self.active) {
        self.active -= 1;
    } else if (index == self.active) {
        self.activate(@min(index, remaining - 1), tab.focused);
    }
    self.destroyTab(tab);
    self.layout();
    self.tab_bar.invalidate();
    self.refreshTitle();
}

pub fn closeSurface(self: *Window, surface: *Surface) void {
    const index = self.tabIndex(surface) orelse return surface.destroy();
    const tab = &self.tabs.items[index];
    if (!tab.tree.isSplit()) return self.removeTab(index);

    const alloc = self.app.core_app.alloc;
    const handle = tab.tree.locate(surface) orelse return;
    const next: *Surface = if (tab.focused != surface) tab.focused else next: {
        const h = (tab.tree.goto(alloc, handle, .previous) catch null) orelse
            (tab.tree.goto(alloc, handle, .next) catch null) orelse
            break :next tab.focused;
        break :next tab.tree.nodes[h.idx()].leaf;
    };
    const tree = tab.tree.remove(alloc, handle) catch |err| {
        log.warn("error removing split err={}", .{err});
        return;
    };
    const focus = index == self.active and self.shouldFocus(surface);
    self.replaceTree(tab, tree);
    tab.focused = next;
    self.layout();
    if (focus) self.focusActive();
    surface.destroy();
    self.tab_bar.invalidate();
    self.refreshTitle();
}

fn replaceTree(self: *Window, tab: *Tab, tree: SplitView.Tree) void {
    self.cancelDrag();
    tab.tree.deinit();
    tab.tree = tree;
}

fn retarget(self: *Window, tab: *Tab, surface: *Surface) void {
    tab.focused = surface;
    const zoomed = tab.tree.zoomed orelse return;
    const handle = tab.tree.locate(surface) orelse return;
    if (zoomed == handle) return;
    if (self.app.config.@"split-preserve-zoom".navigation) {
        tab.tree.zoom(handle);
    } else {
        tab.tree.zoomed = null;
    }
}

fn focusSplit(self: *Window, index: usize, surface: *Surface) void {
    const tab = &self.tabs.items[index];
    const focus = index == self.active and self.shouldFocus(tab.focused);
    self.retarget(tab, surface);
    self.layout();
    if (focus) self.focusActive();
    self.tab_bar.invalidate();
    self.refreshTitle();
}

pub fn newSplit(self: *Window, surface: *Surface, direction: apprt.action.SplitDirection) !void {
    const hwnd = self.hwnd orelse return;
    const alloc = self.app.core_app.alloc;
    const dir: SplitView.Direction = switch (direction) {
        .right => .right,
        .down => .down,
        .left => .left,
        .up => .up,
    };
    const index = self.tabIndex(surface) orelse return;
    const current = if (index == self.active) self.split_view.rectOf(surface) else null;
    const rect = SplitView.newRect(
        current orelse self.contentRect(self.tabs.items.len),
        dir,
        SplitView.gap(c.GetDpiForWindow(hwnd)),
    );
    const focus = index == self.active and self.shouldFocus(surface);

    const new = try Surface.create(self, rect, .split, surface.core());
    errdefer new.destroy();
    var single = try SplitView.Tree.init(alloc, new);
    defer single.deinit();

    const i = self.tabIndex(surface) orelse return error.SurfaceNotFound;
    const tab = &self.tabs.items[i];
    const handle = tab.tree.locate(surface) orelse return error.SurfaceNotFound;
    const tree = try tab.tree.split(alloc, handle, dir, 0.5, &single);
    self.replaceTree(tab, tree);
    tab.focused = new;
    self.layout();
    if (focus) self.focusActive();
    self.tab_bar.invalidate();
    self.refreshTitle();
    log.debug("new split direction={t} nodes={}", .{ direction, tab.tree.nodes.len });
}

pub fn gotoSplit(self: *Window, surface: *Surface, to: apprt.action.GotoSplit) bool {
    const index = self.tabIndex(surface) orelse return false;
    const tab = &self.tabs.items[index];
    const from = tab.tree.locate(surface) orelse return false;
    const goto: SplitView.Tree.Goto = switch (to) {
        .previous => .previous_wrapped,
        .next => .next_wrapped,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };
    const alloc = self.app.core_app.alloc;
    const target = (tab.tree.goto(alloc, from, goto) catch return false) orelse return false;
    if (target == from) return false;
    self.focusSplit(index, tab.tree.nodes[target.idx()].leaf);
    log.debug("goto split {t} from={} target={}", .{ to, from.idx(), target.idx() });
    return true;
}

pub fn resizeSplit(self: *Window, surface: *Surface, value: apprt.action.ResizeSplit) bool {
    if (value.amount == 0) return false;
    const index = self.tabIndex(surface) orelse return false;
    const tab = &self.tabs.items[index];
    if (!tab.tree.isSplit()) return false;
    const from = tab.tree.locate(surface) orelse return false;
    const content = self.contentRect(self.tabs.items.len);
    const width: f32 = @floatFromInt(content.right - content.left);
    const height: f32 = @floatFromInt(content.bottom - content.top);
    if (width <= 0 or height <= 0) return false;
    const amount = @as(f32, @floatFromInt(value.amount)) * surface.content_scale.x;
    const delta: f32 = switch (value.direction) {
        .right => amount / width,
        .left => -amount / width,
        .down => amount / height,
        .up => -amount / height,
    };
    const orientation: SplitView.Layout = switch (value.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };
    const tree = tab.tree.resize(
        self.app.core_app.alloc,
        from,
        orientation,
        @floatCast(std.math.clamp(delta, -1, 1)),
    ) catch return false;
    self.replaceTree(tab, tree);
    self.layout();
    return true;
}

pub fn equalizeSplits(self: *Window, surface: *Surface) bool {
    const index = self.tabIndex(surface) orelse return false;
    const tab = &self.tabs.items[index];
    if (!tab.tree.isSplit()) return false;
    const tree = tab.tree.equalize(self.app.core_app.alloc) catch return false;
    self.replaceTree(tab, tree);
    self.layout();
    return true;
}

pub fn toggleSplitZoom(self: *Window, surface: *Surface) bool {
    const index = self.tabIndex(surface) orelse return false;
    const tab = &self.tabs.items[index];
    if (!tab.tree.isSplit()) return false;
    if (tab.tree.zoomed != null) {
        tab.tree.zoomed = null;
    } else {
        tab.tree.zoom(tab.tree.locate(surface) orelse return false);
        tab.focused = surface;
    }
    self.layout();
    return true;
}

pub fn setTitleOverride(self: *Window, title: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy: ?[:0]const u8 = if (title.len == 0) null else try alloc.dupeZ(u8, title);
    if (self.title_override) |v| alloc.free(v);
    self.title_override = copy;
    self.refreshTitle();
}

fn refreshTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const alloc = self.app.core_app.alloc;
    const base: []const u8 = self.title_override orelse
        if (self.active < self.tabs.items.len) self.tabTitle(self.active) else "Ghostty";
    const prefix: []const u8 = if (self.bell_ringing) "\u{1F514} " else "";
    const full = std.mem.concat(alloc, u8, &.{ prefix, base }) catch return;
    defer alloc.free(full);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, full) catch return;
    defer alloc.free(wide);
    _ = c.SetWindowTextW(hwnd, wide);
}

pub fn applyChrome(self: *Window, chrome: Chrome) void {
    const hwnd = self.hwnd orelse return;
    const dark: c.BOOL = if (chrome.dark) .TRUE else .FALSE;
    _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(c.BOOL));
    const caption = chrome.caption orelse c.DWMWA_COLOR_DEFAULT;
    _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_CAPTION_COLOR, &caption, @sizeOf(c.COLORREF));
    const text = chrome.text orelse c.DWMWA_COLOR_DEFAULT;
    _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_TEXT_COLOR, &text, @sizeOf(c.COLORREF));
    self.layout();
    self.tab_bar.invalidate();
    log.debug("window chrome dark={} caption={?x} text={?x}", .{ chrome.dark, chrome.caption, chrome.text });
}

pub fn ringBell(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const features = self.app.config.@"bell-features";
    if (features.system or features.audio) _ = c.MessageBeep(c.MB_OK);
    if (c.GetForegroundWindow() == hwnd) return;
    if (features.attention) {
        const info: c.FLASHWINFO = .{
            .hwnd = hwnd,
            .dwFlags = c.FLASHW_TRAY,
            .uCount = 3,
        };
        _ = c.FlashWindowEx(&info);
        log.debug("bell flashed taskbar", .{});
    }
    if (features.title and !self.bell_ringing) {
        self.bell_ringing = true;
        self.refreshTitle();
    }
}

fn clearBell(self: *Window) void {
    if (!self.bell_ringing) return;
    self.bell_ringing = false;
    self.refreshTitle();
}

pub fn toggleMaximize(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.fullscreen_saved != null) return;
    _ = c.ShowWindow(hwnd, if (c.IsZoomed(hwnd).toBool()) c.SW_RESTORE else c.SW_MAXIMIZE);
}

pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.fullscreen_saved) |saved| {
        self.fullscreen_saved = null;
        _ = c.SetWindowLongPtrW(hwnd, c.GWL_STYLE, saved.style);
        _ = c.SetWindowPlacement(hwnd, &saved.placement);
        _ = c.SetWindowPos(
            hwnd,
            null,
            0,
            0,
            0,
            0,
            c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED,
        );
        return;
    }

    var placement: c.WINDOWPLACEMENT = .{};
    if (!c.GetWindowPlacement(hwnd, &placement).toBool()) return;
    const monitor = c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return;
    var info: c.MONITORINFO = .{};
    if (!c.GetMonitorInfoW(monitor, &info).toBool()) return;

    const current = c.GetWindowLongPtrW(hwnd, c.GWL_STYLE);
    self.fullscreen_saved = .{ .style = current, .placement = placement };
    const current_bits: usize = @bitCast(current);
    const new_bits = (current_bits & ~@as(usize, c.WS_OVERLAPPEDWINDOW)) | c.WS_POPUP;
    _ = c.SetWindowLongPtrW(hwnd, c.GWL_STYLE, @bitCast(new_bits));
    const r = info.rcMonitor;
    _ = c.SetWindowPos(
        hwnd,
        null,
        r.left,
        r.top,
        r.right - r.left,
        r.bottom - r.top,
        c.SWP_NOZORDER | c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED,
    );
}

pub fn setSizeLimit(self: *Window, limit: apprt.action.SizeLimit) void {
    self.size_limit = limit;
}

pub fn setInitialSize(self: *Window, width: u32, height: u32) void {
    const hwnd = self.hwnd orelse return;
    if (c.IsWindowVisible(hwnd).toBool()) return;
    const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96.0;
    const client_w: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(width)) * scale));
    const client_h: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(height)) * scale));
    var rect: c.RECT = .{ .right = client_w, .bottom = client_h + self.tabBarHeight() };
    _ = c.AdjustWindowRectExForDpi(&rect, style, .FALSE, ex_style, c.GetDpiForWindow(hwnd));
    _ = c.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        rect.right - rect.left,
        rect.bottom - rect.top,
        c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

fn place(self: *Window, prev: ?*Window) void {
    const hwnd = self.hwnd orelse return;
    const surface = self.activeSurface() orelse return;
    const config = &self.app.config;
    const dpi = c.GetDpiForWindow(hwnd);

    var rect: c.RECT = .{};
    _ = c.GetWindowRect(hwnd, &rect);
    var w = rect.right - rect.left;
    var h = rect.bottom - rect.top;
    if (config.@"window-width" == 0 or config.@"window-height" == 0) {
        const cell = surface.core_surface.size.cell;
        const px_per_pt_x = surface.content_scale.x * 96.0 / 72.0;
        const px_per_pt_y = surface.content_scale.y * 96.0 / 72.0;
        const pad_x = config.@"window-padding-x";
        const pad_y = config.@"window-padding-y";
        const pad_w: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(pad_x.top_left)) * px_per_pt_x) +
            @floor(@as(f32, @floatFromInt(pad_x.bottom_right)) * px_per_pt_x));
        const pad_h: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(pad_y.top_left)) * px_per_pt_y) +
            @floor(@as(f32, @floatFromInt(pad_y.bottom_right)) * px_per_pt_y));
        const bar_h: u32 = @intCast(self.tabBarHeight());
        const size = outerSize(hwnd, default_columns * cell.width + pad_w, default_rows * cell.height + pad_h + bar_h);
        w = size.x;
        h = size.y;
    }

    const anchor = if (prev) |p| p.hwnd orelse hwnd else hwnd;
    const monitor = c.MonitorFromWindow(anchor, c.MONITOR_DEFAULTTONEAREST) orelse return;
    var info: c.MONITORINFO = .{};
    if (!c.GetMonitorInfoW(monitor, &info).toBool()) return;
    const work = info.rcWork;
    w = @min(w, work.right - work.left);
    h = @min(h, work.bottom - work.top);

    var x = rect.left;
    var y = rect.top;
    if (prev) |p| if (p.hwnd) |prev_hwnd| {
        var prev_rect: c.RECT = .{};
        if (c.GetWindowRect(prev_hwnd, &prev_rect).toBool()) {
            const step: i32 = @intCast(@divTrunc(cascade_step * dpi, 96));
            x = prev_rect.left + step;
            y = prev_rect.top + step;
            if (x + w > work.right) x = work.left;
            if (y + h > work.bottom) y = work.top;
        }
    };
    x = @max(work.left, @min(x, work.right - w));
    y = @max(work.top, @min(y, work.bottom - h));

    _ = c.SetWindowPos(hwnd, null, x, y, w, h, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

fn outerSize(hwnd: c.HWND, width: u32, height: u32) c.POINT {
    var rect: c.RECT = .{
        .right = @intCast(@min(width, std.math.maxInt(i32))),
        .bottom = @intCast(@min(height, std.math.maxInt(i32))),
    };
    _ = c.AdjustWindowRectExForDpi(&rect, style, .FALSE, ex_style, c.GetDpiForWindow(hwnd));
    return .{ .x = rect.right - rect.left, .y = rect.bottom - rect.top };
}

fn tabBarHeight(self: *const Window) i32 {
    return if (self.tabBarVisible(self.tabs.items.len)) self.tab_bar.height() else 0;
}

fn layout(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var client: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &client);
    const content = self.contentRect(self.tabs.items.len);
    const w = client.right - client.left;
    if (self.tab_bar.hwnd) |bar| {
        if (content.top > client.top) {
            _ = c.MoveWindow(bar, 0, 0, w, content.top - client.top, .TRUE);
            if (!c.IsWindowVisible(bar).toBool()) _ = c.ShowWindow(bar, c.SW_SHOWNA);
        } else if (c.IsWindowVisible(bar).toBool()) {
            _ = c.ShowWindow(bar, c.SW_HIDE);
        }
    }
    self.layoutSplits(content);
}

fn layoutSplits(self: *Window, content: c.RECT) void {
    const hwnd = self.hwnd orelse return;
    const alloc = self.app.core_app.alloc;
    const minimized = c.IsIconic(hwnd).toBool();
    const gap = SplitView.gap(c.GetDpiForWindow(hwnd));

    var count: usize = 0;
    for (self.tabs.items) |*tab| count += tab.tree.nodes.len;
    var changed: std.ArrayList(*Surface) = .empty;
    defer changed.deinit(alloc);

    var pos: SplitView.Positioner = .begin(count);
    for (self.tabs.items, 0..) |*tab, i| {
        if (i != self.active) self.placeTab(tab, false, content, gap, minimized, &pos, &changed);
    }
    if (self.active < self.tabs.items.len) {
        self.placeTab(&self.tabs.items[self.active], true, content, gap, minimized, &pos, &changed);
    } else {
        self.split_view.clear();
    }
    pos.end();

    for (changed.items) |surface| {
        const shown = if (surface.hwnd) |h| isShown(h) else false;
        surface.setVisible(shown and !minimized);
    }
    _ = c.InvalidateRect(hwnd, &content, .FALSE);
}

fn placeTab(
    self: *Window,
    tab: *Tab,
    active: bool,
    content: c.RECT,
    gap: i32,
    minimized: bool,
    pos: *SplitView.Positioner,
    changed: *std.ArrayList(*Surface),
) void {
    const alloc = self.app.core_app.alloc;
    self.split_view.compute(alloc, &tab.tree, content, gap) catch |err| {
        log.warn("error computing split layout err={}", .{err});
        self.split_view.clear();
    };
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        const surface = entry.view;
        const child = surface.hwnd orelse continue;
        const rect = self.split_view.rectOf(surface);
        const show = active and rect != null;
        var flags: c.UINT = c.SWP_NOZORDER | c.SWP_NOACTIVATE;
        if (rect == null or minimized) flags |= c.SWP_NOMOVE | c.SWP_NOSIZE;
        if (show != isShown(child)) {
            flags |= if (show) c.SWP_SHOWWINDOW else c.SWP_HIDEWINDOW;
            changed.append(alloc, surface) catch {};
        }
        pos.move(child, rect orelse content, flags);
    }
}

fn syncPresent(self: *Window) void {
    if (self.active >= self.tabs.items.len) return;
    var it = self.tabs.items[self.active].tree.iterator();
    while (it.next()) |entry| {
        if (!entry.view.waitPresented(present_timeout_ms)) {
            log.debug("resize present timed out", .{});
            break;
        }
    }
    if (self.sizing) _ = c.DwmFlush();
}

const present_timeout_ms = 50;

fn isShown(hwnd: c.HWND) bool {
    const bits: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWL_STYLE));
    return bits & c.WS_VISIBLE != 0;
}

fn setTabVisible(self: *Window, visible: bool) void {
    if (self.active >= self.tabs.items.len) return;
    var it = self.tabs.items[self.active].tree.iterator();
    while (it.next()) |entry| {
        const child = entry.view.hwnd orelse continue;
        if (isShown(child)) entry.view.setVisible(visible);
    }
}

fn cancelDrag(self: *Window) void {
    if (self.drag == null) return;
    self.drag = null;
    if (self.hwnd) |hwnd| {
        if (c.GetCapture() == hwnd) _ = c.ReleaseCapture();
    }
}

fn dragTo(self: *Window, pt: c.POINT) void {
    const handle = self.drag orelse return;
    const hwnd = self.hwnd orelse return;
    if (self.active >= self.tabs.items.len) return self.cancelDrag();
    const divider = self.split_view.find(handle) orelse return self.cancelDrag();
    const tab = &self.tabs.items[self.active];
    const ratio = SplitView.ratioAt(divider, pt, SplitView.gap(c.GetDpiForWindow(hwnd)));
    if (tab.tree.nodes[handle.idx()].split.ratio == ratio) return;
    tab.tree.resizeInPlace(handle, ratio);
    self.layout();
}

fn dividerCursor(self: *Window) ?c.HCURSOR {
    const orientation: SplitView.Layout = if (self.drag) |handle| orientation: {
        const divider = self.split_view.find(handle) orelse return null;
        break :orientation divider.layout;
    } else orientation: {
        const hwnd = self.hwnd orelse return null;
        var pt: c.POINT = .{};
        if (!c.GetCursorPos(&pt).toBool()) return null;
        _ = c.ScreenToClient(hwnd, &pt);
        const divider = self.split_view.hit(pt) orelse return null;
        break :orientation divider.layout;
    };
    return c.LoadCursorW(null, switch (orientation) {
        .horizontal => c.IDC_SIZEWE,
        .vertical => c.IDC_SIZENS,
    });
}

fn paint(self: *Window, hdc: c.HDC, dirty: c.RECT) void {
    const hwnd = self.hwnd orelse return;
    const config = &self.app.config;
    const line = if (config.@"split-divider-color") |color|
        Chrome.colorRef(color)
    else
        TabBar.Palette.init(config).separator;
    self.split_view.paint(hdc, dirty, c.GetDpiForWindow(hwnd), Chrome.colorRef(config.background), line);
}

fn pointFromLparam(lparam: c.LPARAM) c.POINT {
    const x: i16 = @bitCast(c.loword(lparam));
    const y: i16 = @bitCast(c.hiword(lparam));
    return .{ .x = x, .y = y };
}

fn handleClose(self: *Window) void {
    for (0..self.tabs.items.len) |i| {
        if (!self.tabNeedsConfirm(i)) continue;
        if (!dialogs.confirmClose(self.hwnd, .window)) return;
        break;
    }
    if (self.hwnd) |hwnd| _ = c.DestroyWindow(hwnd);
}

pub fn confirmClose(hwnd: ?c.HWND) bool {
    return dialogs.confirmClose(hwnd, .surface);
}

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *Window = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.hwnd = hwnd;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Window = @ptrFromInt(ptr);

    switch (msg) {
        c.WM_SIZE => {
            const minimized = wparam == c.SIZE_MINIMIZED;
            self.setTabVisible(!minimized);
            if (!minimized) {
                self.layout();
                self.syncPresent();
            }
            return 0;
        },

        c.WM_ENTERSIZEMOVE => self.sizing = true,
        c.WM_EXITSIZEMOVE => self.sizing = false,

        c.WM_GETMINMAXINFO => {
            const info: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (self.fullscreen_saved != null) return 0;
            const limit = self.size_limit;
            if (limit.min_width > 0 or limit.min_height > 0) {
                info.ptMinTrackSize = outerSize(hwnd, limit.min_width, limit.min_height);
            }
            if (limit.max_width > 0 and limit.max_height > 0) {
                info.ptMaxTrackSize = outerSize(hwnd, limit.max_width, limit.max_height);
            }
            return 0;
        },

        c.WM_DPICHANGED => {
            const dpi = c.loword(@bitCast(wparam));
            for (self.tabs.items) |*tab| {
                var it = tab.tree.iterator();
                while (it.next()) |entry| entry.view.dpiChanged(dpi);
            }
            const rect: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowPos(
                hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                c.SWP_NOZORDER | c.SWP_NOACTIVATE,
            );
            self.layout();
            self.tab_bar.invalidate();
            return 0;
        },

        c.WM_SETFOCUS => {
            if (self.activeSurface()) |surface| {
                if (surface.hwnd) |child| _ = c.SetFocus(child);
            }
            return 0;
        },

        c.WM_ACTIVATE => {
            const active = c.loword(@bitCast(wparam)) != c.WA_INACTIVE;
            const minimized = c.hiword(@bitCast(wparam)) != 0;
            if (active) self.app.windowActivated(self);
            if (active and !minimized) {
                self.clearBell();
                if (self.activeSurface()) |surface| {
                    if (surface.hwnd) |child| {
                        _ = c.SetFocus(child);
                        return 0;
                    }
                }
            }
        },

        c.WM_SHOWWINDOW => {
            self.setTabVisible(wparam != 0);
        },

        c.WM_CLOSE => {
            self.handleClose();
            return 0;
        },

        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = .{};
            const hdc = c.BeginPaint(hwnd, &ps) orelse return 0;
            self.paint(hdc, ps.rcPaint);
            _ = c.EndPaint(hwnd, &ps);
            return 0;
        },

        c.WM_SETCURSOR => if (wparam == @intFromPtr(hwnd) and c.loword(lparam) == c.HTCLIENT) {
            if (self.dividerCursor()) |cursor| {
                _ = c.SetCursor(cursor);
                return 1;
            }
        },

        c.WM_LBUTTONDOWN => if (self.split_view.hit(pointFromLparam(lparam))) |divider| {
            self.drag = divider.handle;
            _ = c.SetCapture(hwnd);
            return 0;
        },

        c.WM_MOUSEMOVE => if (self.drag != null) {
            self.dragTo(pointFromLparam(lparam));
            return 0;
        },

        c.WM_LBUTTONUP => if (self.drag != null) {
            self.dragTo(pointFromLparam(lparam));
            self.cancelDrag();
            return 0;
        },

        c.WM_CAPTURECHANGED => if (lparam != @as(c.LPARAM, @bitCast(@intFromPtr(hwnd)))) {
            self.drag = null;
        },

        c.WM_SETTINGCHANGE => if (lparam != 0) {
            const name: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (std.mem.eql(u16, std.mem.span(name), L("ImmersiveColorSet"))) {
                self.app.systemColorSchemeChanged();
            }
        },

        c.WM_DESTROY => {
            self.destroyTabs();
            return 0;
        },

        c.WM_NCDESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            self.hwnd = null;
            const app = self.app;
            if (self.title_override) |v| app.core_app.alloc.free(v);
            self.tabs.deinit(app.core_app.alloc);
            self.split_view.deinit(app.core_app.alloc);
            app.removeWindow(self);
            app.core_app.alloc.destroy(self);
            log.debug("window destroyed", .{});
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
