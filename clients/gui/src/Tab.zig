//! A row of the sidebar: one or more panes (sessions) laid out in a tree,
//! as slime keeps them (internal/daemon/layout.go). Splits share
//! their space between children by basis points, along a row or down a
//! column; a tab's panes and the dividers between them tile its area
//! (`place`, into a `Placement`).
//!
//! slime owns a split tab's layout: the window asks it to split or close
//! panes and takes the tree it sends back (`fromLayout`). A session that
//! doesn't run in slime is a tab of its own, one pane. Each slime, the
//! local one or a host's, numbers its own tabs.
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");
const Daemon = @import("Daemon.zig");
const Placement = @import("Placement.zig");
const Rect = @import("renderer/Painter.zig").Rect;

/// The window's number for the tab, never reused: what the chrome names
/// it by (`Id.Target.tab`). slime's ids repeat across daemons.
key: u32 = 0,
/// slime's id for the tab, or none for a session of its own.
id: Daemon.TabRef,
/// The daemon whose tab it is, or null for a session of its own.
conn: ?*Daemon = null,
/// slime's id for the workspace it's in, or 0 for a session of its own.
ws: u32 = 0,
root: Node,
/// The pane that gets the keys.
focus: *Session,
/// The pane filling the tab while it's zoomed. The others keep their
/// sizes, out of sight.
zoom: ?*Session = null,
/// The focus and zoom as slime last had them, from its structure or our
/// last `workspace.focus`, so a change here is sent once (Window's
/// syncFocus). Null until slime has said.
sent_focus: ?Daemon.Focus = null,
/// Its panes aren't listed under it in the sidebar.
folded: bool = false,
/// Set while the tab floats over another, from slime's structure: shown
/// over its host rather than in a row of its own. The host is linked
/// anew with each structure (`App.applyStructure`), and a host freed
/// first unlinks its floats (`App.destroyTab`), so it never dangles.
float: ?Floating = null,

/// A floating tab's host and place: `Daemon.Float` with the host found.
pub const Floating = struct {
    host: *Tab,
    /// In basis points of the host's area.
    rect: Daemon.FloatRect,
    minimized: bool = false,
    /// Stacking among the host's floats: higher is on top.
    z: u32 = 0,
};

pub const Axis = Daemon.Axis;

pub const Node = union(enum) {
    pane: *Session,
    split: Split,
};

pub const Split = struct {
    axis: Axis,
    /// Owned by the tab.
    children: []Child,
};

pub const Child = struct {
    /// Of the split's space, as a fraction of the children's total.
    share: u16,
    /// The pane this child's space was split from, as slime sent it
    /// (rpc.Child's From): closing a pane gives its space back that way.
    /// Kept through drags so `toLayout` sends it back.
    from: ?*Session = null,
    node: Node,
};

pub fn create(alloc: Allocator, key: u32, conn: ?*Daemon, ws: u32, id: Daemon.TabRef, root: Node, focus: *Session) !*Tab {
    const self = try alloc.create(Tab);
    self.* = .{ .key = key, .id = id, .conn = conn, .ws = ws, .root = root, .focus = focus };
    return self;
}

/// Free the tab and its tree; its sessions are the caller's.
pub fn destroy(self: *Tab, alloc: Allocator) void {
    freeNode(alloc, self.root);
    alloc.destroy(self);
}

/// Swap in a new tree from slime, keeping focus and zoom on panes still
/// in it. Frees the old tree.
pub fn setRoot(self: *Tab, alloc: Allocator, root: Node) void {
    freeNode(alloc, self.root);
    self.root = root;
    if (!self.contains(self.focus)) self.focus = first(root);
    if (self.zoom) |z| if (!self.contains(z)) {
        self.zoom = null;
    };
}

pub fn freeNode(alloc: Allocator, node: Node) void {
    switch (node) {
        .pane => {},
        .split => |s| {
            for (s.children) |c| freeNode(alloc, c.node);
            alloc.free(s.children);
        },
    }
}

/// The panes, in layout order: left to right, top to bottom.
pub fn iterator(self: *const Tab) Iterator {
    return switch (self.root) {
        .pane => |s| .{ .single = s },
        .split => |sp| it: {
            var it: Iterator = .{};
            it.stack[0] = .{ .children = sp.children };
            it.len = 1;
            break :it it;
        },
    };
}

pub const Iterator = struct {
    single: ?*Session = null,
    /// slime's trees are at most 32 deep.
    stack: [34]struct { children: []const Child, next: usize = 0 } = undefined,
    len: usize = 0,

    pub fn next(self: *Iterator) ?*Session {
        if (self.single) |s| {
            self.single = null;
            return s;
        }
        while (self.len > 0) {
            const top = &self.stack[self.len - 1];
            if (top.next == top.children.len) {
                self.len -= 1;
                continue;
            }
            const c = top.children[top.next];
            top.next += 1;
            switch (c.node) {
                .pane => |s| return s,
                .split => |sp| {
                    if (self.len == self.stack.len) continue;
                    self.stack[self.len] = .{ .children = sp.children };
                    self.len += 1;
                },
            }
        }
        return null;
    }
};

/// The pane showing slime's pane `id`.
pub fn findPane(self: *const Tab, id: Daemon.PaneRef) ?*Session {
    var it = self.iterator();
    while (it.next()) |s| if (s.daemonPane()) |p| if (p.eql(id)) return s;
    return null;
}

/// The pane whose session is `id`.
pub fn findSession(self: *const Tab, id: u32) ?*Session {
    var it = self.iterator();
    while (it.next()) |s| if (s.id == id) return s;
    return null;
}

/// Whether `s` is drawn: every pane is, unless another is zoomed.
pub fn shows(self: *const Tab, s: *const Session) bool {
    return if (self.zoom) |z| z == s else true;
}

/// Output arrived in a pane while the tab wasn't shown.
pub fn activity(self: *const Tab) bool {
    var it = self.iterator();
    while (it.next()) |s| if (s.activity) return true;
    return false;
}

pub fn contains(self: *const Tab, s: *const Session) bool {
    return containsNode(self.root, s);
}

fn containsNode(node: Node, s: *const Session) bool {
    return switch (node) {
        .pane => |p| p == s,
        .split => |sp| for (sp.children) |c| {
            if (containsNode(c.node, s)) break true;
        } else false,
    };
}

pub fn count(self: *const Tab) usize {
    return countNode(self.root);
}

fn countNode(node: Node) usize {
    return switch (node) {
        .pane => 1,
        .split => |sp| n: {
            var n: usize = 0;
            for (sp.children) |c| n += countNode(c.node);
            break :n n;
        },
    };
}

