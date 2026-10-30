//! The window's font grids: the one at the configured (or ctrl+plus'd)
//! size every pane uses by default, and one more per other size a pane
//! is drawn at. Same family, DPI, and antialias across all of them: a
//! `Grid` is bound to its size (metrics, shaper, and glyphs), so a pane
//! at another size takes a grid of its own rather than sharing glyphs.
const Grids = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Grid = @import("Grid.zig");

const log = std.log.scoped(.font);

base: Grid,
/// Other sizes, each made the first time a pane asks, and freed once
/// no pane is drawn at it (`retain`). Few: one per distinct size.
extra: std.ArrayList(*Grid) = .empty,

pub fn init(base: Grid) Grids {
    return .{ .base = base };
}

pub fn deinit(self: *Grids) void {
    self.dropExtra();
    self.extra.deinit(self.base.alloc);
    self.base.deinit();
    self.* = undefined;
}

/// Make `grid` the base (a font change in the config). The other sizes
/// are made again from it as they're asked for.
pub fn setBase(self: *Grids, grid: Grid) void {
    self.dropExtra();
    self.base.deinit();
    self.base = grid;
}

fn dropExtra(self: *Grids) void {
    for (self.extra.items) |g| self.destroy(g);
    self.extra.clearRetainingCapacity();
}

fn destroy(self: *Grids, g: *Grid) void {
    g.deinit();
    self.base.alloc.destroy(g);
}

/// The grid at `size_pt`: base when it's base's size, else an extra,
/// made now if missing. A grid that can't be made falls back to base.
pub fn get(self: *Grids, size_pt: f32) *Grid {
    if (size_pt == self.base.size_pt) return &self.base;
    for (self.extra.items) |g| if (g.size_pt == size_pt) return g;
    return self.make(size_pt) catch |err| {
        log.err("a grid at {d}pt failed: {}", .{ size_pt, err });
        return &self.base;
    };
}

fn make(self: *Grids, size_pt: f32) !*Grid {
    const b = &self.base;
    const alloc = b.alloc;
    // Base's family as it found it, so the extra needn't look again.
    const family = try std.unicode.utf16LeToUtf8Alloc(alloc, b.family);
    defer alloc.free(family);
    try self.extra.ensureUnusedCapacity(alloc, 1);
    const g = try alloc.create(Grid);
    errdefer alloc.destroy(g);
    g.* = try .init(alloc, b.io, &.{family}, size_pt, b.dpi, b.antialias);
    self.extra.appendAssumeCapacity(g);
    return g;
}

/// Free the extras at none of `sizes`, the sizes panes are drawn at, and
/// one at base's size, which base draws.
pub fn retain(self: *Grids, sizes: []const f32) void {
    var i: usize = 0;
    while (i < self.extra.items.len) {
        const g = self.extra.items[i];
        if (g.size_pt == self.base.size_pt or std.mem.indexOfScalar(f32, sizes, g.size_pt) == null) {
            self.destroy(g);
            _ = self.extra.swapRemove(i);
        } else i += 1;
    }
}

/// Every grid, at a new DPI.
pub fn setDpi(self: *Grids, dpi: u32) void {
    self.base.setDpi(dpi);
    for (self.extra.items) |g| g.setDpi(dpi);
}

/// Base at a new size (the window's font size). An extra at that size
/// is no pane's now, and goes at the next `retain`.
pub fn setSize(self: *Grids, size_pt: f32) void {
    self.base.setSize(size_pt);
}

test Grids {
    const alloc = std.testing.allocator;
    var grids: Grids = .init(try .init(alloc, std.testing.io, &.{}, 12, 96, .grayscale));
    defer grids.deinit();
    try std.testing.expectEqual(&grids.base, grids.get(12));
    const g = grids.get(14);
    try std.testing.expect(g != &grids.base);
    try std.testing.expectEqual(g, grids.get(14));
    try std.testing.expectEqual(1, grids.extra.items.len);
    try std.testing.expect(g.metrics.cell_height > grids.base.metrics.cell_height);
    try std.testing.expect(g.id != grids.base.id);
    // Kept while a pane is at it, then freed.
    grids.retain(&.{ 12, 14 });
    try std.testing.expectEqual(1, grids.extra.items.len);
    grids.retain(&.{12});
    try std.testing.expectEqual(0, grids.extra.items.len);
    // Base moving onto an extra's size takes its place.
    _ = grids.get(13);
    grids.setSize(13);
    try std.testing.expectEqual(&grids.base, grids.get(13));
    grids.retain(&.{13});
    try std.testing.expectEqual(0, grids.extra.items.len);
}
