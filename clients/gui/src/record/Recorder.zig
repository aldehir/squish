//! One recording of a terminal pane, from its start to its file closed.
//! The renderer hands it the pane's pixels on the frames it asks for
//! (`due`, `push`), on the UI thread, which never waits for the file: a
//! thread of the recording's own takes the frames from a short queue,
//! encodes them (`gif.zig`, or `mp4.zig`, whose encoder writes the file
//! itself), and writes them out. When the thread has
//! closed the file, or given up, it posts WM_APP_RECORD_DONE, and the
//! UI thread frees the recording (`deinit`).
//!
//! The thread follows the readers' rule: it never calls anything that
//! waits on the UI thread, and posts instead.
const Recorder = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("../win32/win32.zig");
const binding = @import("../binding.zig");
const messages = @import("../messages.zig");
const gif = @import("gif.zig");
const mp4 = @import("mp4.zig");

const log = std.log.scoped(.record);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

alloc: Allocator,
format: binding.RecordFormat,
/// Absolute. Empty with no file (tests). Deleted if the recording fails.
path: [:0]const u16,
/// The session recorded: its pane closing stops the recording.
session: u32,
/// The picture's size, fixed at the start: a pane resized later is
/// cropped, or padded with `background` at the right and bottom. Even
/// for an MP4, by a pixel less: H.264 halves both for color.
width: u32,
height: u32,
/// BGRA.
background: [4]u8,
opts: Options,

// The UI thread's.
/// QueryPerformanceCounter ticks a second, and between captures.
freq: i64,
interval: i64,
/// When a capture was last taken, whether or not it made a frame, and
/// when the last frame was.
last_capture: ?i64 = null,
last_frame: i64,
/// The time of the last frame in the file's terms: the time since the
/// start, less what the idle cut took out.
media_ms: u64 = 0,
/// The last frame pushed, to drop a capture that changed nothing, and
/// where the next is put together.
prev: []u8,
scratch: []u8,
have_prev: bool = false,
/// The last capture found the queue full: the window asks again soon,
/// so the picture before a pause isn't lost.
retry: bool = false,
/// The next draw captures, whatever the time since the last: the frame
/// the window takes just before `stop`, so the file ends as the screen
/// was.
last: bool = false,
/// `stop` was called: no more frames are wanted.
stopped: bool = false,

// Shared, under `lock`.
lock: win32.SRWLOCK = .{},
queue: Queue = .{},
state: State = .running,
stats: Stats = .{},
/// The time the last frame's showing ends, set by `stop`.
end_ms: u64 = 0,

/// Set when a frame is queued or the state changes: wakes the thread.
wake: win32.HANDLE,
thread: ?std.Thread = null,
/// Posted WM_APP_RECORD_DONE when the thread is done. Null in tests.
hwnd: ?win32.HWND,

// The thread's.
encoder: Encoder,
file: ?win32.HANDLE,

pub const Options = struct {
    /// The most captures a second.
    fps: u32 = 30,
    /// A gap between frames longer than this is cut to it; 0 keeps real
    /// time.
    idle_ms: u32 = 3000,
    /// The window stops the recording after this long; 0 never.
    limit_ms: u32 = 600_000,
};

pub const State = enum { running, finishing, done, failed };

pub const Stats = struct { frames: u32 = 0, dropped: u32 = 0, bytes: u64 = 0 };

/// A frame waiting for the encoder: `width * height * 4` bytes of BGRA
/// from the top, cropped or padded to the picture's size.
pub const FrameBuf = struct { at_ms: u64, pixels: []u8 };

/// At most `capacity` frames wait; a push that finds it full drops its
/// frame (`stats.dropped`), and the one before shows for longer.
pub const Queue = struct {
    pub const capacity = 8;
    items: [capacity]FrameBuf = undefined,
    head: u8 = 0,
    len: u8 = 0,

    fn put(self: *Queue, f: FrameBuf) void {
        self.items[(self.head + self.len) % capacity] = f;
        self.len += 1;
    }

    fn pop(self: *Queue) ?FrameBuf {
        if (self.len == 0) return null;
        const f = self.items[self.head];
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        return f;
    }
};

