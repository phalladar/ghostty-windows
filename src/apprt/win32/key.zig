const std = @import("std");
const builtin = @import("builtin");
const input = @import("../../input.zig");
const c = @import("c.zig");

pub fn translate(
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
    hkl: ?c.HKL,
    buf: []u8,
) ?input.KeyEvent {
    const lp: usize = @bitCast(lparam);
    const action = actionFor(msg, lp) orelse return null;

    var keystate: [256]u8 = undefined;
    if (!c.GetKeyboardState(&keystate).toBool()) keystate = @splat(0);
    return translateState(action, wparam, lp, hkl, &keystate, buf);
}

fn actionFor(msg: c.UINT, lp: usize) ?input.Action {
    return switch (msg) {
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => if (lp & (1 << 30) != 0) .repeat else .press,
        c.WM_KEYUP, c.WM_SYSKEYUP => .release,
        else => null,
    };
}

pub fn translateState(
    action: input.Action,
    wparam: c.WPARAM,
    lp: usize,
    hkl: ?c.HKL,
    keystate: *const [256]u8,
    buf: []u8,
) input.KeyEvent {
    const vk: c.UINT = @truncate(wparam);
    const native = nativeScancode(vk, lp, hkl);
    const physical_key = keyFromNative(native);
    var mods = modsFromState(keystate);

    const altgr = mods.ctrl and mods.alt and
        keystate[c.VK_RMENU] & 0x80 != 0 and
        hasAltGr(hkl);
    if (altgr) {
        mods.ctrl = false;
        mods.alt = false;
        mods.sides.ctrl = .left;
        mods.sides.alt = .left;
    }

    var event: input.KeyEvent = .{
        .action = action,
        .key = physical_key,
        .mods = mods,
    };

    if (action == .release) {
        event.unshifted_codepoint = unshiftedCodepoint(vk, hkl);
        return event;
    }

    var text_state = keystate.*;
    if (!altgr) clearCtrl(&text_state);

    var wbuf: [8]u16 = undefined;
    const n = c.ToUnicodeEx(vk, native & 0xFF, &text_state, &wbuf, wbuf.len, 0, hkl);
    event.unshifted_codepoint = unshiftedCodepoint(vk, hkl);
    if (n < 0) {
        event.composing = true;
        event.utf8 = buf[0..utf16ToUtf8(wbuf[0..1], buf)];
        return event;
    }

    const len = utf16ToUtf8(wbuf[0..@intCast(n)], buf);
    if (len == 0) return event;
    event.utf8 = buf[0..len];

    if (mods.shift) {
        var unshifted_state = text_state;
        unshifted_state[c.VK_SHIFT] = 0;
        unshifted_state[c.VK_LSHIFT] = 0;
        unshifted_state[c.VK_RSHIFT] = 0;
        var ubuf: [8]u16 = undefined;
        const un = c.ToUnicodeEx(vk, native & 0xFF, &unshifted_state, &ubuf, ubuf.len, 0x4, hkl);
        if (un != n or (n > 0 and !std.mem.eql(u16, ubuf[0..@intCast(n)], wbuf[0..@intCast(n)]))) {
            event.consumed_mods.shift = true;
        }
    }

    return event;
}

threadlocal var altgr_cache: struct {
    hkl: ?c.HKL = null,
    value: bool = false,
} = .{};

pub fn hasAltGr(hkl: ?c.HKL) bool {
    if (hkl != null and altgr_cache.hkl == hkl) return altgr_cache.value;

    var state: [256]u8 = @splat(0);
    state[c.VK_CONTROL] = 0x80;
    state[c.VK_LCONTROL] = 0x80;
    state[c.VK_MENU] = 0x80;
    state[c.VK_RMENU] = 0x80;

    const value = for (0x30..0xE3) |vk| {
        if (vk > 0x5A and vk < 0xBA) continue;
        var wbuf: [8]u16 = undefined;
        const n = c.ToUnicodeEx(@intCast(vk), 0, &state, &wbuf, wbuf.len, 0x4, hkl);
        if (n < 0) break true;
        if (n > 0 and wbuf[0] >= 0x20 and wbuf[0] != 0x7F) break true;
    } else false;

    altgr_cache = .{ .hkl = hkl, .value = value };
    return value;
}

