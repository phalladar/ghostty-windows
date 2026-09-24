const TabBar = @This();

const std = @import("std");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32);

const bar_height = 32;
const max_tab_width = 240;
const min_tab_width = 48;
const tab_padding = 10;
const close_size = 16;
const glyph_size = 8;

hwnd: ?c.HWND = null,
font: ?c.HFONT = null,
hover: ?Hit = null,
tracking: bool = false,
drag: ?Drag = null,
drop_hint: ?usize = null,
overlay: bool = false,

const Drag = struct {
    surface: *Surface,
    origin: usize,
    count: usize,
    start_x: i32,
    start_y: i32,
    grab: i32,
    x: i32,
    moving: bool = false,
    took_focus: bool = false,
    float: ?Float = null,
};

const Float = struct {
    window: *Window,
    offset: c.POINT,
    home: c.RECT,
    target: ?*Window = null,
};

const Hit = union(enum) {
    tab: usize,
    close: usize,
    new,
};

pub const Palette = struct {
    bar: c.COLORREF,
    active: c.COLORREF,
    hover: c.COLORREF,
    text: c.COLORREF,
    text_inactive: c.COLORREF,
    separator: c.COLORREF,

    pub fn init(config: *const configpkg.Config) Palette {
        const bg = config.background;
        const fg = config.foreground;
        const dark = Window.Chrome.isDark(bg);
        const bar = mix(bg, if (dark) .{ .r = 0, .g = 0, .b = 0 } else fg, if (dark) 0.35 else 0.08);
        return .{
            .bar = Window.Chrome.colorRef(bar),
            .active = Window.Chrome.colorRef(bg),
            .hover = mixRef(bar, Window.Chrome.colorRef(bg), 0.5),
            .text = Window.Chrome.colorRef(fg),
            .text_inactive = Window.Chrome.colorRef(mix(fg, bg, 0.35)),
            .separator = Window.Chrome.colorRef(mix(bg, fg, 0.2)),
        };
    }

    fn mix(a: configpkg.Config.Color, b: configpkg.Config.Color, t: f32) configpkg.Config.Color {
        return .{ .r = lerp(a.r, b.r, t), .g = lerp(a.g, b.g, t), .b = lerp(a.b, b.b, t) };
    }

    fn mixRef(a: configpkg.Config.Color, b: c.COLORREF, t: f32) c.COLORREF {
        return Window.Chrome.colorRef(mix(a, .{
            .r = @truncate(b),
            .g = @truncate(b >> 8),
            .b = @truncate(b >> 16),
        }, t));
    }

    fn lerp(a: u8, b: u8, t: f32) u8 {
        const af: f32 = @floatFromInt(a);
        const bf: f32 = @floatFromInt(b);
        return @intFromFloat(@round(af + (bf - af) * t));
    }
};

pub fn create(self: *TabBar, parent: c.HWND, instance: ?c.HINSTANCE) !void {
    _ = c.CreateWindowExW(
        0,
        App.tab_bar_class_name,
        null,
        c.WS_CHILD | c.WS_CLIPSIBLINGS,
        0,
        0,
        0,
        0,
        parent,
        null,
        instance,
        self,
    ) orelse return error.CreateWindowFailed;
    self.updateFont();
}

fn window(self: *TabBar) *Window {
    return @fieldParentPtr("tab_bar", self);
}

pub fn height(self: *const TabBar) i32 {
    const hwnd = self.hwnd orelse return 0;
    return scale(bar_height, c.GetDpiForWindow(hwnd));
}

fn scale(v: i32, dpi: c.UINT) i32 {
    return @intCast(@divTrunc(v * @as(i32, @intCast(dpi)), 96));
}

pub fn invalidate(self: *TabBar) void {
    if (self.hwnd) |hwnd| _ = c.InvalidateRect(hwnd, null, .FALSE);
}

pub fn updateFont(self: *TabBar) void {
    const hwnd = self.hwnd orelse return;
    var ncm: c.NONCLIENTMETRICSW = .{};
    const dpi = c.GetDpiForWindow(hwnd);
    if (!c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi).toBool()) {
        log.warn("unable to read non-client metrics for tab bar font", .{});
        return;
    }
    const font = c.CreateFontIndirectW(&ncm.lfCaptionFont) orelse return;
    if (self.font) |old| _ = c.DeleteObject(old);
    self.font = font;
    self.invalidate();
}

