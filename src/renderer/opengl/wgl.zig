const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const log = std.log.scoped(.wgl);

pub const HWND = windows.HWND;
pub const HDC = windows.HDC;
pub const HGLRC = windows.HGLRC;
const HINSTANCE = windows.HINSTANCE;
const HMODULE = windows.HMODULE;
const BOOL = windows.BOOL;
const UINT = windows.UINT;
const DWORD = windows.DWORD;
const WORD = windows.WORD;
const BYTE = windows.BYTE;
const ATOM = windows.ATOM;
const LPCWSTR = windows.LPCWSTR;
const WPARAM = usize;
const LPARAM = windows.LPARAM;
const LRESULT = windows.LONG_PTR;
const PROC = *const fn () callconv(.winapi) void;

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?*anyopaque = null,
};

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: WORD = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: WORD = 1,
    dwFlags: DWORD = 0,
    iPixelType: BYTE = 0,
    cColorBits: BYTE = 0,
    cRedBits: BYTE = 0,
    cRedShift: BYTE = 0,
    cGreenBits: BYTE = 0,
    cGreenShift: BYTE = 0,
    cBlueBits: BYTE = 0,
    cBlueShift: BYTE = 0,
    cAlphaBits: BYTE = 0,
    cAlphaShift: BYTE = 0,
    cAccumBits: BYTE = 0,
    cAccumRedBits: BYTE = 0,
    cAccumGreenBits: BYTE = 0,
    cAccumBlueBits: BYTE = 0,
    cAccumAlphaBits: BYTE = 0,
    cDepthBits: BYTE = 0,
    cStencilBits: BYTE = 0,
    cAuxBuffers: BYTE = 0,
    iLayerType: BYTE = 0,
    bReserved: BYTE = 0,
    dwLayerMask: DWORD = 0,
    dwVisibleMask: DWORD = 0,
    dwDamageMask: DWORD = 0,
};

const CS_OWNDC: UINT = 0x0020;
const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const WS_CLIPSIBLINGS: DWORD = 0x04000000;
const WS_CLIPCHILDREN: DWORD = 0x02000000;
const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));

const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
const PFD_TYPE_RGBA: BYTE = 0;
const PFD_MAIN_PLANE: BYTE = 0;

const WGL_DRAW_TO_WINDOW_ARB = 0x2001;
const WGL_SUPPORT_OPENGL_ARB = 0x2010;
const WGL_DOUBLE_BUFFER_ARB = 0x2011;
const WGL_PIXEL_TYPE_ARB = 0x2013;
const WGL_COLOR_BITS_ARB = 0x2014;
const WGL_ALPHA_BITS_ARB = 0x201B;
const WGL_DEPTH_BITS_ARB = 0x2022;
const WGL_STENCIL_BITS_ARB = 0x2023;
const WGL_TYPE_RGBA_ARB = 0x202B;
const WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB = 0x20A9;

const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const WGL_CONTEXT_FLAGS_ARB = 0x2094;
const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const WGL_CONTEXT_DEBUG_BIT_ARB = 0x0001;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;

extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) ?HGLRC;
extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?PROC;
extern "opengl32" fn wglGetCurrentContext() callconv(.winapi) ?HGLRC;

extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: c_int, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn DescribePixelFormat(hdc: HDC, format: c_int, bytes: UINT, ppfd: ?*PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;

extern "user32" fn RegisterClassExW(wc: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn UnregisterClassW(class_name: LPCWSTR, instance: ?HINSTANCE) callconv(.winapi) BOOL;
extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: LPCWSTR,
    window_name: ?LPCWSTR,
    style: DWORD,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    parent: ?HWND,
    menu: ?*anyopaque,
    instance: ?HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hwnd: ?HWND, hdc: HDC) callconv(.winapi) c_int;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;

extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HMODULE;
extern "kernel32" fn LoadLibraryW(name: LPCWSTR) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?PROC;
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual_reset: BOOL, initial_state: BOOL, name: ?LPCWSTR) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) BOOL;

extern "dwmapi" fn DwmFlush() callconv(.winapi) c_long;