/// What a format's writer does. A frame's time on screen is known only
/// when the next one comes, so each `frame` says how long it's shown.
const Encoder = union(enum) {
    /// An MP4's, before the thread has made it and once it has let it
    /// go: Media Foundation's objects are the thread's alone.
    none,
    gif: gif.Writer,
    mp4: mp4.Writer,
    stub: *Stub,

    fn frame(self: *Encoder, pixels: []const u8, duration_ms: u32) !void {
        switch (self.*) {
            .none => return error.NoEncoder,
            .gif => |*w| try w.frame(pixels, duration_ms),
            .mp4 => |*w| try w.frame(pixels, duration_ms),
            .stub => |s| try s.frame(pixels, duration_ms),
        }
    }

    fn finish(self: *Encoder) !void {
        switch (self.*) {
            .none => return error.NoEncoder,
            .gif => |*w| try w.finish(),
            .mp4 => |*w| try w.finish(),
            .stub => |s| s.finished = true,
        }
    }

    /// The file's bytes since the last call, from an encoder that
    /// leaves the writing to us.
    fn take(self: *Encoder) []const u8 {
        return switch (self.*) {
            .gif => |*w| w.take(),
            .none, .mp4, .stub => &.{},
        };
    }

    fn deinit(self: *Encoder) void {
        switch (self.*) {
            .gif => |*w| w.deinit(),
            .mp4 => |*w| w.deinit(),
            .none, .stub => {},
        }
        self.* = .none;
    }
};

/// An encoder that keeps what it's given, for tests.
pub const Stub = struct {
    alloc: Allocator,
    calls: std.ArrayList(Call) = .empty,
    finished: bool = false,
    /// The frame, from 0, that fails.
    fail_at: ?usize = null,

    pub const Call = struct { duration_ms: u32, pixels: []u8 };

    pub fn deinit(self: *Stub) void {
        for (self.calls.items) |c| self.alloc.free(c.pixels);
        self.calls.deinit(self.alloc);
    }

    fn frame(self: *Stub, pixels: []const u8, duration_ms: u32) !void {
        if (self.fail_at == self.calls.items.len) return error.StubFailed;
        const copy = try self.alloc.dupe(u8, pixels);
        errdefer self.alloc.free(copy);
        try self.calls.append(self.alloc, .{ .duration_ms = duration_ms, .pixels = copy });
    }
};

pub const Init = struct {
    alloc: Allocator,
    format: binding.RecordFormat = .gif,
    /// The file, open for writing, and its path (copied). The recording
    /// closes it, and deletes it if it fails; if `create` fails it's
    /// still the caller's. An MP4 has the path alone: its encoder makes
    /// the file there, over what there is.
    file: ?win32.HANDLE = null,
    path: []const u16 = &.{},
    session: u32,
    width: u32,
    height: u32,
    background: [4]u8,
    opts: Options = .{},
    hwnd: ?win32.HWND = null,
    /// The clock: now, and its ticks a second.
    now: i64,
    freq: i64,
    /// Tests: encode into this, and with `thread` false call `run`
    /// themselves, after `stop`.
    stub: ?*Stub = null,
    thread: bool = true,
};

pub const Error = Allocator.Error || std.Thread.SpawnError || error{ TooLarge, Win32 };

