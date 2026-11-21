//! Media Foundation, for the H.264 encoder Windows ships: a sink writer
//! that takes frames and writes an MP4 (`record/mp4.zig`). Slot numbers
//! and GUIDs are from mingw's mfobjects.h, mfreadwrite.h, and mfapi.h.

const win32 = @import("win32.zig");
const com = @import("com.zig");

const HRESULT = win32.HRESULT;
const GUID = win32.GUID;

/// MF_VERSION: MF_SDK_VERSION 2 over MF_API_VERSION 0x70.
pub const VERSION = 0x0002_0070;
pub const STARTUP_FULL = 0;

pub extern "mfplat" fn MFStartup(u32, u32) callconv(.winapi) HRESULT;
pub extern "mfplat" fn MFShutdown() callconv(.winapi) HRESULT;
pub extern "mfplat" fn MFCreateMediaType(*?*IMediaType) callconv(.winapi) HRESULT;
pub extern "mfplat" fn MFCreateSample(*?*ISample) callconv(.winapi) HRESULT;
pub extern "mfplat" fn MFCreateMemoryBuffer(u32, *?*IMediaBuffer) callconv(.winapi) HRESULT;
pub extern "mfplat" fn MFCreateAttributes(*?*IAttributes, u32) callconv(.winapi) HRESULT;
/// The container is the one the URL's extension names.
pub extern "mfreadwrite" fn MFCreateSinkWriterFromURL(?[*:0]const u16, ?*anyopaque, ?*IAttributes, *?*ISinkWriter) callconv(.winapi) HRESULT;

fn guid(data1: u32, data2: u16, data3: u16, data4: [8]u8) GUID {
    return .{ .data1 = data1, .data2 = data2, .data3 = data3, .data4 = data4 };
}

/// A media subtype by its FourCC or D3DFORMAT (DEFINE_MEDIATYPE_GUID).
fn mediaType(format: u32) GUID {
    return guid(format, 0x0000, 0x0010, .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 });
}

pub const MFMediaType_Video = mediaType(0x73646976);
/// 'H264'.
pub const MFVideoFormat_H264 = mediaType(0x34363248);
/// D3DFMT_X8R8G8B8: BGRA in memory, the fourth byte unused.
pub const MFVideoFormat_RGB32 = mediaType(22);

pub const MF_MT_MAJOR_TYPE = guid(0x48eba18e, 0xf8c9, 0x4687, .{ 0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f });
pub const MF_MT_SUBTYPE = guid(0xf7e34c9a, 0x42e8, 0x4714, .{ 0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5 });
/// Bits a second.
pub const MF_MT_AVG_BITRATE = guid(0x20332624, 0xfb0d, 0x4d9e, .{ 0xbd, 0x0d, 0xcb, 0xf6, 0x78, 0x6c, 0x10, 0x2e });
pub const MF_MT_INTERLACE_MODE = guid(0xe2724bb8, 0xe676, 0x4806, .{ 0xb4, 0xb2, 0xa8, 0xd6, 0xef, 0xb4, 0x4c, 0xcd });
/// The three below are pairs in a UINT64 (`pair`): width and height,
/// frames over seconds, and a pixel's width over its height.
pub const MF_MT_FRAME_SIZE = guid(0x1652c33d, 0xd6b2, 0x4012, .{ 0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d });
pub const MF_MT_FRAME_RATE = guid(0xc459a2e8, 0x3d2c, 0x4e44, .{ 0xb1, 0x32, 0xfe, 0xe5, 0x15, 0x6c, 0x7b, 0xb0 });
pub const MF_MT_PIXEL_ASPECT_RATIO = guid(0xc6376a1e, 0x8d0a, 0x4027, .{ 0xbe, 0x45, 0x6d, 0x9a, 0x0a, 0xd3, 0x9b, 0xb6 });
/// Bytes from a row to the next: positive for rows from the top, which
/// RGB isn't unless this says so.
pub const MF_MT_DEFAULT_STRIDE = guid(0x644b4e48, 0x1e02, 0x4516, .{ 0xb0, 0xeb, 0xc0, 0x1c, 0xa9, 0xd4, 0x9a, 0xc6 });
pub const MFVideoInterlace_Progressive = 2;