const WglGetExtensionsStringARB = *const fn (hdc: HDC) callconv(.winapi) ?[*:0]const u8;
const WglChoosePixelFormatARB = *const fn (
    hdc: HDC,
    int_attribs: ?[*]const c_int,
    float_attribs: ?[*]const f32,
    max_formats: UINT,
    formats: [*]c_int,
    num_formats: *UINT,
) callconv(.winapi) BOOL;
const WglCreateContextAttribsARB = *const fn (
    hdc: HDC,
    share: ?HGLRC,
    attribs: [*]const c_int,
) callconv(.winapi) ?HGLRC;
const WglSwapIntervalEXT = *const fn (interval: c_int) callconv(.winapi) BOOL;

const Extensions = struct {
    choosePixelFormat: WglChoosePixelFormatARB,
    createContextAttribs: WglCreateContextAttribsARB,
    swapInterval: ?WglSwapIntervalEXT,
    srgb: bool,
};

const dummy_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWglDummy");

fn dummyWndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn getProcAddress(name: [*:0]const u8) callconv(.c) ?*const anyopaque {
    if (wglGetProcAddress(name)) |p| {
        switch (@intFromPtr(p)) {
            1, 2, 3, std.math.maxInt(usize) => {},
            else => return @ptrCast(p),
        }
    }
    const module = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll")) orelse
        LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll")) orelse
        return null;
    return @ptrCast(GetProcAddress(module, name));
}

fn hasExtension(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |ext| if (std.mem.eql(u8, ext, name)) return true;
    return false;
}

fn loadExtensions() !Extensions {
    const instance: ?HINSTANCE = @ptrCast(GetModuleHandleW(null));

    const wc: WNDCLASSEXW = .{
        .style = CS_OWNDC,
        .lpfnWndProc = dummyWndProc,
        .hInstance = instance,
        .lpszClassName = dummy_class_name,
    };
    const atom = RegisterClassExW(&wc);
    defer if (atom != 0) {
        _ = UnregisterClassW(dummy_class_name, instance);
    };

    const hwnd = CreateWindowExW(
        0,
        dummy_class_name,
        dummy_class_name,
        WS_OVERLAPPEDWINDOW | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
        0,
        0,
        1,
        1,
        null,
        null,
        instance,
        null,
    ) orelse return error.WglDummyWindowFailed;
    defer _ = DestroyWindow(hwnd);

    const hdc = GetDC(hwnd) orelse return error.WglDummyWindowFailed;
    defer _ = ReleaseDC(hwnd, hdc);

    const pfd: PIXELFORMATDESCRIPTOR = .{
        .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
        .iPixelType = PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cAlphaBits = 8,
        .iLayerType = PFD_MAIN_PLANE,
    };
    const format = ChoosePixelFormat(hdc, &pfd);
    if (format == 0) return error.WglChoosePixelFormatFailed;
    if (!SetPixelFormat(hdc, format, &pfd).toBool()) return error.WglSetPixelFormatFailed;

    const ctx = wglCreateContext(hdc) orelse return error.WglCreateContextFailed;
    defer _ = wglDeleteContext(ctx);
    if (!wglMakeCurrent(hdc, ctx).toBool()) return error.WglMakeCurrentFailed;
    defer _ = wglMakeCurrent(null, null);

    const getExtensionsString: WglGetExtensionsStringARB = @ptrCast(
        wglGetProcAddress("wglGetExtensionsStringARB") orelse
            return error.WglMissingExtension,
    );
    const ext_ptr = getExtensionsString(hdc) orelse return error.WglMissingExtension;
    const exts = std.mem.span(ext_ptr);

    if (!hasExtension(exts, "WGL_ARB_pixel_format") or
        !hasExtension(exts, "WGL_ARB_create_context") or
        !hasExtension(exts, "WGL_ARB_create_context_profile"))
    {
        log.warn("required WGL extensions missing extensions={s}", .{exts});
        return error.WglMissingExtension;
    }

    return .{
        .choosePixelFormat = @ptrCast(wglGetProcAddress("wglChoosePixelFormatARB") orelse
            return error.WglMissingExtension),
        .createContextAttribs = @ptrCast(wglGetProcAddress("wglCreateContextAttribsARB") orelse
            return error.WglMissingExtension),
        .swapInterval = if (hasExtension(exts, "WGL_EXT_swap_control"))
            @ptrCast(wglGetProcAddress("wglSwapIntervalEXT"))
        else
            null,
        .srgb = hasExtension(exts, "WGL_ARB_framebuffer_sRGB") or
            hasExtension(exts, "WGL_EXT_framebuffer_sRGB"),
    };
}

