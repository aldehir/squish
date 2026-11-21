//! An animated GIF89a writer for a recording: frames of BGRA pixels in,
//! each shown for a time, and the file's bytes out. It loops forever and
//! never dithers (dither speckles flat backgrounds and ruins LZW on
//! text).
//!
//! Each frame after the first is the box of pixels that changed since
//! the last, the unchanged ones inside it transparent, left over the
//! picture before (disposal "leave"), with a color table of its own:
//! exact while the box has few enough colors, which typing does, else
//! a median cut over a 15-bit histogram.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A GIF's sizes are 16 bits.
pub const max_size = 65535;

/// Browsers show a delay under this, in centiseconds, as 100 ms.
const min_delay = 2;

pub const Writer = struct {
    alloc: Allocator,
    width: u16,
    height: u16,
    /// The file's bytes since the last `take`.
    out: std.ArrayList(u8) = .empty,
    /// The last frame given, BGRA: the next one encodes only the box of
    /// pixels that differ from it.
    canvas: []u8,
    /// No frame yet: the first covers the picture, with nothing
    /// transparent.
    first: bool = true,
    /// Milliseconds the delays written so far fall short of the
    /// durations given (or run over, when negative): delays are whole
    /// centiseconds, and the remainder goes into the next.
    carry_ms: i64 = 0,
    /// A frame's pixels as indices into its color table.
    indices: std.ArrayList(u8) = .empty,
    quant: *Quantizer,
    lzw: *Lzw,

    /// The header and the loop extension are written at once.
    pub fn init(alloc: Allocator, width: u16, height: u16) Allocator.Error!Writer {
        std.debug.assert(width > 0 and height > 0);
        const canvas = try alloc.alloc(u8, @as(usize, width) * height * 4);
        errdefer alloc.free(canvas);
        const quant = try alloc.create(Quantizer);
        errdefer alloc.destroy(quant);
        const lzw = try alloc.create(Lzw);
        errdefer alloc.destroy(lzw);
        var self: Writer = .{ .alloc = alloc, .width = width, .height = height, .canvas = canvas, .quant = quant, .lzw = lzw };
        errdefer self.out.deinit(alloc);
        try self.out.appendSlice(alloc, "GIF89a");
        try self.int16(width);
        try self.int16(height);
        // No global table, 8 bits of color resolution; background 0; no
        // aspect ratio.
        try self.out.appendSlice(alloc, &.{ 0x70, 0, 0 });
        // Loop forever.
        try self.out.appendSlice(alloc, "\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00");
        return self;
    }

    pub fn deinit(self: *Writer) void {
        self.out.deinit(self.alloc);
        self.indices.deinit(self.alloc);
        self.alloc.free(self.canvas);
        self.alloc.destroy(self.quant);
        self.alloc.destroy(self.lzw);
        self.* = undefined;
    }

    /// The bytes written since the last call, for the file. Valid until
    /// the next `frame` or `finish`.
    pub fn take(self: *Writer) []const u8 {
        const bytes = self.out.items;
        self.out.items.len = 0;
        return bytes;
    }

    /// A frame, `width * height * 4` bytes of BGRA from the top, shown
    /// for `duration_ms`.
    pub fn frame(self: *Writer, pixels: []const u8, duration_ms: u32) Allocator.Error!void {
        std.debug.assert(pixels.len == self.canvas.len);
        const box = self.changed(pixels) orelse Box{ .x = 0, .y = 0, .w = 1, .h = 1 };
        // Index 0 is the transparent one, but in the first frame.
        const base: u16 = if (self.first) 0 else 1;
        try self.indices.resize(self.alloc, @as(usize, box.w) * box.h);

        var table: [256][3]u8 = undefined;
        const colors = self.exact(pixels, box, base, &table) orelse self.quantize(pixels, box, base, &table);
        var bits: u4 = 1;
        while ((@as(u16, 1) << bits) < colors + base) bits += 1;

        // The graphic control: leave the frame in place, the delay, and
        // the transparent index.
        self.carry_ms += duration_ms;
        const cs: u16 = @intCast(std.math.clamp(@divTrunc(self.carry_ms, 10), min_delay, std.math.maxInt(u16)));
        self.carry_ms -= @as(i64, cs) * 10;
        try self.out.appendSlice(self.alloc, &.{ 0x21, 0xF9, 4, if (self.first) 0x04 else 0x05 });
        try self.int16(cs);
        try self.out.appendSlice(self.alloc, &.{ 0, 0 });
        // The image, with its table.
        try self.out.append(self.alloc, 0x2C);
        try self.int16(box.x);
        try self.int16(box.y);
        try self.int16(box.w);
        try self.int16(box.h);
        try self.out.append(self.alloc, 0x80 | @as(u8, bits - 1));
        const entries = @as(usize, 1) << bits;
        for (0..entries) |i| {
            const c: [3]u8 = if (i >= base and i - base < colors) table[i - base] else .{ 0, 0, 0 };
            try self.out.appendSlice(self.alloc, &c);
        }
        const lit: u4 = @max(2, bits);
        try self.out.append(self.alloc, lit);
        try self.lzw.encode(self.alloc, &self.out, lit, self.indices.items);
        try self.out.append(self.alloc, 0);

        @memcpy(self.canvas, pixels);
        self.first = false;
    }

    /// The trailer: nothing follows.
    pub fn finish(self: *Writer) Allocator.Error!void {
        try self.out.append(self.alloc, 0x3B);
    }

    fn int16(self: *Writer, v: u16) Allocator.Error!void {
        try self.out.appendSlice(self.alloc, &.{ @truncate(v), @truncate(v >> 8) });
    }

    const Box = struct { x: u16, y: u16, w: u16, h: u16 };

    /// The box of pixels in `pixels` that differ from the canvas: all of
    /// the first frame, and null for a frame that changes nothing.
    fn changed(self: *const Writer, pixels: []const u8) ?Box {
        if (self.first) return .{ .x = 0, .y = 0, .w = self.width, .h = self.height };
        const w: usize = self.width;
        const h: usize = self.height;
        var y0: usize = 0;
        while (y0 < h and std.mem.eql(u8, row(pixels, w, y0), row(self.canvas, w, y0))) y0 += 1;
        if (y0 == h) return null;
        var y1: usize = h;
        while (std.mem.eql(u8, row(pixels, w, y1 - 1), row(self.canvas, w, y1 - 1))) y1 -= 1;
        var x0: usize = w;
        var x1: usize = 0;
        for (y0..y1) |y| {
            const a = row(pixels, w, y);
            const b = row(self.canvas, w, y);
            var x: usize = 0;
            while (x < x0 and rgb(a, x) == rgb(b, x)) x += 1;
            x0 = x;
            x = w;
            while (x > x1 and rgb(a, x - 1) == rgb(b, x - 1)) x -= 1;
            x1 = @max(x1, x);
        }
        // Rows that differ only in the byte no one sees.
        if (x1 <= x0) return null;
        return .{ .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
    }

    /// `box`'s indices with a table of its very colors, if they're few
    /// enough: how many, or null, with the indices left half done.
    fn exact(self: *Writer, pixels: []const u8, box: Box, base: u16, table: *[256][3]u8) ?u16 {
        const slots = 1024;
        // A color and its index plus one; 0 for an empty slot.
        var keys: [slots]u32 = undefined;
        var vals: [slots]u16 = @splat(0);
        const most = 256 - base;
        var colors: u16 = 0;
        var last_color: u32 = 0;
        var last_index: u8 = 0;
        var have_last = false;
        const w: usize = self.width;
        var n: usize = 0;
        for (box.y..@as(usize, box.y) + box.h) |y| {
            const a = row(pixels, w, y);
            const b = row(self.canvas, w, y);
            for (box.x..@as(usize, box.x) + box.w) |x| {
                defer n += 1;
                const c = rgb(a, x);
                if (!self.first and c == rgb(b, x)) {
                    self.indices.items[n] = 0;
                    continue;
                }
                if (have_last and c == last_color) {
                    self.indices.items[n] = last_index;
                    continue;
                }
                var slot = (c ^ (c >> 11) ^ (c >> 19)) & (slots - 1);
                while (vals[slot] != 0 and keys[slot] != c) slot = (slot + 1) & (slots - 1);
                if (vals[slot] == 0) {
                    if (colors == most) return null;
                    keys[slot] = c;
                    colors += 1;
                    vals[slot] = colors;
                    table[colors - 1] = .{ @truncate(c >> 16), @truncate(c >> 8), @truncate(c) };
                }
                last_color = c;
                last_index = @intCast(vals[slot] - 1 + base);
                have_last = true;
                self.indices.items[n] = last_index;
            }
        }
        // A table needs a color, even for a box of nothing but
        // transparency.
        if (colors == 0) {
            table[0] = .{ 0, 0, 0 };
            colors = 1;
        }
        return colors;
    }

    /// `box`'s indices with a table cut from its colors' histogram.
    fn quantize(self: *Writer, pixels: []const u8, box: Box, base: u16, table: *[256][3]u8) u16 {
        const q = self.quant;
        q.reset();
        const w: usize = self.width;
        for (box.y..@as(usize, box.y) + box.h) |y| {
            const a = row(pixels, w, y);
            const b = row(self.canvas, w, y);
            for (box.x..@as(usize, box.x) + box.w) |x| {
                const c = rgb(a, x);
                if (self.first or c != rgb(b, x)) q.add(c);
            }
        }
        const colors = q.cut(256 - base, table);
        var n: usize = 0;
        for (box.y..@as(usize, box.y) + box.h) |y| {
            const a = row(pixels, w, y);
            const b = row(self.canvas, w, y);
            for (box.x..@as(usize, box.x) + box.w) |x| {
                const c = rgb(a, x);
                self.indices.items[n] = if (!self.first and c == rgb(b, x)) 0 else @intCast(q.map[Quantizer.bin(c)] + base);
                n += 1;
            }
        }
        return colors;
    }
};

fn row(pixels: []const u8, w: usize, y: usize) []const u8 {
    return pixels[y * w * 4 ..][0 .. w * 4];
}

/// Pixel `x` of a BGRA row as 0xRRGGBB.
fn rgb(r: []const u8, x: usize) u32 {
    return std.mem.readInt(u32, r[x * 4 ..][0..4], .little) & 0xFFFFFF;
}

/// A median cut: the colors counted in 15 bits (five a channel), and
/// the bins split along their longest side at the median, the fullest
/// box first, until there's a box per table entry. A box's color is the
/// mean of the pixels in it.
const Quantizer = struct {
    const bins = 1 << 15;

    count: [bins]u32,
    /// The sums of each bin's pixels, to average.
    sum: [bins][3]u32,
    /// The bins with pixels in them, each box a run of these.
    used: [bins]u16,
    /// Each bin's table entry, after `cut`.
    map: [bins]u8,

    fn reset(self: *Quantizer) void {
        @memset(&self.count, 0);
        @memset(&self.sum, .{ 0, 0, 0 });
    }

    fn bin(c: u32) u16 {
        return @intCast(((c >> 19) & 31) << 10 | ((c >> 11) & 31) << 5 | ((c >> 3) & 31));
    }

    fn add(self: *Quantizer, c: u32) void {
        const i = bin(c);
        self.count[i] += 1;
        self.sum[i][0] += (c >> 16) & 0xFF;
        self.sum[i][1] += (c >> 8) & 0xFF;
        self.sum[i][2] += c & 0xFF;
    }

    const Range = struct { start: u16, end: u16, pixels: u64 };

    /// A bin's place along a channel: the shift that brings its five
    /// bits down.
    fn along(shift: u4, b: u16) u16 {
        return (b >> shift) & 31;
    }

    fn lessAlong(shift: u4, a: u16, b: u16) bool {
        return along(shift, a) < along(shift, b);
    }

    /// Fill `table` with at most `most` colors and `map` with each bin's
    /// entry. Returns how many.
    fn cut(self: *Quantizer, most: u16, table: *[256][3]u8) u16 {
        var n: usize = 0;
        var total: u64 = 0;
        for (self.count, 0..) |c, i| if (c > 0) {
            self.used[n] = @intCast(i);
            n += 1;
            total += c;
        };
        var boxes: [256]Range = undefined;
        boxes[0] = .{ .start = 0, .end = @intCast(n), .pixels = total };
        var nboxes: usize = 1;
        while (nboxes < most) {
            // The fullest box that can still be split.
            var pick: ?usize = null;
            for (boxes[0..nboxes], 0..) |b, i| {
                if (b.end - b.start < 2) continue;
                if (pick == null or b.pixels > boxes[pick.?].pixels) pick = i;
            }
            const i = pick orelse break;
            const b = boxes[i];
            const run = self.used[b.start..b.end];
            // Its longest side; green first among equals, as the eye has
            // it.
            var shift: u4 = 5;
            var longest: u16 = 0;
            for ([_]u4{ 5, 10, 0 }) |s| {
                var lo: u16 = 31;
                var hi: u16 = 0;
                for (run) |u| {
                    lo = @min(lo, along(s, u));
                    hi = @max(hi, along(s, u));
                }
                if (hi - lo > longest) {
                    longest = hi - lo;
                    shift = s;
                }
            }
            std.mem.sort(u16, run, shift, lessAlong);
            // Cut where half its pixels are behind, leaving a bin each
            // side at least.
            var behind: u64 = 0;
            var k: usize = 0;
            while (k < run.len - 1) : (k += 1) {
                behind += self.count[run[k]];
                if (behind * 2 >= b.pixels) break;
            }
            const mid: u16 = b.start + @as(u16, @intCast(@min(k + 1, run.len - 1)));
            var front: u64 = 0;
            for (self.used[b.start..mid]) |u| front += self.count[u];
            boxes[i] = .{ .start = b.start, .end = mid, .pixels = front };
            boxes[nboxes] = .{ .start = mid, .end = b.end, .pixels = b.pixels - front };
            nboxes += 1;
        }
        for (boxes[0..nboxes], 0..) |b, i| {
            var sum: [3]u64 = .{ 0, 0, 0 };
            for (self.used[b.start..b.end]) |u| {
                for (&sum, self.sum[u]) |*s, v| s.* += v;
                self.map[u] = @intCast(i);
            }
            const px = @max(1, b.pixels);
            table[i] = .{ @intCast((sum[0] + px / 2) / px), @intCast((sum[1] + px / 2) / px), @intCast((sum[2] + px / 2) / px) };
        }
        return @intCast(nboxes);
    }
};

/// GIF's LZW: codes that grow from one bit over the literals' width to
/// twelve, least significant bit first, in blocks of at most 255 bytes.
/// The dictionary starts over (a clear code) when its codes run out.
const Lzw = struct {
    const max_code = (1 << 12) - 1;
    const slots = 1 << 14;

    /// A prefix code and a byte (20 bits) over the code for the two; 0
    /// for an empty slot, which no entry is: codes start past the
    /// literals.
    table: [slots]u32,

    const Bits = struct {
        alloc: Allocator,
        out: *std.ArrayList(u8),
        acc: u32 = 0,
        n: u5 = 0,
        /// The block being filled, and where its length goes once it's
        /// full or the data ends.
        block: [255]u8 = undefined,
        len: u8 = 0,

        fn code(self: *Bits, c: u32, width: u5) Allocator.Error!void {
            self.acc |= c << self.n;
            self.n += width;
            while (self.n >= 8) {
                try self.byte(@truncate(self.acc));
                self.acc >>= 8;
                self.n -= 8;
            }
        }

        fn byte(self: *Bits, b: u8) Allocator.Error!void {
            self.block[self.len] = b;
            if (self.len == 254) {
                self.len = 255;
                try self.flush();
            } else self.len += 1;
        }

        fn flush(self: *Bits) Allocator.Error!void {
            if (self.len == 0) return;
            try self.out.append(self.alloc, self.len);
            try self.out.appendSlice(self.alloc, self.block[0..self.len]);
            self.len = 0;
        }

        fn end(self: *Bits) Allocator.Error!void {
            if (self.n > 0) try self.byte(@truncate(self.acc));
            try self.flush();
        }
    };

    fn hash(key: u32) u32 {
        return ((key >> 12) ^ key) & (slots - 1);
    }

    /// `data`'s codes into `out`, as data blocks, without the terminator
    /// that ends them.
    fn encode(self: *Lzw, alloc: Allocator, out: *std.ArrayList(u8), lit: u4, data: []const u8) Allocator.Error!void {
        var bits: Bits = .{ .alloc = alloc, .out = out };
        const clear: u32 = @as(u32, 1) << lit;
        var width: u5 = @as(u5, lit) + 1;
        // The last code given out, and the one that needs another bit.
        var hi: u32 = clear + 1;
        var overflow: u32 = clear << 1;
        @memset(&self.table, 0);
        try bits.code(clear, width);
        if (data.len > 0) {
            var code: u32 = data[0];
            var i: usize = 1;
            // One pass more than the data: the last code goes out as the
            // others do, and the widths move with the decoder's.
            while (i <= data.len) : (i += 1) {
                var key: u32 = 0;
                if (i < data.len) {
                    key = code << 8 | data[i];
                    var slot = hash(key);
                    const found: ?u32 = while (self.table[slot] != 0) : (slot = (slot + 1) & (slots - 1)) {
                        if (self.table[slot] >> 12 == key) break self.table[slot] & max_code;
                    } else null;
                    if (found) |f| {
                        code = f;
                        continue;
                    }
                }
                try bits.code(code, width);
                hi += 1;
                if (hi == overflow) {
                    width += 1;
                    overflow <<= 1;
                }
                if (hi == max_code) {
                    try bits.code(clear, width);
                    width = @as(u5, lit) + 1;
                    hi = clear + 1;
                    overflow = clear << 1;
                    @memset(&self.table, 0);
                } else if (i < data.len) {
                    var slot = hash(key);
                    while (self.table[slot] != 0) slot = (slot + 1) & (slots - 1);
                    self.table[slot] = key << 12 | hi;
                }
                if (i < data.len) code = data[i];
            }
        }
        try bits.code(clear + 1, width);
        try bits.end();
    }
};

/// A decoder for the tests: what a viewer would show after each frame.
const Decoded = struct {
    width: u16,
    height: u16,
    loops: bool,
    trailer: bool,
    frames: []Frame,
    arena: std.heap.ArenaAllocator,

    const Frame = struct {
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        delay_cs: u16,
        /// The whole picture once the frame is drawn, 0xRRGGBB.
        picture: []u32,
    };

    fn deinit(self: *Decoded) void {
        self.arena.deinit();
    }

    fn u16At(b: []const u8, i: usize) u16 {
        return std.mem.readInt(u16, b[i..][0..2], .little);
    }

    fn parse(gpa: Allocator, bytes: []const u8) !Decoded {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        if (!std.mem.eql(u8, bytes[0..6], "GIF89a")) return error.BadHeader;
        const width = u16At(bytes, 6);
        const height = u16At(bytes, 8);
        if (bytes[10] & 0x80 != 0) return error.GlobalTable;
        var i: usize = 13;
        var frames: std.ArrayList(Frame) = .empty;
        const picture = try a.alloc(u32, @as(usize, width) * height);
        @memset(picture, 0);
        var loops = false;
        var trailer = false;
        var delay: u16 = 0;
        var transparent: ?u8 = null;
        while (i < bytes.len) switch (bytes[i]) {
            0x21 => {
                if (bytes[i + 1] == 0xF9) {
                    if (bytes[i + 3] >> 2 & 7 != 1) return error.Disposal;
                    transparent = if (bytes[i + 3] & 1 != 0) bytes[i + 6] else null;
                    delay = u16At(bytes, i + 4);
                } else if (bytes[i + 1] == 0xFF) loops = std.mem.eql(u8, bytes[i + 3 ..][0..11], "NETSCAPE2.0");
                i += 2;
                while (bytes[i] != 0) i += @as(usize, bytes[i]) + 1;
                i += 1;
            },
            0x2C => {
                const x = u16At(bytes, i + 1);
                const y = u16At(bytes, i + 3);
                const w = u16At(bytes, i + 5);
                const h = u16At(bytes, i + 7);
                const flags = bytes[i + 9];
                if (flags & 0x80 == 0) return error.NoLocalTable;
                const entries = @as(usize, 2) << @as(u3, @truncate(flags));
                const table = bytes[i + 10 ..][0 .. entries * 3];
                i += 10 + entries * 3;
                const lit = bytes[i];
                i += 1;
                var data: std.ArrayList(u8) = .empty;
                while (bytes[i] != 0) {
                    try data.appendSlice(a, bytes[i + 1 ..][0..bytes[i]]);
                    i += @as(usize, bytes[i]) + 1;
                }
                i += 1;
                const indices = try unlzw(a, lit, data.items);
                if (indices.len != @as(usize, w) * h) return error.WrongLength;
                for (indices, 0..) |index, n| {
                    if (index >= entries) return error.IndexPastTable;
                    if (transparent != null and transparent.? == index) continue;
                    const c = table[@as(usize, index) * 3 ..][0..3];
                    picture[(y + n / w) * @as(usize, width) + x + n % w] = @as(u32, c[0]) << 16 | @as(u32, c[1]) << 8 | c[2];
                }
                try frames.append(a, .{ .x = x, .y = y, .w = w, .h = h, .delay_cs = delay, .picture = try a.dupe(u32, picture) });
            },
            0x3B => {
                trailer = true;
                i += 1;
                if (i != bytes.len) return error.BytesAfterTrailer;
            },
            else => return error.UnknownBlock,
        };
        return .{ .width = width, .height = height, .loops = loops, .trailer = trailer, .frames = frames.items, .arena = arena };
    }

    fn unlzw(a: Allocator, lit: u8, data: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        const clear: u16 = @as(u16, 1) << @intCast(lit);
        var prefix: [4096]u16 = undefined;
        var suffix: [4096]u8 = undefined;
        var stack: [4096]u8 = undefined;
        var width: u5 = @intCast(lit + 1);
        var next: u16 = clear + 2;
        var prev: ?u16 = null;
        var acc: u32 = 0;
        var nbits: u5 = 0;
        var i: usize = 0;
        while (true) {
            while (nbits < width) {
                if (i == data.len) return error.NoEndCode;
                acc |= @as(u32, data[i]) << nbits;
                nbits += 8;
                i += 1;
            }
            const code: u16 = @intCast(acc & ((@as(u32, 1) << width) - 1));
            acc >>= width;
            nbits -= width;
            if (code == clear) {
                width = @intCast(lit + 1);
                next = clear + 2;
                prev = null;
                continue;
            }
            if (code == clear + 1) break;
            if (code > next or (code == next and prev == null)) return error.BadCode;
            // The string for the code, backwards: for the one not made
            // yet, the last string and its first byte again.
            var n: usize = 0;
            var c = code;
            if (code == next) c = prev.?;
            while (c >= clear) : (c = prefix[c]) {
                stack[n] = suffix[c];
                n += 1;
            }
            const head: u8 = @intCast(c);
            try out.append(a, head);
            while (n > 0) : (n -= 1) try out.append(a, stack[n - 1]);
            if (code == next) try out.append(a, head);
            if (prev) |p| {
                if (next < 4096) {
                    prefix[next] = p;
                    suffix[next] = head;
                }
                next += 1;
                if (next == @as(u32, 1) << width and width < 12) width += 1;
            }
            prev = code;
        }
        if (i != data.len) return error.BytesAfterEnd;
        return out.items;
    }
};

/// A `w` x `h` picture of one color, BGRA.
fn solid(alloc: Allocator, w: usize, h: usize, color: u32) ![]u8 {
    const p = try alloc.alloc(u8, w * h * 4);
    for (0..w * h) |i| set(p, i, color);
    return p;
}

fn set(p: []u8, i: usize, color: u32) void {
    std.mem.writeInt(u32, p[i * 4 ..][0..4], color | 0xFF000000, .little);
}

fn expectPicture(pixels: []const u8, picture: []const u32) !void {
    for (picture, 0..) |c, i| try std.testing.expectEqual(rgb(pixels, i), c);
}

test "round trip: three frames of few colors come back as they went in" {
    const alloc = std.testing.allocator;
    const w = 40;
    const h = 30;
    var gif: Writer = try .init(alloc, w, h);
    defer gif.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);

    const a = try solid(alloc, w, h, 0x282c34);
    defer alloc.free(a);
    for (0..w) |x| set(a, 3 * w + x, if (x % 3 == 0) 0xffffff else 0x98c379);
    const b = try alloc.dupe(u8, a);
    defer alloc.free(b);
    for (10..20) |y| for (5..25) |x| set(b, y * w + x, @intCast(0x100000 * (x % 7) + 0x20 * (y % 5)));
    const c = try alloc.dupe(u8, b);
    defer alloc.free(c);
    // Back to what the first frame had there, and a new color beside it.
    set(c, 12 * w + 8, 0x282c34);
    set(c, 29 * w + 39, 0xe06c75);

    for ([_][]const u8{ a, b, c }) |f| {
        try gif.frame(f, 100);
        try bytes.appendSlice(alloc, gif.take());
    }
    try gif.finish();
    try bytes.appendSlice(alloc, gif.take());

    var d: Decoded = try .parse(alloc, bytes.items);
    defer d.deinit();
    try std.testing.expectEqual(w, d.width);
    try std.testing.expectEqual(h, d.height);
    try std.testing.expect(d.loops);
    try std.testing.expect(d.trailer);
    try std.testing.expectEqual(3, d.frames.len);
    try expectPicture(a, d.frames[0].picture);
    try expectPicture(b, d.frames[1].picture);
    try expectPicture(c, d.frames[2].picture);
    try std.testing.expectEqual(10, d.frames[0].delay_cs);
}

