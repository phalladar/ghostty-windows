const std = @import("std");
const apprt = @import("../../apprt.zig");
const c = @import("c.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_taskbar);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const State = struct {
    list: ?*ITaskbarList3 = null,
    list_failed: bool = false,
    icon_added: bool = false,
    balloon_active: bool = false,
    hidden: bool = false,
};

const WM_TRAY_CALLBACK = c.WM_APP + 0x40;
const tray_icon_id: c.UINT = 1;
const balloon_timer_id: c.UINT_PTR = 0x4754;
const balloon_timeout_ms: c.UINT = 10 * std.time.ms_per_s;
const progress_timer_id: c.UINT_PTR = 0x4750;
const progress_timeout_ms: c.UINT = 15 * std.time.ms_per_s;

const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

const CLSID_TaskbarList: GUID = .{
    .data1 = 0x56FDF344,
    .data2 = 0xFD6D,
    .data3 = 0x11d0,
    .data4 = .{ 0x95, 0x8A, 0x00, 0x60, 0x97, 0xC9, 0xA0, 0x90 },
};

const IID_ITaskbarList3: GUID = .{
    .data1 = 0xEA1AFB91,
    .data2 = 0x9E28,
    .data3 = 0x4B86,
    .data4 = .{ 0x90, 0xE9, 0x9E, 0x9F, 0x8A, 0x5E, 0xEF, 0xAF },
};

const CLSCTX_INPROC_SERVER: c.DWORD = 0x1;

const TBPF_NOPROGRESS: c_int = 0x0;
const TBPF_INDETERMINATE: c_int = 0x1;
const TBPF_NORMAL: c_int = 0x2;
const TBPF_ERROR: c_int = 0x4;
const TBPF_PAUSED: c_int = 0x8;

const ITaskbarList3 = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*ITaskbarList3, *const GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *const fn (*ITaskbarList3) callconv(.winapi) u32,
        Release: *const fn (*ITaskbarList3) callconv(.winapi) u32,
        HrInit: *const fn (*ITaskbarList3) callconv(.winapi) c.HRESULT,
        AddTab: *const anyopaque,
        DeleteTab: *const anyopaque,
        ActivateTab: *const anyopaque,
        SetActiveAlt: *const anyopaque,
        MarkFullscreenWindow: *const anyopaque,
        SetProgressValue: *const fn (*ITaskbarList3, c.HWND, u64, u64) callconv(.winapi) c.HRESULT,
        SetProgressState: *const fn (*ITaskbarList3, c.HWND, c_int) callconv(.winapi) c.HRESULT,
    };
};

const NOTIFYICONDATAW = extern struct {
    cbSize: c.DWORD = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?c.HWND = null,
    uID: c.UINT = 0,
    uFlags: c.UINT = 0,
    uCallbackMessage: c.UINT = 0,
    hIcon: ?c.HICON = null,
    szTip: [128]u16 = @splat(0),
    dwState: c.DWORD = 0,
    dwStateMask: c.DWORD = 0,
    szInfo: [256]u16 = @splat(0),
    uVersion: c.UINT = 0,
    szInfoTitle: [64]u16 = @splat(0),
    dwInfoFlags: c.DWORD = 0,
    guidItem: GUID = std.mem.zeroes(GUID),
    hBalloonIcon: ?c.HICON = null,
};

comptime {
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(NOTIFYICONDATAW) == 976);
}

const NIM_ADD: c.DWORD = 0x0;
const NIM_MODIFY: c.DWORD = 0x1;
const NIM_DELETE: c.DWORD = 0x2;
const NIF_MESSAGE: c.UINT = 0x1;
const NIF_ICON: c.UINT = 0x2;
const NIF_TIP: c.UINT = 0x4;
const NIF_INFO: c.UINT = 0x10;
const NIIF_INFO: c.DWORD = 0x1;
const NIIF_USER: c.DWORD = 0x4;
const NIIF_LARGE_ICON: c.DWORD = 0x20;
const NIN_BALLOONTIMEOUT: u16 = 0x404;
const NIN_BALLOONUSERCLICK: u16 = 0x405;

const GWL_EXSTYLE: c_int = -20;
const WS_EX_TOPMOST: usize = 0x8;
const SW_HIDE: c_int = 0;
const HWND_TOPMOST: c.HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const HWND_NOTOPMOST: c.HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
const IDI_APPLICATION = c.makeIntResource(32512);

extern "ole32" fn CoCreateInstance(
    clsid: *const GUID,
    outer: ?*anyopaque,
    context: c.DWORD,
    iid: *const GUID,
    out: *?*anyopaque,
) callconv(.winapi) c.HRESULT;
extern "shell32" fn Shell_NotifyIconW(message: c.DWORD, data: *NOTIFYICONDATAW) callconv(.winapi) c.BOOL;

pub fn deinit(app: *App) void {
    const state = &app.taskbar;
    removeIcon(app);
    if (state.list) |list| _ = list.vtable.Release(list);
    state.list = null;
}