/// Start a recording. The first frame is the first `push`.
pub fn create(init: Init) Error!*Recorder {
    const alloc = init.alloc;
    const even: u32 = if (init.format == .mp4) 1 else 0;
    const width = init.width & ~even;
    const height = init.height & ~even;
    if (width == 0 or height == 0) return error.TooLarge;
    if (init.format == .gif and (width > gif.max_size or height > gif.max_size)) return error.TooLarge;
    const self = try alloc.create(Recorder);
    errdefer alloc.destroy(self);
    const path = try alloc.dupeSentinel(u16, init.path, 0);
    errdefer alloc.free(path);
    const size = @as(usize, width) * height * 4;
    const prev = try alloc.alloc(u8, size);
    errdefer alloc.free(prev);
    const scratch = try alloc.alloc(u8, size);
    errdefer alloc.free(scratch);
    var encoder: Encoder = if (init.stub) |s| .{ .stub = s } else switch (init.format) {
        .gif => .{ .gif = try .init(alloc, @intCast(width), @intCast(height)) },
        // The thread's to make (`run`).
        .mp4 => .none,
    };
    errdefer encoder.deinit();
    const wake = win32.CreateEventW(null, win32.FALSE, win32.FALSE, null) orelse return win32.lastError("CreateEventW");
    errdefer _ = win32.CloseHandle(wake);

    // A GIF's delays are centiseconds, and none is under two.
    const fps = std.math.clamp(init.opts.fps, 1, 60);
    const least: i64 = if (init.format == .gif) @divTrunc(init.freq, 50) else 0;
    self.* = .{
        .alloc = alloc,
        .format = init.format,
        .path = path,
        .session = init.session,
        .width = width,
        .height = height,
        .background = init.background,
        .opts = init.opts,
        .freq = init.freq,
        .interval = @max(least, @divTrunc(init.freq, fps)),
        .last_frame = init.now,
        .prev = prev,
        .scratch = scratch,
        .wake = wake,
        .hwnd = init.hwnd,
        .encoder = encoder,
        .file = init.file,
    };
    if (init.thread) self.thread = try std.Thread.spawn(.{}, run, .{self});
    return self;
}

/// After WM_APP_RECORD_DONE; or any time, which stops the recording and
/// waits for the thread to close the file (the window going).
pub fn deinit(self: *Recorder) void {
    self.stop(self.last_capture orelse self.last_frame);
    if (self.thread) |t| t.join();
    // Not run at all: a test that never called `run`.
    while (self.queue.pop()) |f| self.alloc.free(f.pixels);
    if (self.file) |h| _ = win32.CloseHandle(h);
    self.encoder.deinit();
    _ = win32.CloseHandle(self.wake);
    self.alloc.free(self.prev);
    self.alloc.free(self.scratch);
    self.alloc.free(self.path);
    self.alloc.destroy(self);
}

/// The clock recordings run on, and its ticks a second.
pub fn now() i64 {
    var t: i64 = undefined;
    _ = win32.QueryPerformanceCounter(&t);
    return t;
}

pub fn frequency() i64 {
    var f: i64 = undefined;
    _ = win32.QueryPerformanceFrequency(&f);
    return f;
}

fn ms(self: *const Recorder, ticks: i64) u64 {
    return @intCast(@divTrunc(@max(0, ticks) * 1000, self.freq));
}

/// Whether a draw at `at` should capture: the recording goes on, and
/// its time between frames has passed since the last capture.
pub fn due(self: *const Recorder, at: i64) bool {
    if (self.stopped) return false;
    if (self.last) return true;
    const last = self.last_capture orelse return true;
    return at - last >= self.interval;
}

/// Milliseconds from `at` until a capture is due, at least one: what
/// the window's timer waits when a draw came too soon.
pub fn wait(self: *const Recorder, at: i64) u32 {
    const last = self.last_capture orelse return 1;
    return @intCast(std.math.clamp(self.ms(self.interval - (at - last)), 1, 1000));
}

/// How long a frame taken `ticks` after the one before follows it in
/// the file: as long, up to the idle cut.
fn gap(self: *const Recorder, ticks: i64) u64 {
    const real = self.ms(ticks);
    return if (self.opts.idle_ms > 0) @min(real, self.opts.idle_ms) else real;
}