test "a frame that changes one cell writes a box of one cell" {
    const alloc = std.testing.allocator;
    const w = 80;
    const h = 48;
    var gif: Writer = try .init(alloc, w, h);
    defer gif.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);

    const a = try solid(alloc, w, h, 0x000000);
    defer alloc.free(a);
    const b = try alloc.dupe(u8, a);
    defer alloc.free(b);
    // An 8 x 16 cell at column 3, row 1.
    for (16..32) |y| for (24..32) |x| set(b, y * w + x, 0xdcdcdc);
    try gif.frame(a, 50);
    try gif.frame(b, 50);
    // Nothing changed: a frame all the same, to carry its time.
    try gif.frame(b, 50);
    try gif.finish();
    try bytes.appendSlice(alloc, gif.take());

    var d: Decoded = try .parse(alloc, bytes.items);
    defer d.deinit();
    try std.testing.expectEqual(3, d.frames.len);
    const f = d.frames[1];
    try std.testing.expectEqual([4]u16{ 24, 16, 8, 16 }, [4]u16{ f.x, f.y, f.w, f.h });
    try std.testing.expectEqual([2]u16{ 1, 1 }, [2]u16{ d.frames[2].w, d.frames[2].h });
    try expectPicture(b, d.frames[2].picture);
}

