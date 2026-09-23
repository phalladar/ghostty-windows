const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = @import("c.zig");

const log = std.log.scoped(.win32_ime);

pub const HIMC = *opaque {};

pub const WM_IME_STARTCOMPOSITION: c.UINT = 0x010D;
pub const WM_IME_ENDCOMPOSITION: c.UINT = 0x010E;
pub const WM_IME_COMPOSITION: c.UINT = 0x010F;
pub const WM_IME_SETCONTEXT: c.UINT = 0x0281;
pub const WM_IME_NOTIFY: c.UINT = 0x0282;
pub const WM_IME_CHAR: c.UINT = 0x0286;

pub const GCS_COMPSTR: c.DWORD = 0x0008;
pub const GCS_RESULTSTR: c.DWORD = 0x0800;
pub const CFS_POINT: c.DWORD = 0x0002;
pub const CFS_CANDIDATEPOS: c.DWORD = 0x0040;
pub const CFS_EXCLUDE: c.DWORD = 0x0080;
pub const ISC_SHOWUICOMPOSITIONWINDOW: c.LPARAM = 0x80000000;
pub const IMN_CHANGECANDIDATE: c.WPARAM = 0x0003;
pub const IMN_OPENCANDIDATE: c.WPARAM = 0x0005;
const LANG_CHINESE: usize = 0x04;

pub const COMPOSITIONFORM = extern struct {
    dwStyle: c.DWORD = 0,
    ptCurrentPos: c.POINT = .{},
    rcArea: c.RECT = .{},
};

pub const CANDIDATEFORM = extern struct {
    dwIndex: c.DWORD = 0,
    dwStyle: c.DWORD = 0,
    ptCurrentPos: c.POINT = .{},
    rcArea: c.RECT = .{},
};