/// A capture, at `at`: `h` rows of `w` BGRA pixels, `pitch` bytes
/// apart, valid only for the call. Queued for the thread unless nothing
/// changed since the last, or the queue is full. Never waits.
pub fn push(self: *Recorder, src: [*]const u8, pitch: u32, w: u32, h: u32, at: i64) void {
    if (self.stopped) return;
    self.last_capture = at;
    self.retry = false;
    // The pane as it is now, in the picture's size.
    const row_len = @as(usize, self.width) * 4;
    const copy = @as(usize, @min(w, self.width)) * 4;
    for (0..self.height) |y| {
        const row = self.scratch[y * row_len ..][0..row_len];
        const have = if (y < h) copy else 0;
        if (have > 0) @memcpy(row[0..have], src[y * @as(usize, pitch) ..][0..have]);
        var x = have;
        while (x < row_len) : (x += 4) row[x..][0..4].* = self.background;
    }
    if (self.have_prev and std.mem.eql(u8, self.scratch, self.prev)) return;

    win32.AcquireSRWLockExclusive(&self.lock);
    const open = self.state == .running;
    const full = self.queue.len == Queue.capacity;
    if (open and full) self.stats.dropped += 1;
    win32.ReleaseSRWLockExclusive(&self.lock);
    // The thread gave up: the window hears of it by message.
    if (!open) return;
    if (full) {
        self.retry = true;
        return;
    }
    const pixels = self.alloc.dupe(u8, self.scratch) catch {
        self.retry = true;
        return;
    };
    if (self.have_prev) self.media_ms += self.gap(at - self.last_frame);
    self.last_frame = at;
    std.mem.swap([]u8, &self.prev, &self.scratch);
    self.have_prev = true;

    win32.AcquireSRWLockExclusive(&self.lock);
    // Only the thread takes from the queue, so there's still room.
    self.queue.put(.{ .at_ms = self.media_ms, .pixels = pixels });
    self.stats.frames += 1;
    win32.ReleaseSRWLockExclusive(&self.lock);
    _ = win32.SetEvent(self.wake);
}

/// No more frames, as of `at`: the thread encodes what's queued, closes
/// the file, and posts. Returns at once. Again does nothing.
pub fn stop(self: *Recorder, at: i64) void {
    if (self.stopped) return;
    self.stopped = true;
    win32.AcquireSRWLockExclusive(&self.lock);
    if (self.state == .running) {
        self.state = .finishing;
        self.end_ms = self.media_ms + self.gap(at - self.last_frame);
    }
    win32.ReleaseSRWLockExclusive(&self.lock);
    _ = win32.SetEvent(self.wake);
}

/// What became of it, once the thread is done; null until then.
pub fn result(self: *Recorder) ?State {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    return switch (self.state) {
        .running, .finishing => null,
        .done, .failed => self.state,
    };
}

pub fn counts(self: *Recorder) Stats {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    return self.stats;
}