pub const Present = enum { swap_interval, dwm_flush };

fn qpc() i64 {
    var v: i64 = 0;
    _ = QueryPerformanceCounter(&v);
    return v;
}

const FrameStats = struct {
    freq: i64,
    window_start: i64 = 0,
    last: i64 = 0,
    frames: u32 = 0,
    max: i64 = 0,

    fn init() FrameStats {
        var freq: i64 = 0;
        _ = QueryPerformanceFrequency(&freq);
        return .{ .freq = @max(1, freq) };
    }

    fn record(self: *FrameStats, mode: Present) void {
        const now = qpc();
        if (self.last == 0 or now - self.last > self.freq) {
            self.window_start = now;
            self.frames = 0;
            self.max = 0;
            self.last = now;
            return;
        }
        self.max = @max(self.max, now - self.last);
        self.last = now;
        self.frames += 1;
        const elapsed = now - self.window_start;
        if (elapsed < self.freq) return;
        const elapsed_ms: f64 = @as(f64, @floatFromInt(elapsed)) * 1000.0 / @as(f64, @floatFromInt(self.freq));
        log.debug("present mode={t} frames={} avg_ms={d:.2} max_ms={d:.2}", .{
            mode,
            self.frames,
            elapsed_ms / @as(f64, @floatFromInt(self.frames)),
            @as(f64, @floatFromInt(self.max)) * 1000.0 / @as(f64, @floatFromInt(self.freq)),
        });
        self.window_start = now;
        self.frames = 0;
        self.max = 0;
    }
};

pub const Context = struct {
    hwnd: HWND,
    hdc: HDC,
    hglrc: HGLRC,
    present_mode: Present,
    present_event: windows.HANDLE,
    presented_size: std.atomic.Value(u64) = .init(0),
    stats: FrameStats,

    pub fn init(hwnd: HWND, vsync: bool) !Context {
        const ext = try loadExtensions();

        const hdc = GetDC(hwnd) orelse return error.WglGetDCFailed;
        errdefer _ = ReleaseDC(hwnd, hdc);

        const pixel_attribs = [_]c_int{
            WGL_DRAW_TO_WINDOW_ARB,                                1,
            WGL_SUPPORT_OPENGL_ARB,                                1,
            WGL_DOUBLE_BUFFER_ARB,                                 1,
            WGL_PIXEL_TYPE_ARB,                                    WGL_TYPE_RGBA_ARB,
            WGL_COLOR_BITS_ARB,                                    32,
            WGL_ALPHA_BITS_ARB,                                    8,
            WGL_DEPTH_BITS_ARB,                                    0,
            WGL_STENCIL_BITS_ARB,                                  0,
            if (ext.srgb) WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB else 0, 1,
            0,
        };

        var format: c_int = 0;
        var count: UINT = 0;
        if (!ext.choosePixelFormat(hdc, &pixel_attribs, null, 1, @ptrCast(&format), &count).toBool() or
            count == 0)
        {
            return error.WglChoosePixelFormatFailed;
        }

        var pfd: PIXELFORMATDESCRIPTOR = .{};
        _ = DescribePixelFormat(hdc, format, @sizeOf(PIXELFORMATDESCRIPTOR), &pfd);
        if (!SetPixelFormat(hdc, format, &pfd).toBool()) return error.WglSetPixelFormatFailed;

        const flags: c_int = if (builtin.mode == .Debug) WGL_CONTEXT_DEBUG_BIT_ARB else 0;
        const context_attribs = [_]c_int{
            WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
            WGL_CONTEXT_MINOR_VERSION_ARB, 3,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            WGL_CONTEXT_FLAGS_ARB,         flags,
            0,
        };
        const hglrc = ext.createContextAttribs(hdc, null, &context_attribs) orelse
            return error.WglCreateContextFailed;
        errdefer _ = wglDeleteContext(hglrc);

        if (!wglMakeCurrent(hdc, hglrc).toBool()) return error.WglMakeCurrentFailed;
        defer _ = wglMakeCurrent(null, null);

        const mode: Present = mode: {
            const swapInterval = ext.swapInterval orelse break :mode .dwm_flush;
            const interval: c_int = if (vsync) 1 else 0;
            if (!swapInterval(interval).toBool()) {
                log.warn("wglSwapIntervalEXT failed interval={}", .{interval});
                break :mode .dwm_flush;
            }
            break :mode if (vsync) .swap_interval else .dwm_flush;
        };
        log.debug("present policy vsync={} mode={t}", .{ vsync, mode });

        const event = CreateEventW(null, .FALSE, .FALSE, null) orelse return error.WglCreateEventFailed;

        return .{
            .hwnd = hwnd,
            .hdc = hdc,
            .hglrc = hglrc,
            .present_mode = mode,
            .present_event = event,
            .stats = .init(),
        };
    }

    pub fn deinit(self: *Context) void {
        if (wglGetCurrentContext() == self.hglrc) _ = wglMakeCurrent(null, null);
        _ = CloseHandle(self.present_event);
        _ = wglDeleteContext(self.hglrc);
        _ = ReleaseDC(self.hwnd, self.hdc);
        self.* = undefined;
    }

    pub fn makeCurrent(self: *const Context) !void {
        if (!wglMakeCurrent(self.hdc, self.hglrc).toBool()) return error.WglMakeCurrentFailed;
    }

    pub fn releaseCurrent() void {
        _ = wglMakeCurrent(null, null);
    }

    pub fn swapBuffers(self: *Context, width: u32, height: u32) !void {
        if (!SwapBuffers(self.hdc).toBool()) return error.WglSwapBuffersFailed;
        if (self.present_mode == .dwm_flush) _ = DwmFlush();
        self.presented_size.store(packSize(width, height), .release);
        _ = SetEvent(self.present_event);
        self.stats.record(self.present_mode);
    }

    pub fn waitPresented(self: *const Context, width: u32, height: u32, timeout_ms: u32) bool {
        const want = packSize(width, height);
        const freq = self.stats.freq;
        const deadline = qpc() + @divTrunc(freq * timeout_ms, 1000);
        while (self.presented_size.load(.acquire) != want) {
            const left = deadline - qpc();
            if (left <= 0) return false;
            const ms: DWORD = @intCast(@max(1, @divTrunc(left * 1000, freq)));
            _ = WaitForSingleObject(self.present_event, ms);
        }
        return true;
    }
};