pub extern "imm32" fn ImmGetContext(hwnd: c.HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(hwnd: c.HWND, himc: HIMC) callconv(.winapi) c.BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(himc: HIMC, index: c.DWORD, buf: ?*anyopaque, len: c.DWORD) callconv(.winapi) i32;
pub extern "imm32" fn ImmSetCompositionWindow(himc: HIMC, form: *const COMPOSITIONFORM) callconv(.winapi) c.BOOL;
pub extern "imm32" fn ImmGetCompositionWindow(himc: HIMC, form: *COMPOSITIONFORM) callconv(.winapi) c.BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(himc: HIMC, form: *const CANDIDATEFORM) callconv(.winapi) c.BOOL;
pub extern "imm32" fn ImmGetCandidateWindow(himc: HIMC, index: c.DWORD, form: *CANDIDATEFORM) callconv(.winapi) c.BOOL;
pub extern "imm32" fn ImmGetVirtualKey(hwnd: c.HWND) callconv(.winapi) c.UINT;

pub const Caret = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Forms = struct {
    composition: COMPOSITIONFORM,
    candidate_pos: CANDIDATEFORM,
    candidate_exclude: CANDIDATEFORM,
};

pub fn forms(caret: Caret) Forms {
    const pt: c.POINT = .{ .x = caret.x, .y = caret.y };
    const rect: c.RECT = .{
        .left = caret.x,
        .top = caret.y,
        .right = caret.x + @max(1, caret.width),
        .bottom = caret.y + caret.height,
    };
    return .{
        .composition = .{ .dwStyle = CFS_POINT, .ptCurrentPos = pt },
        .candidate_pos = .{
            .dwStyle = CFS_CANDIDATEPOS,
            .ptCurrentPos = .{ .x = caret.x, .y = rect.bottom },
        },
        .candidate_exclude = .{ .dwStyle = CFS_EXCLUDE, .ptCurrentPos = pt, .rcArea = rect },
    };
}

pub fn place(hwnd: c.HWND, caret: Caret) void {
    const himc = ImmGetContext(hwnd) orelse return;
    defer _ = ImmReleaseContext(hwnd, himc);
    const f = forms(caret);
    _ = ImmSetCompositionWindow(himc, &f.composition);
    const lang = @intFromPtr(c.GetKeyboardLayout(0)) & 0x3FF;
    if (lang == LANG_CHINESE) _ = ImmSetCandidateWindow(himc, &f.candidate_pos);
    _ = ImmSetCandidateWindow(himc, &f.candidate_exclude);
}

pub const Dedup = struct {
    buf: [64]u16 = undefined,
    len: u8 = 0,
    pos: u8 = 0,
    time: i32 = 0,

    const window_ms = 1000;

    pub fn record(self: *Dedup, units: []const u16, time: i32) void {
        const n: u8 = @intCast(@min(units.len, self.buf.len));
        @memcpy(self.buf[0..n], units[0..n]);
        self.len = n;
        self.pos = 0;
        self.time = time;
    }

    pub fn reset(self: *Dedup) void {
        self.len = 0;
        self.pos = 0;
    }

    pub fn skip(self: *Dedup, unit: u16, time: i32) bool {
        if (self.pos >= self.len) return false;
        const age = @as(u32, @bitCast(time)) -% @as(u32, @bitCast(self.time));
        if (age > window_ms or self.buf[self.pos] != unit) {
            self.reset();
            return false;
        }
        self.pos += 1;
        return true;
    }
};

pub const State = struct {
    composing: bool = false,
    eaten: std.StaticBitSet(256) = .initEmpty(),
    dedup: Dedup = .{},

    pub fn onKey(self: *State, hwnd: c.HWND, msg: c.UINT, vk: c.UINT) bool {
        const down = msg == c.WM_KEYDOWN or msg == c.WM_SYSKEYDOWN;
        if (vk == c.VK_PROCESSKEY) {
            if (down) {
                const real = ImmGetVirtualKey(hwnd);
                if (real != c.VK_PROCESSKEY and real < 256) self.eaten.set(real);
            }
            return true;
        }
        if (vk < 256 and !down and self.eaten.isSet(vk)) {
            self.eaten.unset(vk);
            return true;
        }
        if (!down) return self.composing;
        self.dedup.reset();
        if (self.composing and !hasComposition(hwnd)) self.composing = false;
        return self.composing;
    }

    pub fn handle(
        self: *State,
        sink: anytype,
        alloc: Allocator,
        hwnd: c.HWND,
        msg: c.UINT,
        wparam: c.WPARAM,
        lparam: c.LPARAM,
    ) ?c.LRESULT {
        switch (msg) {
            WM_IME_SETCONTEXT => {
                const lp = if (wparam != 0) lparam & ~ISC_SHOWUICOMPOSITIONWINDOW else lparam;
                return c.DefWindowProcW(hwnd, msg, wparam, lp);
            },
            WM_IME_STARTCOMPOSITION => {
                self.composing = true;
                if (sink.imeCaret()) |caret| place(hwnd, caret);
                return 0;
            },
            WM_IME_COMPOSITION => {
                self.composition(sink, alloc, hwnd, lparam);
                if (sink.imeCaret()) |caret| place(hwnd, caret);
                return 0;
            },
            WM_IME_ENDCOMPOSITION => {
                self.composing = false;
                sink.imePreedit(null);
                return 0;
            },
            WM_IME_NOTIFY => {
                if (wparam == IMN_OPENCANDIDATE or wparam == IMN_CHANGECANDIDATE) {
                    if (sink.imeCaret()) |caret| place(hwnd, caret);
                }
                return null;
            },
            WM_IME_CHAR => {
                if (self.dedup.skip(@truncate(wparam), c.GetMessageTime())) return 0;
                return null;
            },
            else => return null,
        }
    }

    fn composition(self: *State, sink: anytype, alloc: Allocator, hwnd: c.HWND, lparam: c.LPARAM) void {
        const flags: c.DWORD = @truncate(@as(usize, @bitCast(lparam)));
        const himc = ImmGetContext(hwnd) orelse {
            sink.imePreedit(null);
            return;
        };
        defer _ = ImmReleaseContext(hwnd, himc);

        if (flags & GCS_RESULTSTR != 0) {
            if (readString(alloc, himc, GCS_RESULTSTR)) |units| {
                defer alloc.free(units);
                self.dedup.record(units, c.GetMessageTime());
                sink.imePreedit(null);
                if (std.unicode.utf16LeToUtf8Alloc(alloc, units)) |utf8| {
                    defer alloc.free(utf8);
                    sink.imeCommit(utf8);
                } else |err| log.warn("invalid IME result string err={}", .{err});
            }
        }

        if (flags & GCS_COMPSTR != 0) {
            const units = readString(alloc, himc, GCS_COMPSTR) orelse {
                sink.imePreedit(null);
                return;
            };
            defer alloc.free(units);
            self.composing = true;
            const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, units) catch |err| {
                log.warn("invalid IME composition string err={}", .{err});
                return;
            };
            defer alloc.free(utf8);
            sink.imePreedit(utf8);
        } else if (flags & GCS_RESULTSTR == 0) {
            sink.imePreedit(null);
        }
    }
};