/// The first pane in layout order.
pub fn first(node: Node) *Session {
    return switch (node) {
        .pane => |s| s,
        .split => |sp| first(sp.children[0].node),
    };
}

/// Take `s` out of the tree, as slime will once it hears: its space goes
/// to its heir (`heirOf`), else its siblings share it, and a split left
/// with one child gives way to it. Returns the pane nearest to where it
/// was, to focus, or null if it was the tab's last.
pub fn remove(self: *Tab, alloc: Allocator, s: *const Session) ?*Session {
    if (self.zoom == s) self.zoom = null;
    switch (self.root) {
        .pane => return null,
        .split => {},
    }
    const near = removeNode(alloc, &self.root, s) orelse return null;
    if (self.focus == s) self.focus = near;
    return near;
}

/// slime's removeNode (internal/daemon/layout.go), so the window lays
/// the tab out as slime will.
fn removeNode(alloc: Allocator, root: *Node, s: *const Session) ?*Session {
    const p = parentOf(root, s) orelse return null;
    const sp = p.split;
    const i = p.index;
    const gone = sp.children[i];
    const heir = heirOf(sp, i);
    if (heir) |h| sp.children[h].share +|= gone.share;
    const rest = alloc.alloc(Child, sp.children.len - 1) catch {
        // Leave it in, sharing nothing: slime's tree replaces this one
        // soon.
        sp.children[i].share = 0;
        return first(sp.children[if (i == 0) 1 else i - 1].node);
    };
    @memcpy(rest[0..i], sp.children[0..i]);
    @memcpy(rest[i..], sp.children[i + 1 ..]);
    alloc.free(sp.children);
    sp.children = rest;
    const near = first(rest[if (i == 0) 0 else i - 1].node);
    // What pointed at s points at what took its region.
    if (heir) |h| {
        const c = &rest[if (h > i) h - 1 else h];
        if (c.from == s) {
            // Split from s, it lived in s's region: it takes s's place
            // in the chain.
            c.from = gone.from;
            repoint(root, s, first(c.node));
        } else repoint(root, s, gone.from);
    } else repoint(root, s, gone.from);
    if (rest.len == 1) {
        const only = rest[0].node;
        alloc.free(rest);
        p.node.* = only;
    }
    normalize(root);
    return near;
}

/// The sibling that takes child `i`'s space when its pane closes: the
/// nearest split from it (the one before on a tie), else the one holding
/// the pane it was split from. Null if neither: the siblings share it.
fn heirOf(sp: *const Split, i: usize) ?usize {
    const s = sp.children[i].node.pane;
    var d: usize = 1;
    while (d < sp.children.len) : (d += 1) {
        if (i >= d and sp.children[i - d].from == s) return i - d;
        if (i + d < sp.children.len and sp.children[i + d].from == s) return i + d;
    }
    const from = sp.children[i].from orelse return null;
    for (sp.children, 0..) |c, j| {
        if (j != i and containsNode(c.node, from)) return j;
    }
    return null;
}

/// Make every `from` naming `gone` name `to` instead.
fn repoint(node: *Node, gone: *const Session, to: ?*Session) void {
    switch (node.*) {
        .pane => {},
        .split => |sp| for (sp.children) |*c| {
            if (c.from == gone) c.from = to;
            repoint(&c.node, gone, to);
        },
    }
}

/// Clear every `from` that doesn't name a pane in a sibling's subtree,
/// as slime does: that child's space goes back in proportion instead.
fn normalize(node: *Node) void {
    switch (node.*) {
        .pane => {},
        .split => |sp| for (sp.children, 0..) |*c, i| {
            if (c.from) |from| {
                const beside = for (sp.children, 0..) |o, j| {
                    if (j != i and containsNode(o.node, from)) break true;
                } else false;
                if (!beside) c.from = null;
            }
            normalize(&c.node);
        },
    }
}

/// Where a dragged pane goes.
pub const Place = union(enum) {
    /// Where this pane is, which takes its place.
    swap: *Session,
    /// On `side` of `target`, taking half its space.
    beside: struct { target: *Session, side: Daemon.Direction },
    /// Along the tab's whole `side`, taking half the tab.
    edge: Daemon.Direction,
};

/// Move pane `s` to `to`, and focus it. The tree changes whole or not at
/// all: the move is made on a copy.
pub fn move(self: *Tab, alloc: Allocator, s: *Session, to: Place) !void {
    if (self.count() < 2 or !self.contains(s)) return;
    switch (to) {
        .swap => |t| if (t == s or !self.contains(t)) return,
        .beside => |b| if (b.target == s or !self.contains(b.target)) return,
        .edge => {},
    }
    var root = try cloneNode(alloc, self.root);
    errdefer freeNode(alloc, root);
    switch (to) {
        .swap => |t| {
            const from = leafOf(&root, s).?;
            const into = leafOf(&root, t).?;
            from.* = .{ .pane = t };
            into.* = .{ .pane = s };
            // The slots stay; what named either names whoever is in its
            // region now.
            swapRefs(&root, s, t);
        },
        .beside => |b| {
            try take(alloc, &root, s);
            try insertBeside(alloc, &root, s, b.target, b.side);
        },
        .edge => |side| {
            try take(alloc, &root, s);
            try insertEdge(alloc, &root, s, side);
        },
    }
    normalize(&root);
    freeNode(alloc, self.root);
    self.root = root;
    self.zoom = null;
    self.focus = s;
}

fn swapRefs(node: *Node, a: *Session, b: *Session) void {
    switch (node.*) {
        .pane => {},
        .split => |sp| for (sp.children) |*c| {
            if (c.from == a) c.from = b else if (c.from == b) c.from = a;
            swapRefs(&c.node, a, b);
        },
    }
}

fn cloneNode(alloc: Allocator, node: Node) !Node {
    switch (node) {
        .pane => return node,
        .split => |sp| {
            const children = try alloc.alloc(Child, sp.children.len);
            var made: usize = 0;
            errdefer {
                for (children[0..made]) |c| freeNode(alloc, c.node);
                alloc.free(children);
            }
            for (children, sp.children) |*out, c| {
                out.* = .{ .share = c.share, .from = c.from, .node = try cloneNode(alloc, c.node) };
                made += 1;
            }
            return .{ .split = .{ .axis = sp.axis, .children = children } };
        },
    }
}

/// The leaf holding `s`.
fn leafOf(node: *Node, s: *const Session) ?*Node {
    switch (node.*) {
        .pane => |p| return if (p == s) node else null,
        .split => |*sp| for (sp.children) |*c| {
            if (leafOf(&c.node, s)) |n| return n;
        },
    }
    return null;
}