/// The thread: frames from the queue into the file until the recording
/// is stopped and the queue empty, or something fails. One frame is
/// held back, waiting for the next to say how long it showed.
pub fn run(self: *Recorder) void {
    var held: ?FrameBuf = null;
    var failed = false;
    var end_ms: u64 = 0;
    // An MP4's encoder is Media Foundation's, made and let go here.
    const media = self.encoder == .none and mp4.startup();
    defer if (media) mp4.shutdown();
    if (self.encoder == .none) {
        if (!media) {
            log.warn("Windows has no Media Foundation here (an N edition needs the Media Feature Pack): no MP4", .{});
            failed = true;
        } else if (mp4.Writer.init(self.path, self.width, self.height, std.math.clamp(self.opts.fps, 1, 60))) |w| {
            self.encoder = .{ .mp4 = w };
        } else |err| {
            log.warn("no H.264 encoder took {d} x {d}: {}", .{ self.width, self.height, err });
            failed = true;
        }
    }
    while (!failed) {
        win32.AcquireSRWLockExclusive(&self.lock);
        const next = self.queue.pop();
        const finishing = self.state != .running;
        end_ms = self.end_ms;
        win32.ReleaseSRWLockExclusive(&self.lock);
        const f = next orelse {
            if (finishing) break;
            _ = win32.WaitForSingleObject(self.wake, win32.INFINITE);
            continue;
        };
        if (held) |h| {
            failed = !self.encode(h, f.at_ms);
            self.alloc.free(h.pixels);
        }
        held = f;
    }
    if (held) |h| {
        if (!failed) failed = !self.encode(h, end_ms);
        self.alloc.free(h.pixels);
    }
    if (!failed) {
        if (self.encoder.finish()) |_| {
            failed = !self.write(self.encoder.take());
        } else |err| {
            log.warn("finishing the recording failed: {}", .{err});
            failed = true;
        }
    }
    if (self.file) |h| _ = win32.CloseHandle(h);
    self.file = null;
    // Its encoder wrote the file: what's there is what it came to.
    const wrote: u64 = if (self.encoder == .mp4 and !failed) fileSize(self.path) else 0;
    if (self.encoder == .mp4) self.encoder.deinit();

    win32.AcquireSRWLockExclusive(&self.lock);
    self.stats.bytes += wrote;
    // Nothing was drawn while it ran: there's no picture to keep.
    const empty = self.stats.frames == 0;
    self.state = if (failed or empty) .failed else .done;
    // What came after a failure.
    while (self.queue.pop()) |f| self.alloc.free(f.pixels);
    const stats = self.stats;
    win32.ReleaseSRWLockExclusive(&self.lock);

    if (failed or empty) {
        if (self.path.len > 0) _ = win32.DeleteFileW(self.path);
        if (empty and !failed) log.info("nothing was recorded", .{});
    } else log.info("recorded {d} frames ({d} dropped), {d} bytes: {f}", .{ stats.frames, stats.dropped, stats.bytes, std.unicode.fmtUtf16Le(self.path) });
    if (self.hwnd) |hwnd| _ = win32.PostMessageW(hwnd, messages.WM_APP_RECORD_DONE, 0, @bitCast(@intFromPtr(self)));
}

/// Frame `f`, shown until `until_ms`, into the file. False if it failed,
/// which is logged.
fn encode(self: *Recorder, f: FrameBuf, until_ms: u64) bool {
    const duration: u32 = @intCast(@min(until_ms -| f.at_ms, std.math.maxInt(u32)));
    self.encoder.frame(f.pixels, duration) catch |err| {
        log.warn("encoding a frame failed: {}", .{err});
        return false;
    };
    return self.write(self.encoder.take());
}

fn fileSize(path: [:0]const u16) u64 {
    var info: win32.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (win32.GetFileAttributesExW(path, win32.GetFileExInfoStandard, &info) == 0) return 0;
    return @as(u64, info.nFileSizeHigh) << 32 | info.nFileSizeLow;
}

fn write(self: *Recorder, bytes: []const u8) bool {
    const h = self.file orelse return true;
    var rest = bytes;
    while (rest.len > 0) {
        var n: u32 = 0;
        if (win32.WriteFile(h, rest.ptr, @intCast(@min(rest.len, 1 << 30)), &n, null) == 0 or n == 0) {
            log.warn("writing the recording failed: GetLastError={d}", .{win32.GetLastError()});
            return false;
        }
        rest = rest[n..];
    }
    win32.AcquireSRWLockExclusive(&self.lock);
    self.stats.bytes += bytes.len;
    win32.ReleaseSRWLockExclusive(&self.lock);
    return true;
}

pub const File = struct {
    /// Owned by the caller.
    path: [:0]u16,
    handle: win32.HANDLE,
};