pub fn isSyntheticAltGrCtrl(vk: c.UINT, lparam: c.LPARAM) bool {
    const lp: usize = @bitCast(lparam);
    if (vk != c.VK_CONTROL or lp & (1 << 24) != 0) return false;

    var next: c.MSG = .{};
    if (!c.PeekMessageW(&next, null, c.WM_KEYDOWN, c.WM_SYSKEYUP, c.PM_NOREMOVE).toBool()) return false;
    switch (next.message) {
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN, c.WM_KEYUP, c.WM_SYSKEYUP => {},
        else => return false,
    }
    const next_lp: usize = @bitCast(next.lParam);
    return next.wParam == c.VK_MENU and
        next_lp & (1 << 24) != 0 and
        next.time == @as(c.DWORD, @bitCast(c.GetMessageTime()));
}

pub const CharDecoder = struct {
    high: u16 = 0,

    pub fn push(self: *CharDecoder, unit: u16) ?u21 {
        switch (unit) {
            0xD800...0xDBFF => {
                self.high = unit;
                return null;
            },
            0xDC00...0xDFFF => {
                const high = self.high;
                self.high = 0;
                if (high == 0) return null;
                return std.unicode.utf16DecodeSurrogatePair(&.{ high, unit }) catch null;
            },
            0 => return null,
            else => {
                self.high = 0;
                return unit;
            },
        }
    }
};

pub fn charEvent(cp: u21, buf: []u8) ?input.KeyEvent {
    const control_key: ?input.Key = switch (cp) {
        0x08 => .backspace,
        0x09 => .tab,
        0x0D => .enter,
        0x1B => .escape,
        else => null,
    };
    if (control_key) |k| return .{ .action = .press, .key = k };
    if (cp < 0x20 or cp == 0x7F) return null;

    const len = std.unicode.utf8Encode(cp, buf) catch return null;
    return .{
        .action = .press,
        .key = .unidentified,
        .utf8 = buf[0..len],
        .unshifted_codepoint = cp,
    };
}

fn nativeScancode(vk: c.UINT, lp: usize, hkl: ?c.HKL) u32 {
    switch (vk) {
        c.VK_PAUSE => return 0x0045,
        c.VK_NUMLOCK => return 0xE045,
        c.VK_SNAPSHOT => return 0xE037,
        else => {},
    }

    const sc: u32 = @truncate((lp >> 16) & 0xFF);
    if (sc == 0) return c.MapVirtualKeyExW(vk, c.MAPVK_VK_TO_VSC_EX, hkl);
    return sc | (if (lp & (1 << 24) != 0) @as(u32, 0xE000) else 0);
}

pub fn keyFromNative(native: u32) input.Key {
    if (native == 0) return .unidentified;
    for (input.keycodes.entries) |entry| {
        if (entry.native == native and entry.key != .unidentified) return entry.key;
    }
    return switch (native) {
        0x56 => .intl_backslash,
        0x73 => .intl_ro,
        0x7D => .intl_yen,
        else => .unidentified,
    };
}

fn modsFromState(state: *const [256]u8) input.Mods {
    const down = struct {
        fn f(s: *const [256]u8, vk: usize) bool {
            return s[vk] & 0x80 != 0;
        }
    }.f;

    var mods: input.Mods = .{
        .shift = down(state, c.VK_SHIFT),
        .ctrl = down(state, c.VK_CONTROL),
        .alt = down(state, c.VK_MENU),
        .super = down(state, c.VK_LWIN) or down(state, c.VK_RWIN),
        .caps_lock = state[c.VK_CAPITAL] & 1 != 0,
        .num_lock = state[c.VK_NUMLOCK] & 1 != 0,
    };
    if (down(state, c.VK_RSHIFT) and !down(state, c.VK_LSHIFT)) mods.sides.shift = .right;
    if (down(state, c.VK_RCONTROL) and !down(state, c.VK_LCONTROL)) mods.sides.ctrl = .right;
    if (down(state, c.VK_RMENU) and !down(state, c.VK_LMENU)) mods.sides.alt = .right;
    if (down(state, c.VK_RWIN) and !down(state, c.VK_LWIN)) mods.sides.super = .right;
    return mods;
}

fn clearCtrl(state: *[256]u8) void {
    state[c.VK_CONTROL] = 0;
    state[c.VK_LCONTROL] = 0;
    state[c.VK_RCONTROL] = 0;
}