/// Take `s` out of `root`, which holds another pane too.
fn take(alloc: Allocator, root: *Node, s: *const Session) !void {
    _ = removeNode(alloc, root, s);
    // Removing keeps the pane, with no share, when it can't allocate.
    if (containsNode(root.*, s)) return error.OutOfMemory;
}

/// The split directly holding the leaf of `s`, the node it is, and its
/// index there.
fn parentOf(node: *Node, s: *const Session) ?struct { node: *Node, split: *Split, index: usize } {
    const sp = switch (node.*) {
        .pane => return null,
        .split => |*sp| sp,
    };
    for (sp.children, 0..) |*c, i| switch (c.node) {
        .pane => |p| if (p == s) return .{ .node = node, .split = sp, .index = i },
        .split => if (parentOf(&c.node, s)) |found| return found,
    };
    return null;
}

fn axisOf(side: Daemon.Direction) Axis {
    return if (side == .right or side == .left) .row else .column;
}

fn after(side: Daemon.Direction) bool {
    return side == .right or side == .down;
}

/// `children` with `child` put in at `at`, in a new slice; frees the old.
fn insertChild(alloc: Allocator, sp: *Split, at: usize, child: Child) !void {
    const more = try alloc.alloc(Child, sp.children.len + 1);
    @memcpy(more[0..at], sp.children[0..at]);
    more[at] = child;
    @memcpy(more[at + 1 ..], sp.children[at..]);
    alloc.free(sp.children);
    sp.children = more;
}

/// Put `s` on `side` of `target`: into the split holding it if that runs
/// the same way, sharing its space, else in a new split with it. Like a
/// split, it's from `target`, so closing it gives the space back.
fn insertBeside(alloc: Allocator, root: *Node, s: *Session, target: *Session, side: Daemon.Direction) !void {
    const axis = axisOf(side);
    if (parentOf(root, target)) |p| if (p.split.axis == axis) {
        const t = &p.split.children[p.index];
        const half = @max(1, t.share / 2);
        t.share = @max(1, t.share - half);
        return insertChild(alloc, p.split, if (after(side)) p.index + 1 else p.index, .{ .share = half, .from = target, .node = .{ .pane = s } });
    };
    const leaf = leafOf(root, target).?;
    const kids = try alloc.alloc(Child, 2);
    kids[@intFromBool(!after(side))] = .{ .share = 5000, .node = .{ .pane = target } };
    kids[@intFromBool(after(side))] = .{ .share = 5000, .from = target, .node = .{ .pane = s } };
    leaf.* = .{ .split = .{ .axis = axis, .children = kids } };
}

/// Put `s` along `side` of the whole tree, taking half of it.
fn insertEdge(alloc: Allocator, root: *Node, s: *Session, side: Daemon.Direction) !void {
    const axis = axisOf(side);
    switch (root.*) {
        .split => |*sp| if (sp.axis == axis) {
            var total: u32 = 0;
            for (sp.children) |c| total += c.share;
            const share: u16 = @intCast(@min(total, std.math.maxInt(u16)));
            return insertChild(alloc, sp, if (after(side)) sp.children.len else 0, .{ .share = share, .node = .{ .pane = s } });
        },
        .pane => {},
    }
    const kids = try alloc.alloc(Child, 2);
    kids[@intFromBool(!after(side))] = .{ .share = 5000, .node = root.* };
    kids[@intFromBool(after(side))] = .{ .share = 5000, .node = .{ .pane = s } };
    root.* = .{ .split = .{ .axis = axis, .children = kids } };
}

/// Give each pane its part of `area` as its frame in `p`, replacing what
/// `p` held, with `gap` pixel dividers between them, which the mouse
/// takes hold of `grip` pixels wide where the gap is narrower; a zoomed
/// pane gets all of it. The rest of each pane's placement is the
/// caller's to fill.
pub fn place(self: *Tab, alloc: Allocator, p: *Placement, area: Rect, gap: f32, grip: f32) !void {
    p.clear();
    try self.placeInto(alloc, p, area, gap, grip);
}

/// `place`, adding to what `p` holds: a float's panes after its host's.
/// Corners are found among this tab's dividers alone.
pub fn placeInto(self: *Tab, alloc: Allocator, p: *Placement, area: Rect, gap: f32, grip: f32) !void {
    if (self.zoom) |z| {
        try p.panes.append(alloc, .{ .session = z, .tab = self, .frame = area });
        return;
    }
    const g = @max(gap, grip);
    const first_divider = p.dividers.items.len;
    try placeNode(alloc, p, self, &self.root, area, gap, g);
    try p.findCorners(alloc, first_divider, g);
}

fn placeNode(alloc: Allocator, p: *Placement, tab: *Tab, node: *Node, r: Rect, gap: f32, grip: f32) !void {
    const sp = switch (node.*) {
        .pane => |s| return p.panes.append(alloc, .{ .session = s, .tab = tab, .frame = r }),
        .split => |*sp| sp,
    };
    const row = sp.axis == .row;
    const n: f32 = @floatFromInt(sp.children.len);
    const base = if (row) r.x else r.y;
    const span = @max(0, (if (row) r.w else r.h) - gap * (n - 1));
    var total: u32 = 0;
    for (sp.children) |c| total += c.share;
    var sum: u32 = 0;
    var start: f32 = base;
    for (sp.children, 0..) |*c, i| {
        sum += c.share;
        const last = i == sp.children.len - 1;
        // Ends on whole pixels, from the running total so rounding
        // doesn't add up; the last child takes what's left.
        const frac = if (total == 0) @as(f32, @floatFromInt(i + 1)) / n else @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(total));
        const end = if (last) base + span + gap * (n - 1) else base + @round(span * frac) + gap * @as(f32, @floatFromInt(i));
        const child: Rect = if (row)
            .{ .x = start, .y = r.y, .w = @max(0, end - start), .h = r.h }
        else
            .{ .x = r.x, .y = start, .w = r.w, .h = @max(0, end - start) };
        try placeNode(alloc, p, tab, &c.node, child, gap, grip);
        // The grip, widened about the gap's middle.
        const grab = end + @round((gap - grip) / 2);
        if (!last) try p.dividers.append(alloc, .{
            .rect = if (row)
                .{ .x = end, .y = r.y, .w = gap, .h = r.h }
            else
                .{ .x = r.x, .y = end, .w = r.w, .h = gap },
            .grip = if (row)
                .{ .x = grab, .y = r.y, .w = grip, .h = r.h }
            else
                .{ .x = r.x, .y = grab, .w = r.w, .h = grip },
            .split = sp,
            .index = i,
            .span = span,
        });
        start = end + gap;
    }
}