const Layout = struct {
    tab_width: i32,
    count: usize,
    height: i32,
    dpi: c.UINT,

    fn init(bar: *TabBar) ?Layout {
        const hwnd = bar.hwnd orelse return null;
        var rect: c.RECT = .{};
        _ = c.GetClientRect(hwnd, &rect);
        const dpi = c.GetDpiForWindow(hwnd);
        const h = rect.bottom - rect.top;
        const count = bar.window().tabs.items.len;
        const avail = @max(0, rect.right - rect.left - h);
        const n: i32 = @intCast(@max(count, 1));
        const w = std.math.clamp(@divTrunc(avail, n), scale(min_tab_width, dpi), scale(max_tab_width, dpi));
        return .{ .tab_width = w, .count = count, .height = h, .dpi = dpi };
    }

    fn tab(self: Layout, i: usize) c.RECT {
        const left = self.tab_width * @as(i32, @intCast(i));
        return .{ .left = left, .top = 0, .right = left + self.tab_width, .bottom = self.height };
    }

    fn close(self: Layout, i: usize) c.RECT {
        return self.closeIn(self.tab(i));
    }

    fn closeIn(self: Layout, t: c.RECT) c.RECT {
        const size = scale(close_size, self.dpi);
        const right = t.right - scale(tab_padding, self.dpi) + @divTrunc(size - scale(glyph_size, self.dpi), 2);
        const top = @divTrunc(self.height - size, 2);
        return .{ .left = right - size, .top = top, .right = right, .bottom = top + size };
    }

    fn new(self: Layout) c.RECT {
        const left = self.tab_width * @as(i32, @intCast(self.count));
        return .{ .left = left, .top = 0, .right = left + self.height, .bottom = self.height };
    }

    fn hit(self: Layout, x: i32, y: i32) ?Hit {
        if (contains(self.new(), x, y)) return .new;
        for (0..self.count) |i| {
            if (!contains(self.tab(i), x, y)) continue;
            if (contains(self.close(i), x, y)) return .{ .close = i };
            return .{ .tab = i };
        }
        return null;
    }
};

fn contains(r: c.RECT, x: i32, y: i32) bool {
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

fn hitEql(a: ?Hit, b: ?Hit) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.meta.eql(x, y);
}

fn paint(self: *TabBar, hwnd: c.HWND) void {
    var ps: c.PAINTSTRUCT = .{};
    const hdc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);

    var rect: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &rect);
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    if (w <= 0 or h <= 0) return;

    const mem = c.CreateCompatibleDC(hdc) orelse return;
    defer _ = c.DeleteDC(mem);
    const bmp = c.CreateCompatibleBitmap(hdc, w, h) orelse return;
    defer _ = c.DeleteObject(bmp);
    const old_bmp = c.SelectObject(mem, bmp);
    defer if (old_bmp) |o| {
        _ = c.SelectObject(mem, o);
    };
    const old_font = if (self.font) |f| c.SelectObject(mem, f) else null;
    defer if (old_font) |o| {
        _ = c.SelectObject(mem, o);
    };

    self.draw(mem, rect);
    _ = c.BitBlt(hdc, 0, 0, w, h, mem, 0, 0, c.SRCCOPY);
}

fn draw(self: *TabBar, hdc: c.HDC, rect: c.RECT) void {
    const win = self.window();
    const palette: Palette = .init(&win.app.config);
    const layout = Layout.init(self) orelse return;

    fill(hdc, rect, palette.bar);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    const dragged = self.draggedIndex();
    for (0..layout.count) |i| {
        if (dragged) |d| if (d == i) continue;
        self.drawTab(hdc, palette, layout, i, layout.tab(i));
    }

    const new = layout.new();
    const new_hovered = if (self.hover) |hv| hv == .new else false;
    if (new_hovered) fill(hdc, new, palette.hover);
    cross(hdc, new, if (new_hovered) palette.text else palette.text_inactive, scale(10, layout.dpi), true);

    if (self.drop_hint) |i| {
        const x = std.math.clamp(layout.tab_width * @as(i32, @intCast(i)), 1, @max(1, rect.right - 2));
        const half = @max(1, scale(1, layout.dpi));
        const inset = @divTrunc(layout.height, 6);
        fill(hdc, .{ .left = x - half, .top = inset, .right = x + half, .bottom = layout.height - inset }, palette.text);
    }

    if (dragged) |i| {
        const d = self.drag.?;
        const left = dragLeft(layout, d.x - d.grab);
        self.drawTab(hdc, palette, layout, i, .{
            .left = left,
            .top = 0,
            .right = left + layout.tab_width,
            .bottom = layout.height,
        });
    }
}