fn taskbarList(app: *App) ?*ITaskbarList3 {
    const state = &app.taskbar;
    if (state.list) |list| return list;
    if (state.list_failed) return null;
    var out: ?*anyopaque = null;
    const hr = CoCreateInstance(
        &CLSID_TaskbarList,
        null,
        CLSCTX_INPROC_SERVER,
        &IID_ITaskbarList3,
        &out,
    );
    const list: *ITaskbarList3 = if (hr >= 0 and out != null) @ptrCast(@alignCast(out.?)) else {
        log.warn("CoCreateInstance(TaskbarList) failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        state.list_failed = true;
        return null;
    };
    const init_hr = list.vtable.HrInit(list);
    if (init_hr < 0) {
        log.warn("ITaskbarList3.HrInit failed hr=0x{x}", .{@as(u32, @bitCast(init_hr))});
        _ = list.vtable.Release(list);
        state.list_failed = true;
        return null;
    }
    state.list = list;
    return list;
}

pub fn setProgress(
    app: *App,
    window: *Window,
    report: apprt.Action.Value(.progress_report),
) void {
    const hwnd = window.hwnd orelse return;
    _ = c.KillTimer(hwnd, progress_timer_id);
    const list = taskbarList(app) orelse return;

    const state: c_int = if (!app.config.@"progress-style") TBPF_NOPROGRESS else switch (report.state) {
        .remove => TBPF_NOPROGRESS,
        .set => if (report.progress == null) TBPF_INDETERMINATE else TBPF_NORMAL,
        .@"error" => TBPF_ERROR,
        .indeterminate => TBPF_INDETERMINATE,
        .pause => TBPF_PAUSED,
    };

    const state_hr = list.vtable.SetProgressState(list, hwnd, state);
    var value_hr: c.HRESULT = 0;
    if (state != TBPF_NOPROGRESS and state != TBPF_INDETERMINATE) {
        if (report.progress) |progress| {
            value_hr = list.vtable.SetProgressValue(list, hwnd, @min(progress, 100), 100);
        }
    }
    log.debug("taskbar progress state={t} progress={?d} tbpf={d} hr=0x{x} value_hr=0x{x}", .{
        report.state,
        report.progress,
        state,
        @as(u32, @bitCast(state_hr)),
        @as(u32, @bitCast(value_hr)),
    });

    if (state != TBPF_NOPROGRESS) {
        _ = c.SetTimer(hwnd, progress_timer_id, progress_timeout_ms, progressTimerProc);
    }
}

fn progressTimerProc(hwnd: c.HWND, _: c.UINT, id: c.UINT_PTR, _: c.DWORD) callconv(.winapi) void {
    _ = c.KillTimer(hwnd, id);
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return;
    const window: *Window = @ptrFromInt(ptr);
    log.debug("taskbar progress timed out", .{});
    setProgress(window.app, window, .{ .state = .remove });
}

pub fn commandFinished(window: *Window, value: apprt.Action.Value(.command_finished)) void {
    const app = window.app;
    const config = &app.config;
    const focused = window.hwnd != null and c.GetForegroundWindow() == window.hwnd;
    switch (config.@"notify-on-command-finish") {
        .never => return,
        .unfocused => if (focused) return,
        .always => {},
    }
    if (value.duration.lte(config.@"notify-on-command-finish-after")) return;

    const action = config.@"notify-on-command-finish-action";
    log.debug("command finished exit_code={?d} bell={} notify={}", .{ value.exit_code, action.bell, action.notify });
    if (action.bell) window.ringBell();
    if (action.notify) {
        const title: []const u8 = if (value.exit_code) |code|
            if (code == 0) "Command Succeeded" else "Command Failed"
        else
            "Command Finished";
        var buf: [256]u8 = undefined;
        const duration = value.duration.round(std.time.ns_per_ms);
        const body = if (value.exit_code) |code|
            std.fmt.bufPrint(&buf, "Command took {f} and exited with code {d}.", .{ duration, code }) catch return
        else
            std.fmt.bufPrint(&buf, "Command took {f}.", .{duration}) catch return;
        notify(app, title, body);
    }
}

pub fn notify(app: *App, title: []const u8, body: []const u8) void {
    if (!app.config.@"desktop-notifications") return;
    if (!ensureIcon(app)) return;
    const hwnd = app.msg_hwnd orelse return;
    var data: NOTIFYICONDATAW = .{
        .hWnd = hwnd,
        .uID = tray_icon_id,
        .uFlags = NIF_INFO,
    };
    copyWide(app, &data.szInfoTitle, title);
    copyWide(app, &data.szInfo, if (body.len == 0) " " else body);
    if (loadIcon(app)) |icon| {
        data.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON;
        data.hBalloonIcon = icon;
    } else {
        data.dwInfoFlags = NIIF_INFO;
    }
    const ok = Shell_NotifyIconW(NIM_MODIFY, &data).toBool();
    log.debug("desktop notification shown={} title={s}", .{ ok, title });
    if (!ok) {
        if (!app.taskbar.hidden) removeIcon(app);
        return;
    }
    app.taskbar.balloon_active = true;
    _ = c.SetTimer(hwnd, balloon_timer_id, balloon_timeout_ms, null);
}

pub fn handleMessage(app: *App, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) bool {
    switch (msg) {
        c.WM_TIMER => {
            if (wparam != balloon_timer_id) return false;
            balloonDone(app);
            return true;
        },
        WM_TRAY_CALLBACK => {
            switch (c.loword(lparam)) {
                NIN_BALLOONTIMEOUT => balloonDone(app),
                NIN_BALLOONUSERCLICK => {
                    balloonDone(app);
                    showWindows(app);
                },
                c.WM_LBUTTONUP => showWindows(app),
                else => {},
            }
            return true;
        },
        else => return false,
    }
}

fn balloonDone(app: *App) void {
    if (app.msg_hwnd) |hwnd| _ = c.KillTimer(hwnd, balloon_timer_id);
    app.taskbar.balloon_active = false;
    if (!app.taskbar.hidden) removeIcon(app);
}

fn loadIcon(app: *App) ?c.HICON {
    return c.LoadIconW(app.instance, c.makeIntResource(1)) orelse
        c.LoadIconW(null, IDI_APPLICATION);
}

fn ensureIcon(app: *App) bool {
    const state = &app.taskbar;
    if (state.icon_added) return true;
    const hwnd = app.msg_hwnd orelse return false;
    var data: NOTIFYICONDATAW = .{
        .hWnd = hwnd,
        .uID = tray_icon_id,
        .uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
        .uCallbackMessage = WM_TRAY_CALLBACK,
        .hIcon = loadIcon(app),
    };
    const tip = L("Ghostty");
    @memcpy(data.szTip[0..tip.len], tip);
    state.icon_added = Shell_NotifyIconW(NIM_ADD, &data).toBool();
    if (!state.icon_added) log.warn("unable to add notification area icon", .{});
    return state.icon_added;
}

fn removeIcon(app: *App) void {
    const state = &app.taskbar;
    if (!state.icon_added) return;
    state.icon_added = false;
    state.balloon_active = false;
    const hwnd = app.msg_hwnd orelse return;
    _ = c.KillTimer(hwnd, balloon_timer_id);
    var data: NOTIFYICONDATAW = .{ .hWnd = hwnd, .uID = tray_icon_id };
    _ = Shell_NotifyIconW(NIM_DELETE, &data);
}

fn copyWide(app: *App, dst: []u16, src: []const u8) void {
    const alloc = app.core_app.alloc;
    const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, src) catch return;
    defer alloc.free(wide);
    var n = @min(wide.len, dst.len - 1);
    if (n > 0 and n < wide.len and std.unicode.utf16IsHighSurrogate(wide[n - 1])) n -= 1;
    @memcpy(dst[0..n], wide[0..n]);
    dst[n] = 0;
}