fn hasComposition(hwnd: c.HWND) bool {
    const himc = ImmGetContext(hwnd) orelse return false;
    defer _ = ImmReleaseContext(hwnd, himc);
    return ImmGetCompositionStringW(himc, GCS_COMPSTR, null, 0) > 0;
}

fn readString(alloc: Allocator, himc: HIMC, index: c.DWORD) ?[]u16 {
    const bytes = ImmGetCompositionStringW(himc, index, null, 0);
    if (bytes <= 0) return null;
    const units = alloc.alloc(u16, @intCast(@divTrunc(bytes, 2))) catch return null;
    const got = ImmGetCompositionStringW(himc, index, units.ptr, @intCast(units.len * 2));
    if (got <= 0) {
        alloc.free(units);
        return null;
    }
    const n: usize = @intCast(@divTrunc(got, 2));
    if (n == units.len) return units;
    return alloc.realloc(units, n) catch units[0..n];
}

test "caret forms" {
    const testing = std.testing;
    const f = forms(.{ .x = 40, .y = 100, .width = 0, .height = 20 });
    try testing.expectEqual(CFS_POINT, f.composition.dwStyle);
    try testing.expectEqual(@as(i32, 40), f.composition.ptCurrentPos.x);
    try testing.expectEqual(@as(i32, 100), f.composition.ptCurrentPos.y);
    try testing.expectEqual(CFS_EXCLUDE, f.candidate_exclude.dwStyle);
    try testing.expectEqual(@as(i32, 41), f.candidate_exclude.rcArea.right);
    try testing.expectEqual(@as(i32, 120), f.candidate_exclude.rcArea.bottom);
    try testing.expectEqual(@as(i32, 120), f.candidate_pos.ptCurrentPos.y);
}

test "dedup drops WM_CHAR echoing the IME result" {
    const testing = std.testing;
    var d: Dedup = .{};
    const units = [_]u16{ 0x65E5, 0x672C, 0xD83D, 0xDE00 };
    d.record(&units, 1000);
    try testing.expect(d.skip(0x65E5, 1000));
    try testing.expect(d.skip(0x672C, 1001));
    try testing.expect(d.skip(0xD83D, 1001));
    try testing.expect(d.skip(0xDE00, 1001));
    try testing.expect(!d.skip(0x65E5, 1001));

    d.record(&units, 1000);
    try testing.expect(!d.skip('a', 1000));
    try testing.expect(!d.skip(0x65E5, 1000));

    d.record(&units, 1000);
    try testing.expect(!d.skip(0x65E5, 5000));

    d.record(&units, -10);
    try testing.expect(d.skip(0x65E5, 10));

    d.record(&units, 1000);
    d.reset();
    try testing.expect(!d.skip(0x65E5, 1000));
}