/// The pane after `from` in layout order, or before it, wrapping.
pub fn following(self: *const Tab, from: *const Session, forward: bool) *Session {
    var it = self.iterator();
    var head: ?*Session = null;
    var prev: ?*Session = null;
    var found = false;
    while (it.next()) |s| {
        if (found) return s;
        if (head == null) head = s;
        if (s == from) {
            if (forward) found = true else if (prev) |p| return p;
        }
        prev = s;
    }
    return if (forward) head.? else prev.?;
}

/// The divider that resizing `s` toward `side` moves, among `dividers`
/// from the last `place`: the nearest on that side of it, across that
/// way, else the nearest on the other.
pub fn dividerFor(self: *const Tab, dividers: []const Divider, s: *const Session, side: Daemon.Direction) ?Divider {
    var found: [2]?DividerAt = .{ null, null };
    _ = dividerIn(&self.root, s, axisOf(side), after(side), &found);
    const at = found[0] orelse found[1] orelse return null;
    for (dividers) |d| {
        if (d.split == at.split and d.index == at.index) return d;
    }
    return null;
}

const DividerAt = struct { split: *const Split, index: usize };

/// Whether `node` holds `s`. On the way back up, fills in the dividers
/// toward that side of it and away, innermost first.
fn dividerIn(node: *const Node, s: *const Session, axis: Axis, toward_after: bool, out: *[2]?DividerAt) bool {
    const sp = switch (node.*) {
        .pane => |p| return p == s,
        .split => |*sp| sp,
    };
    for (sp.children, 0..) |*c, i| {
        if (!dividerIn(&c.node, s, axis, toward_after, out)) continue;
        if (sp.axis != axis) return true;
        const before: ?usize = if (i > 0) i - 1 else null;
        const behind: ?usize = if (i + 1 < sp.children.len) i else null;
        const toward, const away = if (toward_after) .{ behind, before } else .{ before, behind };
        if (out[0] == null) if (toward) |j| {
            out[0] = .{ .split = sp, .index = j };
        };
        if (out[1] == null) if (away) |j| {
            out[1] = .{ .split = sp, .index = j };
        };
        return true;
    }
    return false;
}

/// Share each split's space so the panes across it come out the same
/// size: a child gets as much as the panes side by side in it.
pub fn equalize(self: *Tab) void {
    equalizeNode(&self.root);
}

fn equalizeNode(node: *Node) void {
    const sp = switch (node.*) {
        .pane => return,
        .split => |*sp| sp,
    };
    const total = width(node.*, sp.axis);
    var given: u32 = 0;
    for (sp.children, 0..) |*c, i| {
        equalizeNode(&c.node);
        const share: u32 = if (i + 1 == sp.children.len) 10000 - given else 10000 * width(c.node, sp.axis) / total;
        c.share = @intCast(share);
        given += share;
    }
}

/// How many panes `node` puts side by side along `axis`.
fn width(node: Node, axis: Axis) u32 {
    return switch (node) {
        .pane => 1,
        .split => |sp| n: {
            var n: u32 = 0;
            for (sp.children) |c| {
                const w = width(c.node, axis);
                n = if (sp.axis == axis) n + w else @max(n, w);
            }
            break :n n;
        },
    };
}

/// A gap between two of a split's children, which dragging moves.
/// Points into the tree, so it's good until the tree next changes.
pub const Divider = struct {
    /// The gap between the children: what's drawn as ground.
    rect: Rect,
    /// Where the mouse takes hold of it: `rect`, widened about its
    /// middle to the grip where the gap is narrower.
    grip: Rect,
    split: *Split,
    /// Between children `index` and `index + 1`.
    index: usize,
    /// The split's pixels, gaps aside, which its shares divide.
    span: f32,

    pub fn axis(self: Divider) Axis {
        return self.split.axis;
    }

    /// The shares of the children on either side.
    pub fn shares(self: Divider) [2]u16 {
        return .{ self.split.children[self.index].share, self.split.children[self.index + 1].share };
    }

    /// Move the divider `delta` pixels from where the children's shares
    /// `from` had it, keeping either side at least `min` pixels where
    /// there's room. Only those two children change.
    pub fn drag(self: Divider, from: [2]u16, delta: f32, min: f32) void {
        var total: u32 = 0;
        for (self.split.children) |c| total += c.share;
        if (total == 0 or self.span <= 0) return;
        const pair = @as(u32, from[0]) + from[1];
        if (pair < 2) return;
        const per = self.span / @as(f32, @floatFromInt(total));
        const pair_px = @as(f32, @floatFromInt(pair)) * per;
        const lo = @min(min, pair_px / 2);
        const a_px = std.math.clamp(@as(f32, @floatFromInt(from[0])) * per + delta, lo, pair_px - lo);
        const a: u32 = std.math.clamp(@as(u32, @intFromFloat(@round(a_px / per))), 1, pair - 1);
        self.split.children[self.index].share = @intCast(a);
        self.split.children[self.index + 1].share = @intCast(pair - a);
    }
};

/// The tree as slime's, in `arena`, for sending back after a drag. Null
/// if a pane isn't slime's.
pub fn toLayout(self: *const Tab, arena: Allocator) !?Daemon.Node {
    return toLayoutNode(arena, self.root);
}

fn toLayoutNode(arena: Allocator, node: Node) !?Daemon.Node {
    switch (node) {
        .pane => |s| return .{ .pane = s.daemonPane() orelse return null },
        .split => |sp| {
            const children = try arena.alloc(Daemon.Child, sp.children.len);
            for (children, sp.children) |*out, c| out.* = .{
                .share = c.share,
                .from = if (c.from) |f| f.daemonPane() else null,
                .node = try toLayoutNode(arena, c.node) orelse return null,
            };
            return .{ .split = .{ .axis = sp.axis, .children = children } };
        },
    }
}

/// slime's tree for a tab as one of ours, with each pane's session from
/// `ctx.session(pane)`. Panes without one are left out, and splits that
/// leaves empty or alone collapse. Null if no pane has a session.
pub fn fromLayout(alloc: Allocator, node: Daemon.Node, ctx: anytype) !?Node {
    switch (node) {
        .pane => |id| return if (ctx.session(id)) |s| .{ .pane = s } else null,
        .split => |sp| {
            var kids: std.ArrayList(Child) = .empty;
            errdefer {
                for (kids.items) |c| freeNode(alloc, c.node);
                kids.deinit(alloc);
            }
            for (sp.children) |c| {
                const child = try fromLayout(alloc, c.node, ctx) orelse continue;
                const from = if (c.from) |id| ctx.session(id) else null;
                kids.append(alloc, .{ .share = c.share, .from = from, .node = child }) catch |err| {
                    freeNode(alloc, child);
                    return err;
                };
            }
            switch (kids.items.len) {
                0 => return null,
                1 => {
                    const only = kids.items[0].node;
                    kids.deinit(alloc);
                    return only;
                },
                else => return .{ .split = .{ .axis = sp.axis, .children = try kids.toOwnedSlice(alloc) } },
            }
        },
    }
}