/// Make the file for a recording that starts now, open for writing:
/// `squish-<YYYYMMDD>-<HHMMSS>.<format>` in `dir` (UTF-8, absolute), or
/// in `squish` under the user's Videos; a second in the same second gets
/// `-2`. The directory is made if it isn't there. Why it failed is
/// logged here.
pub fn openFile(alloc: Allocator, dir: ?[]const u8, format: binding.RecordFormat) !File {
    var path: std.ArrayList(u16) = .empty;
    defer path.deinit(alloc);
    if (dir) |d| {
        const wide = try std.unicode.utf8ToUtf16LeAlloc(alloc, d);
        defer alloc.free(wide);
        try path.appendSlice(alloc, wide);
        for (path.items) |*c| if (c.* == '/') {
            c.* = '\\';
        };
    } else {
        var videos: ?[*:0]u16 = null;
        defer win32.CoTaskMemFree(videos);
        if (win32.SHGetKnownFolderPath(&win32.FOLDERID_Videos, 0, null, &videos) < 0) {
            log.warn("the user's Videos folder isn't known: set record.dir", .{});
            return error.NoDirectory;
        }
        try path.appendSlice(alloc, std.mem.span(videos.?));
        try path.appendSlice(alloc, L("\\squish"));
    }
    while (path.items.len > 3 and path.items[path.items.len - 1] == '\\') path.items.len -= 1;
    {
        try path.append(alloc, 0);
        defer path.items.len -= 1;
        const made = win32.SHCreateDirectoryExW(null, @ptrCast(path.items.ptr), null);
        if (made != 0 and made != win32.ERROR_FILE_EXISTS and made != win32.ERROR_ALREADY_EXISTS) {
            log.warn("making {f} failed: error {d}", .{ std.unicode.fmtUtf16Le(path.items[0 .. path.items.len - 1]), made });
            return error.NoDirectory;
        }
    }
    var t: win32.SYSTEMTIME = undefined;
    win32.GetLocalTime(&t);
    const dir_len = path.items.len;
    var n: u32 = 1;
    while (n < 100) : (n += 1) {
        path.items.len = dir_len;
        var buf: [64]u8 = undefined;
        var suffix: [8]u8 = undefined;
        const again = if (n > 1) std.fmt.bufPrint(&suffix, "-{d}", .{n}) catch unreachable else "";
        const name = std.fmt.bufPrint(&buf, "\\squish-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}{s}.{t}", .{
            t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, again, format,
        }) catch unreachable;
        for (name) |c| try path.append(alloc, c);
        try path.append(alloc, 0);
        const h = win32.CreateFileW(@ptrCast(path.items.ptr), win32.GENERIC_WRITE, win32.FILE_SHARE_READ, null, win32.CREATE_NEW, win32.FILE_ATTRIBUTE_NORMAL, null);
        if (h != win32.INVALID_HANDLE_VALUE) {
            errdefer {
                _ = win32.CloseHandle(h);
                _ = win32.DeleteFileW(@ptrCast(path.items.ptr));
            }
            path.items.len -= 1;
            return .{ .path = try path.toOwnedSliceSentinel(alloc, 0), .handle = h };
        }
        if (win32.GetLastError() != win32.ERROR_FILE_EXISTS) return win32.lastError("CreateFileW");
    }
    log.warn("too many recordings this second", .{});
    return error.TooManyFiles;
}

/// A recorder of a `w` x `h` picture on black, with a clock in
/// milliseconds from 0, no file, and no thread.
fn testRecorder(stub: *Stub, w: u32, h: u32, opts: Options) !*Recorder {
    return create(.{
        .alloc = std.testing.allocator,
        .session = 1,
        .width = w,
        .height = h,
        .background = .{ 0, 0, 0, 255 },
        .opts = opts,
        .now = 0,
        .freq = 1000,
        .stub = stub,
        .thread = false,
    });
}

/// `w` x `h` pixels of `color`, with no padding between rows.
fn fill(buf: []u8, color: [4]u8) void {
    var i: usize = 0;
    while (i < buf.len) : (i += 4) buf[i..][0..4].* = color;
}

