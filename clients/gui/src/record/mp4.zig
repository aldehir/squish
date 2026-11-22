//! An MP4 writer for a recording: frames of BGRA pixels in, each shown
//! for a time, and H.264 out, from the encoder Windows ships, through
//! Media Foundation's sink writer, which writes the file itself. Each
//! frame carries its own time and duration, so the file's frame rate
//! varies as the recording's does.
//!
//! All of it runs on the recording's thread: `startup` first, there,
//! and `shutdown` last.

const std = @import("std");
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const mf = win32.mf;

const log = std.log.scoped(.record);

/// CoInitializeEx's COINIT_MULTITHREADED.
const multithreaded = 0;

/// Unless it's told one, the file's budget is a bit a second for each
/// pixel of the picture, whatever the frame rate, within these: a
/// terminal's text stays sharp at rest down to about half this, and
/// smears below.
const min_bitrate = 250_000;
const max_bitrate = 8_000_000;

/// Media Foundation, for the calling thread. False if Windows has none
/// (an N edition without the Media Feature Pack).
pub fn startup() bool {
    if (win32.CoInitializeEx(null, multithreaded) < 0) return false;
    if (mf.MFStartup(mf.VERSION, mf.STARTUP_FULL) < 0) {
        win32.CoUninitialize();
        return false;
    }
    return true;
}

pub fn shutdown() void {
    _ = mf.MFShutdown();
    win32.CoUninitialize();
}

/// How the encoder spends bits.
pub const Rate = union(enum) {
    /// As many as each frame needs to look this good, 1 to 100: next to
    /// none for a screen at rest, and a scroll stays as sharp as the
    /// rest.
    quality: u32,
    /// This many a second on average, however much moves: a scroll
    /// softens to fit, and sharpens again at rest.
    bitrate: u32,
};

