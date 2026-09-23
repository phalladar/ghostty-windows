const std = @import("std");
const windows = std.os.windows;

pub const HINSTANCE = windows.HINSTANCE;
pub const HMENU = windows.HMENU;
pub const HWND = windows.HWND;
pub const BOOL = windows.BOOL;
pub const UINT = u32;
pub const DWORD = u32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const LONG_PTR = isize;
pub const UINT_PTR = usize;
pub const ATOM = u16;
pub const LPCWSTR = [*:0]const u16;
pub const LPCWSTR_RES = [*:0]align(1) const u16;
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub const TIMERPROC = *const fn (HWND, UINT, UINT_PTR, DWORD) callconv(.winapi) void;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON = null,
};

pub const POINT = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const RECT = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: UINT = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
    lPrivate: DWORD = 0,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: ?HINSTANCE,
    hMenu: ?HMENU,
    hwndParent: ?HWND,
    cy: c_int,
    cx: c_int,
    y: c_int,
    x: c_int,
    style: i32,
    lpszName: ?LPCWSTR,
    lpszClass: ?LPCWSTR,
    dwExStyle: DWORD,
};

pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_OWNDC: UINT = 0x0020;

pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));

pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
pub const GWLP_USERDATA: c_int = -21;

pub const SW_SHOW: c_int = 5;
pub const SW_SHOWNORMAL: c_int = 1;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;

pub const SIZE_MINIMIZED: WPARAM = 1;

pub const MB_YESNO: UINT = 0x00000004;
pub const MB_ICONWARNING: UINT = 0x00000030;
pub const IDYES: c_int = 6;

pub const IDC_ARROW = makeIntResource(32512);
pub const IDC_IBEAM = makeIntResource(32513);
pub const IDC_WAIT = makeIntResource(32514);
pub const IDC_CROSS = makeIntResource(32515);
pub const IDC_SIZENWSE = makeIntResource(32642);
pub const IDC_SIZENESW = makeIntResource(32643);
pub const IDC_SIZEWE = makeIntResource(32644);
pub const IDC_SIZENS = makeIntResource(32645);
pub const IDC_SIZEALL = makeIntResource(32646);
pub const IDC_NO = makeIntResource(32648);
pub const IDC_HAND = makeIntResource(32649);
pub const IDC_APPSTARTING = makeIntResource(32650);
pub const IDC_HELP = makeIntResource(32651);

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD = 0,
    hwndTrack: ?HWND = null,
    dwHoverTime: DWORD = 0,
};

pub const TME_LEAVE: DWORD = 0x00000002;
pub const HTCLIENT: u16 = 1;
pub const WA_INACTIVE: u16 = 0;
pub const WHEEL_DELTA: f64 = 120.0;
pub const WHEEL_PAGESCROLL: UINT = std.math.maxInt(UINT);
pub const SPI_GETWHEELSCROLLLINES: UINT = 0x0068;
pub const SPI_GETWHEELSCROLLCHARS: UINT = 0x006C;
pub extern "user32" fn SystemParametersInfoW(
    action: UINT,
    param: UINT,
    pv: ?*anyopaque,
    win_ini: UINT,
) callconv(.winapi) BOOL;
pub const XBUTTON1: u16 = 0x0001;
pub const XBUTTON2: u16 = 0x0002;
pub const MK_LBUTTON: WPARAM = 0x0001;
pub const MK_RBUTTON: WPARAM = 0x0002;
pub const MK_SHIFT: WPARAM = 0x0004;
pub const MK_CONTROL: WPARAM = 0x0008;
pub const MK_MBUTTON: WPARAM = 0x0010;
pub const MK_XBUTTON1: WPARAM = 0x0020;
pub const MK_XBUTTON2: WPARAM = 0x0040;

pub fn makeIntResource(id: u16) LPCWSTR_RES {
    return @ptrFromInt(id);
}

pub const WM_CREATE: UINT = 0x0001;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_ENTERSIZEMOVE: UINT = 0x0231;
pub const WM_EXITSIZEMOVE: UINT = 0x0232;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_GETMINMAXINFO: UINT = 0x0024;
pub const WM_NCCREATE: UINT = 0x0081;
pub const WM_NCDESTROY: UINT = 0x0082;
pub const WM_TIMER: UINT = 0x0113;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_DPICHANGED_AFTERPARENT: UINT = 0x02E3;
pub const WM_APP: UINT = 0x8000;
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WM_SHOWWINDOW: UINT = 0x0018;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_LBUTTONDBLCLK: UINT = 0x0203;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_XBUTTONDOWN: UINT = 0x020B;
pub const WM_XBUTTONUP: UINT = 0x020C;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;
pub const WM_CAPTURECHANGED: UINT = 0x0215;
pub const WM_MOUSELEAVE: UINT = 0x02A3;