test "placing and removing panes" {
    const alloc = std.testing.allocator;
    var a: Session = undefined;
    var b: Session = undefined;
    var c: Session = undefined;
    // a | (b over c), 75/25.
    const column = try alloc.alloc(Child, 2);
    column[0] = .{ .share = 5000, .node = .{ .pane = &b } };
    column[1] = .{ .share = 5000, .node = .{ .pane = &c } };
    const row = try alloc.alloc(Child, 2);
    row[0] = .{ .share = 7500, .node = .{ .pane = &a } };
    row[1] = .{ .share = 2500, .node = .{ .split = .{ .axis = .column, .children = column } } };
    const tab = try create(alloc, 1, null, 0, .none, .{ .split = .{ .axis = .row, .children = row } }, &c);
    defer tab.destroy(alloc);

    var p: Placement = .{};
    defer p.deinit(alloc);
    try tab.place(alloc, &p, .{ .x = 10, .y = 20, .w = 401, .h = 201 }, 1, 1);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 300, .h = 201 }, p.find(&a).?.frame);
    try std.testing.expectEqual(Rect{ .x = 311, .y = 20, .w = 100, .h = 100 }, p.find(&b).?.frame);
    try std.testing.expectEqual(Rect{ .x = 311, .y = 121, .w = 100, .h = 100 }, p.find(&c).?.frame);
    try std.testing.expectEqual(@as(usize, 3), p.panes.items.len);
    try std.testing.expectEqual(@as(usize, 2), p.dividers.items.len);
    try std.testing.expectEqual(@as(usize, 3), tab.count());
    try std.testing.expectEqual(&b, p.at(350, 50).?.session);
    try std.testing.expect(p.at(5, 50) == null);

    // Dragging the row's divider 100 of its 400 pixels left makes it
    // 50/50; past the minimum, it stops there.
    const d = p.dividers.items[0];
    try std.testing.expectEqual(Axis.row, d.axis());
    const from = d.shares();
    d.drag(from, -100, 50);
    try std.testing.expectEqual([2]u16{ 5000, 5000 }, d.shares());
    d.drag(from, -1000, 50);
    try std.testing.expectEqual([2]u16{ 1250, 8750 }, d.shares());
    d.drag(from, 0, 50);

    // Removing c gives its space to b, which takes the focus, and the
    // column collapses.
    try std.testing.expectEqual(&b, tab.remove(alloc, &c).?);
    try std.testing.expectEqual(&b, tab.focus);
    try std.testing.expect(!tab.contains(&c));
    try tab.place(alloc, &p, .{ .w = 401, .h = 100 }, 1, 1);
    try std.testing.expectEqual(Rect{ .x = 301, .w = 100, .h = 100 }, p.find(&b).?.frame);
    try std.testing.expect(p.find(&c) == null);

    // Zoomed, a is all that's placed.
    tab.zoom = &a;
    try tab.place(alloc, &p, .{ .w = 401, .h = 100 }, 1, 1);
    try std.testing.expectEqual(Rect{ .w = 401, .h = 100 }, p.find(&a).?.frame);
    try std.testing.expectEqual(@as(usize, 1), p.panes.items.len);
    try std.testing.expectEqual(@as(usize, 0), p.dividers.items.len);

    try std.testing.expectEqual(&b, tab.remove(alloc, &a).?);
    try std.testing.expect(tab.zoom == null);
    try std.testing.expect(tab.remove(alloc, &b) == null);
}

test "navigating, resizing, and equalizing panes" {
    const alloc = std.testing.allocator;
    var a: Session = undefined;
    var b: Session = undefined;
    var c: Session = undefined;
    var d: Session = undefined;
    // a | (b over (c | d)).
    const pair = try alloc.alloc(Child, 2);
    pair[0] = .{ .share = 5000, .node = .{ .pane = &c } };
    pair[1] = .{ .share = 5000, .node = .{ .pane = &d } };
    const column = try alloc.alloc(Child, 2);
    column[0] = .{ .share = 5000, .node = .{ .pane = &b } };
    column[1] = .{ .share = 5000, .node = .{ .split = .{ .axis = .row, .children = pair } } };
    const row = try alloc.alloc(Child, 2);
    row[0] = .{ .share = 5000, .node = .{ .pane = &a } };
    row[1] = .{ .share = 5000, .node = .{ .split = .{ .axis = .column, .children = column } } };
    const tab = try create(alloc, 1, null, 0, .none, .{ .split = .{ .axis = .row, .children = row } }, &a);
    defer tab.destroy(alloc);
    var p: Placement = .{};
    defer p.deinit(alloc);
    try tab.place(alloc, &p, .{ .w = 401, .h = 201 }, 1, 1);

    // From a, right is b: b and c touch it and are as far off its middle,
    // and b comes first. From c, up is b, and left is a.
    try std.testing.expectEqual(&b, p.neighbor(&a, .right).?);
    try std.testing.expectEqual(null, p.neighbor(&a, .left));
    try std.testing.expectEqual(&b, p.neighbor(&c, .up).?);
    try std.testing.expectEqual(&a, p.neighbor(&c, .left).?);
    try std.testing.expectEqual(&c, p.neighbor(&b, .down).?);
    try std.testing.expectEqual(&d, p.neighbor(&c, .right).?);

    try std.testing.expectEqual(&b, tab.following(&a, true));
    try std.testing.expectEqual(&a, tab.following(&d, true));
    try std.testing.expectEqual(&d, tab.following(&a, false));
    try std.testing.expectEqual(&c, tab.following(&d, false));

    // Resizing c left moves the divider on its left, the outer row's;
    // right, the one between it and d. d has none on its right, so takes
    // the one on its left.
    const row_split = &tab.root.split;
    const pair_split = &row_split.children[1].node.split.children[1].node.split;
    const dividers = p.dividers.items;
    const left = tab.dividerFor(dividers, &c, .left).?;
    try std.testing.expect(left.split == row_split and left.index == 0);
    const right = tab.dividerFor(dividers, &c, .right).?;
    try std.testing.expect(right.split == pair_split and right.index == 0);
    try std.testing.expect(tab.dividerFor(dividers, &d, .right).?.split == pair_split);
    // b up has only the column's divider below it.
    try std.testing.expectEqual(@as(usize, 0), tab.dividerFor(dividers, &b, .up).?.index);
    try std.testing.expectEqual(null, tab.dividerFor(dividers, &a, .up));

    // a takes half the row's width in panes across: a third.
    tab.equalize();
    try std.testing.expectEqual(@as(u16, 3333), row_split.children[0].share);
    try std.testing.expectEqual(@as(u16, 6667), row_split.children[1].share);
    try std.testing.expectEqual(@as(u16, 5000), pair_split.children[0].share);
}