pub fn toggleVisibility(app: *App) void {
    if (app.taskbar.hidden) return showWindows(app);
    if (app.windows.items.len == 0) return;
    app.taskbar.hidden = true;
    _ = ensureIcon(app);
    for (app.windows.items) |window| {
        if (window.hwnd) |hwnd| _ = c.ShowWindow(hwnd, SW_HIDE);
    }
    log.debug("windows hidden count={d}", .{app.windows.items.len});
}

fn showWindows(app: *App) void {
    const was_hidden = app.taskbar.hidden;
    app.taskbar.hidden = false;
    if (was_hidden) {
        for (app.windows.items) |window| {
            if (window.hwnd) |hwnd| _ = c.ShowWindow(hwnd, c.SW_SHOW);
        }
        if (!app.taskbar.balloon_active) removeIcon(app);
    }
    const target = app.last_active orelse
        if (app.windows.items.len > 0) app.windows.items[0] else return;
    const hwnd = target.hwnd orelse return;
    if (c.IsIconic(hwnd).toBool()) _ = c.ShowWindow(hwnd, c.SW_RESTORE);
    _ = c.SetForegroundWindow(hwnd);
}

pub fn setFloat(window: *Window, mode: apprt.action.FloatWindow) void {
    const hwnd = window.hwnd orelse return;
    const ex: usize = @bitCast(c.GetWindowLongPtrW(hwnd, GWL_EXSTYLE));
    const topmost = ex & WS_EX_TOPMOST != 0;
    const want = switch (mode) {
        .on => true,
        .off => false,
        .toggle => !topmost,
    };
    _ = c.SetWindowPos(
        hwnd,
        if (want) HWND_TOPMOST else HWND_NOTOPMOST,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE,
    );
    log.debug("float window topmost={}", .{want});
}