fn unshiftedCodepoint(vk: c.UINT, hkl: ?c.HKL) u21 {
    const empty: [256]u8 = @splat(0);
    var wbuf: [8]u16 = undefined;
    const n = c.ToUnicodeEx(vk, 0, &empty, &wbuf, wbuf.len, 0x4, hkl);
    if (n == 0) return 0;
    const len: usize = if (n < 0) 1 else @intCast(n);
    var it = std.unicode.Utf16LeIterator.init(wbuf[0..len]);
    const cp = (it.nextCodepoint() catch return 0) orelse return 0;
    if (cp < 0x20 or cp == 0x7F) return 0;
    return cp;
}

fn utf16ToUtf8(src: []const u16, dst: []u8) usize {
    var len: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(src);
    while (it.nextCodepoint() catch null) |cp| {
        if (cp < 0x20 or cp == 0x7F) continue;
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch continue;
        if (len + n > dst.len) break;
        @memcpy(dst[len..][0..n], tmp[0..n]);
        len += n;
    }
    return len;
}

test "scancode to key" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    try testing.expectEqual(input.Key.key_a, keyFromNative(0x1E));
    try testing.expectEqual(input.Key.arrow_left, keyFromNative(0xE04B));
    try testing.expectEqual(input.Key.enter, keyFromNative(0x1C));
    try testing.expectEqual(input.Key.numpad_enter, keyFromNative(0xE01C));
    try testing.expectEqual(input.Key.num_lock, keyFromNative(0xE045));
    try testing.expectEqual(input.Key.pause, keyFromNative(0x45));
    try testing.expectEqual(input.Key.control_right, keyFromNative(0xE01D));
    try testing.expectEqual(input.Key.unidentified, keyFromNative(0));
}

test "translate with explicit key state" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    const hkl = c.GetKeyboardLayout(0);
    if ((@intFromPtr(hkl) & 0xFFFF) != 0x0409) return error.SkipZigTest;

    try testing.expectEqual(input.Action.press, actionFor(c.WM_KEYDOWN, 0x001E0001).?);
    try testing.expectEqual(input.Action.repeat, actionFor(c.WM_KEYDOWN, 0x401E0001).?);
    try testing.expectEqual(input.Action.release, actionFor(c.WM_KEYUP, 0xC01E0001).?);
    try testing.expectEqual(input.Action.press, actionFor(c.WM_SYSKEYDOWN, 0x201E0001).?);
    try testing.expect(actionFor(c.WM_CHAR, 0) == null);

    var buf: [32]u8 = undefined;
    var state: [256]u8 = @splat(0);
    var out: [64]u8 = undefined;

    {
        const ev = translateState(.press, 'A', 0x001E0001, hkl, &state, &buf);
        try testing.expectEqual(input.Key.key_a, ev.key);
        try testing.expectEqualStrings("a", ev.utf8);
        try testing.expectEqual(@as(u21, 'a'), ev.unshifted_codepoint);
        try testing.expect(!ev.consumed_mods.shift);
    }

    state[c.VK_SHIFT] = 0x80;
    state[c.VK_LSHIFT] = 0x80;
    {
        const ev = translateState(.press, 'A', 0x001E0001, hkl, &state, &buf);
        try testing.expectEqualStrings("A", ev.utf8);
        try testing.expect(ev.mods.shift);
        try testing.expect(ev.consumed_mods.shift);
        try testing.expectEqual(@as(u21, 'a'), ev.unshifted_codepoint);
    }
    {
        const ev = translateState(.press, 0x25, 0x014B0001, hkl, &state, &buf);
        try testing.expectEqual(input.Key.arrow_left, ev.key);
        try testing.expectEqualStrings("", ev.utf8);
        var w: std.Io.Writer = .fixed(&out);
        try input.key_encode.encode(&w, ev, .{});
        try testing.expectEqualStrings("\x1b[1;2D", w.buffered());
    }
    state[c.VK_SHIFT] = 0;
    state[c.VK_LSHIFT] = 0;

    state[c.VK_RSHIFT] = 0x80;
    state[c.VK_SHIFT] = 0x80;
    try testing.expect(translateState(.press, 'A', 0x001E0001, hkl, &state, &buf).mods.sides.shift == .right);
    state[c.VK_RSHIFT] = 0;
    state[c.VK_SHIFT] = 0;

    state[c.VK_CONTROL] = 0x80;
    state[c.VK_LCONTROL] = 0x80;
    {
        const ev = translateState(.press, 'C', 0x002E0001, hkl, &state, &buf);
        try testing.expectEqual(input.Key.key_c, ev.key);
        try testing.expect(ev.mods.ctrl);
        try testing.expectEqualStrings("c", ev.utf8);
        var w: std.Io.Writer = .fixed(&out);
        try input.key_encode.encode(&w, ev, .{});
        try testing.expectEqualStrings("\x03", w.buffered());
    }
    state[c.VK_CONTROL] = 0;
    state[c.VK_LCONTROL] = 0;

    state[c.VK_MENU] = 0x80;
    state[c.VK_LMENU] = 0x80;
    {
        const ev = translateState(.press, 0x0D, 0x201C0001, hkl, &state, &buf);
        try testing.expectEqual(input.Key.enter, ev.key);
        try testing.expect(ev.mods.alt);
        try testing.expectEqualStrings("", ev.utf8);
        var w: std.Io.Writer = .fixed(&out);
        try input.key_encode.encode(&w, ev, .{});
        try testing.expectEqualStrings("\x1b\r", w.buffered());
    }
    state[c.VK_MENU] = 0;
    state[c.VK_LMENU] = 0;

    state[c.VK_CAPITAL] = 0x01;
    {
        const ev = translateState(.press, 'A', 0x001E0001, hkl, &state, &buf);
        try testing.expectEqualStrings("A", ev.utf8);
        try testing.expect(ev.mods.caps_lock);
    }
    state[c.VK_CAPITAL] = 0;

    {
        const ev = translateState(.press, 0x0D, 0x011C0001, hkl, &state, &buf);
        try testing.expectEqual(input.Key.numpad_enter, ev.key);
        const ev2 = translateState(.release, 0x70, 0xC03B0001, hkl, &state, &buf);
        try testing.expectEqual(input.Key.f1, ev2.key);
        try testing.expectEqual(input.Action.release, ev2.action);
    }
}

