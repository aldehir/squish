//! The window's log in a file, as well as on stderr: a release build is
//! a GUI program, with no console to show stderr. The file is
//! %LOCALAPPDATA%\slime\slime-gui.log (slime-gui-<instance>.log with
//! SLIME_INSTANCE), cut to its last `keep` bytes when a window starts.
//! Windows running at once share it: each line goes in whole.

const std = @import("std");
const win32 = @import("win32/win32.zig");
const Daemon = @import("Daemon.zig");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// How much of the file a starting window keeps.
const keep = 1024 * 1024;

/// Opened for appending by `open`; null if it couldn't be.
var handle: ?win32.HANDLE = null;

/// Open the file, cutting it down first. Without LOCALAPPDATA, or if it
/// can't be opened, the log goes to stderr alone.
pub fn open() void {
    var buf: [600]u16 = undefined;
    var len: usize = win32.GetEnvironmentVariableW(L("LOCALAPPDATA"), &buf, 260);
    if (len == 0 or len >= 260) return;
    const dir = L("\\slime");
    @memcpy(buf[len..][0..dir.len], dir);
    len += dir.len;
    buf[len] = 0;
    _ = win32.CreateDirectoryW(@ptrCast(&buf), null);
    const name = L("\\slime-gui");
    @memcpy(buf[len..][0..name.len], name);
    len += name.len;
    var inst: [64]u16 = undefined;
    if (Daemon.instance(&inst)) |i| {
        buf[len] = '-';
        @memcpy(buf[len + 1 ..][0..i.len], i);
        len += 1 + i.len;
    }
    const ext = L(".log");
    @memcpy(buf[len..][0..ext.len], ext);
    len += ext.len;
    buf[len] = 0;
    const path: [*:0]const u16 = @ptrCast(&buf);

    trim(path);
    const h = win32.CreateFileW(
        path,
        win32.FILE_APPEND_DATA | win32.SYNCHRONIZE,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
        null,
        win32.OPEN_ALWAYS,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == win32.INVALID_HANDLE_VALUE) return;
    handle = h;
}

/// Cut the file at `path` to its last `keep` bytes, from a line's start.
fn trim(path: [*:0]const u16) void {
    const h = win32.CreateFileW(
        path,
        win32.GENERIC_READ | win32.GENERIC_WRITE,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
        null,
        win32.OPEN_EXISTING,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == win32.INVALID_HANDLE_VALUE) return;
    defer _ = win32.CloseHandle(h);
    var size: i64 = 0;
    if (win32.GetFileSizeEx(h, &size) == 0 or size <= keep) return;
    const tail = std.heap.page_allocator.alloc(u8, keep) catch return;
    defer std.heap.page_allocator.free(tail);
    if (win32.SetFilePointerEx(h, size - keep, null, win32.FILE_BEGIN) == 0) return;
    var got: u32 = 0;
    if (win32.ReadFile(h, tail.ptr, keep, &got, null) == 0) return;
    var rest = tail[0..got];
    if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| rest = rest[nl + 1 ..];
    if (win32.SetFilePointerEx(h, 0, null, win32.FILE_BEGIN) == 0) return;
    _ = win32.WriteFile(h, rest.ptr, @intCast(rest.len), null, null);
    _ = win32.SetEndOfFile(h);
}

/// `std.Options.logFn`: std's to stderr, and a line with the time to the
/// file.
pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    std.log.defaultLog(level, scope, format, args);
    const h = handle orelse return;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var t: win32.SYSTEMTIME = undefined;
    win32.GetLocalTime(&t);
    const prefix = comptime level.asText() ++ (if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ");
    const cut = "...\n";
    w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} " ++ prefix ++ format ++ "\n", .{
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds,
    } ++ args) catch {
        // Too long: what fits, marked as cut.
        @memcpy(buf[buf.len - cut.len ..], cut);
        w.end = buf.len;
    };
    _ = win32.WriteFile(h, w.buffered().ptr, @intCast(w.buffered().len), null, null);
}