test "corners are where a divider ends at one across it" {
    const alloc = std.testing.allocator;
    var a: Session = undefined;
    var b: Session = undefined;
    var c: Session = undefined;
    var d: Session = undefined;
    // a | (b over (c | d)): the column's divider ends at the row's, and
    // the pair's at the column's.
    const pair = try alloc.alloc(Child, 2);
    pair[0] = .{ .share = 5000, .node = .{ .pane = &c } };
    pair[1] = .{ .share = 5000, .node = .{ .pane = &d } };
    const column = try alloc.alloc(Child, 2);
    column[0] = .{ .share = 5000, .node = .{ .pane = &b } };
    column[1] = .{ .share = 5000, .node = .{ .split = .{ .axis = .row, .children = pair } } };
    const row = try alloc.alloc(Child, 2);
    row[0] = .{ .share = 5000, .node = .{ .pane = &a } };
    row[1] = .{ .share = 5000, .node = .{ .split = .{ .axis = .column, .children = column } } };
    const tab = try create(alloc, 1, null, 0, .none, .{ .split = .{ .axis = .row, .children = row } }, &a);
    defer tab.destroy(alloc);
    var p: Placement = .{};
    defer p.deinit(alloc);
    try tab.place(alloc, &p, .{ .w = 401, .h = 201 }, 1, 1);

    try std.testing.expectEqual(@as(usize, 3), p.dividers.items.len);
    try std.testing.expectEqual(@as(usize, 2), p.corners.items.len);
    const outer = p.corners.items[0];
    try std.testing.expectEqual(@as(u16, 0), outer.through);
    try std.testing.expectEqual([2]?u16{ 1, null }, outer.ends);
    try std.testing.expectEqual(Rect{ .x = 199.5, .y = 99.5, .w = 2, .h = 2 }, outer.rect);
    const second = p.corners.items[1];
    try std.testing.expectEqual(@as(u16, 1), second.through);
    try std.testing.expectEqual([2]?u16{ 2, null }, second.ends);
    try std.testing.expectEqual(Rect{ .x = 300.5, .y = 99.5, .w = 2, .h = 2 }, second.rect);

    // Dragging the first corner left and down moves the row's divider
    // and the column's, each by its own axis.
    const across = p.dividers.items[outer.through];
    const down = p.dividers.items[outer.ends[0].?];
    across.drag(across.shares(), -100, 50);
    down.drag(down.shares(), 50, 50);
    try std.testing.expectEqual([2]u16{ 2500, 7500 }, across.shares());
    try std.testing.expectEqual([2]u16{ 7500, 2500 }, down.shares());
    try std.testing.expectEqual([2]u16{ 5000, 5000 }, p.dividers.items[2].shares());
}

test "a cross is one corner with an end from each side" {
    const alloc = std.testing.allocator;
    var a: Session = undefined;
    var b: Session = undefined;
    var c: Session = undefined;
    var d: Session = undefined;
    // (a over b) | (c over d), both columns split halfway.
    const left = try alloc.alloc(Child, 2);
    left[0] = .{ .share = 5000, .node = .{ .pane = &a } };
    left[1] = .{ .share = 5000, .node = .{ .pane = &b } };
    const right = try alloc.alloc(Child, 2);
    right[0] = .{ .share = 5000, .node = .{ .pane = &c } };
    right[1] = .{ .share = 5000, .node = .{ .pane = &d } };
    const row = try alloc.alloc(Child, 2);
    row[0] = .{ .share = 5000, .node = .{ .split = .{ .axis = .column, .children = left } } };
    row[1] = .{ .share = 5000, .node = .{ .split = .{ .axis = .column, .children = right } } };
    const tab = try create(alloc, 1, null, 0, .none, .{ .split = .{ .axis = .row, .children = row } }, &a);
    defer tab.destroy(alloc);
    var p: Placement = .{};
    defer p.deinit(alloc);
    try tab.place(alloc, &p, .{ .w = 401, .h = 201 }, 1, 1);

    try std.testing.expectEqual(@as(usize, 1), p.corners.items.len);
    const cross = p.corners.items[0];
    try std.testing.expectEqual(@as(u16, 1), cross.through);
    try std.testing.expectEqual([2]?u16{ 0, 2 }, cross.ends);

    // Zoomed, there are no dividers and so no corners.
    tab.zoom = &a;
    try tab.place(alloc, &p, .{ .w = 401, .h = 201 }, 1, 1);
    try std.testing.expectEqual(@as(usize, 0), p.corners.items.len);
}

test "with no gap, panes abut and the dividers keep a grip" {
    const alloc = std.testing.allocator;
    var a: Session = undefined;
    var b: Session = undefined;
    const row = try alloc.alloc(Child, 2);
    row[0] = .{ .share = 5000, .node = .{ .pane = &a } };
    row[1] = .{ .share = 5000, .node = .{ .pane = &b } };
    const tab = try create(alloc, 1, null, 0, .none, .{ .split = .{ .axis = .row, .children = row } }, &a);
    defer tab.destroy(alloc);
    var p: Placement = .{};
    defer p.deinit(alloc);

    try tab.place(alloc, &p, .{ .w = 400, .h = 200 }, 0, 6);
    try std.testing.expectEqual(p.find(&a).?.frame.right(), p.find(&b).?.frame.x);
    const d = p.dividers.items[0];
    try std.testing.expectEqual(Rect{ .x = 200, .w = 0, .h = 200 }, d.rect);
    try std.testing.expectEqual(Rect{ .x = 197, .w = 6, .h = 200 }, d.grip);

    // A gap at least as wide is its own grip.
    try tab.place(alloc, &p, .{ .w = 410, .h = 200 }, 10, 10);
    try std.testing.expectEqual(p.dividers.items[0].rect, p.dividers.items[0].grip);
}

