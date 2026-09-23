const std = @import("std");
const windows = std.os.windows;

// NOTE: The Windows part of the Zig stdlib is currently in the process of
// having most of its features removed, with the ultimate goal of switching to
// serve as a support for higher-level functionality offered in places like
// `std.Io` only. As such this file serves as a "bridge" between type
// information (mostly coming from stdlib) and manually-defined constants and
// external functions.

// Utility functions
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const GetCurrentThreadId = windows.GetCurrentThreadId;
pub const RtlAddVectoredExceptionHandler = windows.ntdll.RtlAddVectoredExceptionHandler;
pub const RtlCaptureContext = windows.ntdll.RtlCaptureContext;
pub const GetLastError = windows.GetLastError;
pub const unexpectedError = windows.unexpectedError;
pub const unexpectedStatus = windows.unexpectedStatus;

// Primitive types
pub const BOOL = windows.BOOL;
pub const CONTEXT = windows.CONTEXT;
pub const COORD = windows.COORD;
pub const HMODULE = windows.HMODULE;
pub const DWORD = windows.DWORD;
pub const DWORD_PTR = windows.DWORD_PTR;
pub const EXCEPTION_POINTERS = windows.EXCEPTION_POINTERS;
pub const EXCEPTION_RECORD = windows.EXCEPTION_RECORD;
pub const HANDLE = windows.HANDLE;
pub const HINSTANCE = windows.HINSTANCE;
pub const HPCON = windows.LPVOID;
pub const HRESULT = c_long;
pub const LARGE_INTEGER = windows.LARGE_INTEGER;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPSTR = windows.LPSTR;
pub const LPVOID = windows.LPVOID;
pub const LPWSTR = windows.LPWSTR;
pub const PVOID = windows.PVOID;
pub const SIZE_T = windows.SIZE_T;
pub const UINT = windows.UINT;
pub const ULONG = windows.ULONG;
pub const ULONG_PTR = windows.ULONG_PTR;
pub const UNICODE_STRING = windows.UNICODE_STRING;

// Structs and opaque types
pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const STARTUPINFOW = windows.STARTUPINFOW;

pub const OVERLAPPED = extern struct {
    Internal: ULONG_PTR,
    InternalHigh: ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?PVOID,
    },
    hEvent: ?HANDLE,
};
pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};
pub const STARTUPINFOEX = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
};
pub const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

pub const MINIDUMP_EXCEPTION_INFORMATION = extern struct {
    ThreadId: DWORD,
    ExceptionPointers: *EXCEPTION_POINTERS align(4),
    ClientPointers: BOOL,
};

pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};
pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};
pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: LARGE_INTEGER = 0,
    PerJobUserTimeLimit: LARGE_INTEGER = 0,
    LimitFlags: DWORD = 0,
    MinimumWorkingSetSize: SIZE_T = 0,
    MaximumWorkingSetSize: SIZE_T = 0,
    ActiveProcessLimit: DWORD = 0,
    Affinity: ULONG_PTR = 0,
    PriorityClass: DWORD = 0,
    SchedulingClass: DWORD = 0,
};
pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = std.mem.zeroes(IO_COUNTERS),
    ProcessMemoryLimit: SIZE_T = 0,
    JobMemoryLimit: SIZE_T = 0,
    PeakProcessMemoryUsed: SIZE_T = 0,
    PeakJobMemoryUsed: SIZE_T = 0,
};
pub const JOBOBJECTINFOCLASS = enum(c_int) {
    BasicProcessIdList = 3,
    ExtendedLimitInformation = 9,
};

// Well-known constant values
pub const ATTACH_PARENT_PROCESS: DWORD = 0xFFFFFFFF;
pub const CP_UTF8: UINT = 65001;
pub const INFINITE = 4294967295;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const MAX_PATH = windows.MAX_PATH;
pub const FALSE: windows.BOOL = .fromBool(false);
pub const TRUE: windows.BOOL = .fromBool(true);
pub const LOCALE_NAME_MAX_LENGTH = 85;

pub const COMPUTER_NAME_FORMAT = enum(c_int) {
    NetBIOS = 0,
    DnsHostname = 1,
    DnsDomain = 2,
    DnsFullyQualified = 3,
    PhysicalNetBIOS = 4,
    PhysicalDnsHostname = 5,
    PhysicalDnsDomain = 6,
    PhysicalDnsFullyQualified = 7,
};