const TestLayout = struct {
    hkl: c.HKL,
    loaded: bool,

    fn open(id: []const u8) ?TestLayout {
        var before: [64]?c.HKL = undefined;
        const count: usize = @intCast(@max(0, c.GetKeyboardLayoutList(before.len, &before)));

        var wid: [16:0]u16 = @splat(0);
        for (id, 0..) |ch, i| wid[i] = ch;
        const hkl = c.LoadKeyboardLayoutW(&wid, c.KLF_NOTELLSHELL) orelse return null;
        const existed = for (before[0..count]) |h| {
            if (h == hkl) break true;
        } else false;
        return .{ .hkl = hkl, .loaded = !existed };
    }

    fn close(self: TestLayout) void {
        if (self.loaded) _ = c.UnloadKeyboardLayout(self.hkl);
    }
};

fn testKeystate(vks: []const c.UINT) [256]u8 {
    var state: [256]u8 = @splat(0);
    for (vks) |vk| state[vk] = 0x80;
    return state;
}

test "scancode table covers numpad, intl, and right-side modifiers" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    try testing.expectEqual(input.Key.numpad_4, keyFromNative(0x4B));
    try testing.expectEqual(input.Key.numpad_divide, keyFromNative(0xE035));
    try testing.expectEqual(input.Key.numpad_decimal, keyFromNative(0x53));
    try testing.expectEqual(input.Key.meta_left, keyFromNative(0xE05B));
    try testing.expectEqual(input.Key.meta_right, keyFromNative(0xE05C));
    try testing.expectEqual(input.Key.alt_right, keyFromNative(0xE038));
    try testing.expectEqual(input.Key.intl_backslash, keyFromNative(0x56));
    try testing.expectEqual(input.Key.intl_ro, keyFromNative(0x73));
    try testing.expectEqual(input.Key.intl_yen, keyFromNative(0x7D));
}