const TestSink = struct {
    alloc: Allocator,
    events: std.ArrayList([]u8) = .empty,
    caret: ?Caret = null,

    fn deinit(self: *TestSink) void {
        self.clear();
        self.events.deinit(self.alloc);
    }

    fn clear(self: *TestSink) void {
        for (self.events.items) |e| self.alloc.free(e);
        self.events.clearRetainingCapacity();
    }

    fn push(self: *TestSink, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        self.events.append(self.alloc, s) catch self.alloc.free(s);
    }

    fn expect(self: *TestSink, expected: []const []const u8) !void {
        try std.testing.expectEqual(expected.len, self.events.items.len);
        for (expected, self.events.items) |e, a| try std.testing.expectEqualStrings(e, a);
        self.clear();
    }

    pub fn imePreedit(self: *TestSink, text: ?[]const u8) void {
        if (text) |t| self.push("preedit:{s}", .{t}) else self.push("preedit:null", .{});
    }

    pub fn imeCommit(self: *TestSink, text: []const u8) void {
        self.push("commit:{s}", .{text});
    }

    pub fn imeCaret(self: *TestSink) ?Caret {
        return self.caret;
    }
};

const TestImc = struct {
    const HIMCC = *opaque {};
    extern "imm32" fn ImmLockIMC(himc: HIMC) callconv(.winapi) ?[*]u8;
    extern "imm32" fn ImmUnlockIMC(himc: HIMC) callconv(.winapi) c.BOOL;
    extern "imm32" fn ImmLockIMCC(h: HIMCC) callconv(.winapi) ?[*]u8;
    extern "imm32" fn ImmUnlockIMCC(h: HIMCC) callconv(.winapi) c.BOOL;
    extern "imm32" fn ImmReSizeIMCC(h: HIMCC, size: c.DWORD) callconv(.winapi) ?HIMCC;
    extern "imm32" fn ImmCreateIMCC(size: c.DWORD) callconv(.winapi) ?HIMCC;

    const hcompstr_offset = 288;
    const header = 100;

    fn set(himc: HIMC, comp: []const u16, result: []const u16) !void {
        const ic = ImmLockIMC(himc) orelse return error.SkipZigTest;
        defer _ = ImmUnlockIMC(himc);
        const slot: *align(1) ?HIMCC = @ptrCast(ic + hcompstr_offset);
        const size: c.DWORD = @intCast(header + (comp.len + result.len) * 2);
        const h = (if (slot.*) |old| ImmReSizeIMCC(old, size) else ImmCreateIMCC(size)) orelse
            return error.SkipZigTest;
        slot.* = h;
        const p = ImmLockIMCC(h) orelse return error.SkipZigTest;
        defer _ = ImmUnlockIMCC(h);
        @memset(p[0..size], 0);
        const d: [*]align(1) u32 = @ptrCast(p);
        d[0] = size;
        d[11] = @intCast(comp.len);
        d[12] = header;
        d[21] = @intCast(result.len);
        d[22] = @intCast(header + comp.len * 2);
        @memcpy(@as([*]align(1) u16, @ptrCast(p + header))[0..comp.len], comp);
        @memcpy(@as([*]align(1) u16, @ptrCast(p + header + comp.len * 2))[0..result.len], result);
    }
};