// Bit-field and enum constant values
pub const CREATE_ALWAYS = 2;
pub const CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
pub const CREATE_SUSPENDED = 0x00000004;
pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
pub const DELETE = 0x00010000;
pub const ERROR_SUCCESS = 0;
pub const EXCEPTION_ACCESS_VIOLATION = windows.EXCEPTION_ACCESS_VIOLATION;
pub const EXCEPTION_CONTINUE_SEARCH = windows.EXCEPTION_CONTINUE_SEARCH;
pub const EXCEPTION_DATATYPE_MISALIGNMENT = windows.EXCEPTION_DATATYPE_MISALIGNMENT;
pub const EXCEPTION_EXECUTE_HANDLER = 1;
pub const EXCEPTION_ILLEGAL_INSTRUCTION = windows.EXCEPTION_ILLEGAL_INSTRUCTION;
pub const EXCEPTION_NONCONTINUABLE = 0x1;
pub const EXCEPTION_STACK_OVERFLOW = windows.EXCEPTION_STACK_OVERFLOW;
pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
pub const FILE_ATTRIBUTE_DIRECTORY = 0x10;
pub const FILE_ATTRIBUTE_NORMAL = 0x80;
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
pub const SW_SHOWNORMAL = 1;
pub const COINIT_APARTMENTTHREADED = 0x2;
pub const COINIT_DISABLE_OLE1DDE = 0x4;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
pub const FILE_FLAG_OVERLAPPED = 0x40000000;
/// GetFinalPathNameByHandleW dwFlags: normalized name with a DOS drive
/// letter (both are the zero flag values).
pub const FILE_NAME_NORMALIZED = 0x0;
pub const FILE_NON_DIRECTORY_FILE = 0x00000040;
/// NtCreateFile CreateDisposition: open an existing file, never create.
/// Distinct from the Win32 CreateFileW value OPEN_EXISTING.
pub const FILE_OPEN = 0x00000001;
pub const FILE_OPEN_REPARSE_POINT = 0x00200000;
pub const FILE_SHARE_DELETE = 0x00000004;
pub const FILE_SHARE_READ = 0x00000001;
pub const FILE_SHARE_WRITE = 0x00000002;
pub const FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
pub const GENERIC_READ = 0x80000000;
pub const GENERIC_WRITE = 0x40000000;
pub const HANDLE_FLAG_INHERIT = 0x00000001;
pub const JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x00000800;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
pub const MEM_COMMIT = 0x1000;
pub const MEM_RELEASE = 0x8000;
pub const MEM_RESERVE = 0x2000;
pub const OPEN_EXISTING = 3; // Known as FILE_OPEN in Windows docs
pub const PAGE_READWRITE = 0x04;
pub const PIPE_ACCESS_OUTBOUND = 0x00000002;
pub const PIPE_TYPE_BYTE = 0x00000000;
pub const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;
pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
pub const PSEUDOCONSOLE_INHERIT_CURSOR: DWORD = 0x1;
pub const LOAD_WITH_ALTERED_SEARCH_PATH: DWORD = 0x8;
pub const S_OK = 0;
pub const STD_ERROR_HANDLE: DWORD = 0xFFFFFFF4;
pub const STD_INPUT_HANDLE: DWORD = 0xFFFFFFF6;
pub const STD_OUTPUT_HANDLE: DWORD = 0xFFFFFFF5;
pub const SYNCHRONIZE = 0x00100000;
pub const VOLUME_NAME_DOS = 0x0;
pub const WAIT_FAILED = 0xFFFFFFFF;
pub const WAIT_TIMEOUT = 0x00000102;

/// IOCTL that fills the output buffer with bytes from the kernel CSPRNG
/// behind `\Device\CNG` (what ProcessPrng and BCryptGenRandom draw from).
pub const IOCTL_KSEC_GEN_RANDOM: CTL_CODE = windows.IOCTL.KSEC.GEN_RANDOM;

pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(
    .ProcThreadAttributePseudoConsole,
    false,
    true,
    false,
);

// Types needed for ntdll calls
pub const ACCESS_MASK = windows.ACCESS_MASK;
pub const CTL_CODE = windows.CTL_CODE;
pub const FILE_ALL_INFORMATION = windows.FILE.ALL_INFORMATION;
pub const FILE_ATTRIBUTE_TAG_INFORMATION = windows.FILE.ATTRIBUTE_TAG_INFO;
pub const FILE_DISPOSITION_INFORMATION = windows.FILE.DISPOSITION.INFORMATION;
pub const FILE_DISPOSITION_INFORMATION_EX = windows.FILE.DISPOSITION.INFORMATION.EX;
pub const FILE_INFORMATION_CLASS = windows.FILE.INFORMATION_CLASS;
pub const FILE_POSITION_INFORMATION = windows.FILE.POSITION_INFORMATION;
pub const FILE_STANDARD_INFORMATION = windows.FILE.STANDARD_INFORMATION;
pub const IO_STATUS_BLOCK = windows.IO_STATUS_BLOCK;
pub const NTSTATUS = windows.NTSTATUS;
pub const OBJECT_ATTRIBUTES = windows.OBJECT.ATTRIBUTES;