pub fn loword(v: LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(v)));
}

pub fn hiword(v: LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(v)) >> 16);
}

pub extern "user32" fn RegisterClassExW(wc: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW(class_name: LPCWSTR, instance: ?HINSTANCE) callconv(.winapi) BOOL;
pub extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: LPCWSTR,
    window_name: ?LPCWSTR,
    style: DWORD,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    parent: ?HWND,
    menu: ?HMENU,
    instance: ?HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd: c_int) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT) callconv(.winapi) c_int;
pub extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(hwnd: ?HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(code: c_int) callconv(.winapi) void;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: c_int) callconv(.winapi) LONG_PTR;
pub extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: c_int, value: LONG_PTR) callconv(.winapi) LONG_PTR;
pub extern "user32" fn SetWindowTextW(hwnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn MoveWindow(hwnd: HWND, x: c_int, y: c_int, w: c_int, h: c_int, repaint: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(hwnd: HWND, after: ?HWND, x: c_int, y: c_int, cx: c_int, cy: c_int, flags: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;
pub extern "user32" fn AdjustWindowRectExForDpi(rect: *RECT, style: DWORD, menu: BOOL, ex_style: DWORD, dpi: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(instance: ?HINSTANCE, name: LPCWSTR_RES) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn LoadIconW(instance: ?HINSTANCE, name: LPCWSTR_RES) callconv(.winapi) ?HICON;
pub extern "user32" fn SetTimer(hwnd: ?HWND, id: UINT_PTR, elapse: UINT, func: ?TIMERPROC) callconv(.winapi) UINT_PTR;
pub extern "user32" fn KillTimer(hwnd: ?HWND, id: UINT_PTR) callconv(.winapi) BOOL;
pub extern "user32" fn MessageBoxW(hwnd: ?HWND, text: LPCWSTR, caption: LPCWSTR, flags: UINT) callconv(.winapi) c_int;
pub extern "user32" fn ValidateRect(hwnd: HWND, rect: ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(hwnd: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
pub extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn GetCapture() callconv(.winapi) ?HWND;
pub extern "user32" fn GetSystemMetrics(index: c_int) callconv(.winapi) c_int;
pub const SM_CXDRAG: c_int = 68;
pub const VK_ESCAPE: WPARAM = 0x1B;
pub const WM_CANCELMODE: UINT = 0x001F;
pub extern "user32" fn SetParent(child: HWND, parent: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn WindowFromPoint(pt: POINT) callconv(.winapi) ?HWND;
pub extern "user32" fn GetAncestor(hwnd: HWND, flags: UINT) callconv(.winapi) ?HWND;
pub const GA_ROOT: UINT = 2;
pub extern "user32" fn ClientToScreen(hwnd: HWND, pt: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromPoint(pt: POINT, flags: DWORD) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn TrackMouseEvent(tme: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetCursor(cursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn GetKeyState(vk: c_int) callconv(.winapi) i16;
pub extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;

pub const HRESULT = i32;
pub const COLORREF = DWORD;
pub const HKEY = *opaque {};
pub const HMONITOR = *opaque {};

pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000001)))))));
pub const RRF_RT_REG_DWORD: DWORD = 0x00000010;

pub const WM_SETTINGCHANGE: UINT = 0x001A;

pub const GWL_STYLE: c_int = -16;
pub const WS_POPUP: DWORD = 0x80000000;
pub const SW_MAXIMIZE: c_int = 3;
pub const SW_RESTORE: c_int = 9;
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const SWP_NOOWNERZORDER: UINT = 0x0200;
pub const MONITOR_DEFAULTTONEAREST: DWORD = 0x00000002;

pub const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;
pub const DWMWA_CAPTION_COLOR: DWORD = 35;
pub const DWMWA_TEXT_COLOR: DWORD = 36;
pub const DWMWA_COLOR_DEFAULT: COLORREF = 0xFFFFFFFF;

pub const MB_OK: UINT = 0x00000000;
pub const MB_ICONERROR: UINT = 0x00000010;
pub const FLASHW_TRAY: DWORD = 0x00000002;

pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;
pub const COINIT_DISABLE_OLE1DDE: DWORD = 0x4;

pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: DWORD = 0,
};

pub const WINDOWPLACEMENT = extern struct {
    length: UINT = @sizeOf(WINDOWPLACEMENT),
    flags: UINT = 0,
    showCmd: UINT = 0,
    ptMinPosition: POINT = .{},
    ptMaxPosition: POINT = .{},
    rcNormalPosition: RECT = .{},
};

pub const FLASHWINFO = extern struct {
    cbSize: UINT = @sizeOf(FLASHWINFO),
    hwnd: HWND,
    dwFlags: DWORD,
    uCount: UINT,
    dwTimeout: DWORD = 0,
};

pub extern "user32" fn GetWindowPlacement(hwnd: HWND, wp: *WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPlacement(hwnd: HWND, wp: *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromWindow(hwnd: HWND, flags: DWORD) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(monitor: HMONITOR, info: *MONITORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn IsZoomed(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn MessageBeep(kind: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn FlashWindowEx(info: *const FLASHWINFO) callconv(.winapi) BOOL;
pub extern "dwmapi" fn DwmSetWindowAttribute(hwnd: HWND, attr: DWORD, value: *const anyopaque, size: DWORD) callconv(.winapi) HRESULT;
pub extern "dwmapi" fn DwmFlush() callconv(.winapi) HRESULT;
pub extern "advapi32" fn RegGetValueW(
    key: HKEY,
    sub_key: ?LPCWSTR,
    value: ?LPCWSTR,
    flags: DWORD,
    kind: ?*DWORD,
    data: ?*anyopaque,
    size: ?*DWORD,
) callconv(.winapi) i32;
pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(id: LPCWSTR) callconv(.winapi) HRESULT;

pub const HKL = *opaque {};

pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_SYSCHAR: UINT = 0x0106;

pub const VK_SHIFT: UINT = 0x10;
pub const VK_CONTROL: UINT = 0x11;
pub const VK_MENU: UINT = 0x12;
pub const VK_PAUSE: UINT = 0x13;
pub const VK_CAPITAL: UINT = 0x14;
pub const VK_SNAPSHOT: UINT = 0x2C;
pub const VK_LWIN: UINT = 0x5B;
pub const VK_RWIN: UINT = 0x5C;
pub const VK_NUMLOCK: UINT = 0x90;
pub const VK_LSHIFT: UINT = 0xA0;
pub const VK_RSHIFT: UINT = 0xA1;
pub const VK_LCONTROL: UINT = 0xA2;
pub const VK_RCONTROL: UINT = 0xA3;
pub const VK_LMENU: UINT = 0xA4;
pub const VK_RMENU: UINT = 0xA5;

pub const MAPVK_VK_TO_VSC_EX: UINT = 4;
pub const VK_PROCESSKEY: UINT = 0xE5;
pub const VK_PACKET: UINT = 0xE7;
pub const WM_INPUTLANGCHANGE: UINT = 0x0051;
pub const PM_NOREMOVE: UINT = 0;
pub const GWLP_WNDPROC: c_int = -4;
pub const KLF_NOTELLSHELL: UINT = 0x80;

pub extern "user32" fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT, remove: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageTime() callconv(.winapi) i32;
pub extern "user32" fn GetKeyboardLayoutList(n: c_int, list: ?[*]?HKL) callconv(.winapi) c_int;
pub extern "user32" fn LoadKeyboardLayoutW(id: LPCWSTR, flags: UINT) callconv(.winapi) ?HKL;
pub extern "user32" fn UnloadKeyboardLayout(hkl: HKL) callconv(.winapi) BOOL;

pub extern "user32" fn GetKeyboardState(state: *[256]u8) callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyboardLayout(thread_id: DWORD) callconv(.winapi) ?HKL;
pub extern "user32" fn MapVirtualKeyExW(code: UINT, map_type: UINT, hkl: ?HKL) callconv(.winapi) UINT;
pub extern "user32" fn ToUnicodeEx(
    vk: UINT,
    scancode: UINT,
    state: *const [256]u8,
    buf: [*]u16,
    buf_len: c_int,
    flags: UINT,
    hkl: ?HKL,
) callconv(.winapi) c_int;

pub const HGLOBAL = *opaque {};
pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;

pub extern "user32" fn OpenClipboard(owner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(format: UINT) callconv(.winapi) ?HGLOBAL;
pub extern "user32" fn SetClipboardData(format: UINT, mem: ?HGLOBAL) callconv(.winapi) ?HGLOBAL;
pub extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(mem: HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(mem: HGLOBAL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalSize(mem: HGLOBAL) callconv(.winapi) usize;
pub extern "kernel32" fn GlobalFree(mem: HGLOBAL) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
pub extern "user32" fn EnumClipboardFormats(format: UINT) callconv(.winapi) UINT;

pub const HDC = *opaque {};
pub const HGDIOBJ = *opaque {};
pub const HBITMAP = *opaque {};
pub const HFONT = *opaque {};
pub const HPEN = *opaque {};

pub const SW_HIDE: c_int = 0;
pub const SW_SHOWNA: c_int = 8;
pub const TRANSPARENT: c_int = 1;
pub const SRCCOPY: DWORD = 0x00CC0020;
pub const PS_SOLID: c_int = 0;
pub const DT_CENTER: UINT = 0x00000001;
pub const DT_VCENTER: UINT = 0x00000004;
pub const DT_SINGLELINE: UINT = 0x00000020;
pub const DT_NOPREFIX: UINT = 0x00000800;
pub const DT_END_ELLIPSIS: UINT = 0x00008000;
pub const SPI_GETNONCLIENTMETRICS: UINT = 0x0029;

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC = null,
    fErase: BOOL = .FALSE,
    rcPaint: RECT = .{},
    fRestore: BOOL = .FALSE,
    fIncUpdate: BOOL = .FALSE,
    rgbReserved: [32]u8 = @splat(0),
};

pub const LOGFONTW = extern struct {
    lfHeight: i32 = 0,
    lfWidth: i32 = 0,
    lfEscapement: i32 = 0,
    lfOrientation: i32 = 0,
    lfWeight: i32 = 0,
    lfItalic: u8 = 0,
    lfUnderline: u8 = 0,
    lfStrikeOut: u8 = 0,
    lfCharSet: u8 = 0,
    lfOutPrecision: u8 = 0,
    lfClipPrecision: u8 = 0,
    lfQuality: u8 = 0,
    lfPitchAndFamily: u8 = 0,
    lfFaceName: [32]u16 = @splat(0),
};

pub const NONCLIENTMETRICSW = extern struct {
    cbSize: UINT = @sizeOf(NONCLIENTMETRICSW),
    iBorderWidth: c_int = 0,
    iScrollWidth: c_int = 0,
    iScrollHeight: c_int = 0,
    iCaptionWidth: c_int = 0,
    iCaptionHeight: c_int = 0,
    lfCaptionFont: LOGFONTW = .{},
    iSmCaptionWidth: c_int = 0,
    iSmCaptionHeight: c_int = 0,
    lfSmCaptionFont: LOGFONTW = .{},
    iMenuWidth: c_int = 0,
    iMenuHeight: c_int = 0,
    lfMenuFont: LOGFONTW = .{},
    lfStatusFont: LOGFONTW = .{},
    lfMessageFont: LOGFONTW = .{},
    iPaddedBorderWidth: c_int = 0,
};

pub extern "user32" fn BeginPaint(hwnd: HWND, ps: *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(hwnd: HWND, ps: *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(hwnd: ?HWND, rect: ?*const RECT, erase: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn FillRect(hdc: HDC, rect: *const RECT, brush: HBRUSH) callconv(.winapi) c_int;
pub extern "user32" fn DrawTextW(hdc: HDC, text: [*]const u16, len: c_int, rect: *RECT, format: UINT) callconv(.winapi) c_int;
pub extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SystemParametersInfoForDpi(action: UINT, param: UINT, pv: ?*anyopaque, win_ini: UINT, dpi: UINT) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn CreateCompatibleBitmap(hdc: HDC, w: c_int, h: c_int) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn SelectObject(hdc: HDC, obj: *anyopaque) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn DeleteObject(obj: *anyopaque) callconv(.winapi) BOOL;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn BitBlt(dst: HDC, x: c_int, y: c_int, w: c_int, h: c_int, src: ?HDC, sx: c_int, sy: c_int, rop: DWORD) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.winapi) ?HBRUSH;
pub extern "gdi32" fn CreatePen(style: c_int, width: c_int, color: COLORREF) callconv(.winapi) ?HPEN;
pub extern "gdi32" fn CreateFontIndirectW(lf: *const LOGFONTW) callconv(.winapi) ?HFONT;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: c_int) callconv(.winapi) c_int;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn MoveToEx(hdc: HDC, x: c_int, y: c_int, prev: ?*POINT) callconv(.winapi) BOOL;
pub extern "gdi32" fn LineTo(hdc: HDC, x: c_int, y: c_int) callconv(.winapi) BOOL;

pub const HDWP = *opaque {};
pub const SWP_SHOWWINDOW: UINT = 0x0040;
pub const SWP_HIDEWINDOW: UINT = 0x0080;
pub extern "user32" fn BeginDeferWindowPos(count: c_int) callconv(.winapi) ?HDWP;
pub extern "user32" fn DeferWindowPos(hdwp: HDWP, hwnd: HWND, after: ?HWND, x: c_int, y: c_int, cx: c_int, cy: c_int, flags: UINT) callconv(.winapi) ?HDWP;
pub extern "user32" fn EndDeferWindowPos(hdwp: HDWP) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(pt: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(hwnd: HWND, pt: *POINT) callconv(.winapi) BOOL;