fn drawTab(self: *TabBar, hdc: c.HDC, palette: Palette, layout: Layout, i: usize, r: c.RECT) void {
    const win = self.window();
    const alloc = win.app.core_app.alloc;
    const active = i == win.active;
    const hovered = if (self.hover) |hv| switch (hv) {
        .tab, .close => |idx| idx == i,
        .new => false,
    } else false;
    if (active) {
        fill(hdc, r, palette.active);
    } else if (hovered) {
        fill(hdc, r, palette.hover);
    }
    if (!active and i + 1 != win.active) {
        const inset = @divTrunc(layout.height, 4);
        line(hdc, palette.separator, 1, r.right - 1, r.top + inset, r.right - 1, r.bottom - inset);
    }

    const close = layout.closeIn(r);
    var text_rect: c.RECT = .{
        .left = r.left + scale(tab_padding, layout.dpi),
        .top = r.top,
        .right = close.left - scale(4, layout.dpi),
        .bottom = r.bottom,
    };
    _ = c.SetTextColor(hdc, if (active) palette.text else palette.text_inactive);
    if (std.unicode.utf8ToUtf16LeAlloc(alloc, win.tabTitle(i))) |wide| {
        defer alloc.free(wide);
        _ = c.DrawTextW(
            hdc,
            wide.ptr,
            @intCast(wide.len),
            &text_rect,
            c.DT_SINGLELINE | c.DT_VCENTER | c.DT_NOPREFIX | c.DT_END_ELLIPSIS,
        );
    } else |_| {}

    if (active or hovered) {
        const close_hovered = if (self.hover) |hv| switch (hv) {
            .close => |idx| idx == i,
            else => false,
        } else false;
        if (close_hovered) fill(hdc, close, palette.separator);
        const color = if (active or close_hovered) palette.text else palette.text_inactive;
        cross(hdc, close, color, scale(glyph_size, layout.dpi), false);
    }
}

fn fill(hdc: c.HDC, rect: c.RECT, color: c.COLORREF) void {
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, &rect, brush);
}

fn line(hdc: c.HDC, color: c.COLORREF, width: c_int, x0: i32, y0: i32, x1: i32, y1: i32) void {
    const pen = c.CreatePen(c.PS_SOLID, width, color) orelse return;
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer if (old) |o| {
        _ = c.SelectObject(hdc, o);
    };
    _ = c.MoveToEx(hdc, x0, y0, null);
    _ = c.LineTo(hdc, x1, y1);
}

fn cross(hdc: c.HDC, r: c.RECT, color: c.COLORREF, size: i32, plus: bool) void {
    const cx = @divTrunc(r.left + r.right, 2);
    const cy = @divTrunc(r.top + r.bottom, 2);
    const half = @divTrunc(size, 2);
    const width: c_int = @max(1, @divTrunc(size, 8));
    if (plus) {
        line(hdc, color, width, cx - half, cy, cx + half + 1, cy);
        line(hdc, color, width, cx, cy - half, cx, cy + half + 1);
    } else {
        line(hdc, color, width, cx - half, cy - half, cx + half + 1, cy + half + 1);
        line(hdc, color, width, cx + half, cy - half, cx - half - 1, cy + half + 1);
    }
}

fn setHover(self: *TabBar, hit: ?Hit) void {
    if (hitEql(self.hover, hit)) return;
    self.hover = hit;
    self.invalidate();
}

fn hitAt(self: *TabBar, lparam: c.LPARAM) ?Hit {
    const layout = Layout.init(self) orelse return null;
    const x: i16 = @bitCast(c.loword(lparam));
    const y: i16 = @bitCast(c.hiword(lparam));
    return layout.hit(x, y);
}

fn xOf(lparam: c.LPARAM) i32 {
    const x: i16 = @bitCast(c.loword(lparam));
    return x;
}

fn yOf(lparam: c.LPARAM) i32 {
    const y: i16 = @bitCast(c.hiword(lparam));
    return y;
}

fn dragLeft(layout: Layout, left: i32) i32 {
    const n: i32 = @intCast(@max(layout.count, 1) - 1);
    return std.math.clamp(left, 0, layout.tab_width * n);
}