// Exported functions by library
pub const exp = struct {
    pub const kernel32 = struct {
        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *HANDLE,
            hWritePipe: *HANDLE,
            lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
            nSize: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: COORD,
            hInput: HANDLE,
            hOutput: HANDLE,
            dwFlags: DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(
            hPC: HPCON,
            size: COORD,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        pub extern "kernel32" fn GetModuleFileNameW(
            hModule: ?HMODULE,
            lpFilename: [*]u16,
            nSize: DWORD,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn LoadLibraryExW(
            lpLibFileName: LPCWSTR,
            hFile: ?HANDLE,
            dwFlags: DWORD,
        ) callconv(.winapi) ?HMODULE;
        pub extern "kernel32" fn GetProcAddress(
            hModule: HMODULE,
            lpProcName: [*:0]const u8,
        ) callconv(.winapi) ?*const anyopaque;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: DWORD,
            dwFlags: DWORD,
            lpSize: *SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: DWORD,
            Attribute: DWORD_PTR,
            lpValue: PVOID,
            cbSize: SIZE_T,
            lpPreviousValue: ?PVOID,
            lpReturnSize: ?*SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: HANDLE,
            lpBuffer: ?LPVOID,
            nBufferSize: DWORD,
            lpBytesRead: ?*DWORD,
            lpTotalBytesAvail: ?*DWORD,
            lpBytesLeftThisMessage: ?*DWORD,
        ) callconv(.winapi) BOOL;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?LPWSTR,
            lpCommandLine: ?LPWSTR,
            lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
            bInheritHandles: BOOL,
            dwCreationFlags: DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?LPWSTR,
            lpStartupInfo: *STARTUPINFOW,
            lpProcessInformation: *PROCESS_INFORMATION,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getcomputernamea
        pub extern "kernel32" fn GetComputerNameA(
            lpBuffer: LPSTR,
            nSize: *DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn GetComputerNameExW(
            NameType: COMPUTER_NAME_FORMAT,
            lpBuffer: ?[*]u16,
            nSize: *DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn GetUserDefaultLocaleName(
            lpLocaleName: [*]u16,
            cchLocaleName: c_int,
        ) callconv(.winapi) c_int;
        pub extern "kernel32" fn GetEnvironmentVariableW(
            lpName: LPCWSTR,
            lpBuffer: ?[*]u16,
            nSize: DWORD,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn SetEnvironmentVariableW(
            lpName: LPCWSTR,
            lpValue: ?LPCWSTR,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw
        pub extern "kernel32" fn GetTempPathW(
            nBufferLength: DWORD,
            lpBuffer: LPWSTR,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn SetHandleInformation(
            hObject: HANDLE,
            dwMask: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreateFileW(
            lpFileName: LPCWSTR,
            dwDesiredAccess: DWORD,
            dwShareMode: DWORD,
            lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
            dwCreationDisposition: DWORD,
            dwFlagsAndAttributes: DWORD,
            hTemplateFile: ?HANDLE,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CreateNamedPipeW(
            lpName: LPCWSTR,
            dwOpenMode: DWORD,
            dwPipeMode: DWORD,
            nMaxInstances: DWORD,
            nOutBufferSize: DWORD,
            nInBufferSize: DWORD,
            nDefaultTimeOut: DWORD,
            lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CloseHandle(
            hObject: HANDLE,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn VirtualAlloc(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            flAllocationType: DWORD,
            flProtect: DWORD,
        ) callconv(.winapi) ?LPVOID;
        pub extern "kernel32" fn VirtualFree(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            dwFreeType: DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-discardvirtualmemory
        pub extern "kernel32" fn DiscardVirtualMemory(
            VirtualAddress: PVOID,
            Size: SIZE_T,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn WaitForSingleObject(
            hHandle: HANDLE,
            dwMilliseconds: DWORD,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn GetExitCodeProcess(
            hProcess: HANDLE,
            lpExitCode: *DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreateJobObjectW(
            lpJobAttributes: ?*SECURITY_ATTRIBUTES,
            lpName: ?LPCWSTR,
        ) callconv(.winapi) ?HANDLE;
        pub extern "kernel32" fn SetInformationJobObject(
            hJob: HANDLE,
            JobObjectInformationClass: JOBOBJECTINFOCLASS,
            lpJobObjectInformation: *const anyopaque,
            cbJobObjectInformationLength: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn QueryInformationJobObject(
            hJob: ?HANDLE,
            JobObjectInformationClass: JOBOBJECTINFOCLASS,
            lpJobObjectInformation: *anyopaque,
            cbJobObjectInformationLength: DWORD,
            lpReturnLength: ?*DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn AssignProcessToJobObject(
            hJob: HANDLE,
            hProcess: HANDLE,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn TerminateJobObject(
            hJob: HANDLE,
            uExitCode: UINT,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn ResumeThread(
            hThread: HANDLE,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn OpenProcess(
            dwDesiredAccess: DWORD,
            bInheritHandle: BOOL,
            dwProcessId: DWORD,
        ) callconv(.winapi) ?HANDLE;
        pub extern "kernel32" fn GetProcessTimes(
            hProcess: HANDLE,
            lpCreationTime: *FILETIME,
            lpExitTime: *FILETIME,
            lpKernelTime: *FILETIME,
            lpUserTime: *FILETIME,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn TerminateProcess(
            hProcess: HANDLE,
            uExitCode: UINT,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CancelIoEx(
            hFile: HANDLE,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn ReadFile(
            hFile: HANDLE,
            lpBuffer: LPVOID,
            nNumberOfBytesToRead: DWORD,
            lpNumberOfBytesRead: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn WriteFile(
            hFile: HANDLE,
            lpBuffer: *const anyopaque,
            nNumberOfBytesToWrite: DWORD,
            lpNumberOfBytesWritten: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
        pub extern "kernel32" fn GetProcessHandleCount(
            hProcess: HANDLE,
            pdwHandleCount: *DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew
        pub extern "kernel32" fn GetFinalPathNameByHandleW(
            hFile: HANDLE,
            lpszFilePath: [*]u16,
            cchFilePath: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn AttachConsole(
            dwProcessId: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn GetStdHandle(
            nStdHandle: DWORD,
        ) callconv(.winapi) ?HANDLE;
        pub extern "kernel32" fn SetStdHandle(
            nStdHandle: DWORD,
            hHandle: HANDLE,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn SetConsoleOutputCP(
            wCodePageID: UINT,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn GetFileAttributesW(
            lpFileName: LPCWSTR,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn GetSystemTime(
            lpSystemTime: *SYSTEMTIME,
        ) callconv(.winapi) void;
        pub extern "kernel32" fn SetUnhandledExceptionFilter(
            lpTopLevelExceptionFilter: ?*const fn (*EXCEPTION_POINTERS) callconv(.winapi) c_long,
        ) callconv(.winapi) ?*const fn (*EXCEPTION_POINTERS) callconv(.winapi) c_long;
    };
    pub const dbghelp = struct {
        pub extern "dbghelp" fn MiniDumpWriteDump(
            hProcess: HANDLE,
            ProcessId: DWORD,
            hFile: HANDLE,
            DumpType: DWORD,
            ExceptionParam: ?*const MINIDUMP_EXCEPTION_INFORMATION,
            UserStreamParam: ?*const anyopaque,
            CallbackParam: ?*const anyopaque,
        ) callconv(.winapi) BOOL;
    };
    pub const shell32 = struct {
        pub extern "shell32" fn ShellExecuteW(
            hwnd: ?*anyopaque,
            lpOperation: ?LPCWSTR,
            lpFile: LPCWSTR,
            lpParameters: ?LPCWSTR,
            lpDirectory: ?LPCWSTR,
            nShowCmd: c_int,
        ) callconv(.winapi) ?HINSTANCE;
    };
    pub const ole32 = struct {
        pub extern "ole32" fn CoInitializeEx(
            pvReserved: ?LPVOID,
            dwCoInit: DWORD,
        ) callconv(.winapi) HRESULT;
        pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    };
    pub const user32 = struct {
        pub extern "user32" fn GetDoubleClickTime() callconv(.winapi) UINT;
    };
    pub const ntdll = struct {
        pub extern "ntdll" fn NtCreateFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            AllocationSize: ?*LARGE_INTEGER,
            FileAttributes: ULONG,
            ShareAccess: ULONG,
            CreateDisposition: ULONG,
            CreateOptions: ULONG,
            EaBuffer: ?*anyopaque,
            EaLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtOpenFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            ShareAccess: ULONG,
            OpenOptions: ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtClose(Handle: HANDLE) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtReadFile(
            FileHandle: HANDLE,
            Event: ?HANDLE,
            ApcRoutine: ?*const anyopaque,
            ApcContext: ?*anyopaque,
            IoStatusBlock: *IO_STATUS_BLOCK,
            Buffer: *anyopaque,
            Length: ULONG,
            ByteOffset: ?*const LARGE_INTEGER,
            Key: ?*const ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtQueryInformationFile(
            FileHandle: HANDLE,
            IoStatusBlock: *IO_STATUS_BLOCK,
            FileInformation: *anyopaque,
            Length: ULONG,
            FileInformationClass: FILE_INFORMATION_CLASS,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtSetInformationFile(
            FileHandle: HANDLE,
            IoStatusBlock: *IO_STATUS_BLOCK,
            FileInformation: *anyopaque,
            Length: ULONG,
            FileInformationClass: FILE_INFORMATION_CLASS,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtDeviceIoControlFile(
            FileHandle: HANDLE,
            Event: ?HANDLE,
            ApcRoutine: ?*const anyopaque,
            ApcContext: ?*anyopaque,
            IoStatusBlock: *IO_STATUS_BLOCK,
            IoControlCode: CTL_CODE,
            InputBuffer: ?*const anyopaque,
            InputBufferLength: ULONG,
            OutputBuffer: ?*anyopaque,
            OutputBufferLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
        /// Resolves a Win32 path against the process working directory and
        /// canonicalizes it, keeping any `\\?\` or `\\.\` prefix. Returns
        /// the byte length written excluding the terminator, the required
        /// byte length if the buffer is too small, or 0 on failure.
        pub extern "ntdll" fn RtlGetFullPathName_U(
            FileName: [*:0]const u16,
            BufferByteLength: ULONG,
            Buffer: [*]u16,
            ShortName: ?*[*:0]const u16,
        ) callconv(.winapi) ULONG;
        /// The futex primitives that kernel32's WaitOnAddress and
        /// WakeByAddress* forward to. Timeout is a relative (negative)
        /// interval in 100ns units, null to wait forever.
        pub extern "ntdll" fn RtlWaitOnAddress(
            Address: *const anyopaque,
            CompareAddress: *const anyopaque,
            AddressSize: SIZE_T,
            Timeout: ?*const LARGE_INTEGER,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn RtlWakeAddressSingle(Address: *const anyopaque) callconv(.winapi) void;
        pub extern "ntdll" fn RtlWakeAddressAll(Address: *const anyopaque) callconv(.winapi) void;
    };
};

pub const ProcThreadAttributeNumber = enum(DWORD) {
    ProcThreadAttributePseudoConsole = 22,
    _,
};

/// Corresponds to the ProcThreadAttributeValue define in WinBase.h
pub fn ProcThreadAttributeValue(
    comptime attribute: ProcThreadAttributeNumber,
    comptime thread: bool,
    comptime input: bool,
    comptime additive: bool,
) DWORD {
    return (@intFromEnum(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
        (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
        (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
        (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
}

pub fn attachParentConsole() bool {
    const k32 = exp.kernel32;
    const conin = std.unicode.utf8ToUtf16LeStringLiteral("CONIN$");
    const conout = std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$");
    const stds = [_]struct { id: DWORD, name: [*:0]const u16 }{
        .{ .id = STD_INPUT_HANDLE, .name = conin },
        .{ .id = STD_OUTPUT_HANDLE, .name = conout },
        .{ .id = STD_ERROR_HANDLE, .name = conout },
    };

    var missing: [stds.len]bool = undefined;
    for (stds, &missing) |s, *m| {
        const h = k32.GetStdHandle(s.id);
        m.* = h == null or h == INVALID_HANDLE_VALUE;
    }

    if (!k32.AttachConsole(ATTACH_PARENT_PROCESS).toBool()) return false;
    _ = k32.SetConsoleOutputCP(CP_UTF8);

    for (stds, missing) |s, m| {
        if (!m) continue;
        const h = k32.CreateFileW(
            s.name,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            null,
            OPEN_EXISTING,
            0,
            null,
        );
        if (h == INVALID_HANDLE_VALUE) continue;
        _ = k32.SetStdHandle(s.id, h);
    }

    return true;
}