test "more than 255 colors quantizes, each pixel near its color" {
    const alloc = std.testing.allocator;
    const w = 32;
    const h = 16;
    var gif: Writer = try .init(alloc, w, h);
    defer gif.deinit();
    const a = try alloc.alloc(u8, w * h * 4);
    defer alloc.free(a);
    // 512 colors.
    for (0..h) |y| for (0..w) |x| set(a, y * w + x, @intCast(x * 8 << 16 | y * 16 << 8));
    // And over it, a frame that changes every pixel but a column, which
    // stays as it was quantized.
    const b = try alloc.dupe(u8, a);
    defer alloc.free(b);
    for (0..h) |y| for (1..w) |x| set(b, y * w + x, @intCast(y * 16 << 16 | x * 8 | 0x4000));
    try gif.frame(a, 20);
    try gif.frame(b, 20);
    try gif.finish();

    var d: Decoded = try .parse(alloc, gif.take());
    defer d.deinit();
    try std.testing.expectEqual(2, d.frames.len);
    // The second's colors don't halve evenly: its boxes are wider.
    for ([_][]const u8{ a, b }, d.frames, [_]u32{ 8, 16 }) |src, f, most| for (f.picture, 0..) |got, i| {
        // The column left alone is as the first frame drew it.
        const want = if (i % w == 0) rgb(a, i) else rgb(src, i);
        for ([_]u5{ 16, 8, 0 }) |shift| {
            const x: i32 = @intCast(got >> shift & 0xFF);
            const y: i32 = @intCast(want >> shift & 0xFF);
            try std.testing.expect(@abs(x - y) <= most);
        }
    };
    try std.testing.expectEqual(d.frames[0].picture[5 * w], d.frames[1].picture[5 * w]);
}