fn dragIndex(self: *TabBar, d: Drag) ?usize {
    const win = self.window();
    if (win.tabs.items.len != d.count) return null;
    return win.tabIndex(d.surface);
}

fn draggedIndex(self: *TabBar) ?usize {
    const d = self.drag orelse return null;
    if (!d.moving) return null;
    return self.dragIndex(d);
}

fn beginDrag(self: *TabBar, hwnd: c.HWND, index: usize, x: i32, y: i32) void {
    const win = self.window();
    const layout = Layout.init(self) orelse return;
    if (index >= layout.count) return;
    self.drag = .{
        .surface = win.tabs.items[index].focused,
        .origin = index,
        .count = layout.count,
        .start_x = x,
        .start_y = y,
        .grab = x - layout.tab(index).left,
        .x = x,
    };
    _ = c.SetCapture(hwnd);
}

fn dragTo(self: *TabBar, hwnd: c.HWND, lparam: c.LPARAM) void {
    const d = &(self.drag orelse return);
    const x = xOf(lparam);
    const y = yOf(lparam);
    var pt: c.POINT = .{ .x = x, .y = y };
    _ = c.ClientToScreen(hwnd, &pt);
    if (d.float != null) return self.floatTo(pt);
    const index = self.dragIndex(d.*) orelse return self.endDrag(false);
    const layout = Layout.init(self) orelse return;
    d.x = x;
    if (!d.moving) {
        if (@abs(x - d.start_x) < c.GetSystemMetrics(c.SM_CXDRAG) and
            @abs(y - d.start_y) < c.GetSystemMetrics(c.SM_CYDRAG)) return;
        d.moving = true;
        self.hover = null;
        if (c.GetFocus() != null) {
            _ = c.SetFocus(self.hwnd);
            d.took_focus = true;
        }
    }
    if (self.leftBar(hwnd, pt)) return self.detach(index, pt);
    const left = dragLeft(layout, x - d.grab);
    const w = @max(layout.tab_width, 1);
    const target: usize = @intCast(@divTrunc(left + @divTrunc(w, 2), w));
    if (target != index) {
        const delta = @as(isize, @intCast(target)) - @as(isize, @intCast(index));
        _ = self.window().moveTab(d.surface, delta);
    }
    self.invalidate();
}

fn leftBar(self: *TabBar, hwnd: c.HWND, pt: c.POINT) bool {
    const win_hwnd = self.window().hwnd orelse return false;
    var bar: c.RECT = .{};
    var win: c.RECT = .{};
    _ = c.GetWindowRect(hwnd, &bar);
    _ = c.GetWindowRect(win_hwnd, &win);
    if (pt.x < win.left or pt.x >= win.right) return true;
    const h = bar.bottom - bar.top;
    return pt.y < bar.top - h or pt.y >= bar.bottom + h;
}

fn detach(self: *TabBar, index: usize, pt: c.POINT) void {
    const d = &(self.drag orelse return);
    const win = self.window();
    const win_hwnd = win.hwnd orelse return;
    var home: c.RECT = .{};
    _ = c.GetWindowRect(win_hwnd, &home);
    const float = if (win.tabs.items.len == 1)
        win
    else
        win.detachTab(index, pt, d.grab) orelse return self.endDrag(false);
    const float_hwnd = float.hwnd orelse return self.endDrag(false);
    var rect: c.RECT = .{};
    _ = c.GetWindowRect(float_hwnd, &rect);
    d.float = .{
        .window = float,
        .offset = .{ .x = pt.x - rect.left, .y = pt.y - rect.top },
        .home = home,
    };
    if (d.took_focus) _ = c.SetFocus(self.hwnd);
    self.invalidate();
}

fn alive(app: *App, win: *Window) bool {
    for (app.windows.items) |w| if (w == win) return win.hwnd != null;
    return false;
}

fn floatTo(self: *TabBar, pt: c.POINT) void {
    const d = &(self.drag orelse return);
    const f = &(d.float orelse return);
    const app = self.window().app;
    if (!alive(app, f.window)) return self.endDrag(false);
    const float_hwnd = f.window.hwnd.?;
    _ = c.SetWindowPos(
        float_hwnd,
        null,
        pt.x - f.offset.x,
        pt.y - f.offset.y,
        0,
        0,
        c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_NOREDRAW | c.SWP_NOCOPYBITS | c.SWP_NOSENDCHANGING,
    );
    const target = windowUnder(app, pt, float_hwnd);
    const at = if (target) |t| t.tab_bar.dropIndex(pt) else null;
    const next = if (at != null) target else null;
    if (f.target) |old| if (old != next and alive(app, old)) old.tab_bar.setDropHint(null);
    f.target = next;
    if (next) |t| t.tab_bar.setDropHint(at);
}

