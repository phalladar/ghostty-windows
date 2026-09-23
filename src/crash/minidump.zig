const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = @import("../os/windows.zig");
const dir = @import("dir.zig");

const log = std.log.scoped(.minidump);

const MiniDumpWithIndirectlyReferencedMemory = 0x00000040;
const MiniDumpWithThreadInfo = 0x00001000;
const dump_type = MiniDumpWithIndirectlyReferencedMemory | MiniDumpWithThreadInfo;

const panic_exception_code: u32 = 0xE05A4947;

var dir_buf: [1024]u16 = undefined;
var dir_len: usize = 0;
var dumped: std.atomic.Value(bool) = .init(false);

pub fn install(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
) !void {
    if (comptime builtin.os.tag != .windows) return;

    const crash_dir = try dir.defaultDir(io, alloc, environ_map);
    defer alloc.free(crash_dir.path);
    if (try std.unicode.calcUtf16LeLen(crash_dir.path) > dir_buf.len - 64)
        return error.NameTooLong;
    try std.Io.Dir.cwd().createDirPath(io, crash_dir.path);
    dir_len = try std.unicode.utf8ToUtf16Le(&dir_buf, crash_dir.path);

    _ = windows.exp.kernel32.SetUnhandledExceptionFilter(unhandledFilter);

    // std.debug's segfault handler is a vectored handler that aborts the
    // process, so the unhandled filter would never see these exceptions.
    if (comptime std.options.enable_segfault_handler) {
        _ = windows.RtlAddVectoredExceptionHandler(1, vectoredHandler);
    }

    log.debug("minidump handler installed dir={s}", .{crash_dir.path});

    if (comptime builtin.mode == .Debug) debugCrash(environ_map);
}

pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (comptime builtin.os.tag == .windows) {
        var context: windows.CONTEXT = undefined;
        windows.RtlCaptureContext(&context);
        var record: windows.EXCEPTION_RECORD = undefined;
        @memset(std.mem.asBytes(&record), 0);
        record.ExceptionCode = panic_exception_code;
        record.ExceptionFlags = windows.EXCEPTION_NONCONTINUABLE;
        record.ExceptionAddress = @ptrFromInt(context.getRegs().ip);
        var pointers: windows.EXCEPTION_POINTERS = .{
            .ExceptionRecord = &record,
            .ContextRecord = &context,
        };
        write(&pointers, msg);
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn vectoredHandler(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    switch (info.ExceptionRecord.ExceptionCode) {
        windows.EXCEPTION_ACCESS_VIOLATION,
        windows.EXCEPTION_DATATYPE_MISALIGNMENT,
        windows.EXCEPTION_ILLEGAL_INSTRUCTION,
        windows.EXCEPTION_STACK_OVERFLOW,
        => write(info, null),
        else => {},
    }
    return windows.EXCEPTION_CONTINUE_SEARCH;
}

fn unhandledFilter(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    write(info, null);
    return windows.EXCEPTION_EXECUTE_HANDLER;
}

fn write(info: *windows.EXCEPTION_POINTERS, msg: ?[]const u8) void {
    if (dir_len == 0) return;
    if (dumped.swap(true, .acq_rel)) return;

    var st: windows.SYSTEMTIME = undefined;
    windows.exp.kernel32.GetSystemTime(&st);
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(
        &name_buf,
        "\\{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d}.",
        .{
            st.wYear,                      st.wMonth,  st.wDay,
            st.wHour,                      st.wMinute, st.wSecond,
            windows.GetCurrentProcessId(),
        },
    ) catch return;

    var path: [dir_buf.len]u16 = undefined;
    @memcpy(path[0..dir_len], dir_buf[0..dir_len]);
    for (name, path[dir_len..][0..name.len]) |c, *w| w.* = c;
    const ext_start = dir_len + name.len;

    const dump_file = create(&path, ext_start, "dmp") orelse return;
    const exc: windows.MINIDUMP_EXCEPTION_INFORMATION = .{
        .ThreadId = windows.GetCurrentThreadId(),
        .ExceptionPointers = info,
        .ClientPointers = windows.FALSE,
    };
    _ = windows.exp.dbghelp.MiniDumpWriteDump(
        windows.exp.kernel32.GetCurrentProcess(),
        windows.GetCurrentProcessId(),
        dump_file,
        dump_type,
        &exc,
        null,
        null,
    );
    _ = windows.exp.kernel32.CloseHandle(dump_file);

    const text = msg orelse return;
    const txt_file = create(&path, ext_start, "txt") orelse return;
    const prefix = "panic: ";
    _ = windows.exp.kernel32.WriteFile(txt_file, prefix, prefix.len, null, null);
    _ = windows.exp.kernel32.WriteFile(txt_file, text.ptr, @intCast(text.len), null, null);
    _ = windows.exp.kernel32.CloseHandle(txt_file);
}

fn create(path: []u16, ext_start: usize, comptime ext: []const u8) ?windows.HANDLE {
    for (ext, path[ext_start..][0..ext.len]) |c, *w| w.* = c;
    path[ext_start + ext.len] = 0;
    const h = windows.exp.kernel32.CreateFileW(
        @ptrCast(path.ptr),
        windows.GENERIC_WRITE,
        0,
        null,
        windows.CREATE_ALWAYS,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == windows.INVALID_HANDLE_VALUE) return null;
    return h;
}

fn debugCrash(environ_map: *const std.process.Environ.Map) void {
    const kind = environ_map.get("GHOSTTY_DEBUG_CRASH") orelse return;
    if (std.mem.eql(u8, kind, "panic")) @panic("GHOSTTY_DEBUG_CRASH=panic");
    if (std.mem.eql(u8, kind, "segfault")) {
        const p: *allowzero volatile u8 = @ptrFromInt(0);
        p.* = 1;
    }
    if (std.mem.eql(u8, kind, "breakpoint")) @breakpoint();
}

test "MINIDUMP_EXCEPTION_INFORMATION layout" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const T = windows.MINIDUMP_EXCEPTION_INFORMATION;
    try std.testing.expectEqual(4, @offsetOf(T, "ExceptionPointers"));
    try std.testing.expectEqual(12, @offsetOf(T, "ClientPointers"));
    try std.testing.expectEqual(16, @sizeOf(T));
}