test "us layout: ctrl+alt is not altgr, bindings see unshifted codepoint" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    const layout = TestLayout.open("00000409") orelse return error.SkipZigTest;
    defer layout.close();
    const hkl = layout.hkl;
    try testing.expect(!hasAltGr(hkl));

    var buf: [32]u8 = undefined;
    {
        const state = testKeystate(&.{ c.VK_CONTROL, c.VK_LCONTROL, c.VK_MENU, c.VK_RMENU });
        const ev = translateState(.press, 'C', 0x002E0001, hkl, &state, &buf);
        try testing.expect(ev.mods.ctrl and ev.mods.alt);
        try testing.expectEqualStrings("c", ev.utf8);
    }

    var set: input.Binding.Set = .{};
    defer set.deinit(alloc);
    try set.parseAndPut(alloc, "ctrl+shift+c=copy_to_clipboard");
    try set.parseAndPut(alloc, "super+k=clear_screen");
    {
        const state = testKeystate(&.{ c.VK_CONTROL, c.VK_LCONTROL, c.VK_SHIFT, c.VK_LSHIFT });
        const ev = translateState(.press, 'C', 0x002E0001, hkl, &state, &buf);
        try testing.expectEqual(@as(u21, 'c'), ev.unshifted_codepoint);
        try testing.expect(set.getEvent(ev) != null);
    }
    {
        const state = testKeystate(&.{c.VK_LWIN});
        const ev = translateState(.press, 'K', 0x00250001, hkl, &state, &buf);
        try testing.expect(ev.mods.super);
        try testing.expect(set.getEvent(ev) != null);
    }
    {
        const state = testKeystate(&.{ c.VK_CONTROL, c.VK_LCONTROL });
        const ev = translateState(.press, 0xBB, 0x000D0001, hkl, &state, &buf);
        try testing.expectEqual(input.Key.equal, ev.key);
        try testing.expectEqual(@as(u21, '='), ev.unshifted_codepoint);
    }
    {
        const state = testKeystate(&.{});
        const ev = translateState(.release, 'A', 0xC01E0001, hkl, &state, &buf);
        try testing.expectEqual(@as(u21, 'a'), ev.unshifted_codepoint);
    }
}

test "us-international dead keys" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    const layout = TestLayout.open("00020409") orelse return error.SkipZigTest;
    defer layout.close();
    const hkl = layout.hkl;

    var buf: [32]u8 = undefined;
    const none = testKeystate(&.{});
    const shift = testKeystate(&.{ c.VK_SHIFT, c.VK_LSHIFT });

    {
        const dead = translateState(.press, 0xDE, 0x00280001, hkl, &none, &buf);
        try testing.expect(dead.composing);
        try testing.expectEqualStrings("'", dead.utf8);
        const ev = translateState(.press, 'A', 0x001E0001, hkl, &none, &buf);
        try testing.expect(!ev.composing);
        try testing.expectEqualStrings("á", ev.utf8);
    }
    {
        _ = translateState(.press, 0xDE, 0x00280001, hkl, &none, &buf);
        const ev = translateState(.press, 0x20, 0x00390001, hkl, &none, &buf);
        try testing.expectEqualStrings("'", ev.utf8);
    }
    {
        const dead = translateState(.press, 0xDE, 0x00280001, hkl, &shift, &buf);
        try testing.expect(dead.composing);
        try testing.expectEqualStrings("\"", dead.utf8);
        const ev = translateState(.press, 'U', 0x00160001, hkl, &none, &buf);
        try testing.expectEqualStrings("ü", ev.utf8);
    }
}