test "IMM messages on a real window" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    const class = L("GhosttyImeTest");
    const instance = c.GetModuleHandleW(null);
    const wc: c.WNDCLASSEXW = .{
        .lpfnWndProc = &c.DefWindowProcW,
        .hInstance = instance,
        .lpszClassName = class,
    };
    _ = c.RegisterClassExW(&wc);
    defer _ = c.UnregisterClassW(class, instance);
    const hwnd = c.CreateWindowExW(0, class, null, c.WS_POPUP, 0, 0, 200, 100, null, null, instance, null) orelse
        return error.SkipZigTest;
    defer _ = c.DestroyWindow(hwnd);
    const himc = ImmGetContext(hwnd) orelse return error.SkipZigTest;
    defer _ = ImmReleaseContext(hwnd, himc);

    var sink: TestSink = .{ .alloc = alloc, .caret = .{ .x = 37, .y = 54, .width = 0, .height = 18 } };
    defer sink.deinit();
    var state: State = .{};

    try testing.expectEqual(@as(?c.LRESULT, 0), state.handle(&sink, alloc, hwnd, WM_IME_STARTCOMPOSITION, 0, 0));
    try testing.expect(state.composing);
    try sink.expect(&.{});

    var comp: COMPOSITIONFORM = .{};
    try testing.expect(ImmGetCompositionWindow(himc, &comp).toBool());
    try testing.expectEqual(CFS_POINT, comp.dwStyle);
    try testing.expectEqual(@as(i32, 37), comp.ptCurrentPos.x);
    try testing.expectEqual(@as(i32, 54), comp.ptCurrentPos.y);
    var cand: CANDIDATEFORM = .{};
    try testing.expect(ImmGetCandidateWindow(himc, 0, &cand).toBool());
    try testing.expectEqual(CFS_EXCLUDE, cand.dwStyle);
    try testing.expectEqual(c.RECT{ .left = 37, .top = 54, .right = 38, .bottom = 72 }, cand.rcArea);

    try TestImc.set(himc, L("にほんご"), &.{});
    _ = state.handle(&sink, alloc, hwnd, WM_IME_COMPOSITION, 0, GCS_COMPSTR);
    try sink.expect(&.{"preedit:にほんご"});

    try TestImc.set(himc, &.{}, L("日本語"));
    _ = state.handle(&sink, alloc, hwnd, WM_IME_COMPOSITION, 0, GCS_RESULTSTR);
    try sink.expect(&.{ "preedit:null", "commit:日本語" });
    const t = c.GetMessageTime();
    try testing.expect(state.dedup.skip(0x65E5, t));
    try testing.expectEqual(@as(?c.LRESULT, 0), state.handle(&sink, alloc, hwnd, WM_IME_CHAR, 0x672C, 0));
    try testing.expect(state.dedup.skip(0x8A9E, t));
    try testing.expect(!state.dedup.skip(0x8A9E, t));

    _ = state.handle(&sink, alloc, hwnd, WM_IME_ENDCOMPOSITION, 0, 0);
    try testing.expect(!state.composing);
    try sink.expect(&.{"preedit:null"});

    _ = state.handle(&sink, alloc, hwnd, WM_IME_STARTCOMPOSITION, 0, 0);
    try TestImc.set(himc, L("안"), L("한"));
    _ = state.handle(&sink, alloc, hwnd, WM_IME_COMPOSITION, 0, GCS_RESULTSTR | GCS_COMPSTR);
    try sink.expect(&.{ "preedit:null", "commit:한", "preedit:안" });
    try testing.expect(state.composing);

    try TestImc.set(himc, &.{}, &.{});
    _ = state.handle(&sink, alloc, hwnd, WM_IME_COMPOSITION, 0, 0);
    try sink.expect(&.{"preedit:null"});
    try testing.expect(!state.onKey(hwnd, c.WM_KEYDOWN, 'A'));
    try testing.expect(!state.composing);

    try TestImc.set(himc, &.{}, L("\u{1F1EF}\u{1F1F5}"));
    _ = state.handle(&sink, alloc, hwnd, WM_IME_COMPOSITION, 0, GCS_RESULTSTR);
    try sink.expect(&.{ "preedit:null", "commit:\u{1F1EF}\u{1F1F5}" });
    try testing.expectEqual(@as(?c.LRESULT, null), state.handle(&sink, alloc, hwnd, WM_IME_CHAR, 'x', 0));

    try testing.expect(state.handle(&sink, alloc, hwnd, WM_IME_NOTIFY, IMN_OPENCANDIDATE, 0) == null);
    try testing.expect(state.handle(&sink, alloc, hwnd, c.WM_SIZE, 0, 0) == null);
    try TestImc.set(himc, &.{}, &.{});
}