fn windowUnder(app: *App, pt: c.POINT, skip: c.HWND) ?*Window {
    var next = c.GetTopWindow(null);
    while (next) |h| : (next = c.GetWindow(h, c.GW_HWNDNEXT)) {
        if (h == skip) continue;
        if (!c.IsWindowVisible(h).toBool() or c.IsIconic(h).toBool()) continue;
        const ex: usize = @bitCast(c.GetWindowLongPtrW(h, c.GWL_EXSTYLE));
        if (ex & c.WS_EX_TRANSPARENT != 0) continue;
        var cloaked: c.DWORD = 0;
        if (c.DwmGetWindowAttribute(h, c.DWMWA_CLOAKED, &cloaked, @sizeOf(c.DWORD)) == 0 and cloaked != 0) continue;
        var r: c.RECT = .{};
        if (!c.GetWindowRect(h, &r).toBool() or !contains(r, pt.x, pt.y)) continue;
        for (app.windows.items) |w| if (w.hwnd == h) return w;
        return null;
    }
    return null;
}

pub fn setDropHint(self: *TabBar, hint: ?usize) void {
    const hwnd = self.hwnd orelse return;
    if (std.meta.eql(self.drop_hint, hint)) return;
    self.drop_hint = hint;
    if (hint != null and !c.IsWindowVisible(hwnd).toBool()) {
        if (self.window().hwnd) |parent| {
            var rect: c.RECT = .{};
            _ = c.GetClientRect(parent, &rect);
            _ = c.SetWindowPos(hwnd, null, 0, 0, rect.right - rect.left, self.height(), c.SWP_SHOWWINDOW | c.SWP_NOACTIVATE);
            self.overlay = true;
        }
    } else if (hint == null and self.overlay) {
        self.overlay = false;
        _ = c.ShowWindow(hwnd, c.SW_HIDE);
    }
    self.invalidate();
}

fn release(self: *TabBar, hwnd: c.HWND, lparam: c.LPARAM) void {
    const d = self.drag orelse return;
    if (d.float != null) return self.endDrag(true);
    if (!d.moving) return self.endDrag(true);
    var pt: c.POINT = .{ .x = xOf(lparam), .y = @as(i16, @bitCast(c.hiword(lparam))) };
    _ = c.ClientToScreen(hwnd, &pt);
    if (!self.outside(hwnd, pt)) return self.endDrag(true);
    const index = self.dragIndex(d) orelse return self.endDrag(false);
    self.endDrag(true);
    self.window().dropTab(index, pt, d.grab);
}

fn outside(self: *TabBar, hwnd: c.HWND, pt: c.POINT) bool {
    const win_hwnd = self.window().hwnd orelse return false;
    var bar: c.RECT = .{};
    var win: c.RECT = .{};
    _ = c.GetWindowRect(hwnd, &bar);
    _ = c.GetWindowRect(win_hwnd, &win);
    if (!contains(win, pt.x, pt.y)) return true;
    const top = if (c.WindowFromPoint(pt)) |h| c.GetAncestor(h, c.GA_ROOT) else null;
    if (top != win_hwnd) return true;
    const margin = 2 * (bar.bottom - bar.top);
    return pt.y < bar.top - margin or pt.y >= bar.bottom + margin;
}

pub fn dropIndex(self: *TabBar, pt: c.POINT) ?usize {
    const win = self.window();
    const win_hwnd = win.hwnd orelse return null;
    const count = win.tabs.items.len;
    if (self.hwnd) |hwnd| if (c.IsWindowVisible(hwnd).toBool()) {
        var r: c.RECT = .{};
        _ = c.GetWindowRect(hwnd, &r);
        const h = r.bottom - r.top;
        if (pt.x < r.left or pt.x >= r.right) return null;
        if (pt.y < r.top - h or pt.y >= r.bottom + @divTrunc(h, 2)) return null;
        const layout = Layout.init(self) orelse return null;
        const w = @max(layout.tab_width, 1);
        const slot: usize = @intCast(@divTrunc(@max(0, pt.x - r.left) + @divTrunc(w, 2), w));
        return @min(slot, count);
    };
    var r: c.RECT = .{};
    _ = c.GetWindowRect(win_hwnd, &r);
    var origin: c.POINT = .{};
    _ = c.ClientToScreen(win_hwnd, &origin);
    if (!contains(r, pt.x, pt.y) or pt.y >= origin.y + self.height()) return null;
    return count;
}