test "the same pixels twice is one frame, and a frame shows until the next" {
    var stub: Stub = .{ .alloc = std.testing.allocator };
    defer stub.deinit();
    const r = try testRecorder(&stub, 2, 2, .{});
    defer r.deinit();
    var px: [16]u8 = undefined;
    fill(&px, .{ 1, 2, 3, 255 });
    try std.testing.expect(r.due(0));
    r.push(&px, 8, 2, 2, 0);
    // Too soon for the next, at 30 a second.
    try std.testing.expect(!r.due(20));
    try std.testing.expectEqual(13, r.wait(20));
    // But for the one before it stops.
    r.last = true;
    try std.testing.expect(r.due(20));
    r.last = false;
    try std.testing.expect(r.due(34));
    r.push(&px, 8, 2, 2, 40);
    fill(&px, .{ 9, 9, 9, 255 });
    r.push(&px, 8, 2, 2, 100);
    r.push(&px, 8, 2, 2, 150);
    r.stop(400);
    try std.testing.expect(!r.due(1000));
    try std.testing.expectEqual(null, r.result());
    r.run();
    try std.testing.expectEqual(State.done, r.result().?);
    try std.testing.expectEqual(2, r.counts().frames);
    try std.testing.expectEqual(2, stub.calls.items.len);
    try std.testing.expectEqual(100, stub.calls.items[0].duration_ms);
    try std.testing.expectEqual(300, stub.calls.items[1].duration_ms);
    try std.testing.expectEqual([4]u8{ 9, 9, 9, 255 }, stub.calls.items[1].pixels[0..4].*);
    try std.testing.expect(stub.finished);
}

test "a full queue drops and counts, and asks to be tried again" {
    var stub: Stub = .{ .alloc = std.testing.allocator };
    defer stub.deinit();
    const r = try testRecorder(&stub, 1, 1, .{});
    defer r.deinit();
    var at: i64 = 0;
    for (0..Queue.capacity + 2) |i| {
        const px: [4]u8 = .{ @intCast(i), 0, 0, 255 };
        r.push(&px, 4, 1, 1, at);
        at += 50;
        try std.testing.expectEqual(i >= Queue.capacity, r.retry);
    }
    try std.testing.expectEqual(Queue.capacity, r.counts().frames);
    try std.testing.expectEqual(2, r.counts().dropped);
    r.stop(at);
    r.run();
    try std.testing.expectEqual(Queue.capacity, stub.calls.items.len);
    // The last one kept shows through the two that weren't.
    try std.testing.expectEqual(150, stub.calls.items[Queue.capacity - 1].duration_ms);
}

test "a gap over idle is cut to it, between frames and at the end" {
    var stub: Stub = .{ .alloc = std.testing.allocator };
    defer stub.deinit();
    const r = try testRecorder(&stub, 1, 1, .{ .idle_ms = 3000 });
    defer r.deinit();
    r.push(&[4]u8{ 1, 0, 0, 255 }, 4, 1, 1, 0);
    r.push(&[4]u8{ 2, 0, 0, 255 }, 4, 1, 1, 60_000);
    r.push(&[4]u8{ 3, 0, 0, 255 }, 4, 1, 1, 61_000);
    r.stop(100_000);
    r.run();
    var got: [3]u32 = undefined;
    for (stub.calls.items, &got) |c, *g| g.* = c.duration_ms;
    try std.testing.expectEqualSlices(u32, &.{ 3000, 1000, 3000 }, &got);

    // With no cut, real time.
    var real: Stub = .{ .alloc = std.testing.allocator };
    defer real.deinit();
    const k = try testRecorder(&real, 1, 1, .{ .idle_ms = 0 });
    defer k.deinit();
    k.push(&[4]u8{ 1, 0, 0, 255 }, 4, 1, 1, 0);
    k.stop(60_000);
    k.run();
    try std.testing.expectEqual(60_000, real.calls.items[0].duration_ms);
}

