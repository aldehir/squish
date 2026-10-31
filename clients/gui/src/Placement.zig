//! Where a tab's panes are on screen, from the window's last layout: each
//! pane's frame (its title strip and terminal), its terminal under the
//! strip, the space around the grid in that, and the grid that fits; and
//! the dividers between panes. Made from the tab's tree (`Tab.place`) and
//! the terminal area, and remade whenever either changes, so nothing here
//! outlives a layout: the window draws, hit-tests, and drags against it,
//! and the sessions themselves hold no geometry.
//!
//! The tab shown may have floating tabs over it: their panes, dividers,
//! and corners follow its own, a float's after the one under it, and
//! `floats` says which are whose. Minimized floats aren't placed: the
//! sidebar lists them.
const Placement = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");
const Tab = @import("Tab.zig");
const Daemon = @import("Daemon.zig");
const Rect = @import("renderer/Painter.zig").Rect;

/// The panes shown, in layout order.
panes: std.ArrayList(Pane) = .empty,
/// Between them, in the order `Tab.place` meets them.
dividers: std.ArrayList(Tab.Divider) = .empty,
/// Where dividers meet, dragged to move all of them at once.
corners: std.ArrayList(Corner) = .empty,
/// The floats shown over the tab, bottom to top.
floats: std.ArrayList(Float) = .empty,

/// A float shown over the tab: its box (header and panes), the header
/// that moves it, and where its panes, dividers, and corners start in
/// the lists. Each runs to the next float's start, or the end.
pub const Float = struct {
    tab: *Tab,
    frame: Rect,
    header: Rect,
    panes: usize,
    dividers: usize,
    corners: usize,
};

/// Where the shown tab's own panes, dividers, and corners end: where the
/// first float's start, else the lists' ends.
pub fn hostEnd(self: *const Placement) Float {
    if (self.floats.items.len > 0) return self.floats.items[0];
    return .{ .tab = undefined, .frame = .{}, .header = .{}, .panes = self.panes.items.len, .dividers = self.dividers.items.len, .corners = self.corners.items.len };
}

/// Float `i`'s panes, dividers, and corners.
pub fn floatParts(self: *const Placement, i: usize) struct { panes: []const Pane, dividers: [2]usize, corners: [2]usize } {
    const f = self.floats.items[i];
    const next: ?Float = if (i + 1 < self.floats.items.len) self.floats.items[i + 1] else null;
    const pe = if (next) |n| n.panes else self.panes.items.len;
    return .{
        .panes = self.panes.items[f.panes..pe],
        .dividers = .{ f.dividers, if (next) |n| n.dividers else self.dividers.items.len },
        .corners = .{ f.corners, if (next) |n| n.corners else self.corners.items.len },
    };
}

/// Pixels around a grid, inside its terminal.
pub const Padding = struct { left: u32 = 0, right: u32 = 0, top: u32 = 0, bottom: u32 = 0 };

pub const Pane = struct {
    session: *Session,
    /// The tab it's in: the one shown, or a float over it.
    tab: *Tab,
    /// All of it: its title strip and terminal.
    frame: Rect,
    /// Its terminal, or a browser's page, under the strip (`under`).
    /// Filled in after `Tab.place`, with the rest.
    rect: Rect = .{},
    /// The space around the grid in `rect`: the configured padding, plus
    /// what's left over of a cell at the right and bottom.
    pad: Padding = .{},
    /// The grid that fits.
    cols: u16 = 0,
    rows: u16 = 0,
    /// The font size the pane is drawn at (the window's plus its delta,
    /// clamped), and the cell that size gives, which `cols`/`rows`
    /// divide by. A browser's are the window's.
    size_pt: f32 = 0,
    cell: Session.CellSize = .{ .width = 1, .height = 1 },
};

/// What a pane's `frame` holds under its title strip, `strip` tall: its
/// terminal, or its browser's page.
pub fn under(frame: Rect, strip: f32) Rect {
    const top = @min(strip, frame.h);
    return .{ .x = frame.x, .y = frame.y + top, .w = frame.w, .h = frame.h - top };
}

/// A junction of dividers: one passing through it and one ending at
/// it, or two where dividers on both sides of the first line up.
pub const Corner = struct {
    /// Twice the grip square, centered on the junction.
    rect: Rect,
    /// Indices into `dividers`.
    through: u16,
    ends: [2]?u16,
};

pub fn deinit(self: *Placement, alloc: Allocator) void {
    self.panes.deinit(alloc);
    self.dividers.deinit(alloc);
    self.corners.deinit(alloc);
    self.floats.deinit(alloc);
    self.* = undefined;
}