/// On a sink writer: let it use the GPU's encoder, and don't hold
/// WriteSample back to the pace of the samples' times.
pub const MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS = guid(0xa634a91c, 0x822b, 0x41b9, .{ 0xa4, 0x94, 0x4d, 0xe4, 0x64, 0x36, 0x12, 0xb0 });
pub const MF_SINK_WRITER_DISABLE_THROTTLING = guid(0x08b845d8, 0x2b74, 0x4afe, .{ 0x9d, 0x53, 0xbe, 0x16, 0xd2, 0xd5, 0xae, 0x4f });

/// Two numbers as the attributes above hold them (MFSetAttributeSize,
/// MFSetAttributeRatio).
pub fn pair(high: u32, low: u32) u64 {
    return @as(u64, high) << 32 | low;
}

/// IMFAttributes: values by GUID.
pub const IAttributes = extern struct {
    vtable: com.VTable,

    pub fn setUINT32(self: *IAttributes, key: *const GUID, value: u32) HRESULT {
        return com.call(self, 21, fn (*const GUID, u32) HRESULT, .{ key, value });
    }

    pub fn setUINT64(self: *IAttributes, key: *const GUID, value: u64) HRESULT {
        return com.call(self, 22, fn (*const GUID, u64) HRESULT, .{ key, value });
    }

    pub fn setGUID(self: *IAttributes, key: *const GUID, value: *const GUID) HRESULT {
        return com.call(self, 24, fn (*const GUID, *const GUID) HRESULT, .{ key, value });
    }
};

/// IMFMediaType: an IMFAttributes that describes a format.
pub const IMediaType = extern struct {
    vtable: com.VTable,

    pub fn attributes(self: *IMediaType) *IAttributes {
        return @ptrCast(self);
    }
};

/// IMFSample: an IMFAttributes with buffers, a time, and a duration, the
/// last two in 100 ns units.
pub const ISample = extern struct {
    vtable: com.VTable,

    pub fn setSampleTime(self: *ISample, time: i64) HRESULT {
        return com.call(self, 36, fn (i64) HRESULT, .{time});
    }

    pub fn setSampleDuration(self: *ISample, duration: i64) HRESULT {
        return com.call(self, 38, fn (i64) HRESULT, .{duration});
    }

    pub fn addBuffer(self: *ISample, buffer: *IMediaBuffer) HRESULT {
        return com.call(self, 42, fn (*IMediaBuffer) HRESULT, .{buffer});
    }
};

/// IMFMediaBuffer.
pub const IMediaBuffer = extern struct {
    vtable: com.VTable,

    pub fn lock(self: *IMediaBuffer, out: *?[*]u8) HRESULT {
        return com.call(self, 3, fn (*?[*]u8, ?*u32, ?*u32) HRESULT, .{ out, null, null });
    }

    pub fn unlock(self: *IMediaBuffer) HRESULT {
        return com.call(self, 4, fn () HRESULT, .{});
    }

    /// How much of it holds data.
    pub fn setCurrentLength(self: *IMediaBuffer, len: u32) HRESULT {
        return com.call(self, 6, fn (u32) HRESULT, .{len});
    }
};

/// IMFSinkWriter: samples in, a file out.
pub const ISinkWriter = extern struct {
    vtable: com.VTable,

    /// A stream of the file, in the format it's stored in.
    pub fn addStream(self: *ISinkWriter, target: *IMediaType, index: *u32) HRESULT {
        return com.call(self, 3, fn (*IMediaType, *u32) HRESULT, .{ target, index });
    }

    /// The format the stream's samples come in: the writer finds what
    /// turns one into the other.
    pub fn setInputMediaType(self: *ISinkWriter, stream: u32, input: *IMediaType) HRESULT {
        return com.call(self, 4, fn (u32, *IMediaType, ?*IAttributes) HRESULT, .{ stream, input, null });
    }

    pub fn beginWriting(self: *ISinkWriter) HRESULT {
        return com.call(self, 5, fn () HRESULT, .{});
    }

    pub fn writeSample(self: *ISinkWriter, stream: u32, sample: *ISample) HRESULT {
        return com.call(self, 6, fn (u32, *ISample) HRESULT, .{ stream, sample });
    }

    /// Encode what's left and close the file. Waits for it.
    pub fn finalize(self: *ISinkWriter) HRESULT {
        return com.call(self, 11, fn () HRESULT, .{});
    }
};