pub const Writer = struct {
    sink: *mf.ISinkWriter,
    stream: u32,
    width: u32,
    height: u32,
    /// The next frame's time, in 100 ns units, as Media Foundation
    /// counts.
    at: i64 = 0,

    /// Start the file at `path`, replacing what's there, for pictures
    /// `width` by `height` (both even: H.264 halves them for color) at
    /// about `fps` frames a second, spending bits as `rate` says. The GPU's encoder if it takes the
    /// format, else the software one.
    pub fn init(path: [:0]const u16, width: u32, height: u32, fps: u32, rate: Rate) com.Error!Writer {
        std.debug.assert(width % 2 == 0 and height % 2 == 0);
        return open(path, width, height, fps, rate, true) catch {
            log.info("no hardware encoder for {d} x {d}: trying software", .{ width, height });
            return open(path, width, height, fps, rate, false);
        };
    }

    fn open(path: [:0]const u16, width: u32, height: u32, fps: u32, rate: Rate, hardware: bool) com.Error!Writer {
        var attrs: ?*mf.IAttributes = null;
        try com.check(mf.MFCreateAttributes(&attrs, 2), "MFCreateAttributes");
        defer com.releaseOpt(&attrs);
        try com.check(attrs.?.setUINT32(&mf.MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, @intFromBool(hardware)), "SetUINT32(hardware)");
        try com.check(attrs.?.setUINT32(&mf.MF_SINK_WRITER_DISABLE_THROTTLING, 1), "SetUINT32(throttling)");
        var sink: ?*mf.ISinkWriter = null;
        try com.check(mf.MFCreateSinkWriterFromURL(path, null, attrs, &sink), "MFCreateSinkWriterFromURL");
        errdefer com.releaseOpt(&sink);

        // By quality, the budget is what an encoder that doesn't know
        // the mode falls back on.
        const bitrate: u32 = switch (rate) {
            .quality => @intCast(std.math.clamp(@as(u64, width) * height, min_bitrate, max_bitrate)),
            .bitrate => |b| b,
        };
        var target: ?*mf.IMediaType = null;
        try com.check(mf.MFCreateMediaType(&target), "MFCreateMediaType");
        defer com.releaseOpt(&target);
        try describe(target.?.attributes(), &mf.MFVideoFormat_H264, width, height, fps);
        try com.check(target.?.attributes().setUINT32(&mf.MF_MT_AVG_BITRATE, bitrate), "SetUINT32(bitrate)");
        var stream: u32 = 0;
        try com.check(sink.?.addStream(target.?, &stream), "IMFSinkWriter::AddStream");

        var input: ?*mf.IMediaType = null;
        try com.check(mf.MFCreateMediaType(&input), "MFCreateMediaType");
        defer com.releaseOpt(&input);
        try describe(input.?.attributes(), &mf.MFVideoFormat_RGB32, width, height, fps);
        // Our rows come from the top.
        try com.check(input.?.attributes().setUINT32(&mf.MF_MT_DEFAULT_STRIDE, width * 4), "SetUINT32(stride)");
        // The encoder's own settings go with its input.
        var encoding: ?*mf.IAttributes = null;
        defer com.releaseOpt(&encoding);
        switch (rate) {
            .quality => |q| {
                try com.check(mf.MFCreateAttributes(&encoding, 2), "MFCreateAttributes");
                try com.check(encoding.?.setUINT32(&mf.CODECAPI_AVEncCommonRateControlMode, mf.eAVEncCommonRateControlMode_Quality), "SetUINT32(rate control)");
                try com.check(encoding.?.setUINT32(&mf.CODECAPI_AVEncCommonQuality, std.math.clamp(q, 1, 100)), "SetUINT32(quality)");
            },
            .bitrate => {},
        }
        try com.check(sink.?.setInputMediaType(stream, input.?, encoding), "IMFSinkWriter::SetInputMediaType");
        try com.check(sink.?.beginWriting(), "IMFSinkWriter::BeginWriting");
        return .{ .sink = sink.?, .stream = stream, .width = width, .height = height };
    }

    /// What the stored format and the one the frames come in share.
    fn describe(t: *mf.IAttributes, subtype: *const win32.GUID, width: u32, height: u32, fps: u32) com.Error!void {
        try com.check(t.setGUID(&mf.MF_MT_MAJOR_TYPE, &mf.MFMediaType_Video), "SetGUID(major type)");
        try com.check(t.setGUID(&mf.MF_MT_SUBTYPE, subtype), "SetGUID(subtype)");
        try com.check(t.setUINT32(&mf.MF_MT_INTERLACE_MODE, mf.MFVideoInterlace_Progressive), "SetUINT32(interlace)");
        try com.check(t.setUINT64(&mf.MF_MT_FRAME_SIZE, mf.pair(width, height)), "SetUINT64(frame size)");
        try com.check(t.setUINT64(&mf.MF_MT_FRAME_RATE, mf.pair(fps, 1)), "SetUINT64(frame rate)");
        try com.check(t.setUINT64(&mf.MF_MT_PIXEL_ASPECT_RATIO, mf.pair(1, 1)), "SetUINT64(pixel aspect)");
    }

    /// Release the writer. A file not finished is left as it is, for the
    /// caller to delete.
    pub fn deinit(self: *Writer) void {
        com.release(self.sink);
        self.* = undefined;
    }

    /// A frame, `width * height * 4` bytes of BGRA from the top, shown
    /// for `duration_ms`.
    pub fn frame(self: *Writer, pixels: []const u8, duration_ms: u32) com.Error!void {
        std.debug.assert(pixels.len == @as(usize, self.width) * self.height * 4);
        const len: u32 = @intCast(pixels.len);
        var buffer: ?*mf.IMediaBuffer = null;
        try com.check(mf.MFCreateMemoryBuffer(len, &buffer), "MFCreateMemoryBuffer");
        defer com.releaseOpt(&buffer);
        var data: ?[*]u8 = null;
        try com.check(buffer.?.lock(&data), "IMFMediaBuffer::Lock");
        @memcpy(data.?[0..pixels.len], pixels);
        _ = buffer.?.unlock();
        try com.check(buffer.?.setCurrentLength(len), "IMFMediaBuffer::SetCurrentLength");

        var sample: ?*mf.ISample = null;
        try com.check(mf.MFCreateSample(&sample), "MFCreateSample");
        defer com.releaseOpt(&sample);
        try com.check(sample.?.addBuffer(buffer.?), "IMFSample::AddBuffer");
        // A frame shown for no time at all would be none.
        const duration = @as(i64, @max(1, duration_ms)) * 10_000;
        try com.check(sample.?.setSampleTime(self.at), "IMFSample::SetSampleTime");
        try com.check(sample.?.setSampleDuration(duration), "IMFSample::SetSampleDuration");
        try com.check(self.sink.writeSample(self.stream, sample.?), "IMFSinkWriter::WriteSample");
        self.at += duration;
    }

    /// Encode what's left and close the file.
    pub fn finish(self: *Writer) com.Error!void {
        try com.check(self.sink.finalize(), "IMFSinkWriter::Finalize");
    }
};