pub fn clear(self: *Placement) void {
    self.panes.clearRetainingCapacity();
    self.dividers.clearRetainingCapacity();
    self.corners.clearRetainingCapacity();
    self.floats.clearRetainingCapacity();
}

/// Find the corners among the dividers from `first` on: each end of a divider that
/// meets one across it. A divider spans its split, so the one it ends
/// at is an ancestor split's, and the ends from both sides of it only
/// line up by chance. Each is `grip` either way of the junction: the
/// dividers' grip, so it's there to take hold of with no gap.
pub fn findCorners(self: *Placement, alloc: Allocator, first: usize, grip: f32) !void {
    const ds = self.dividers.items;
    const first_corner = self.corners.items.len;
    for (ds[first..], first..) |d, i| {
        const vertical = d.axis() == .row;
        for (ds[first..], first..) |e, j| {
            if (e.axis() == d.axis()) continue;
            // d runs between e's long sides, and an end of it touches e.
            const within = if (vertical)
                d.rect.x >= e.rect.x and d.rect.right() <= e.rect.right()
            else
                d.rect.y >= e.rect.y and d.rect.bottom() <= e.rect.bottom();
            if (!within) continue;
            const touches = if (vertical)
                near(d.rect.y, e.rect.bottom()) or near(d.rect.bottom(), e.rect.y)
            else
                near(d.rect.x, e.rect.right()) or near(d.rect.right(), e.rect.x);
            if (!touches) continue;
            const cx = if (vertical) d.rect.x + d.rect.w / 2 else e.rect.x + e.rect.w / 2;
            const cy = if (vertical) e.rect.y + e.rect.h / 2 else d.rect.y + d.rect.h / 2;
            const rect: Rect = .{ .x = cx - grip, .y = cy - grip, .w = 2 * grip, .h = 2 * grip };
            // The end from the other side of e, if it got here first.
            for (self.corners.items[first_corner..]) |*c| {
                if (c.through == j and near(c.rect.x, rect.x) and near(c.rect.y, rect.y)) {
                    c.ends[1] = @intCast(i);
                    break;
                }
            } else try self.corners.append(alloc, .{ .rect = rect, .through = @intCast(j), .ends = .{ @intCast(i), null } });
        }
    }
}

fn near(a: f32, b: f32) bool {
    return @abs(a - b) < 0.5;
}

/// Where `s` is, if it's shown.
pub fn find(self: *const Placement, s: *const Session) ?*const Pane {
    for (self.panes.items) |*p| {
        if (p.session == s) return p;
    }
    return null;
}

/// The pane at a client position, if one's there: a float's over the
/// tab's, the top float's first.
pub fn at(self: *const Placement, x: f32, y: f32) ?*const Pane {
    var i = self.panes.items.len;
    while (i > 0) {
        i -= 1;
        const p = &self.panes.items[i];
        if (p.frame.contains(x, y)) return p;
    }
    return null;
}

/// The float whose box is at a client position, the top one first.
pub fn floatAt(self: *const Placement, x: f32, y: f32) ?*const Float {
    var i = self.floats.items.len;
    while (i > 0) {
        i -= 1;
        const f = &self.floats.items[i];
        if (f.frame.contains(x, y)) return f;
    }
    return null;
}

/// The pane next to `from` on `side`: of those past that edge and level
/// with it, the nearest, then the one most in line with it.
pub fn neighbor(self: *const Placement, from: *const Session, side: Daemon.Direction) ?*Session {
    const fp = self.find(from) orelse return null;
    const f = fp.frame;
    const along = side == .left or side == .right;
    var best: ?*Session = null;
    var best_gap: f32 = 0;
    var best_off: f32 = 0;
    for (self.panes.items) |p| {
        if (p.session == from or p.tab != fp.tab) continue;
        const r = p.frame;
        const gap = switch (side) {
            .left => f.x - r.right(),
            .right => r.x - f.right(),
            .up => f.y - r.bottom(),
            .down => r.y - f.bottom(),
        };
        if (gap < 0) continue;
        const level = if (along)
            @min(f.bottom(), r.bottom()) - @max(f.y, r.y)
        else
            @min(f.right(), r.right()) - @max(f.x, r.x);
        if (level <= 0) continue;
        const off = if (along) @abs((r.y + r.h / 2) - (f.y + f.h / 2)) else @abs((r.x + r.w / 2) - (f.x + f.w / 2));
        if (best == null or gap < best_gap or (gap == best_gap and off < best_off)) {
            best = p.session;
            best_gap = gap;
            best_off = off;
        }
    }
    return best;
}