fn packSize(width: u32, height: u32) u64 {
    return @as(u64, width) << 32 | height;
}

test "wgl context" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWglTest");
    const instance: ?HINSTANCE = @ptrCast(GetModuleHandleW(null));
    const wc: WNDCLASSEXW = .{
        .style = CS_OWNDC,
        .lpfnWndProc = dummyWndProc,
        .hInstance = instance,
        .lpszClassName = class_name,
    };
    if (RegisterClassExW(&wc) == 0) return error.SkipZigTest;
    defer _ = UnregisterClassW(class_name, instance);

    const hwnd = CreateWindowExW(
        0,
        class_name,
        class_name,
        WS_OVERLAPPEDWINDOW | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        64,
        64,
        null,
        null,
        instance,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = DestroyWindow(hwnd);

    var ctx = Context.init(hwnd, true) catch return error.SkipZigTest;
    defer ctx.deinit();

    try ctx.makeCurrent();
    defer Context.releaseCurrent();

    const GetStringFn = *const fn (name: c_uint) callconv(.winapi) ?[*:0]const u8;
    const getString: GetStringFn = @ptrCast(getProcAddress("glGetString") orelse
        return error.TestUnexpectedResult);
    const GL_VENDOR = 0x1F00;
    const GL_RENDERER = 0x1F01;
    const GL_VERSION = 0x1F02;
    const version = std.mem.span(getString(GL_VERSION) orelse return error.TestUnexpectedResult);
    log.info("vendor={s} renderer={s} version={s}", .{
        getString(GL_VENDOR) orelse "(null)",
        getString(GL_RENDERER) orelse "(null)",
        version,
    });
    try std.testing.expect(std.mem.startsWith(u8, version, "4."));

    try ctx.swapBuffers(64, 64);
    try std.testing.expect(ctx.waitPresented(64, 64, 0));
    try std.testing.expect(!ctx.waitPresented(32, 32, 5));
}