test "with no gap, corners are where they'd be with one, a grip square" {
    const alloc = std.testing.allocator;
    var sessions: [4]Session = undefined;
    const a = &sessions[0];
    const b = &sessions[1];
    const c = &sessions[2];
    const d = &sessions[3];
    // A T, a | (b over (c | d)), then a cross, (a over b) | (c over d).
    const pair = try alloc.alloc(Child, 2);
    pair[0] = .{ .share = 5000, .node = .{ .pane = c } };
    pair[1] = .{ .share = 5000, .node = .{ .pane = d } };
    const column = try alloc.alloc(Child, 2);
    column[0] = .{ .share = 5000, .node = .{ .pane = b } };
    column[1] = .{ .share = 5000, .node = .{ .split = .{ .axis = .row, .children = pair } } };
    const row = try alloc.alloc(Child, 2);
    row[0] = .{ .share = 5000, .node = .{ .pane = a } };
    row[1] = .{ .share = 5000, .node = .{ .split = .{ .axis = .column, .children = column } } };
    const t = try create(alloc, 1, null, 0, .none, .{ .split = .{ .axis = .row, .children = row } }, a);
    defer t.destroy(alloc);

    const left = try alloc.alloc(Child, 2);
    left[0] = .{ .share = 5000, .node = .{ .pane = a } };
    left[1] = .{ .share = 5000, .node = .{ .pane = b } };
    const right = try alloc.alloc(Child, 2);
    right[0] = .{ .share = 5000, .node = .{ .pane = c } };
    right[1] = .{ .share = 5000, .node = .{ .pane = d } };
    const cross_row = try alloc.alloc(Child, 2);
    cross_row[0] = .{ .share = 5000, .node = .{ .split = .{ .axis = .column, .children = left } } };
    cross_row[1] = .{ .share = 5000, .node = .{ .split = .{ .axis = .column, .children = right } } };
    const plus = try create(alloc, 2, null, 0, .none, .{ .split = .{ .axis = .row, .children = cross_row } }, a);
    defer plus.destroy(alloc);

    for ([_]*Tab{ t, plus }) |tab| {
        var gapped: Placement = .{};
        defer gapped.deinit(alloc);
        try tab.place(alloc, &gapped, .{ .w = 420, .h = 210 }, 10, 10);
        var flush: Placement = .{};
        defer flush.deinit(alloc);
        try tab.place(alloc, &flush, .{ .w = 400, .h = 200 }, 0, 6);

        try std.testing.expectEqual(gapped.corners.items.len, flush.corners.items.len);
        for (gapped.corners.items, flush.corners.items) |g, f| {
            try std.testing.expectEqual(g.through, f.through);
            try std.testing.expectEqual(g.ends, f.ends);
            try std.testing.expectEqual(@as(f32, 12), f.rect.w);
            try std.testing.expectEqual(@as(f32, 12), f.rect.h);
        }
    }
}

test "moving panes" {
    const alloc = std.testing.allocator;
    var a: Session = undefined;
    var b: Session = undefined;
    var c: Session = undefined;
    const row = try alloc.alloc(Child, 3);
    row[0] = .{ .share = 3334, .node = .{ .pane = &a } };
    row[1] = .{ .share = 3333, .node = .{ .pane = &b } };
    row[2] = .{ .share = 3333, .node = .{ .pane = &c } };
    const tab = try create(alloc, 1, null, 0, .none, .{ .split = .{ .axis = .row, .children = row } }, &a);
    defer tab.destroy(alloc);

    // c along the top: a column of c over the rest.
    try tab.move(alloc, &c, .{ .edge = .up });
    try std.testing.expectEqual(Axis.column, tab.root.split.axis);
    try std.testing.expectEqual(&c, tab.root.split.children[0].node.pane);
    try std.testing.expectEqual(@as(usize, 2), tab.root.split.children[1].node.split.children.len);
    try std.testing.expectEqual(&c, tab.focus);

    // a below b: b's leaf becomes a column, and the row collapses.
    try tab.move(alloc, &a, .{ .beside = .{ .target = &b, .side = .down } });
    try std.testing.expectEqual(Axis.column, tab.root.split.axis);
    try std.testing.expectEqual(@as(usize, 3), tab.root.split.children.len);
    try std.testing.expectEqual(&b, tab.root.split.children[1].node.pane);
    try std.testing.expectEqual(&a, tab.root.split.children[2].node.pane);

    // Swapping trades leaves and keeps the shape.
    try tab.move(alloc, &a, .{ .swap = &c });
    try std.testing.expectEqual(&a, tab.root.split.children[0].node.pane);
    try std.testing.expectEqual(&c, tab.root.split.children[2].node.pane);

    // Right of b, in the column: a new row of b and c.
    try tab.move(alloc, &c, .{ .beside = .{ .target = &b, .side = .right } });
    const pair = tab.root.split.children[1].node.split;
    try std.testing.expectEqual(Axis.row, pair.axis);
    try std.testing.expectEqual(&b, pair.children[0].node.pane);
    try std.testing.expectEqual(&c, pair.children[1].node.pane);
    try std.testing.expectEqual(@as(usize, 3), tab.count());
}

test fromLayout {
    const alloc = std.testing.allocator;
    var a: Session = undefined;
    var b: Session = undefined;
    const Ctx = struct {
        a: *Session,
        b: *Session,
        pub fn session(self: @This(), id: Daemon.PaneRef) ?*Session {
            return switch (id.n) {
                1 => self.a,
                2 => self.b,
                else => null,
            };
        }
    };
    const p = struct {
        fn p(n: u32) Daemon.PaneRef {
            return .{ .ws = 1, .tab = 1, .n = n };
        }
    }.p;
    var inner = [_]Daemon.Child{ .{ .share = 5000, .node = .{ .pane = p(2) } }, .{ .share = 5000, .node = .{ .pane = p(3) } } };
    var outer = [_]Daemon.Child{ .{ .share = 5000, .node = .{ .pane = p(1) } }, .{ .share = 5000, .node = .{ .split = .{ .axis = .column, .children = &inner } } } };
    // Pane 3 has no session, so the column gives way to b.
    const root = (try fromLayout(alloc, .{ .split = .{ .axis = .row, .children = &outer } }, Ctx{ .a = &a, .b = &b })).?;
    defer freeNode(alloc, root);
    try std.testing.expectEqual(@as(usize, 2), root.split.children.len);
    try std.testing.expectEqual(&b, root.split.children[1].node.pane);
}

/// Sessions standing for slime's panes 1.1.n, n their index, for tests
/// that go through slime's trees.
const TestPanes = struct {
    sessions: []Session,

    fn init(sessions: []Session) TestPanes {
        for (sessions, 0..) |*s, n| s.transport = .{ .daemon = .{ .conn = undefined, .pane = .{ .ws = 1, .tab = 1, .n = @intCast(n) } } };
        return .{ .sessions = sessions };
    }

    pub fn session(self: TestPanes, id: Daemon.PaneRef) ?*Session {
        return if (id.n < self.sessions.len) &self.sessions[id.n] else null;
    }
};