test "delays carry their remainders, and none is under two centiseconds" {
    const alloc = std.testing.allocator;
    var gif: Writer = try .init(alloc, 4, 4);
    defer gif.deinit();
    const colors = [_]u32{ 0x111111, 0x222222, 0x333333, 0x444444, 0x555555, 0x666666 };
    const durations = [_]u32{ 33, 33, 34, 5, 5, 30 };
    for (colors, durations) |c, ms| {
        const p = try solid(alloc, 4, 4, c);
        defer alloc.free(p);
        try gif.frame(p, ms);
    }
    try gif.finish();
    var d: Decoded = try .parse(alloc, gif.take());
    defer d.deinit();
    var got: [6]u16 = undefined;
    for (d.frames, &got) |f, *g| g.* = f.delay_cs;
    // The two short ones take 40 ms where they had 10; the next gives
    // the 30 back, down to the least.
    try std.testing.expectEqualSlices(u16, &.{ 3, 3, 4, 2, 2, 2 }, &got);
}

test "a long frame runs the dictionary out and starts it over" {
    const alloc = std.testing.allocator;
    const w = 200;
    const h = 200;
    var gif: Writer = try .init(alloc, w, h);
    defer gif.deinit();
    const a = try alloc.alloc(u8, w * h * 4);
    defer alloc.free(a);
    // Noise in 200 colors: nothing for LZW to find.
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    for (0..w * h) |i| set(a, i, @as(u32, random.uintLessThan(u32, 200)) * 0x010203);
    try gif.frame(a, 100);
    try gif.finish();
    var d: Decoded = try .parse(alloc, gif.take());
    defer d.deinit();
    try expectPicture(a, d.frames[0].picture);
}