test "german layout: altgr and dead keys" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    const layout = TestLayout.open("00000407") orelse return error.SkipZigTest;
    defer layout.close();
    const hkl = layout.hkl;
    try testing.expect(hasAltGr(hkl));

    var buf: [32]u8 = undefined;
    const none = testKeystate(&.{});
    const altgr = testKeystate(&.{ c.VK_CONTROL, c.VK_LCONTROL, c.VK_MENU, c.VK_RMENU });
    const ctrl_lalt = testKeystate(&.{ c.VK_CONTROL, c.VK_LCONTROL, c.VK_MENU, c.VK_LMENU });

    {
        const ev = translateState(.press, 'Q', 0x00100001, hkl, &altgr, &buf);
        try testing.expectEqualStrings("@", ev.utf8);
        try testing.expect(!ev.mods.ctrl and !ev.mods.alt);
        try testing.expectEqual(@as(u21, 'q'), ev.unshifted_codepoint);
    }
    {
        const ev = translateState(.press, '8', 0x00090001, hkl, &altgr, &buf);
        try testing.expectEqualStrings("[", ev.utf8);
    }
    {
        const ev = translateState(.press, 'Q', 0x00100001, hkl, &ctrl_lalt, &buf);
        try testing.expect(ev.mods.ctrl and ev.mods.alt);
        try testing.expectEqualStrings("q", ev.utf8);
    }
    {
        const ev = translateState(.press, 0xDB, 0x000C0001, hkl, &none, &buf);
        try testing.expectEqual(input.Key.minus, ev.key);
        try testing.expectEqualStrings("ß", ev.utf8);
    }
    {
        const ev = translateState(.press, 0xBA, 0x001A0001, hkl, &none, &buf);
        try testing.expectEqualStrings("ü", ev.utf8);
    }
    {
        const ctrl = testKeystate(&.{ c.VK_CONTROL, c.VK_LCONTROL });
        const ev = translateState(.press, 0xBB, 0x001B0001, hkl, &ctrl, &buf);
        try testing.expectEqualStrings("+", ev.utf8);
        try testing.expectEqual(@as(u21, '+'), ev.unshifted_codepoint);
    }
    {
        const dead = translateState(.press, 0xDC, 0x00290001, hkl, &none, &buf);
        try testing.expect(dead.composing);
        try testing.expectEqualStrings("^", dead.utf8);
        const ev = translateState(.press, 'A', 0x001E0001, hkl, &none, &buf);
        try testing.expectEqualStrings("â", ev.utf8);
    }
    {
        _ = translateState(.press, 0xDD, 0x000D0001, hkl, &none, &buf);
        const ev = translateState(.press, 'E', 0x00120001, hkl, &none, &buf);
        try testing.expectEqualStrings("é", ev.utf8);
    }
}

test "french layout: altgr digits and shifted digits" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    const layout = TestLayout.open("0000040C") orelse return error.SkipZigTest;
    defer layout.close();
    const hkl = layout.hkl;
    try testing.expect(hasAltGr(hkl));

    var buf: [32]u8 = undefined;
    const none = testKeystate(&.{});
    const shift = testKeystate(&.{ c.VK_SHIFT, c.VK_LSHIFT });
    const altgr = testKeystate(&.{ c.VK_CONTROL, c.VK_LCONTROL, c.VK_MENU, c.VK_RMENU });

    {
        const ev = translateState(.press, '0', 0x000B0001, hkl, &altgr, &buf);
        try testing.expectEqualStrings("@", ev.utf8);
    }
    {
        const ev = translateState(.press, '0', 0x000B0001, hkl, &none, &buf);
        try testing.expectEqualStrings("à", ev.utf8);
        const ev2 = translateState(.press, '0', 0x000B0001, hkl, &shift, &buf);
        try testing.expectEqualStrings("0", ev2.utf8);
        try testing.expect(ev2.consumed_mods.shift);
    }
    {
        const ev = translateState(.press, 0xDE, 0x00290001, hkl, &none, &buf);
        try testing.expectEqualStrings("²", ev.utf8);
    }
}

test "WM_CHAR text becomes key events" {
    const testing = std.testing;
    var buf: [8]u8 = undefined;
    var out: [64]u8 = undefined;
    var dec: CharDecoder = .{};

    {
        const cp = dec.push(0xE9).?;
        const ev = charEvent(cp, &buf).?;
        try testing.expectEqualStrings("\u{e9}", ev.utf8);
        var w: std.Io.Writer = .fixed(&out);
        try input.key_encode.encode(&w, ev, .{});
        try testing.expectEqualStrings("\u{e9}", w.buffered());
    }
    {
        try testing.expect(dec.push(0xD83D) == null);
        try testing.expect(dec.push(0) == null);
        const cp = dec.push(0xDE00).?;
        const ev = charEvent(cp, &buf).?;
        var w: std.Io.Writer = .fixed(&out);
        try input.key_encode.encode(&w, ev, .{});
        try testing.expectEqualStrings("\u{1F600}", w.buffered());
        var wk: std.Io.Writer = .fixed(&out);
        try input.key_encode.encode(&wk, ev, .{ .kitty_flags = .{ .disambiguate = true } });
        try testing.expectEqualStrings("\u{1F600}", wk.buffered());
    }
    try testing.expect(dec.push(0xDE00) == null);
    try testing.expect(dec.push(0) == null);
    {
        const ev = charEvent(dec.push(0x0D).?, &buf).?;
        var w: std.Io.Writer = .fixed(&out);
        try input.key_encode.encode(&w, ev, .{});
        try testing.expectEqualStrings("\r", w.buffered());
    }
    try testing.expect(charEvent(0x01, &buf) == null);
}