test "closing a pane gives its space back as slime does" {
    // slime's TestHeirFixtures writes these from its own cases.
    const Fixture = struct { name: []const u8, tree: Daemon.Node, close: Daemon.PaneRef, want: Daemon.Node };
    const alloc = std.testing.allocator;
    var sessions: [8]Session = undefined;
    const panes = TestPanes.init(&sessions);
    const parsed = try std.json.parseFromSlice([]const Fixture, alloc, @embedFile("testdata/heir.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(parsed.value.len > 0);
    for (parsed.value) |f| {
        const root = (try fromLayout(alloc, f.tree, panes)).?;
        const tab = try create(alloc, 1, null, 0, .none, root, first(root));
        defer tab.destroy(alloc);
        _ = tab.remove(alloc, panes.session(f.close).?);
        const got = try std.json.Stringify.valueAlloc(a, (try tab.toLayout(a)).?, .{});
        const want = try std.json.Stringify.valueAlloc(a, f.want, .{});
        std.testing.expectEqualStrings(want, got) catch |err| {
            std.debug.print("case: {s}\n", .{f.name});
            return err;
        };
    }
}

test "a moved pane forgets its origin, and what came from it follows its region" {
    const alloc = std.testing.allocator;
    var a: Session = undefined;
    var b: Session = undefined;
    var c: Session = undefined;
    // A 5000, B 2500, C 2500, C split from B.
    const chain = struct {
        fn chain(al: Allocator, pa: *Session, pb: *Session, pc: *Session) !*Tab {
            const row = try al.alloc(Child, 3);
            row[0] = .{ .share = 5000, .node = .{ .pane = pa } };
            row[1] = .{ .share = 2500, .node = .{ .pane = pb } };
            row[2] = .{ .share = 2500, .from = pb, .node = .{ .pane = pc } };
            return create(al, 1, null, 0, .none, .{ .split = .{ .axis = .row, .children = row } }, pa);
        }
    }.chain;

    {
        // B to the bottom edge: C takes B's place, with B's origin (none).
        const tab = try chain(alloc, &a, &b, &c);
        defer tab.destroy(alloc);
        try tab.move(alloc, &b, .{ .edge = .down });
        const column = tab.root.split;
        try std.testing.expectEqual(Axis.column, column.axis);
        try std.testing.expectEqual(&b, column.children[1].node.pane);
        try std.testing.expect(column.children[1].from == null);
        const row = column.children[0].node.split.children;
        try std.testing.expectEqual(@as(u16, 5000), row[0].share);
        try std.testing.expectEqual(@as(u16, 5000), row[1].share);
        try std.testing.expect(row[1].from == null);
        // Then closing C shares its space over the row: A alone.
        _ = tab.remove(alloc, &c);
        try std.testing.expectEqual(&a, tab.root.split.children[0].node.pane);

        // Back beside C, on its left: from C, so closing it gives C the
        // space, not the layout from before the move.
        const again = try chain(alloc, &a, &b, &c);
        defer again.destroy(alloc);
        try again.move(alloc, &b, .{ .edge = .down });
        try again.move(alloc, &b, .{ .beside = .{ .target = &c, .side = .left } });
        const kids = again.root.split.children;
        try std.testing.expectEqual(@as(usize, 3), kids.len);
        try std.testing.expectEqual(&b, kids[1].node.pane);
        try std.testing.expectEqual(@as(?*Session, &c), kids[1].from);
        try std.testing.expectEqual([3]u16{ 5000, 2500, 2500 }, [3]u16{ kids[0].share, kids[1].share, kids[2].share });
        _ = again.remove(alloc, &b);
        try std.testing.expectEqual([2]u16{ 5000, 5000 }, [2]u16{ again.root.split.children[0].share, again.root.split.children[1].share });
        try std.testing.expectEqual(&c, again.root.split.children[1].node.pane);
    }
    {
        // B beside A, to its left: from A, and closing it gives A its
        // space back.
        const tab = try chain(alloc, &a, &b, &c);
        defer tab.destroy(alloc);
        try tab.move(alloc, &b, .{ .beside = .{ .target = &a, .side = .left } });
        const kids = tab.root.split.children;
        try std.testing.expectEqual(&b, kids[0].node.pane);
        try std.testing.expectEqual(@as(?*Session, &a), kids[0].from);
        try std.testing.expect(kids[1].from == null);
        try std.testing.expectEqual([3]u16{ 2500, 2500, 5000 }, [3]u16{ kids[0].share, kids[1].share, kids[2].share });
        _ = tab.remove(alloc, &b);
        try std.testing.expectEqual([2]u16{ 5000, 5000 }, [2]u16{ tab.root.split.children[0].share, tab.root.split.children[1].share });
        try std.testing.expectEqual(&a, tab.root.split.children[0].node.pane);
    }
    {
        // Swapping B and C swaps what names them: B's slot is from C.
        const tab = try chain(alloc, &a, &b, &c);
        defer tab.destroy(alloc);
        try tab.move(alloc, &b, .{ .swap = &c });
        const kids = tab.root.split.children;
        try std.testing.expectEqual(&c, kids[1].node.pane);
        try std.testing.expectEqual(&b, kids[2].node.pane);
        try std.testing.expectEqual(@as(?*Session, &c), kids[2].from);
        _ = tab.remove(alloc, &b);
        try std.testing.expectEqual([2]u16{ 5000, 5000 }, [2]u16{ tab.root.split.children[0].share, tab.root.split.children[1].share });
    }
}

test "a layout's from goes to slime and back" {
    const alloc = std.testing.allocator;
    var sessions: [4]Session = undefined;
    const panes = TestPanes.init(&sessions);
    const p = struct {
        fn p(n: u32) Daemon.PaneRef {
            return .{ .ws = 1, .tab = 1, .n = n };
        }
    }.p;
    var inner = [_]Daemon.Child{ .{ .share = 5000, .node = .{ .pane = p(2) } }, .{ .share = 5000, .from = p(2), .node = .{ .pane = p(3) } } };
    var outer = [_]Daemon.Child{ .{ .share = 5000, .node = .{ .pane = p(1) } }, .{ .share = 5000, .from = p(1), .node = .{ .split = .{ .axis = .column, .children = &inner } } } };
    const tree: Daemon.Node = .{ .split = .{ .axis = .row, .children = &outer } };
    const root = (try fromLayout(alloc, tree, panes)).?;
    const tab = try create(alloc, 1, null, 0, .none, root, first(root));
    defer tab.destroy(alloc);
    try std.testing.expectEqual(@as(?*Session, &sessions[1]), tab.root.split.children[1].from);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const want = try std.json.Stringify.valueAlloc(a, tree, .{});
    const got = try std.json.Stringify.valueAlloc(a, (try tab.toLayout(a)).?, .{});
    try std.testing.expectEqualStrings(want, got);
}