fn endDrag(self: *TabBar, commit: bool) void {
    const d = self.drag orelse return;
    self.drag = null;
    const win = self.window();
    if (d.float == null and !commit) if (self.dragIndex(d)) |i| if (i != d.origin) {
        const delta = @as(isize, @intCast(d.origin)) - @as(isize, @intCast(i));
        _ = win.moveTab(d.surface, delta);
    };
    if (self.hwnd) |hwnd| {
        if (c.GetCapture() == hwnd) _ = c.ReleaseCapture();
        if (c.GetFocus() == hwnd) if (win.activeSurface()) |s| if (s.hwnd) |h| {
            _ = c.SetFocus(h);
        };
    }
    self.invalidate();
    if (d.float) |f| self.endFloat(d, f, commit);
}

fn endFloat(self: *TabBar, d: Drag, f: Float, commit: bool) void {
    const home = self.window();
    const app = home.app;
    var hint: ?usize = null;
    if (f.target) |t| if (alive(app, t)) {
        hint = t.tab_bar.drop_hint;
        t.tab_bar.setDropHint(null);
    };
    if (!alive(app, f.window)) return;
    const float = f.window;
    const float_hwnd = float.hwnd.?;
    const index = float.tabIndex(d.surface) orelse return;
    if (float != home) float.setTransitions(true);

    if (!commit) {
        if (float == home) {
            _ = c.SetWindowPos(float_hwnd, null, f.home.left, f.home.top, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        } else if (alive(app, home)) {
            _ = float.transferTab(index, home, d.origin);
        }
        return;
    }

    if (f.target) |t| if (hint) |at| if (alive(app, t)) {
        const target_hwnd = t.hwnd;
        if (float.transferTab(index, t, at)) {
            if (target_hwnd) |h| _ = c.SetForegroundWindow(h);
            return;
        }
    };
    _ = c.SetForegroundWindow(float_hwnd);
}

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *TabBar = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.hwnd = hwnd;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *TabBar = @ptrFromInt(ptr);

    switch (msg) {
        c.WM_PAINT => {
            self.paint(hwnd);
            return 0;
        },

        c.WM_ERASEBKGND => return 1,

        c.WM_SIZE => {
            self.invalidate();
            return 0;
        },

        c.WM_DPICHANGED_AFTERPARENT => {
            self.updateFont();
            return 0;
        },

        c.WM_MOUSEMOVE => {
            if (self.drag != null) {
                if (wparam & c.MK_LBUTTON != 0) self.dragTo(hwnd, lparam);
                return 0;
            }
            if (!self.tracking) {
                var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = hwnd };
                if (c.TrackMouseEvent(&tme).toBool()) self.tracking = true;
            }
            self.setHover(self.hitAt(lparam));
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.tracking = false;
            self.setHover(null);
            return 0;
        },

        c.WM_LBUTTONDOWN => {
            if (self.drag != null) return 0;
            const hit = self.hitAt(lparam) orelse return 0;
            const win = self.window();
            switch (hit) {
                .tab => |i| {
                    win.selectTab(i);
                    self.beginDrag(hwnd, i, xOf(lparam), yOf(lparam));
                },
                .close => |i| win.closeTabAt(i),
                .new => win.newTab(null),
            }
            return 0;
        },

        c.WM_LBUTTONUP => {
            self.release(hwnd, lparam);
            return 0;
        },

        c.WM_KEYDOWN => {
            if (wparam == c.VK_ESCAPE and self.drag != null) {
                self.endDrag(false);
                return 0;
            }
        },

        c.WM_CAPTURECHANGED => {
            self.endDrag(false);
            return 0;
        },

        c.WM_CANCELMODE => self.endDrag(false),

        c.WM_MBUTTONUP => {
            if (self.drag != null) return 0;
            const hit = self.hitAt(lparam) orelse return 0;
            switch (hit) {
                .tab, .close => |i| self.window().closeTabAt(i),
                .new => {},
            }
            return 0;
        },

        c.WM_NCDESTROY => {
            self.drag = null;
            self.drop_hint = null;
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            if (self.font) |f| _ = c.DeleteObject(f);
            self.font = null;
            self.hwnd = null;
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