test "a smaller frame is padded with the background, a larger one cropped" {
    var stub: Stub = .{ .alloc = std.testing.allocator };
    defer stub.deinit();
    const r = try testRecorder(&stub, 2, 2, .{});
    defer r.deinit();
    const bg: [4]u8 = .{ 0, 0, 0, 255 };
    const a: [4]u8 = .{ 10, 20, 30, 255 };
    // One pixel, then a 3 x 3 with rows 16 bytes apart.
    r.push(&a, 4, 1, 1, 0);
    var big: [48]u8 = undefined;
    for (0..3) |y| for (0..4) |x| {
        big[y * 16 + x * 4 ..][0..4].* = .{ @intCast(y), @intCast(x), 7, 255 };
    };
    r.push(&big, 16, 3, 3, 100);
    r.stop(200);
    r.run();
    try std.testing.expectEqualSlices(u8, &(a ++ bg ++ bg ++ bg), stub.calls.items[0].pixels);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 7, 255, 0, 1, 7, 255, 1, 0, 7, 255, 1, 1, 7, 255 }, stub.calls.items[1].pixels);
}

test "an encoder that fails ends the recording, and nothing recorded is no file" {
    var stub: Stub = .{ .alloc = std.testing.allocator, .fail_at = 1 };
    defer stub.deinit();
    const r = try testRecorder(&stub, 1, 1, .{});
    defer r.deinit();
    for (0..3) |i| r.push(&[4]u8{ @intCast(i), 0, 0, 255 }, 4, 1, 1, @intCast(i * 100));
    r.stop(300);
    r.run();
    try std.testing.expectEqual(State.failed, r.result().?);
    try std.testing.expect(!stub.finished);

    var none: Stub = .{ .alloc = std.testing.allocator };
    defer none.deinit();
    const k = try testRecorder(&none, 1, 1, .{});
    defer k.deinit();
    k.stop(10);
    k.run();
    try std.testing.expectEqual(State.failed, k.result().?);

    try std.testing.expectError(error.TooLarge, testRecorder(&none, 70_000, 1, .{}));
}

test "an MP4's picture is even each way, a pixel cropped" {
    var stub: Stub = .{ .alloc = std.testing.allocator };
    defer stub.deinit();
    const r = try create(.{
        .alloc = std.testing.allocator,
        .format = .mp4,
        .session = 1,
        .width = 5,
        .height = 3,
        .background = .{ 0, 0, 0, 255 },
        .now = 0,
        .freq = 1000,
        .stub = &stub,
        .thread = false,
    });
    defer r.deinit();
    try std.testing.expectEqual([2]u32{ 4, 2 }, [2]u32{ r.width, r.height });
    var px: [60]u8 = undefined;
    fill(&px, .{ 1, 2, 3, 255 });
    r.push(&px, 20, 5, 3, 0);
    r.stop(100);
    r.run();
    try std.testing.expectEqual(State.done, r.result().?);
    try std.testing.expectEqual(4 * 2 * 4, stub.calls.items[0].pixels.len);
    // One pixel of a picture is none.
    try std.testing.expectError(error.TooLarge, create(.{ .alloc = std.testing.allocator, .format = .mp4, .session = 1, .width = 1, .height = 8, .background = .{ 0, 0, 0, 255 }, .now = 0, .freq = 1000, .stub = &stub, .thread = false }));
}

test "a recording on its thread writes a GIF and deletes nothing it finished" {
    const r = try create(.{
        .alloc = std.testing.allocator,
        .session = 1,
        .width = 4,
        .height = 4,
        .background = .{ 0, 0, 0, 255 },
        .now = 0,
        .freq = 1000,
    });
    var px: [64]u8 = undefined;
    for (0..5) |i| {
        fill(&px, .{ @intCast(i * 40), 0, 0, 255 });
        r.push(&px, 16, 4, 4, @intCast(i * 100));
    }
    // Stops, and waits for the thread.
    r.deinit();
}

test {
    _ = gif;
}
